# M4-03 — Replication lag and read-your-writes

**Date:** 2026-10-21 · **Module:** 4 Distributed databases · **Status:** done

The CQRS question: the command side writes to the primary (`pg-lab-rw`), the query side reads from replicas (`pg-lab-ro`). Does a user see their own write when the read comes straight after?

## Hypothesis

1. Without lag, an immediate read on a replica almost always sees the write; under heavy write load or network lag it often doesn't.
2. Three fixes, each with a cost: **read from the primary**, **wait for the write's LSN on the replica**, **`synchronous_commit = remote_apply`**.
3. `remote_apply` with `ANY 1` still allows stale reads, because only one of two replicas is waited for.

## Setup

- pg-lab: 1 primary + 2 replicas (async unless stated), PostgreSQL 18.6.
- **In-server probe** (`ryw.sql`, procedure `ryw_probe`): a session *on the read target* writes one row on the primary through `dblink`, then reads it locally at once, and polls until it's visible. Sub-millisecond precision. Each poll is its own transaction (see finding 2).
- **Client-pod probe** (`./run.sh ext`): write on `pg-lab-rw`, then read on `pg-lab-ro` (a replica picked per connection), one `psql` per query (~47 ms start-up each). Used under network lag, where the in-server probe is invalid: the fault delays all primary → replica traffic, including the probe's own `dblink` replies.
- Load: `pgbench -N -c 8` on the primary. Lag: M4-02's fault, 300 ms on primary → replica traffic. `recovery_min_apply_delay` (delayed apply) would have been cleaner, but CloudNativePG rejects it as a fixed parameter.

## Observed

### No network fault (in-server probe, n = 300, two runs)

| Scenario | Stale first reads | Visible after p50 / p99 | Commit p50 |
| --- | --- | --- | --- |
| Idle | **96–98 %** | 1.18 / 1.4–1.8 ms | 1.2 ms |
| Under pgbench load | **81–84 %** | 1.22 / 2.4 ms | 2.0 ms |

### Replicas 300 ms behind (client-pod probe; times include ~47 ms per `psql`)

| Scenario | Stale first reads | Read sees the row after | Commit |
| --- | --- | --- | --- |
| baseline, no lag | 0 % (the 1 ms lag hides inside 47 ms of overhead) | 48 ms | 47 ms |
| **read from a replica** | **100 %** | **329 ms** | 47 ms |
| fix: read from the primary | 0 % | 46 ms | 47 ms |
| fix: wait for the write's LSN on the replica | 0 % | **325 ms** (the *read* waits) | 48 ms |
| fix: `remote_apply`, `ANY 1` | 0 % | 47 ms | **348 ms** (the *write* waits) |
| fix: `remote_apply`, `ANY 2` | 0 % | 47 ms | 348 ms |

### Only ONE replica 300 ms behind, the other healthy

| Scenario | Stale first reads | Commit |
| --- | --- | --- |
| async | 65.0 % | 51 ms |
| **`remote_apply`, `ANY 1`** | **62.5 %**: no better than async | 49 ms |
| `remote_apply`, `ANY 2` | **0 %** | 348 ms |

### One long read on a replica under write load (`./run.sh longread`, two runs)

`REPEATABLE READ` snapshot held 60 s on a replica while pgbench writes:
```
+5s  replay lag 5 s / 4.9 MB    +15s 16 s / 13 MB    +25s 27-28 s / 14-16 MB
+30s 0 s                        ERROR: canceling statement due to conflict with recovery
                                DETAIL: User query might have needed to see row versions that must be removed.
```

## Result

1. **Refuted in its first half: replicas are almost never read-your-writes, even idle.** The lag is only ~1.2 ms, but a read issued right after the commit is earlier still: 96–98 % stale when idle, 81–84 % under load. "Replication lag is low" and "you will see your own write" are different claims.
2. **Under 300 ms lag every immediate replica read was stale (100 %)**, and the row appeared after ~329 ms.
3. **All three fixes work, and each moves the cost to a different place:**
   - **Read from the primary:** fresh at no latency cost, but the primary carries those reads (the load CQRS wanted to move away).
   - **LSN wait:** the write stays fast; the *read* waits for the replica (325 ms here). It needs the app to carry the write's LSN (e.g. in the session) to the read.
   - **`remote_apply`:** reads are fresh immediately; the *write* waits until the replica has applied (348 ms).
4. **`ANY 1` is not enough for read-your-writes:** confirmed, but only once replicas lag *differently*. With symmetric lag both replicas apply at the same moment, so it looked fine (0 %). With one slow replica, `remote_apply` + `ANY 1` gave **62.5 %** stale reads, the same as async (65 %): the commit waits for the fast replica, and reads through `pg-lab-ro` also land on the slow one. `ANY 2` (every replica) fixes it, at the slow replica's latency.

## Findings beyond the hypothesis

- **Long reads on a replica either stall replication or get cancelled.** Under write load the primary's cleanup (VACUUM/HOT pruning) arrives in the WAL. A replica query holding an old snapshot conflicts with it, so the replica **pauses replay**: its lag grew 5 s → 28 s linearly. After `max_standby_streaming_delay` (30 s) it **cancels the query**. For a CQRS read side that means reports on a replica under heavy writes are either cancelled, or make every other reader on that replica see data up to 30 s old. Options: `hot_standby_feedback = on` (the primary keeps the old row versions: no cancellations, but bloat on the primary), a dedicated reporting replica with a large `max_standby_streaming_delay`, or keep replica queries short.
- **Waiting for replication inside a transaction on a replica can block that replication.** The first probe polled for the row inside one transaction; under load its snapshot blocked replay of the very change it was waiting for, until the 30 s cancel. Each poll must be its own transaction.
- **Measuring sub-millisecond lag needs a sub-millisecond probe.** One `psql` per query costs ~47 ms and completely hides a 1 ms lag; the in-server probe showed 96–98 % stale where the client probe showed 0 %.

## Lessons

- For a CQRS read side, assume a replica read right after a write is **stale by default**, however low the lag.
- Pick the fix by **who should pay**: the primary (route reads there), the reader (LSN wait), or the writer (`remote_apply`). A common hybrid: read from the primary for a short window after the user's own write ("sticky after write"), and from replicas otherwise.
- `remote_apply` gives read-your-writes **only on the replicas it waited for**: `ANY 1` of 2 isn't enough when reads can land anywhere.
- Watch replica **replay lag in seconds** on the dashboard; a single long query can push it to 30 s.
