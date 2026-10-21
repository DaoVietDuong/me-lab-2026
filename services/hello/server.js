// hello: the Module 0 push-to-deploy smoke test, and the call chain for Module 1 experiments.
//   GET /        version (git SHA) and the pod that answered
//   GET /chain   calls itself through the Service, `depth` levels deep (M1-05: retries and timeouts):
//                ?depth=3&timeout_ms=300&retries=2            naive: fixed per-try timeout, retry every failure
//                ?depth=3&retries=2&budget_ms=1500             deadline propagation: one budget for the whole chain
//   GET /metrics Prometheus counters
const http = require('node:http');
const os = require('node:os');

const VERSION = process.env.VERSION || 'dev';
const PORT = Number(process.env.PORT || 8080);
const DOWNSTREAM = process.env.DOWNSTREAM || 'http://hello.demo.svc.cluster.local';
const POD = os.hostname();

// ---- metrics (Prometheus text format, no dependencies) ----
const counters = new Map();
function inc(name, labels) {
  const key = name + '{' + Object.entries(labels).map(([k, v]) => `${k}="${v}"`).join(',') + '}';
  counters.set(key, (counters.get(key) || 0) + 1);
}
function metricsText() {
  const lines = [
    '# TYPE hello_requests_total counter',
    '# TYPE hello_downstream_attempts_total counter',
  ];
  for (const [k, v] of counters) lines.push(`${k} ${v}`);
  return lines.join('\n') + '\n';
}

function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'content-type': type });
  res.end(typeof body === 'string' ? body : JSON.stringify(body) + '\n');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function chain(q, headers) {
  const depth = Number(q.get('depth') || 0);
  const retries = Number(q.get('retries') || 0);
  const timeoutMs = Number(q.get('timeout_ms') || 1000);
  const budgetMs = Number(q.get('budget_ms') || 0);

  if (depth <= 0) return { code: 200, body: { pod: POD, depth: 0 } };

  // Deadline propagation: the first hop sets an absolute deadline, every hop below inherits it
  const deadline = budgetMs ? Number(headers['x-deadline-ms'] || Date.now() + budgetMs) : 0;
  const next = new URLSearchParams(q);
  next.set('depth', String(depth - 1));

  let attempts = 0;
  for (let i = 0; i <= retries; i++) {
    let perTry = timeoutMs;
    if (deadline) {
      perTry = deadline - Date.now() - 5;         // keep a little for our own reply
      if (perTry <= 0) break;                      // out of budget: don't start an attempt that can't finish
    }
    attempts++;
    try {
      const r = await fetch(`${DOWNSTREAM}/chain?${next}`, {
        headers: deadline ? { 'x-deadline-ms': String(deadline) } : {},
        signal: AbortSignal.timeout(perTry),
      });
      if (r.ok) {
        inc('hello_downstream_attempts_total', { result: 'ok' });
        return { code: 200, body: { pod: POD, depth, attempts, downstream: await r.json() } };
      }
      inc('hello_downstream_attempts_total', { result: `http_${r.status}` });
      await r.body?.cancel();
    } catch (e) {
      inc('hello_downstream_attempts_total', { result: e.name === 'TimeoutError' ? 'timeout' : 'error' });
    }
    if (deadline) await sleep(10 + Math.random() * 20);   // jittered backoff, only when a budget is managed
  }
  return { code: 504, body: { pod: POD, depth, attempts, error: 'downstream failed' } };
}

async function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/healthz') return send(res, 200, 'ok\n', 'text/plain');
  if (url.pathname === '/metrics') return send(res, 200, metricsText(), 'text/plain; version=0.0.4');
  if (url.pathname === '/chain') {
    const { code, body } = await chain(url.searchParams, req.headers);
    inc('hello_requests_total', { path: '/chain', depth: url.searchParams.get('depth') || '0', code });
    return send(res, code, body);
  }
  inc('hello_requests_total', { path: '/', depth: '', code: 200 });
  send(res, 200, { service: 'hello', version: VERSION, pod: POD, time: new Date().toISOString() });
}

function start(port = PORT) {
  const server = http.createServer((req, res) => {
    handler(req, res).catch((e) => send(res, 500, { error: String(e) }));
  });
  server.listen(port, () => console.log(`hello ${VERSION} listening on :${port}`));
  // Finish in-flight requests on SIGTERM so rolling updates drop nothing
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
  return server;
}

if (require.main === module) start();
module.exports = { handler, start };
