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
function stubTelegram(status = 200) {
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    sent.push({ url: String(url), body: JSON.parse(init.body) });
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

await test('the report reaches Telegram intact', async () => {
  const t = stubTelegram();
  try {
    const res = await post({ head: HEAD, description: DESCRIPTION, log: LOG });
    const text = t.sent[0].body.text;

    check('answers 200', res.status === 200, 'got ' + res.status);
    check('sends exactly one message', t.sent.length === 1, 'got ' + t.sent.length);
    check('carries what the user wrote', text.includes(DESCRIPTION));
    check('carries the device block', text.includes('version:     32.66'));
    check('carries the log', text.includes('at com.example.Foo.bar(Foo.java:1)'));
    check('keeps the log tail', text.includes('Baz.java:2'), 'the last line is the important one');
  } finally {
    t.restore();
  }
});

await test('the log is split, never truncated', async () => {
  const t = stubTelegram();
  try {
    // 20k of log: enough to exceed one Telegram message.
    const long = Array.from({ length: 900 }, (_, i) => `line ${i} ` + 'x'.repeat(30)).join('\n');
    await post({ head: HEAD, description: '', log: long });

    const total = t.sent.map((m) => m.body.text).join('');
    check('split into several messages', t.sent.length > 1, 'got ' + t.sent.length);
    check('nothing lost', total.includes('line 0 ') && total.includes('line 899 '));
    check('every chunk is under Telegram\'s 4096 limit',
      t.sent.every((m) => m.body.text.length <= 4096),
      'longest ' + Math.max(...t.sent.map((m) => m.body.text.length)));
    check('chunks are labelled so order is readable',
      t.sent.some((m) => m.body.text.includes('(part 1/')),
      'a split log with no labels cannot be read in order');
  } finally {
    t.restore();
  }
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

await test('a log-only report is accepted', async () => {
  const t = stubTelegram();
  try {
    // Most crashes: the user can only say "it broke", and the log is the whole value.
    const res = await post({ head: HEAD, description: '', log: LOG });
    check('answers 200', res.status === 200, 'got ' + res.status);
    check('still forwards the log', t.sent[0].body.text.includes('Foo.java:1'));
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