# M2-02 — Lose 2 of 3 nodes (quorum lost)

**Date:** 2026-10-24 · **Module:** 2 RabbitMQ · **Status:** done

## Hypothesis

A quorum queue on 3 nodes, with a publisher using confirms (max 100 unconfirmed) at 500 msg/s through **server-1**, and the queue's leader (server-0) plus one follower (server-2) lost at once:
1. The queue becomes **unavailable, not lossy**: server-1 alone is 1 of 3, which isn't a majority, so it can't elect a leader or commit. Confirms stop.
2. `pause_minority` (in our config) makes server-1 pause and close the publisher's connection, as soon as it sees the other two go down (kill), or after `net_ticktime` 60 s (freeze).
3. Once the two come back, the queue recovers on its own, and no confirmed message is lost.

## Setup

As in [M2-01](../m2-01-quorum-leader-loss/): RabbitMQ 4.3.7, 3 nodes, queue `m2-02` (quorum, leader on server-0), the same `probe.js` (per-message confirm log + drain). The publisher pod runs on server-1's node, so it never loses its own broker. It doesn't reconnect: if its connection closes, it stops.

## Fault / action

`./run.sh experiment <kill2|freeze2>`: 20 s of publishing, then both server-0 and server-2:

- **kill2**: Chaos Mesh pod-kill, grace 0. Kubernetes restarts them.
- **freeze2**: `SIGSTOP` on both Erlang VMs for 90 s (longer than `net_ticktime`), then `SIGCONT`.

Pod readiness is sampled once a second during the fault.

## Observed

| Run | Longest pause in confirms | Publisher connection | Confirmed | **Lost** | Duplicates | Readiness during the fault |
| --- | --- | --- | --- | --- | --- | --- |
| kill2 | **39.7 s** | stayed open, never closed | 40,000 / 40,000 | **0** | 0 | server-0/2 `0/1` for ~50 s; server-1 `1/1` |
| freeze2 | **92.7 s** | stayed open, never closed | 40,000 / 40,000 | **0** | 0 | **all three `1/1` the whole time** |

kill2, from server-1's log:

| t | Event |
| --- | --- |
| 0 s (07:11:58.3) | pod-kill on server-0 + server-2 |
| +5.5 s | server-0 down (`connection_closed`). server-1 votes for server-2, which **wins term 2**... |
| +5.7 s | ...and is killed itself 0.1 s later. server-1 is alone: no majority, no leader |
| +5.7 … 45 s | confirms stopped. The publisher's window (100) is full, so it blocks; nothing errors |
| +42 s | both restarted pods rejoin. Election → server-2 leader in **term 3** at +45.3 s; confirms resume at once |

freeze2:

| t | Event |
| --- | --- |
| 0 s (07:14:29.0) | server-0 + server-2 frozen. Confirms stop |
| +65 s | `net_tick_timeout`: server-1 marks both nodes down. **No pause, no connection closed**, nothing else logged |
| +94 s | resumed. server-0 is **still the leader of term 1**: no election ever succeeded while it was frozen, so it never lost its place. Confirms resume at +94.9 s |

Why hypothesis 2 failed: `rabbitmqctl list_feature_flags` shows **`khepri_db enabled`**. RabbitMQ 4.x keeps cluster metadata in Khepri, a Raft store, and with Khepri the `cluster_partition_handling` strategies (`pause_minority`, `autoheal`) no longer apply. The behaviour on a partition is Raft's, and it isn't configurable. Our `pause_minority` line was dead config, though `rabbitmqctl environment` still showed it as set.

## Result

1. **Unavailable instead of lossy: confirmed.** 0 of 80,000 confirmed lost, 0 duplicates. The queue simply stopped confirming, for as long as the majority was gone (40 s killed, 93 s frozen).
2. **`pause_minority`: refuted, it's ignored with Khepri.** The minority node kept the publisher's connection open and kept accepting its publishes into the window, but never confirmed them. To the client, quorum loss **looks like silence, not an error**.
3. **Self-healing: confirmed.** No operator action was needed. Freeze resumed with the old leader in the same term. Kill needed a new election.

## Fix

- Removed our `cluster_partition_handling = pause_minority` line from [platform/messaging](../../platform/messaging/), and wrote down why (Khepri). After the restart it is still set: the operator writes the same value in `10-operatorDefaults.conf`. Our line was a duplicate of a default that does nothing.
- For the services (saga, later): **put a timeout on publisher confirms** (e.g. 10 s, which is above M2-01's 7 s election). On a timeout, treat the command as "unknown", not as failed. Report the broker unhealthy, and resend later with the same message id, so a consumer can deduplicate. A publisher with no timeout would hang for as long as the quorum is lost, as this probe did.
- Not changed: the operator's TCP readiness probe. A probe that checked for quorum would mark all three nodes unready at once, so Kubernetes would turn a degraded queue into a full outage of every queue.

## Lessons

- **Majority or nothing.** 2 of 3 down means no writes at all, by design. It's the same trade-off as PostgreSQL sync replication in M4-02/M4-04, but here it's built in and not optional.
- **A lost quorum is silent.** No nack, no closed connection, no unready pod (freeze). The only signal is that confirms stop coming. Clients need confirm timeouts. Monitoring needs "confirms/s dropped to 0 while publishes > 0", or the queue having no leader.
- **Config can lie.** A setting that RabbitMQ accepts and lists can still be ignored. Check the feature flags (Khepri) before trusting older docs. It also changes M2-03: classic mirrored queues are gone in 4.x, and Khepri replaces `pause_minority`, so a partition test is now Raft vs Raft.
- **A Raft leader keeps its term if nobody can win against it**: freeze2 came back as term 1 with no failover. kill2 shows the opposite edge case: a node won an election and died 0.1 s later.
