# M4-01 — PostgreSQL primary dies (CloudNativePG, async replication)

**Date:** 2026-10-21 · **Module:** 4 Distributed databases · **Status:** done

## Hypothesis

`pg-lab` (1 primary + 2 replicas, **asynchronous** replication, node-local disks) under a steady write load:
1. Losing the primary triggers an automatic failover in seconds; clients reconnect to the new primary through `pg-lab-rw`.
2. A clean shutdown loses nothing. A crash or power loss *can* lose acknowledged writes, because with async replication a commit is acknowledged before any replica has it.
3. The harsher the failure, the longer the outage.

## Setup

- CloudNativePG 1.30.1, PostgreSQL 18.6, 3 instances on 3 nodes (`podAntiAffinity: required`), `local-path` volumes.
- `writer.yaml`: a pod (never on the primary's node) streams `INSERT … RETURNING id, clock_timestamp()` over one connection, ~300/s. **Every printed row is an acknowledged commit.** On error it reconnects with a new id range.
- `./run.sh analyze` compares the acknowledged ids with the table: **lost** = acked but missing; **ambiguous** = in the table but never acked (committed while the ack was in flight or still buffered on the client).
- `./run.sh experiment <delete|kill|poweroff>`: reset, 15 s of writes, fault on the current primary, watch the operator's `currentPrimary` once a second, analyse. kubectl talks to the API through a node that survives.

## Observed

| Run | Fault | New primary after | Client write outage | Lost | Ambiguous |
| --- | --- | --- | --- | --- | --- |
| 1 | `kubectl delete pod` (graceful) | **~3 min** (operator started failing over at once, but…) | 18 s, *after* 3 min of writes to the old primary | 0 | 142 |
| 2 | Chaos Mesh pod-kill, grace 0 (SIGKILL) | 21 s | **23 s** | 0 | 31 |
| 3 | `Stop-VM -TurnOff` on the primary's node | **never** (until the node was powered back on, ~3 min) | **unbounded: the client hung** | 0 | — |
| 4 | power-off again, **after fixes A + B** | **57 s** | **69 s** (dead connection detected in 5.5 s) | 0 | 77 |
| 5 | graceful delete again, **after fix C** | 16 s | **3.2 s** (after 15 s of draining) | 0 | 84 |

### What went wrong in runs 1 and 3

**Run 1, the graceful delete, took 3 minutes.** The operator logged `Current primary isn't healthy, initiating a failover` at 11:01:05, then asked PostgreSQL to stop. PostgreSQL's *smart* shutdown waits for connected clients to leave, and the writer's long-lived connection kept the old primary alive, **still accepting ~270 writes/s, until 11:04:06**. That's CloudNativePG's `smartShutdownTimeout`, default 180 s. Only then did it shut down and pg-lab-2 get promoted.

**Run 3, the power-off, never failed over.** Two independent problems:
- **A. The operator died with the primary.** The single `cnpg-cloudnative-pg` pod was on lab-node3, the node I powered off. With nothing to orchestrate it, no failover happens until Kubernetes evicts pods from the unreachable node (300 s by default) or the node comes back. The node came back first (11:11:05).
- **B. The client hung forever.** A powered-off server sends no RST and no FIN. With no keepalive or timeout, the writer's connection (`10.43.49.179:5432`) just waited. Its last ack was 11:08:07.589, and it was **still waiting minutes after PostgreSQL had a primary again**. It would never have recovered by itself.

## Fixes

- **A. Operator HA** (`platform/apps/cnpg.yaml`): `replicaCount: 2` with required anti-affinity, so the operator survives any single node.
- **B. Client dead-peer detection** (`writer.yaml`, and any real app's connection string): `keepalives=1&keepalives_idle=3&keepalives_interval=1&keepalives_count=3&tcp_user_timeout=5000`. `tcp_user_timeout` declares the connection dead when sent data stays unacknowledged for 5 s, which is what caught it in run 4 (5.5 s).
- **C. Shorter smart shutdown** (`platform/databases/pg-lab.yaml`): `smartShutdownTimeout: 15`. Clients get 15 s to finish, then PostgreSQL shuts down fast and the failover goes ahead.

## Result

1. **Automatic failover: confirmed only after fixes A–C.** Out of the box, the two most realistic failures (a planned pod restart with a long-lived client, and a node losing power) took 3 minutes or never completed.
2. **Lost writes: 0 in every run, including SIGKILL and power-off.** At ~300 writes/s with the replicas idle, streaming replication is sub-millisecond behind, so the window for an acknowledged-but-unreplicated commit is tiny. That's luck, not a guarantee: async replication *permits* loss, it just didn't happen here. M4-02 (sync vs async under load) is where to look for it.
3. **Outage scales with how the primary dies:** 3 s (graceful, after the fix) < 23 s (crash) < 69 s (power loss). Power loss is slowest because Kubernetes needs ~40 s to declare the node NotReady before anything is promoted.

"Ambiguous" writes (31–142 per run) are committed and replicated, so they're safe. The count is far higher than the one in-flight insert there should be, so client-side output buffering is still involved even with `stdbuf -oL`. Not fully explained, and it doesn't affect the lost-write count.

## Lessons

- **A failover system has to survive the failure it handles.** A single-replica operator on the primary's node is a single point of failure for the whole database.
- **Clients must detect dead peers themselves.** Without keepalives and `tcp_user_timeout`, a power loss doesn't produce an error, it produces a hang. That's worse, because nothing retries.
- **Defaults can be tuned for safety in a way that hurts availability:** a 180 s smart shutdown is gentle on clients, and turned a pod restart into a 3-minute event.
- **The node-failure path is bounded by Kubernetes, not PostgreSQL:** ~40 s to NotReady. Shortening it (`node-monitor-grace-period`) trades speed for false positives.
