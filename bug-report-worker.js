/**
 * GRTubeYou bug report receiver - Cloudflare Worker.
 *
 * WHY A WORKER AND NOT A WEBHOOK IN THE APK
 * ------------------------------------------
 * Anything shipped inside an APK is extractable. A Telegram bot token, a Discord
 * webhook or a GitHub token embedded in the app can be pulled out by anyone who
 * downloads it, and then used to spam the channel it points at until the credential
 * is rotated. The app therefore carries only a URL - a long random path - and this
 * worker holds the actual secret, as a Worker secret, where it is not distributed.
 *
 * The path is the only thing in the APK, and it is weak authentication on purpose: a
 * 32-character random path is not guessable, is not indexable, and is rotatable by
 * redeploying. Rate limiting is the second layer, because a leaked path should not
 * become a free spam relay even for a moment.
 *
 * WHAT IT DOES
 * ------------
 * POST <path>  with a JSON body -> stored in D1, then forwarded to a Telegram chat as one
 * message plus a log file.
 *
 * The log can be long, so it is split into Telegram-safe chunks rather than truncated:
 * a truncated log is exactly the part that is missing the crash.
 *
 * WHY BOTH D1 AND TELEGRAM
 * -----------------------
 * Forwarding notifies a person. It does not make the report readable by whoever has to fix
 * it: there is no Bot API call that lists a chat's messages, so a report that only went to
 * Telegram existed solely inside a chat window, and getting it out meant a person copying a
 * file out by hand and carrying it somewhere else. That is not a theoretical inconvenience -
 * the first real crash report came in exactly that way and the diagnosis waited on the copy.
 *
 * So the row is written first and the forward second. If the forward fails, the report is
 * already safe and telegram_sent records that nobody was told. If the write fails, the report
 * is still forwarded: storage is a convenience copy, and failing a genuine bug report because
 * the convenience copy could not be written would be a bad trade in both directions.
 *
 * Reading it back is done with the CLI on purpose. An HTTP route that reads this table would
 * be an unauthenticated surface holding crash logs and would need a second secret to be worth
 * anything.
 *
 *   wrangler d1 execute grtubeyou-reports --remote \
 *     --command "SELECT id, received_at, description FROM reports ORDER BY id DESC LIMIT 10"
 *
 *   wrangler d1 execute grtubeyou-reports --remote \
 *     --command "SELECT log FROM reports WHERE id = 7" --json > report.txt
 *
 * SETUP (once, by whoever deploys this)
 * --------------------------------------
 *   1. Create a Telegram bot via @BotFather, copy its token.
 *   2. Add the bot to the chat that should receive reports, and send it one message,
 *      otherwise Telegram rejects the whole chat with 403.
 *   3. Get the chat id:  https://api.telegram.org/bot<TOKEN>/getUpdates
 *   4. Deploy this worker (wrangler deploy).
 *   5. wrangler secret put TELEGRAM_TOKEN     -> the bot token
 *      wrangler secret put TELEGRAM_CHAT_ID   -> the chat id
 *      wrangler secret put REPORT_PATH       -> a random path, e.g.
 *        wrangler secret put REPORT_PATH  and paste 32 chars of noise
 *   6. Put the resulting URL into BugReportSender: ENDPOINT in the app, and build.
 *
 * The path lives in a Worker secret rather than in the code, so it is not readable from
 * the deployed source either. ENDPOINT in the app is the full URL including the path.
 */

/**
 * Largest request body accepted.
 *
 * Must stay above what the app can actually send. The app caps its log at 600k characters,
 * which is up to ~1.8 MB once JSON-escaped and written as UTF-8 - so the original 512 KB
 * limit here would have rejected every large report as "too large" while the app happily
 * built it. 16 MB leaves headroom without being a way to post arbitrary bulk at Telegram.
 */
const MAX_BODY_BYTES = 16 * 1024 * 1024;
const CHUNK = 3500;                  // under Telegram's 4096 limit, with slack
const RATE_LIMIT = 5;                // reports per IP per window
const RATE_WINDOW_MS = 60 * 60 * 1000;

/**
 * Largest log sent as a file, in JS characters.
 *
 * Well under the Bot API's 50 MB document limit on purpose: past this the fallback is plain
 * text messages again, and a log that long is unreadable in a chat either way, so the honest
 * outcome is the chunked one. The app sends a few hundred KB.
 */
const MAX_DOCUMENT_CHARS = 8 * 1024 * 1024;

/**
 * Rate-limit state, kept in module scope rather than hung off `env`.
 *
 * `env` is the bindings object and is not something this worker should be writing to: it is
 * rebuilt per request in some runtimes, and anything stashed on it would be lost unpredictably
 * rather than simply lost on recycle. A module-level Map lives exactly as long as the isolate
 * does, which is the lifetime this limiter actually wants.
 *
 * Pruned on every write, so an isolate that sees many addresses does not grow without bound.
 */
const hitsByIp = new Map();

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // No CORS preflight: the caller is the app, not a browser. Answering OPTIONS would
    // make the path easier to probe from a page.
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 405 });
    }

    // Any path other than the secret one gets a flat 404 - not a 403, because a 403 would
    // confirm the endpoint exists and invite a sweep of neighbouring paths.
    if (url.pathname !== '/' + env.REPORT_PATH) {
      return new Response('Not found', { status: 404 });
    }

    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    let body;
    try {
      const raw = await request.text();
      if (raw.length > MAX_BODY_BYTES) {
        return new Response('Report too large', { status: 413 });
      }
      body = JSON.parse(raw);
    } catch (e) {
      return new Response('Malformed report', { status: 400 });
    }

    if (!body || typeof body !== 'object') {
      return new Response('Malformed report', { status: 400 });
    }

    const report = buildReport(body);
    if (!report) {
      // A report with neither a description nor a log carries nothing to act on, so it is
      // rejected here rather than forwarded as an empty message that looks like a bug in
      // the receiver.
      return new Response('Report is empty', { status: 400 });
    }

    // Rate limiting happens HERE, after the body is known to be a real report, not before.
    // Counting earlier meant a probe or a retry-after-success was charged against the quota,
    // and five malformed requests would lock a genuine user's next report out with a 429 that
    // reads as "you are being rate limited" when in fact nothing had been sent at all.
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (rateLimited(clientIp)) {
      return new Response('Too many reports from this address', { status: 429 });
    }

    // Stored BEFORE forwarding, on purpose. Forwarding is a best-effort courtesy to a person,
    // and if the Telegram call fails the report is exactly the thing that must not be lost -
    // the app gets a 502 and a viewer is told their report did not arrive, so the copy that
    // survives has to already be written.
    const storedId = await storeReport(report, env, clientIp);

    const sent = await sendToTelegram(report, env);

    if (storedId !== null) {
      await markForwarded(env, storedId, sent);
    }

    if (!sent) {
      return new Response('Forwarding failed', { status: 502 });
    }

    return new Response('ok', { status: 200 });
  },
};

/**
 * Largest log written to D1, in JS characters.
 *
 * The app caps its own log at 600k characters, so this holds a real report whole and only ever
 * trims something that arrived from somewhere else.
 *
 * Trimming keeps the TAIL, not the head. A crash is at the end of a log - that is where
 * logcat puts the stack trace - so a report that was shortened from the front keeps the only
 * part anyone needs. log_chars stores the real length either way, and log_truncated says which
 * it was, so a shortened report never looks like a short one.
 */
const MAX_STORED_LOG_CHARS = 600000;

/**
 * Writes the report to D1.
 *
 * Never throws and never fails the request. Two distinct reasons, and the second is the one
 * that matters:
 *
 *   - the binding may be absent, which happens in the tests and in any deployment where the
 *     binding was dropped;
 *   - the write itself may fail - a D1 outage, a too-large value, a missing table.
 *
 * In either case the report is still forwarded and the app is still answered 200. A viewer who
 * hit a crash should never be told their report was lost because a convenience copy of it
 * could not be written, and that is not a hypothetical trade: the whole point of the copy is
 * to be a convenience.
 *
 * @returns the new row id, or null if nothing was stored
 */
async function storeReport(report, env, clientIp) {
  if (!env || !env.REPORTS) {
    console.error('REPORTS binding is not set, report was not stored');
    return null;
  }

  try {
    const full = report.log || '';
    const truncated = full.length > MAX_STORED_LOG_CHARS;
    const log = truncated ? full.slice(full.length - MAX_STORED_LOG_CHARS) : full;

    const row = await env.REPORTS
      .prepare(
        `INSERT INTO reports
           (received_at, path, client_ip, description, head, log, log_chars, log_truncated)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        new Date().toISOString(),
        String(env.REPORT_PATH || ''),
        clientIp || '',
        report.description || '',
        report.head || '',
        log,
        full.length,
        truncated ? 1 : 0,
      )
      .run();

    return row && row.meta && typeof row.meta.last_row_id === 'number'
      ? row.meta.last_row_id
      : null;
  } catch (e) {
    console.error('d1 store failed:', e && e.message);
    return null;
  }
}

/**
 * Records whether the Telegram forward succeeded, once it is known.
 *
 * Best-effort in the same way and for the same reason: the row exists and the report is
 * forwarded, and this is one column on top of that. A viewer who sees 200 and a stored row
 * with telegram_sent = 0 has told us something useful - the forwarding broke and nobody was
 * notified - which is worth a column and not worth an error path.
 */
async function markForwarded(env, rowId, sent) {
  if (!env || !env.REPORTS || rowId === null) {
    return;
  }

  try {
    await env.REPORTS
      .prepare('UPDATE reports SET telegram_sent = ? WHERE id = ?')
      .bind(sent ? 1 : 0, rowId)
      .run();
  } catch (e) {
    console.error('d1 update failed:', e && e.message);
  }
}

/**
 * Splits the report into a short summary and a log.
 *
 * They are handled differently because they want opposite things: the summary is three lines
 * and is read in the chat, the log is tens of thousands of lines and is searched in an
 * editor. Sending both as one text message meant a real report arrived as eighteen chat
 * bubbles - unreadable, and impossible to search for the one line that matters.
 *
 * Field names are fixed here rather than trusted from the body, so a report cannot inject
 * extra headings by sending a field nobody declared.
 *
 * description and head are also returned separately, untouched, because the D1 row stores them
 * in their own columns: a stored row can then be listed and skimmed with one SELECT, and the
 * device block can be matched against, without having to parse a formatted message. The
 * summary is still built for Telegram exactly as before - the split is additive.
 */
function buildReport(body) {
  const head = body.head || '';
  const description = (body.description || '').trim();
  const log = body.log || '';

  if (!description && !log.trim()) {
    return null;
  }

  let summary = 'GRTubeYou bug report\n';
  summary += '=================\n';

  if (description) {
    summary += '\nWhat the user wrote:\n' + description + '\n';
  }

  if (head) {
    summary += '\n' + head + '\n';
  }

  if (log.trim()) {
    // Only the size goes in the message. "400 KB in the attachment" is enough to tell
    // whether the attachment is the whole log or a shortened one.
    summary += `\nLog: ${formatBytes(log.length)}, attached as grtubeyou-log.txt`;
  }

  return { summary, log, description, head };
}

function formatBytes(chars) {
  const bytes = chars * 2; // the report is UTF-16 in JS terms; Telegram counts UTF-8
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function sendToTelegram(report, env) {
  if (!env.TELEGRAM_TOKEN || !env.TELEGRAM_CHAT_ID) {
    // Loud on purpose and in the worker's own log, never to the caller: a wrong token must
    // not be discoverable from outside by probing response codes.
    console.error('TELEGRAM_TOKEN or TELEGRAM_CHAT_ID is not set');
    return false;
  }

  if (!await sendText(report.summary, env)) {
    return false;
  }

  const log = report.log.trim();
  if (!log) {
    return true;
  }

  // The log goes up as a file. A Bot API document upload is capped at 50 MB, and the app
  // sends far less than that, so this is not expected to trip - but if it does, the report
  // still has to arrive, so the text path below is a real fallback rather than a formality.
  if (log.length <= MAX_DOCUMENT_CHARS && await sendLogFile(log, env)) {
    return true;
  }

  console.error('document upload unavailable, falling back to text chunks');
  return sendTextChunks(report.summary + '\n\n----- log -----\n' + log, env);
}

/**
 * Uploads the log as a .txt attachment.
 *
 * No Content-Type is set on purpose: fetch must add it itself together with the multipart
 * boundary, and setting it by hand produces a body Telegram cannot parse - which it answers
 * with a 400 that looks exactly like a bad token.
 */
async function sendLogFile(log, env) {
  const form = new FormData();
  form.append('chat_id', env.TELEGRAM_CHAT_ID);
  form.append('caption', 'Full log');
  form.append(
    'document',
    new Blob([log], { type: 'text/plain; charset=utf-8' }),
    'grtubeyou-log.txt',
  );

  const res = await fetch(
    `https://api.telegram.org/bot${env.TELEGRAM_TOKEN}/sendDocument`,
    { method: 'POST', body: form },
  );

  if (!res.ok) {
    const detail = await res.text();
    console.error('telegram sendDocument failed:', res.status, detail);
    return false;
  }

  return true;
}

async function sendText(text, env) {
  const res = await fetch(
    `https://api.telegram.org/bot${env.TELEGRAM_TOKEN}/sendMessage`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: env.TELEGRAM_CHAT_ID,
        // NO parse_mode: the log is arbitrary application output and may contain
        // underscores, brackets and backslashes, any of which Telegram would reject or
        // mangle. Plain text cannot fail on content.
        text,
        disable_web_page_preview: true,
      }),
    },
  );

  if (!res.ok) {
    const detail = await res.text();
    console.error('telegram sendMessage failed:', res.status, detail);
    return false;
  }

  return true;
}

/**
 * The fallback path only, and only when the file upload is unavailable.
 *
 * Split rather than truncate. A log cut off at a fixed length is likely to lose the
 * exception that caused the report, which is the one line that matters.
 */
async function sendTextChunks(text, env) {
  const chunks = splitForTelegram(text);

  for (let i = 0; i < chunks.length; i++) {
    const part = chunks.length > 1
      ? `(part ${i + 1}/${chunks.length})\n` + chunks[i]
      : chunks[i];

    if (!await sendText(part, env)) {
      return false;
    }
  }

  return true;
}

function splitForTelegram(text) {
  if (text.length <= CHUNK) {
    return [text];
  }

  const chunks = [];

  // Split on newlines so a chunk boundary lands between log lines rather than through the
  // middle of one, which is what makes a split log readable.
  for (let i = 0; i < text.length; i += CHUNK) {
    let piece = text.slice(i, i + CHUNK);

    if (i + CHUNK < text.length) {
      const lastNewline = piece.lastIndexOf('\n');
      if (lastNewline > CHUNK / 2) {
        piece = piece.slice(0, lastNewline);
      }
    }

    chunks.push(piece);
  }

  return chunks;
}

/**
 * Rate limiting, kept in the worker's own isolate memory.
 *
 * Deliberately not durable: it is a speed bump against a script hammering the path, not a
 * quota, and it resets whenever the isolate recycles. Making it durable would need a KV
 * binding and a cost that is not worth it for a channel this size. The consequence is
 * stated rather than hidden - a determined attacker with a rotated path can get through,
 * and the real protection is that the path is not supposed to be public in the first
 * place.
 */
function rateLimited(ip) {
  const now = Date.now();
  const hits = (hitsByIp.get(ip) || []).filter((t) => now - t < RATE_WINDOW_MS);

  if (hits.length >= RATE_LIMIT) {
    hitsByIp.set(ip, hits);
    return true;
  }

  hits.push(now);
  hitsByIp.set(ip, hits);

  // Drop addresses with nothing left in their window. Without this a long-lived isolate
  // accumulates one entry per address it has ever seen.
  if (hitsByIp.size > 1000) {
    for (const [key, times] of hitsByIp) {
      if (!times.length || now - times[times.length - 1] >= RATE_WINDOW_MS) {
        hitsByIp.delete(key);
      }
    }
  }

  return false;
}
