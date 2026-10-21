const test = require('node:test');
const assert = require('node:assert');

// The chain calls DOWNSTREAM; point it at this test server before loading the module
const server = require('node:http').createServer();
let base;

test('hello', async (t) => {
  await new Promise((r) => server.listen(0, r));
  base = `http://127.0.0.1:${server.address().port}`;
  process.env.DOWNSTREAM = base;
  const { handler } = require('./server');
  server.on('request', handler);
  t.after(() => { server.closeAllConnections(); server.close(); });

  await t.test('serves version and health', async () => {
    assert.strictEqual((await fetch(`${base}/healthz`)).status, 200);
    const body = await (await fetch(`${base}/`)).json();
    assert.strictEqual(body.service, 'hello');
    assert.ok(body.version && body.pod);
  });

  await t.test('chain recurses to depth 0', async () => {
    const body = await (await fetch(`${base}/chain?depth=2&timeout_ms=2000`)).json();
    assert.strictEqual(body.depth, 2);
    assert.strictEqual(body.downstream.depth, 1);
    assert.strictEqual(body.downstream.downstream.depth, 0);
  });

  await t.test('budget exhausted gives 504 without attempts', async () => {
    const r = await fetch(`${base}/chain?depth=1&budget_ms=1`, { headers: { 'x-deadline-ms': String(Date.now() - 1) } });
    assert.strictEqual(r.status, 504);
    assert.strictEqual((await r.json()).attempts, 0);
  });

  await t.test('metrics count chain requests', async () => {
    const text = await (await fetch(`${base}/metrics`)).text();
    assert.match(text, /hello_requests_total\{path="\/chain",depth="0",code="200"\} \d+/);
    assert.match(text, /hello_downstream_attempts_total\{result="ok"\} \d+/);
  });
});
