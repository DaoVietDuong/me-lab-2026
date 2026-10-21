# M4-02 — Synchronous vs asynchronous replication

**Date:** 2026-10-21 · **Module:** 4 Distributed databases · **Status:** done (open item: CoreDNS single point of failure)

## Hypothesis

| | Async | Sync (`ANY 1`, `dataDurability: required`) |
| --- | --- | --- |
| Commit cost, healthy replicas | baseline | somewhat higher: each commit waits for a replica's flush |
| Commit cost, replicas 300 ms behind | ≈ unchanged | ≈ 300 ms per commit |
| Primary dies while replicas lag 300 ms | **loses** ~the last 300 ms of acknowledged writes | loses **nothing** |

## Setup

- pg-lab: PostgreSQL 18.6, 1 primary + 2 replicas (CloudNativePG 1.30.1, operator ×2), local-path volumes.
- `./run.sh sync on|off`: `spec.postgresql.synchronous: {method: any, number: 1, dataDurability: required}`, patched live. The `databases` Argo CD app ignores that one field (`ignoreDifferences` + `RespectIgnoreDifferences`), so the toggle sticks; everything else stays Git-controlled.
- `./run.sh lag on|off` (`lag.yaml`): Chaos Mesh delays **only primary → replica** traffic (the WAL stream) by 300 ms. Clients aren't delayed.
- Writer and analysis from M4-01 (`../m4-01-pg-failover`): one connection, `INSERT … RETURNING`, every printed row = an acknowledged commit; lost = acked but missing afterwards.

## Observed: the cost (`./run.sh measure`, unthrottled single writer, 20 s)

| Replication | Replicas healthy | Replicas 300 ms behind |
| --- | --- | --- |
| **Async** | **757 commits/s** (1.3 ms each) | 343/s (2.9 ms): the primary barely notices |
| **Sync** | 423/s (2.4 ms): **−44%** | **3.2/s (308 ms each): −99.6%** |

## Observed: what it buys (primary dies while replicas lag 300 ms, writer at ~300/s)

| Replication | How the primary dies | Lost acked writes | Client outage |
| --- | --- | --- | --- |
| Async | SIGKILL (process only) | **0** | 23 s |
| Sync | SIGKILL | 0 | 24 s |
| **Async** | **kernel crash** of its node (`sysrq c`, power-loss equivalent) | **90** (ids 10005015…) | 69 s |
| **Sync** | **kernel crash** of its node | **0** | **151 s** (see below) |

Hyper-V `Stop-VM` wasn't available in this session (no admin rights), so `../m4-01-pg-failover/run.sh experiment crash` gained a power-loss stand-in: `kernel.panic=120` + `echo c > /proc/sysrq-trigger`. The kernel dies instantly, sends nothing more on the network, and reboots itself after 120 s, which is longer than a failover.

## Result

1. **The cost: confirmed, and larger than expected.** Even with healthy replicas, sync took 44% off a single writer's throughput. With lagging replicas every commit pays the full lag: 3.2 commits/s. Sync replication makes **your write latency equal to your slowest required replica's latency**.
2. **What sync buys: confirmed.** Under the same 300 ms lag, an async primary losing its kernel lost **90 acknowledged writes**, about 300 ms × ~300 writes/s, exactly the lag window. Sync lost **none**.
3. **Not predicted: SIGKILL loses nothing, even async.** Killing only the *process* leaves the kernel running. WAL that PostgreSQL had already written to the replication socket was sitting in the kernel (in the 300 ms delay queue), and the kernel still delivered it after the process died. Only losing the **whole machine** (kernel crash, power cut) loses in-flight replication data. A test that only kills processes overestimates async's safety.

## Finding: the sync crash took 151 s, because CoreDNS died with the node

| Time | Event | s after crash |
| --- | --- | --- |
| 14:48:02 | lab-node1 crashed: the primary (pg-lab-2), **the CNPG operator leader**, and **the only CoreDNS pod** were all on it | 0 |
| 14:49:03 | Standby operator (lab-node2) takes the leader lease (lease 15 s; the takeover took 61 s, not explained) | 61 |
| 14:49:11 | lab-node1 NotReady | 69 |
| 14:49:13 | Failover pg-lab-2 → pg-lab-1 starts | 71 |
| 14:49:30 | pg-lab-1 promoted, "ready to accept connections" | 88 |
| 14:49:08–14:50:3x | pg-lab-3 retrying: `lookup pg-lab-rw on 10.43.0.10:53: i/o timeout` / `connection refused` | |
| 14:50:18 | lab-node1 back, CoreDNS back | 136 |
| 14:50:33 | pg-lab-3 and pg-lab-2 attach as quorum candidates; **first commit** | 151 |

With `dataDurability: required`, the new primary may not confirm *any* commit until a synchronous standby is attached. The surviving replica couldn't attach because **it couldn't resolve `pg-lab-rw`**: k3s runs CoreDNS as **one replica** with no anti-affinity or PodDisruptionBudget, and it was on the crashed node. Async had a 69 s outage in the same situation because its new primary doesn't need a standby to commit. Sync turned a DNS outage into a write outage.

**Decision (2026-10-22): accepted risk, CoreDNS stays at one replica.** If revisited: run CoreDNS with ≥2 replicas on different nodes. k3s re-applies its packaged `coredns.yaml` on every server start, so a `kubectl scale` doesn't stick. Options: disable the packaged CoreDNS (`disable: [coredns]`) and run the CoreDNS Helm chart via Argo CD (same Service IP 10.43.0.10), or stop k3s re-applying it (`coredns.yaml.skip` on every server) and manage the Deployment in Git.

## Options in between

- `dataDurability: preferred`: sync while a standby is available, falls back to async when none is. It avoids the 80 s write stall above, and loses the guarantee exactly when you're failing over.
- `synchronous_commit = remote_write` (replica received, not yet flushed) or `remote_apply` (visible on the replica, which also gives read-your-writes on replicas): per transaction or per user, so only the writes that need it pay.
- `ANY 1` of 2 standbys vs `FIRST 1`: ANY lets the fastest standby confirm, so one slow replica doesn't slow every commit.

## Lessons

- **Sync replication moves the replica's latency into every commit.** Healthy: +1 ms; lagging: +300 ms. Measure it before turning it on.
- **Async loses data only when the machine dies, not when the process dies.** Fault tests must include machine death.
- **Sync + `required` makes the database depend on the rest of the platform.** No synchronous standby means no commits, and here DNS decided whether a standby could attach.
- **Single-replica platform components are hidden SPOFs.** CoreDNS (k3s default: 1 replica) joins the CNPG operator (fixed in M4-01) on the list.
