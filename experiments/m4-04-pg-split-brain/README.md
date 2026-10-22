# M4-04 — PostgreSQL split brain (primary partitioned, client still connected)

**Date:** 2026-10-22 · **Module:** 4 Distributed databases · **Status:** done

## Hypothesis

`pg-lab` primary cut off from the replicas, the operator and the API server, while a client on the other side of the cut still reaches it:
1. The operator promotes a replica. For a while there are **two primaries**, and the client keeps writing to the old one.
2. CloudNativePG fences the old primary by itself (liveness `isolationCheck`: it can reach neither the API server nor any other instance) within ~30 s.
3. With async replication, every write the old primary acknowledged after the cut is lost when it rejoins (pg_rewind). With sync replication, none are, because the old primary can't commit anything.

## Setup

- CloudNativePG 1.30.1, PostgreSQL 18.6, 3 instances, async by default. Fixes from M4-01 are in place: operator HA, `smartShutdownTimeout: 15`, client keepalives / `tcp_user_timeout`.
- Liveness probe: every 10 s, `failureThreshold: 3`, `isolationCheck` enabled (CNPG default). `failoverDelay: 0`.
- Writer: M4-01's `writer.yaml`, ~300 writes/s over one connection through `pg-lab-rw`. Every ack also prints `inet_server_addr()`, so each acknowledged write names the server that acknowledged it.

## Fault / action

`partition.yaml`: three Chaos Mesh `partition` rules on the primary pod. They cut it off from the replicas, from the operator pods and from the API server (node IPs `10.10.0.11-13` and `10.43.0.1`). The client isn't cut off. Kubelet probes still arrive, because they come from `cilium_host` (10.42.x.46), not the node IP (checked with tcpdump).

`./run.sh experiment <label> 90`: 15 s of writes, partition for 90 s while sampling the operator's primary, each instance's role label, readiness and restart count once a second, then heal, wait for 3/3 ready, analyse. `./run.sh sync on|off` switches replication (reuses M4-02).

## Observed

### Run 1: async (default)

Times relative to the partition (12:52:39.5 UTC). The instance-manager log of the old primary, the operator log, and the run's timeline:

| t | Old primary `pg-lab-1` | Operator / cluster | Client |
| --- | --- | --- | --- |
| 0 s | partitioned | still sees `pg-lab-1` as primary | writing to `10.42.2.250` |
| +6 s | `Instance connectivity error - liveness probe failing` (isolation check) | | still acked |
| +13 s | `Failed to renew lease`, `Primary lease lost, cannot verify holder, retrying`, **keeps accepting writes** | | still acked |
| +26 s | 3rd liveness failure: kubelet SIGTERM → **smart shutdown**: existing sessions may keep committing | | still acked |
| +41 s | smart shutdown times out (15 s) → fast shutdown, postmaster exits | | **last ack 12:53:20.439**, then `connection refused` |
| +48 s | kubelet: NotReady | | retrying |
| +49 s | | `Current primary isn't healthy, initiating a failover` | |
| +68…72 s | | `pg-lab-2` promoted, labelled primary | first ack from `10.42.0.44` at +71 s |
| heal | `pg_rewind … Done!`, `Demoting instance`, rejoins as replica | 3/3 healthy | |

| | Acks from old primary | Acks from new primary | **Lost (acked, not in table)** |
| --- | --- | --- | --- |
| async | 17,318 (12:52:23 → 12:53:20) | 28,253 | **12,164**: every write acked from +0.75 s to +41 s |

The first ~0.75 s of writes after the apply survived: the WAL stream ran until the chaos-daemon rules took effect.

### Run 2: sync (`ANY 1`, `dataDurability: required`)

Partition at 12:56:27.274 on `pg-lab-2`. Same sequence: isolation, SIGTERM at ~+26 s, shutdown at ~+40 s, NotReady at +50 s. The failover started only at +79 s, and the new primary `pg-lab-1` was serving at +100 s.

| | Last ack from isolated primary | Write outage (client) | **Lost** | Ambiguous (in table, never acked) |
| --- | --- | --- | --- | --- |
| async | +41 s | 30 s visible (12:53:20.4 → 12:53:50.8), but the 41 s before it were thrown away: **71 s with no durable write** | **12,164** | — |
| sync | **+0.1 s** (one commit in flight) | **100 s** (12:56:27.4 → 12:58:07.8) | **0** | 85 |

Every commit after the cut hung waiting for a replica ack that couldn't arrive, so the isolated primary acknowledged nothing. The 85 "ambiguous" rows are the same client-buffering artifact as in M4-01. They exist and were never reported, so they're harmless.

The extra ~29 s between NotReady and the start of the failover in run 2 is quiet operator time (12:57:16 → 12:57:46), which ends with `Cannot extract Pod status`. That most likely means its HTTP status call to the partitioned primary timed out. In run 1 the failover started 1 s after NotReady, so it depends on where the reconcile loop happens to be. Not verified.

## Result

1. **Two primaries at once: refuted.** The old primary was always down before the new one was promoted. The operator's failover trigger was the kubelet's NotReady, which only came after the old primary's shutdown. CloudNativePG avoids dual-primary by ordering, not by luck.
2. **Self-fencing: confirmed, but slower than expected.** The isolation check noticed at +6 s. But the fence is the liveness probe (3 × 10 s), and then the 15 s smart shutdown, so **writes stayed acknowledged for 41 s**.
3. **Async: all those writes are lost, confirmed: 12,164 acknowledged writes (41 s).** This is the dangerous half of split brain even without a second primary. The isolated side says "committed", and the cluster later rewinds it. `pg_rewind` makes it automatic and silent: nothing logs *which* commits were discarded.
4. **Sync: 0 lost, confirmed.** It costs availability: the isolated primary blocks instead of lying, and writes were down for 100 s.

## Fix

- **Data loss:** synchronous replication (`ANY 1`, `dataDurability: required`). It's the only thing that closes the window, because a primary that can't reach a replica can't commit. Not enabled in Git: the cost is measured in M4-02 (−44 % throughput healthy) and here (100 s outage). It's a per-workload choice. Use it where an acknowledged write must never vanish (orders, payments).
- **Shrinking the async window** (not applied): `probes.liveness.periodSeconds`/`failureThreshold` lower than 3 × 10 s, and a shorter `smartShutdownTimeout`. Each second cut is ~300 fewer lost writes here. But both trade against false fencing and against M4-01's graceful-restart fix.

## Re-run

Run 2 above is the re-run with the fix: 12,164 → 0 lost, at 30 → 100 s of client write outage.

## Lessons

- **Split brain doesn't need two primaries.** One isolated primary that keeps saying "committed" is enough to lose data. The danger is acknowledging what the majority will never see.
- **Fencing has a latency, and every layer adds to it:** detection (6 s) → liveness threshold (+20 s) → graceful shutdown (+15 s). M4-01's gentler shutdown is 15 s more doomed writes here. One knob, two experiments, opposite directions.
- **A lost lease didn't stop writes.** At +13 s the old primary knew it had lost its lease and still committed for 28 s. A lease only fences if losing it *stops writes*, and here only the liveness kill did that.
- **Sync replication turns silent loss into visible unavailability.** That's the CAP choice in one switch: during a partition, block (C) or acknowledge and maybe lose (A).
- **Open:** with `isolationCheck` disabled, would readiness (served from a cached cluster definition) keep the old primary Ready, so the operator never fails over, or fails over while it is still serving? That's the run that could really produce two primaries.
