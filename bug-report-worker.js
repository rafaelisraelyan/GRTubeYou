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
 * POST <path>  with a JSON body -> forwards to a Telegram chat as one message.
 * The log can be long, so it is split into Telegram-safe chunks rather than truncated:
 * a truncated log is exactly the part that is missing the crash.
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

const MAX_BODY_BYTES = 512 * 1024;   // Telegram rejects longer messages outright
const CHUNK = 3500;                  // under Telegram's 4096 limit, with slack
const RATE_LIMIT = 5;                // reports per IP per window
const RATE_WINDOW_MS = 60 * 60 * 1000;

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

    const text = buildMessage(body);
    if (!text) {
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

    const sent = await sendToTelegram(text, env);
    if (!sent) {
      return new Response('Forwarding failed', { status: 502 });
    }

    return new Response('ok', { status: 200 });
  },
};

/**
 * Assembles the human-readable report.
 *
 * Field names are fixed here rather than trusted from the body, so a report cannot
 * inject extra headings by sending a field nobody declared.
 */
function buildMessage(body) {
  const head = body.head || '';
  const description = (body.description || '').trim();
  const log = body.log || '';

  if (!description && !log.trim()) {
    return '';
  }

  let text = 'GRTubeYou bug report\n';
  text += '=================\n';

  if (description) {
    text += '\nWhat the user wrote:\n' + description + '\n';
  }

  if (head) {
    text += '\n' + head + '\n';
  }

  if (log.trim()) {
    text += '\n----- log -----\n' + log;
  }

  return text;
}

async function sendToTelegram(text, env) {
  if (!env.TELEGRAM_TOKEN || !env.TELEGRAM_CHAT_ID) {
    // Loud on purpose and in the worker's own log, never to the caller: a wrong token must
    // not be discoverable from outside by probing response codes.
    console.error('TELEGRAM_TOKEN or TELEGRAM_CHAT_ID is not set');
    return false;
  }

  // Split rather than truncate. A log cut off at a fixed length is likely to lose the
  // exception that caused the report, which is the one line that matters.
  const chunks = splitForTelegram(text);

  for (let i = 0; i < chunks.length; i++) {
    const part = chunks.length > 1
      ? `(part ${i + 1}/${chunks.length})\n` + chunks[i]
      : chunks[i];

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
          text: part,
          disable_web_page_preview: true,
        }),
      }
    );

    if (!res.ok) {
      const detail = await res.text();
      console.error('telegram send failed:', res.status, detail);
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
