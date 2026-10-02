/**
 * Tests for the bug report receiver.
 *
 * Run with:  node test-bug-report-worker.mjs
 *
 * These exercise the parts that decide what the developer actually receives. Every assertion
 * here corresponds to a way the receiver could silently do its job wrong: forward a report
 * without the log, cut the log at the one line that mattered, or turn a wrong token into an
 * error the outside can read.
 *
 * The fetch to Telegram is stubbed, so nothing leaves the machine and no secret is needed.
 */

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed++;
    console.log('  ok   ' + name);
  } else {
    failures.push(name + (detail ? ' -- ' + detail : ''));
    console.log('  FAIL ' + name + (detail ? ' -- ' + detail : ''));
  }
}

async function test(name, fn) {
  console.log('\n' + name);
  try {
    await fn();
  } catch (e) {
    failures.push(name + ' threw: ' + e.message);
    console.log('  FAIL ' + name + ' threw: ' + e.message);
  }
}

const worker = (await import('./bug-report-worker.js')).default;

const PATH = 'correct-horse-battery-staple';
const ENV = {
  REPORT_PATH: PATH,
  TELEGRAM_TOKEN: 'test-token',
  TELEGRAM_CHAT_ID: 'test-chat',
};

/** Captures what would have been sent to Telegram, and answers with a chosen status. */
function stubTelegram(status = 200, failDocument = false) {
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const entry = { url: String(url), method: init.method };

    if (String(url).includes('sendDocument')) {
      entry.document = true;
      entry.contentType = (init.headers && init.headers['Content-Type']) || '(set by fetch)';
      if (init.body && typeof init.body.getAll === 'function') {
        const file = init.body.get('document');
        entry.filename = file && file.name;
        entry.caption = init.body.get('caption');
        entry.chatId = init.body.get('chat_id');
        entry.content = file ? await file.text() : '';
      }
      // The caller must not set Content-Type on a multipart body; if it did, Telegram
      // answers 400 and it looks exactly like a bad token.
      if (failDocument) {
        return { ok: false, status: 400, text: async () => 'stubbed document failure' };
      }
    } else {
      entry.document = false;
      entry.body = JSON.parse(init.body);
    }

    sent.push(entry);
    return { ok: status >= 200 && status < 300, status, text: async () => 'stubbed' };
  };
  return { sent, restore: () => { globalThis.fetch = realFetch; } };
}

/**
 * Each test gets its own address.
 *
 * The rate limiter lives in module scope, which in production lasts as long as the isolate and
 * in a test process lasts as long as the run. Without this the reports sent by the earlier tests
 * would count against the quota of the rate limiting test and it would pass or fail depending on
 * how many tests ran before it - the kind of order dependence that makes a suite untrustworthy.
 */
let nextIp = 1;
function post(body, path = '/' + PATH, method = 'POST', ip = null) {
  const headers = { 'Content-Type': 'application/json' };
  headers['CF-Connecting-IP'] = ip || ('10.0.0.' + nextIp++);

  return worker.fetch(
    new Request('https://receiver.example' + path, {
      method,
      headers,
      body: method === 'POST' ? JSON.stringify(body) : undefined,
    }),
    ENV,
  );
}

const LOG = 'ERROR: boom\n\tat com.example.Foo.bar(Foo.java:1)\nat com.example.Baz.qux(Baz.java:2)';
const DESCRIPTION = 'Комментарии не открываются';
const HEAD = 'version:     32.66\ndevice:      box\nandroid:     9';

await test('the report arrives as one message plus a log file', async () => {
  const t = stubTelegram();
  try {
    const res = await post({ head: HEAD, description: DESCRIPTION, log: LOG });

    check('answers 200', res.status === 200, 'got ' + res.status);
    check('exactly two sends: a message and a document',
      t.sent.length === 2, 'got ' + t.sent.length);

    const message = t.sent.find((s) => !s.document);
    const file = t.sent.find((s) => s.document);

    check('the message carries what the user wrote', message.body.text.includes(DESCRIPTION));
    check('the message carries the device block', message.body.text.includes('version:     32.66'));
    check('the message says the log is attached',
      message.body.text.includes('grtubeyou-log.txt'));
    check('the message is short', message.body.text.length < 1000,
      'a summary of ' + message.body.text.length + ' chars is not a summary');

    check('the log is uploaded as a file', !!file);
    check('named grtubeyou-log.txt', file.filename === 'grtubeyou-log.txt', 'got ' + file.filename);
    check('sent to the configured chat', file.chatId === ENV.TELEGRAM_CHAT_ID);
    check('Content-Type left for fetch to set with its boundary',
      file.contentType === '(set by fetch)', 'got ' + file.contentType);
  } finally {
    t.restore();
  }
});

await test('the log file holds the log whole', async () => {
  const t = stubTelegram();
  try {
    const long = Array.from({ length: 900 }, (_, i) => `line ${i} ` + 'x'.repeat(30)).join('\n');
    await post({ head: HEAD, description: '', log: long });

    const file = t.sent.find((s) => s.document);
    check('the file holds every line', file.content.includes('line 0 ') && file.content.includes('line 899 '));
    check('the file is not chunked into messages', t.sent.length === 2,
      'a real log produced ' + t.sent.length + ' sends');
  } finally {
    t.restore();
  }
});

await test('a log-only report still gets a file', async () => {
  const t = stubTelegram();
  try {
    // Most crashes: the user can only say "it broke", and the log is the whole value.
    const res = await post({ head: HEAD, description: '', log: LOG });
    check('answers 200', res.status === 200, 'got ' + res.status);
    check('the file carries the log',
      t.sent.find((s) => s.document).content.includes('Foo.java:1'));
  } finally {
    t.restore();
  }
});

await test('no log means no file, just the message', async () => {
  const t = stubTelegram();
  try {
    const res = await post({ head: HEAD, description: 'no log this time', log: '' });
    check('answers 200', res.status === 200, 'got ' + res.status);
    check('sends only the message', t.sent.length === 1, 'got ' + t.sent.length);
    check('no empty file is attached', !t.sent.some((s) => s.document));
  } finally {
    t.restore();
  }
});

await test('a failed file upload falls back to text, losing nothing', async () => {
  const t = stubTelegram(200, true); // sendDocument answers 400
  try {
    const res = await post({ head: HEAD, description: DESCRIPTION, log: LOG });

    check('still answers 200', res.status === 200, 'got ' + res.status);
    check('it did not give up on the report', t.sent.length >= 2);

    const total = t.sent
      .filter((s) => !s.document)
      .map((s) => s.body.text)
      .join('');
    check('the fallback text carries the log', total.includes('Foo.java:1'));
    check('the fallback text carries the description', total.includes(DESCRIPTION));
    check('the fallback text is chunked under the 4096 limit',
      t.sent.filter((s) => !s.document).every((s) => s.body.text.length <= 4096));
  } finally {
    t.restore();
  }
});

await test('a full-size log is accepted, not refused as too large', async () => {
  const t = stubTelegram();
  try {
    // The app caps its log at 600k characters. If the receiver's body limit sits below what
    // the app builds, every large report comes back 413 and the user is told the log is too
    // big - while the app was told nothing about the limit. These two numbers live in
    // different repositories, so nothing but this test ties them together.
    const big = 'ы'.repeat(600_000); // Cyrillic: 2 UTF-8 bytes per char, the worst case
    const res = await post({ head: HEAD, description: 'big log', log: big });

    check('answers 200', res.status === 200, 'got ' + res.status + ' - the receiver limit is below what the app sends');
    check('the whole log is attached', t.sent.find((s) => s.document).content.length === big.length);
  } finally {
    t.restore();
  }
});

await test('an absurd body is still refused', async () => {
  const res = await post({ head: HEAD, description: 'x', log: 'y'.repeat(17 * 1024 * 1024) });
  check('answers 413', res.status === 413, 'got ' + res.status);
});

await test('no parse_mode, so a log full of markup still sends', async () => {
  const t = stubTelegram();
  try {
    // Underscores and brackets are what break Telegram's markdown parser.
    await post({ head: HEAD, description: '', log: 'a_b_c [d] \\e/ f*g*' });
    const body = t.sent[0].body;
    check('no parse_mode is set', body.parse_mode === undefined, 'got ' + body.parse_mode);
  } finally {
    t.restore();
  }
});

await test('a wrong path is a flat 404, not a 403', async () => {
  const t = stubTelegram();
  try {
    const res = await post({ head: HEAD, description: 'x', log: 'y' }, '/wrong-path');
    // 403 would confirm the endpoint exists and invite a sweep of neighbours.
    check('answers 404', res.status === 404, 'got ' + res.status);
    check('sends nothing', t.sent.length === 0);
  } finally {
    t.restore();
  }
});

await test('a report with neither text nor log is refused', async () => {
  const t = stubTelegram();
  try {
    const res = await post({ head: HEAD, description: '   ', log: '' });
    check('answers 400', res.status === 400, 'got ' + res.status);
    check('sends nothing', t.sent.length === 0, 'an empty report would read as a receiver bug');
  } finally {
    t.restore();
  }
});

await test('malformed JSON is refused, not crashed on', async () => {
  const res = await worker.fetch(
    new Request('https://receiver.example/' + PATH, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '10.0.0.90' },
      body: '{not json',
    }),
    ENV,
  );
  check('answers 400', res.status === 400, 'got ' + res.status);
});

await test('a malformed body does not spend the quota', async () => {
  const t = stubTelegram();
  try {
    // Ten junk requests, then a real report from the same address. Before the limiter moved
    // below the body check, this last one came back 429 and the user was told to try later for
    // no reason they could see.
    const junk = '10.0.0.91';
    for (let i = 0; i < 10; i++) {
      await worker.fetch(
        new Request('https://receiver.example/' + PATH, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': junk },
          body: '{not json',
        }),
        ENV,
      );
    }

    const real = await post({ head: HEAD, description: 'real', log: LOG }, '/' + PATH, 'POST', junk);
    check('a real report is not blocked by junk', real.status === 200, 'got ' + real.status);
  } finally {
    t.restore();
  }
});

await test('GET is not accepted', async () => {
  const res = await post({ head: HEAD, description: 'x', log: 'y' }, '/' + PATH, 'GET');
  check('answers 405', res.status === 405, 'got ' + res.status);
});

await test('a failed forward answers 502', async () => {
  const t = stubTelegram(403); // what Telegram says for a bot not in the chat
  try {
    const res = await post({ head: HEAD, description: 'x', log: 'y' });
    // Not 200: a wrong token must never look like a delivered report.
    check('answers 502', res.status === 502, 'got ' + res.status);
  } finally {
    t.restore();
  }
});

await test('rate limiting stops a script hammering the path', async () => {
  const t = stubTelegram();
  try {
    // One address, hammering it - which is the case the limiter exists for.
    const spammer = '203.0.113.7';
    let limited = 0;
    let accepted = 0;
    for (let i = 0; i < 9; i++) {
      const res = await post({ head: HEAD, description: 'spam ' + i, log: LOG }, '/' + PATH, 'POST', spammer);
      if (res.status === 429) limited++;
      else if (res.status === 200) accepted++;
    }
    check('a hammer does get limited', limited > 0, 'none were');
    // Exactly the limit, not a vague "some": the quota is 5 per hour, so 9 in a row is 5 through
    // and 4 refused. Asserting the exact split catches the quota being changed by accident in
    // either direction - silently raise it and the receiver becomes a spam relay, silently
    // lower it and honest users lose reports.
    check('exactly the quota gets through', accepted === 5, 'accepted ' + accepted);
    check('the rest are refused', limited === 4, 'limited ' + limited);

    // And the limit must not have bled onto a different address.
    const other = await post({ head: HEAD, description: 'a real user', log: LOG });
    check('a different address is unaffected', other.status === 200, 'got ' + other.status);
  } finally {
    t.restore();
  }
});

console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
if (failures.length) {
  console.log('\nfailures:');
  failures.forEach((f) => console.log('  - ' + f));
  process.exit(1);
}