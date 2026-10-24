# M2-01 — Lose the quorum-queue leader (publisher confirms)

**Date:** 2026-10-23 · **Module:** 2 RabbitMQ · **Status:** done

## Hypothesis

A quorum queue on 3 RabbitMQ nodes, with a publisher using confirms (max 100 unconfirmed) at 500 msg/s:
1. Losing the leader triggers a Raft election. Confirms block for a few seconds, then resume on the new leader.
2. No confirmed message is lost: a confirm is only sent once a majority has the message.
3. Messages left unconfirmed by the failure may be duplicated or missing, but they were never promised.

## Setup

- RabbitMQ Cluster Operator 2.23.1, RabbitMQ 4.3.7 (Erlang/OTP 27), 3 nodes, one per lab node, 512 Mi each, `pause_minority` (later found to be ignored, see M2-02), quorum as the default queue type.
- Queue `m2-01` (quorum, 3 members) declared through server-0's HTTP API, so its leader starts on server-0 (quorum queue leaders are placed `client-local`).
- `probe.js` (Node 24, amqplib 2.2.0) publishes `seq` 1..n through **server-1** (never the leader), and logs every `ack`/`nack` with its sequence number. A second run of it **drains** the queue and lists every message. **Lost = confirmed but not in the queue**, compared by sequence number.
- amqplib is fetched on the host from the npm registry and checked against its published sha512, then shipped as a ConfigMap. The lab spoke can't reach npm (hub firewall default deny), and that's on purpose.

## Fault / action

`./run.sh experiment <none|delete|kill|freeze> [n]`: 20 s of publishing, then the fault on the leader:

- **delete**: `kubectl delete pod` (graceful shutdown).
- **kill**: Chaos Mesh pod-kill, grace 0 (SIGKILL).
- **freeze**: `SIGSTOP` on the leader's Erlang VM for 60 s, sent **from the node**. Inside the container, beam.smp is PID 1, and the kernel ignores SIGSTOP sent to a namespace's init from inside it. A frozen process keeps its sockets open, so peers get no FIN or RST: a hung node, a long pause, a stalled VM.

## Observed

| Run | Fault on leader server-0 | New leader | Longest pause in confirms | Confirmed | **Lost** | Duplicates | Unconfirmed but in queue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | none | — | 16 ms | 10,000 / 10,000 | **0** | 0 | 0 |
| delete | graceful | server-2 | **88 ms** | 40,000 / 40,000 | **0** | 0 | 0 |
| kill | SIGKILL | server-2 | **95 ms** | 40,000 / 40,000 | **0** | 0 | 0 |
| freeze | SIGSTOP 60 s | server-2, **+6.9 s** (Ra log) | **6,548 ms** | 40,000 / 40,000 | **0** | 0 | 0 |

"Longest pause" is measured in the publisher's log, from 1 s before the fault to 15 s after. delete and kill show nothing beyond normal jitter. The longest gaps of those runs (182 / 365 ms) came near the end, away from the fault.

The freeze, from server-2's log:

| t | Event |
| --- | --- |
| 0 s (17:30:12.3) | server-0 frozen; confirms stop |
| **+6.9 s** | `'m2-01': candidate -> leader in term: 2`: **Raft** (Ra's failure detector) elected server-2; confirms resume |
| +6.9 … 60 s | Publishing at full rate on the new leader. The rest of the cluster still thinks server-0 is up |
| **+60.5 s** | `node 'rabbit@rmq-lab-server-0' down: net_tick_timeout`: **Erlang distribution** declares the node down (`net_ticktime` 60 s) |
| +61.5 s | server-0 resumed → `node … up`, rejoins as a follower, catches up |

While server-0 was frozen, **`rabbitmqctl list_queues` on server-1 hung** (my leader watch printed nonsense). The pods stayed `1/1 Ready` throughout, as far as the end-of-run check shows (readiness wasn't sampled during the freeze). The operator sets **no liveness probe**, and readiness is a TCP check on 5672, which the kernel answers even for a frozen process.

A first attempt used RabbitMQ PerfTest. It reported 39,899 messages in the queue after a graceful delete and 40,000 published, so it looked like 101 were lost. That was not real data loss. PerfTest gives rates, not per-message confirms. And the queue depth from `list_queues` lags behind the real content: in a baseline it showed 9,294 when the drain found 10,000. That PerfTest run wasn't re-measured; `probe.js` replaced it.

## Result

1. **Election and resume: confirmed, but the time depends on how the leader dies.** < 0.1 s when it dies loudly (delete, SIGKILL): the kernel closes its connections and the peers know at once. **6.5 s when it hangs silently**: the peers have to wait for their failure detector.
2. **No confirmed message lost: confirmed, 0 of 130,000 across all runs.**
3. **No duplicates or orphans either, refuted as a risk here.** With one publisher on a surviving node, the channel kept its unconfirmed messages and re-sent them to the new leader.

## Fix

None needed for durability: quorum queues with publisher confirms did what they promise. The finding to carry forward is about **timeouts**. A publisher must tolerate a ~7 s stall in confirms. The saga's outbox relay must not time out and resend faster than that, or it will create the duplicates this run didn't have.

## Lessons

- **Loud failures are easy, silent ones are slow.** Same as M4-01's power-off: test with a fault that leaves sockets open (SIGSTOP, partition, power loss), not only with pod deletes.
- **RabbitMQ has two failure detectors:** Ra per quorum queue (~7 s here) and Erlang distribution for cluster membership (`net_ticktime` 60 s). Queues fail over on the first. The CLI and node up/down decisions run on the second (`pause_minority` would too, but Khepri ignores it: M2-02). M2-03 (partition) will be on that slower clock.
- **Kubernetes won't notice a hung broker.** No liveness probe, and a TCP readiness check passes on a frozen process. Recovery came from RabbitMQ's own Raft, not the platform.
- **Measure per message, not by counters.** Queue-depth stats lag, and load-tool rates can't show which messages were confirmed. Diffing sequence numbers is the only exact answer.
