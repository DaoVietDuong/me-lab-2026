# M2-03 — Partition one node (the leader) from the other two

**Date:** 2026-10-24 · **Module:** 2 RabbitMQ · **Status:** done

## Hypothesis

A quorum queue with its leader on server-0. A Chaos Mesh partition cuts server-0 off from server-1/2, but every client can still reach every node. One publisher with confirms is on each side: **min** through server-0, **maj** through server-1. Each sends 40,000 at 500/s with a window of 100.
1. The majority (server-1/2) elects a new leader within the Ra timeout (~7–10 s, M2-01). **maj** pauses for that long, then carries on.
2. The isolated old leader can't commit: **min** gets no confirms, and no error either (M2-02: no `pause_minority` with Khepri). It stays stuck for the whole partition.
3. After healing, the old leader sees the higher term and steps down. Its uncommitted entries are discarded. No confirmed message is lost.

## Setup

RabbitMQ 4.3.7, 3 nodes, Khepri. Queue `m2-03`, leader on server-0. Same `probe.js` as M2-01, with a new `OFFSET` so the two publishers' sequence numbers don't overlap (min 1..40,000; maj 1,000,001..1,040,000). One drain (through server-1) after healing, split by range. [partition.yaml](partition.yaml) blocks only server-0 ↔ server-1/2 traffic, in both directions.

## Fault / action

`./run.sh experiment`: 20 s of publishing, then the partition, then healing. Planned for 90 s, it **actually lasted 229 s**. The leader-watch loop counted iterations, and each `rabbitmqctl` call hung up to its 5 s timeout. The loop now runs on a timer, and the run wasn't repeated: a longer cut only stretches phase 2.

## Observed

| t (from 08:53:28.2) | Majority side (server-1/2) | Minority side (server-0) |
| --- | --- | --- |
| 0 s | partition | partition |
| **+9.2 s** | server-1 votes for server-2: **leader, term 2**. maj resumes after an **8.6 s** gap | still thinks it's the leader of term 1. Accepts min's 100-message window, can't commit any of it |
| +16 … 67 s | `rabbitmqctl list_queues` on server-1 **hangs/times out** (leader shown as "?"): the CLI is still waiting on server-0 | min blocked, no confirm, no error, connection open |
| +60 s | maj finishes: 40,000 / 40,000 confirmed | — |
| +67 / +73 s | Erlang distribution: `node server-0 down: net_tick_timeout`. The CLI works again and shows leader server-2 | `server-1, server-2 down: net_tick_timeout`. **No pause, still serving its client** |
| **+229 s** | heal | heal |
| +229.4 s | | `leader saw append_entries_rpc from server-2 for term 2` → **`leader -> follower in term: 2`** → `term mismatch - follower had entry at 20558 with term 1 but not with term 2`: its uncommitted term-1 tail is thrown away |
| +229.5 s | | min's confirms resume (gap **228.6 s**). It finishes 2 s later |

All three pods were `1/1 Ready` throughout.

| Publisher | Confirmed | **Lost** | Drained but never confirmed | Duplicates | Longest gap |
| --- | --- | --- | --- | --- | --- |
| maj (via server-1) | 40,000 / 40,000 | **0** | 0 | 0 (80,000 drained, all distinct) | **8.6 s** |
| min (via server-0) | 40,000 / 40,000 | **0** | 0 | 0 | **228.6 s** = the whole partition |

## Result

1. **Majority side: confirmed.** New leader in 9.2 s; maj lost nothing and barely noticed.
2. **Minority side: confirmed, and it's worse than "unavailable".** The old leader went on acting as leader in term 1 for almost 4 minutes, accepting publishes it could never commit. Its client saw silence, not an error. Nothing told it to go to another node, although two healthy nodes and a working queue were one connection away.
3. **Heal: confirmed.** One heartbeat from the term-2 leader was enough. server-0 stepped down, its term-1 entries from index 20558 on were discarded, and the server-0 queue client re-sent the stuck messages to the new leader. They landed once each, so nothing confirmed or unconfirmed was lost or duplicated.

Raft did exactly what it promises: **no split brain** (the old leader never committed anything, so there was never a second history) and **no lost writes**. What it doesn't promise is **liveness for a client attached to the wrong side**.

## Fix

- Nothing on the broker. It's correct.
- **Clients:** a confirm timeout (M2-02: ~10 s) and, on a timeout, **reconnect to a different node** and resend with the same message id. With that, min would have stalled ~10 s instead of 229 s. Connect through the `rmq-lab` Service or a list of all three nodes, not one pinned pod.
- **Monitoring:** alert on "publishes but no confirms" per connection. Don't rely on `rabbitmqctl`, which went blind on the healthy side for 67 s, or on Kubernetes readiness.

## Lessons

- **Three clocks in one fault.** Ra election 9 s (the data moves on), Erlang `net_ticktime` 67–73 s (the cluster and the CLI catch up), and the client's own timeout (none here → 229 s). Know which one each tool and alarm runs on.
- **A stale leader isn't dangerous in Raft, just useless.** It can't commit, so its writes are never confirmed. Compare M4-04: PostgreSQL's isolated primary *did* confirm 12,164 async writes that were then lost. The difference is commit-by-majority vs commit-locally.
- **The partition that matters is between the client and the majority**, not between nodes. A client on the minority side is cut off from the queue, even with a perfectly good TCP connection.
- **Measure wall-clock time, not iterations.** In this run the monitoring loop itself slowed down because of the fault.
