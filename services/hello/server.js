// hello: the Module 0 push-to-deploy smoke test.
// Answers with its version (the git SHA it was built from) and the pod that served the request,
// so a rollout is visible from outside: curl it while you push.
const http = require('node:http');
const os = require('node:os');

const VERSION = process.env.VERSION || 'dev';
const PORT = Number(process.env.PORT || 8080);

function handler(req, res) {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end('ok\n');
  }
  const body = {
    service: 'hello',
    version: VERSION,
    pod: os.hostname(),
    time: new Date().toISOString(),
  };
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body) + '\n');
}

function start(port = PORT) {
  const server = http.createServer(handler);
  server.listen(port, () => console.log(`hello ${VERSION} listening on :${port}`));
  // Finish in-flight requests on SIGTERM so rolling updates drop nothing
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
  return server;
}

if (require.main === module) start();
module.exports = { handler, start };
