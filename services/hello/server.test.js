const test = require('node:test');
const assert = require('node:assert');
const { start } = require('./server');

test('serves version and health', async (t) => {
  const server = start(0);
  t.after(() => server.close());
  await new Promise((r) => server.once('listening', r));
  const base = `http://127.0.0.1:${server.address().port}`;

  const health = await fetch(`${base}/healthz`);
  assert.strictEqual(health.status, 200);

  const body = await (await fetch(`${base}/`)).json();
  assert.strictEqual(body.service, 'hello');
  assert.ok(body.version);
  assert.ok(body.pod);
});
