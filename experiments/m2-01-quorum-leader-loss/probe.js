// M2 probe: exact accounting of publisher confirms, which PerfTest can't give (it reports rates only).
//   node probe.js publish   one line per confirm: "ack <seq> <time>" / "nack <seq> <time>"; "# ..." for events
//   node probe.js fire      fire-and-forget (no confirms): "sent <seq> <time>" once handed to the socket
//   node probe.js drain     one line per message in the queue: "got <seq>"; stops after 3 s without messages
// Body = the sequence number as text. Env: AMQP_URL, QUEUE, N, RATE (msg/s), WINDOW (max unconfirmed),
// OFFSET (first seq - 1, so two publishers on one queue can be told apart; default 0).
// No process.exit(): stdout is a pipe in a container and Node writes it asynchronously, so exiting
// early would drop the last lines (the same trap as psql's buffering in M4-01).
const amqp = require('amqplib');

const { AMQP_URL, QUEUE = 'm2-01', N = '40000', RATE = '500', WINDOW = '100' } = process.env;
const OFFSET = Number(process.env.OFFSET) || 0;
const now = () => new Date().toISOString().slice(11, 23);

async function publish() {
  const conn = await amqp.connect(AMQP_URL);
  const ch = await conn.createConfirmChannel();
  let inflight = 0, sent = 0, acked = 0, nacked = 0, failed = false;
  const waiters = [];
  const wake = () => { const w = waiters.shift(); if (w) w(); };
  const fail = (what) => (err) => {
    if (failed) return;
    failed = true;
    console.log(`# ${what} at ${now()}: ${err ? err.message : ''}`);
    console.log(`# sent ${sent} acked ${acked} nacked ${nacked} unconfirmed ${inflight}`);
    process.exitCode = 1;
    waiters.splice(0).forEach((w) => w());
  };
  conn.on('error', fail('connection error'));
  conn.on('close', fail('connection closed'));
  ch.on('error', fail('channel error'));
  ch.on('close', fail('channel closed'));

  console.log(`# publishing ${N} to ${QUEUE} at ${RATE}/s, window ${WINDOW}, start ${now()}`);
  const gap = 1000 / Number(RATE), start = Date.now();
  for (let seq = 1; seq <= Number(N) && !failed; seq++) {
    while (inflight >= Number(WINDOW) && !failed) await new Promise((r) => waiters.push(r));
    const due = start + seq * gap - Date.now();
    if (due > 0) await new Promise((r) => setTimeout(r, due));
    if (failed) break;
    inflight++; sent++;
    const id = OFFSET + seq;
    ch.sendToQueue(QUEUE, Buffer.from(String(id)), { persistent: true }, (err) => {
      inflight--;
      if (err) { nacked++; console.log(`nack ${id} ${now()}`); } else { acked++; console.log(`ack ${id} ${now()}`); }
      wake();
    });
  }
  while (inflight > 0 && !failed) await new Promise((r) => waiters.push(r));
  if (!failed) {
    console.log(`# done ${now()} sent ${sent} acked ${acked} nacked ${nacked}`);
    failed = true;   // a close from here on is ours
    await conn.close();
  }
}

// Same pacing as publish(), but on a plain channel: the client never learns what the broker kept
async function fire() {
  const conn = await amqp.connect(AMQP_URL);
  const ch = await conn.createChannel();
  let sent = 0, failed = false;
  const fail = (what) => (err) => {
    if (failed) return;
    failed = true;
    console.log(`# ${what} at ${now()}: ${err ? err.message : ''}`);
    console.log(`# sent ${sent}`);
    process.exitCode = 1;
  };
  conn.on('error', fail('connection error'));
  conn.on('close', fail('connection closed'));
  ch.on('error', fail('channel error'));
  ch.on('close', fail('channel closed'));

  console.log(`# firing ${N} to ${QUEUE} at ${RATE}/s, no confirms, start ${now()}`);
  const gap = 1000 / Number(RATE), start = Date.now();
  for (let seq = 1; seq <= Number(N) && !failed; seq++) {
    const due = start + seq * gap - Date.now();
    if (due > 0) await new Promise((r) => setTimeout(r, due));
    if (failed) break;
    const id = OFFSET + seq;
    ch.sendToQueue(QUEUE, Buffer.from(String(id)), { persistent: true });
    sent++;
    console.log(`sent ${id} ${now()}`);
  }
  if (!failed) {
    console.log(`# done ${now()} sent ${sent}`);
    failed = true;
    await conn.close();
  }
}

async function drain() {
  const conn = await amqp.connect(AMQP_URL);
  const ch = await conn.createChannel();
  await ch.prefetch(1000);
  let got = 0, last = Date.now();
  await ch.consume(QUEUE, (m) => {
    got++; last = Date.now();
    console.log(`got ${m.content.toString()}${m.fields.redelivered ? ' redelivered' : ''}`);
    ch.ack(m);
  });
  while (Date.now() - last < 3000) await new Promise((r) => setTimeout(r, 500));
  console.log(`# drained ${got}`);
  await conn.close();
}

({ drain, fire }[process.argv[2]] || publish)().catch((err) => {
  console.log(`# fatal at ${now()}: ${err.message}`);
  process.exitCode = 2;
});
