# Lab — Distributed Systems Practice Plan

Oct 20, 2026 · @Duong

*What's built so far, and how: [ARCHITECTURE.md](../ARCHITECTURE.md).*

## Goals

The lab is a 3-node Kubernetes cluster on your 3 Ubuntu VMs, running a small polyglot order system on Kafka and clustered databases, deployed by `git push`. You then break it on purpose, one failure class at a time, and prove each fix with metrics.

What you should be able to do at the end:

1. **Networking** — explain and reproduce latency, packet loss, partitions, DNS failures and MTU problems between nodes, and lock traffic down with NetworkPolicy and mTLS.
2. **Messaging and streaming** — use RabbitMQ for commands between services and Kafka for real-time stream processing; survive a broker loss in both with no acknowledged message lost.
3. **Distributed databases** — operate both models: primary/replica (PostgreSQL, failover and replication lag) and leaderless (Cassandra, tunable quorums, read repair and conflicting writes).
4. **Distributed-systems failures** — see each classic problem happen in your own system: dual writes, partial failure, retries storms, clock skew, split brain, cascading failure. Fix each with a named pattern (outbox, saga, idempotency key, circuit breaker, fencing).
5. **Security and performance** — find the system's breaking point with load, stress, spike and soak tests, and harden it against a scan and a basic attack checklist.

Every experiment follows the same card: **hypothesis → inject the fault → observe in Grafana → result → fix → re-run**. Your notes from those cards are the real output of the lab.

## Design decisions

### Databases: PostgreSQL + Cassandra (CockroachDB dropped)

There are three ways to replicate data, and each one fails differently. The lab should cover the two you can't get anywhere else.

| Model | Who accepts a write | Example | Where you already get it in this lab |
| --- | --- | --- | --- |
| Single leader (primary/replica) | One primary; replicas copy its log | PostgreSQL | **Postgres (CNPG)** — failover, replication lag, split brain |
| Consensus (Raft/Paxos) | A majority of nodes must agree | CockroachDB, etcd | **Already there:** k3s etcd, Kafka KRaft and RabbitMQ quorum queues all use Raft |
| Leaderless (Dynamo-style) | Any node; you choose how many must answer | Cassandra | **Cassandra** — only way to see this model |

I picked CockroachDB first to show Raft at the database level. But you already meet Raft three times in this stack, and with 7 GB per node you can't afford both. Cassandra teaches more new problems:

- **Tunable consistency:** with RF=3, a write at `ONE` and a read at `ONE` can return stale data. `QUORUM` + `QUORUM` can't, because R + W > N. You measure this yourself.
- **Conflicting writes:** last-write-wins by timestamp, so clock skew between nodes silently drops writes. That makes the clock-skew experiment concrete.
- **Repair machinery:** hinted handoff, read repair, `nodetool repair`, tombstones. These are the things that go wrong when a node comes back after a partition.
- **Data modelling:** design tables per query, partition keys, wide rows, hot partitions. This is completely different from relational thinking.

Cassandra is the wrong store for money or stock counts (no multi-row transactions). So orders, inventory and payments stay in Postgres, and Cassandra stores the high-volume stream output: events, time series, aggregates. That is also how Cassandra is used in real systems.

### Service-to-service async: RabbitMQ

RabbitMQ carries **commands and work** between services: "reserve stock for order 42", "charge card", "send email". These messages have one intended receiver, need per-message ack and retry, and are deleted once done.

- 3-node RabbitMQ cluster (RabbitMQ Cluster Operator) with **quorum queues**, replicated on all 3 nodes.
- The order saga runs over RabbitMQ: command queues per service, reply/event exchanges back to the orchestrator.
- Practice: publisher confirms, consumer prefetch, competing consumers, dead-letter exchanges, delayed retry, partition handling (`pause_minority`), and losing the quorum-queue leader.
- The outbox pattern still applies: the order row and the "send command" row are saved in one Postgres transaction.

### Kafka: a real stream-processing job, not a queue

Use Kafka only where its log matters: high event volume, many independent readers, ordering per key, replay of history, and stateful processing over time windows. RabbitMQ can't do these well.

The scenario: a **clickstream and payment-events pipeline** for the shop, fed by a generator that produces 2,000–20,000 events per second.

| Use case | How it works | What it teaches |
| --- | --- | --- |
| Real-time sales dashboard | Kafka Streams: revenue per product in 1-minute tumbling windows → `sales-per-minute` topic → WebSocket dashboard | Windowing, event time vs processing time, late events and grace periods |
| Trending products | Top-N views per 5-minute hopping window | Stateful aggregation, state stores, repartitioning by key |
| Fraud detection | Join payment events with click sessions: more than 3 payments per card in 60 s, or a payment with no prior browsing session → `fraud-alerts` | Stream-stream joins, windows, exactly-once processing |
| Live stock view | Debezium streams Postgres `inventory` changes (CDC) into Kafka → a KTable → joined with the order stream | Change data capture, compacted topics, stream-table joins |
| History store | Kafka Connect sink writes raw events and aggregates to Cassandra | Connectors, at-least-once into an idempotent store |
| Rebuild a read model | Wipe the dashboard's store, reset consumer offsets, replay 3 days of events | Replay and reprocessing, retention sizing |

This is the same shape as real production pipelines (ad-click billing, fraud scoring, IoT telemetry). It also stresses Kafka itself: partitions as the unit of parallelism, consumer lag under load, broker loss during a stateful job, and state-store restore after a pod is killed.

An option closer to your day job: replace the clickstream with **cold-chain sensor telemetry** (freezer temperature every second, alert after 3 minutes above −18 °C, join to production batches to flag affected product). The Kafka concepts are the same.

### Distributed cache: Redis Cluster (replaces Sentinel)

Redis Cluster splits keys across 3 primaries (16,384 hash slots), each with 1 replica on a different node: 6 small pods, about 1 GB RAM in total. Sentinel only fails over a single primary and never shards. It can't show the problems that make a cache *distributed*: key routing, resharding, cross-slot limits, a hot shard.

- **Who uses it:** inventory (cache-aside for product and stock reads), gateway (rate limits and sessions shared by all gateway replicas), payment (dedup keys), and a distributed lock for the saga.
- **Install:** OT-Container-Kit redis-operator (`RedisCluster` resource) through Argo CD. Use Redis 8, or Valkey (the open-source fork with the same protocol).
- **Why it's interesting:** Redis replication is asynchronous and failover has no consensus on data. A cache that loses writes on failover is fine; a lock or a rate limiter that does is a bug. Module 5 makes you find where that line is.

## Environment: hub-and-spoke on one host

Five VMs on private networks, built like an Azure hub-spoke: a small hub VM routes and filters everything, the 3-node lab cluster sits in one spoke, the tester in another. Spokes never talk to each other or the internet except through the hub firewall.

&#91;embedded content: hub-and-spoke lab network · 5 VMs, 3 private networks\]

The tester attacks and loads the system the way a real outside client would: through a firewall, to one public entry point. Moving the load generator off the lab nodes also keeps it from stealing CPU from the system under test.

### Sizing (32 GB RAM, 100 GB disk)

| VM | vCPU | RAM | Disk | Runs |
| --- | --- | --- | --- | --- |
| hub | 1 | 1 GB | 8 GB | nftables firewall + NAT, dnsmasq DNS, `tc netem` WAN emulation, Suricata IDS (optional) |
| lab-node1–3 (each) | 4 | 5 GB | 24 GB | k3s server + all lab workloads |
| tester | 2 | 2 GB | 14 GB | k6, OWASP ZAP, nmap, curl/hey |
| **Total** | **15** | **18 GB** | **94 GB** | leaves \~14 GB RAM for Windows (it uses \~12 GB with Chrome, VS Code and WSL) |

- **Why 5 GB, not 7 GB:** the first build at 7 GB per node failed to start lab-node3. Windows really uses about 12 GB, not the 7 GB first assumed.
- **What 5 GB costs:** the full stack needs about 19 GB across the nodes and 15 GB is available. **Run one module's stack at a time** (each stack is one Argo CD app you switch on or off), and expect Kafka + Cassandra together to be tight. To go to 6–7 GB per node, close apps on Windows first, then `Set-VMMemory` with the VM off.
- **Why not 4 GB per lab node:** three 4 GB nodes would spend the lab fighting OOM kills instead of studying them.
- **Turn off Dynamic Memory** on the lab nodes so performance numbers are repeatable.
- **Disk per lab node (24 GB):** OS 6 · container images 8 · data volumes 8 (Kafka retention capped at 2 GB per broker, Cassandra 2, Postgres 1, Prometheus/Loki 3-day retention) · 2 free.
- **Checkpoints eat the same 100 GB.** Keep one clean checkpoint per VM and merge old ones.
- All five VMs share one physical machine: node failures are simulated, but CPU and disk contention between them are real. Keep that in mind when reading performance results.

### Networks (Hyper-V)

| Switch | Type | Subnet | Members | Purpose |
| --- | --- | --- | --- | --- |
| Default Switch | NAT (built-in) | DHCP | hub NIC 1 | Internet egress |
| lab-mgmt | Internal | 10.0.0.0/24 | Windows 10.0.0.1, hub 10.0.0.2 | You administer from Windows; add `route add 10.10.0.0 mask 255.255.0.0 10.0.0.2` (and 10.20) |
| spoke-lab | Private | 10.10.0.0/24 | hub .1, lab-node1–3 .11–.13, MetalLB VIPs .200–.220 | Main system |
| spoke-test | Private | 10.20.0.0/24 | hub .1, tester .10 | Load and attack traffic source |

*Private* switches mean even Windows can't reach a spoke directly. Each spoke's only gateway is the hub, the same as a spoke VNet whose only peering is to the hub with a 0.0.0.0/0 route to the firewall.

### Hub firewall policy (default deny)

| From → to | Allowed | Why |
| --- | --- | --- |
| tester → lab | TCP 443 to ingress VIP 10.10.0.200 only | Black-box testing, like a real external client |
| tester → lab, *pentest mode* | All ports (a separate nftables rule set you switch on) | Grey-box: can an attacker reach Kafka or the DB directly? |
| lab → tester | Nothing | Spokes are isolated; k6 pushes results in through the ingress |
| lab → internet | DNS via hub; HTTPS to github.com, ghcr.io and image registries only | Argo CD and image pulls work; nothing else leaves |
| tester → internet | HTTPS | Tool updates |
| Windows (lab-mgmt) → spokes | SSH 22, HTTPS 443, Kubernetes API 6443 | Administration |

Every drop is logged on the hub. Reading those logs is part of Module 1.

**How it's built:** nftables on the hub (`lab/bootstrap/hub/`), installed by `30-hub-firewall.sh`. The lab's domain allowlist works through DNS: dnsmasq adds the IPs it resolves for `github.com`, `ghcr.io`, the registries and so on to an nftables set, and only that set may leave on 443. Normal and pentest modes are `sudo lab-fw normal|pentest` on the hub. A new chart or registry that is blocked shows up as `fw-drop fwd ... OUT=eth0` in `journalctl -k`, which is a small Module 1 exercise from the first day.

**Base OS setup (every VM):** Ubuntu 24.04 Server minimal, static IP, default route and DNS via the hub, `chrony` time sync from the hub (broken on purpose later), swap off, SSH keys only.

**How the VMs are built:** all 5 VMs live in `E:\HyperV\lab`. E: has the free space, and the old Ubuntu 22.04 VMs on C: are retired. Ubuntu is installed once, unattended, into a read-only golden disk (`lab/bootstrap/15-golden.ps1`). Each VM is a full copy of that disk, not a differencing disk, configured on first boot by its own cloud-init seed: hostname, user, SSH key, static network, and the hub's NAT, DNS and NTP roles (`lab/bootstrap/20-vms.ps1`). Run order: [bootstrap/README.md](../bootstrap/README.md).

## Platform layer

Use k3s in HA mode (3 servers, embedded etcd) and install every stateful system through its Kubernetes operator. Operators turn "run a Kafka cluster" into one YAML file in Git, which is what makes push-to-deploy work for infrastructure too.

| Layer | Choice | Why this one |
| --- | --- | --- |
| Kubernetes | k3s, 3 servers, embedded etcd | Light enough for 7 GB nodes; etcd quorum is itself a lab topic |
| CNI / network | Cilium (replaces flannel) | NetworkPolicy, Hubble flow view, kube-proxy replacement |
| Load balancer | Cilium LB IPAM + L2 announcements, pool 10.10.0.200–220 (replaces MetalLB) | Real `LoadBalancer` IPs in the lab spoke, routed through the hub; no extra pods |
| Ingress | Cilium Gateway API, `lab-gateway` on 10.10.0.200:443 (replaces ingress-nginx, archived March 2026) | Single entry point the tester spoke is allowed to reach |
| Storage | local-path (k3s default) | Data stays on the node — forces the database to do replication, not the disk |
| TLS | cert-manager + internal CA | mTLS and HTTPS without public certs |
| Commands / work queues | RabbitMQ Cluster Operator, 3 nodes, quorum queues | Service-to-service async: saga commands, retries, DLX |
| Event streaming | Strimzi Kafka, KRaft, 3 brokers | RF=3, `min.insync.replicas=2`, the clickstream pipeline |
| Stream processing | Kafka Streams (Java service) | Windows, joins, state stores, exactly-once |
| CDC + connectors | Kafka Connect with Debezium (Postgres source) and Cassandra sink | Database changes as a stream, no dual writes |
| Schemas | Apicurio Registry | Avro/Protobuf schema evolution across 4 languages |
| Primary/replica DB | CloudNativePG, 1 primary + 2 replicas | Orders, inventory, payments; failover, sync/async switch |
| Leaderless DB | Cassandra (K8ssandra operator), 3 nodes, RF=3 | Events, time series, aggregates; tunable consistency |
| Distributed cache | Redis Cluster (redis-operator), 3 primaries + 3 replicas | Sharded cache, rate limits, locks, dedup; failover without consensus |
| Chaos | Chaos Mesh | Pod kill, network partition/latency/loss, **clock skew**, I/O faults — all as YAML |
| GitOps | Argo CD (app per module, switch on/off) | Pulls from GitHub; lets you run only the stack you're studying |

`local-path` storage is a deliberate choice: when a node dies its data volume is unavailable, so only the database's own replication keeps you safe. That's the behaviour you want to study.

## CI/CD: push and forget

GitHub Actions builds, Argo CD deploys. The lab pulls its changes from GitHub, so it needs no public IP, no open port and no self-hosted runner — the same reason pull-based GitOps works for private AKS where hosted agents can't reach the API server.

What happens after `git push` to `main`:

1. **Actions detects which service changed** (path filter on `services/<name>/**`) and runs only that service's job: build, unit test, Trivy image scan.
2. **Actions pushes the image** to GitHub Container Registry as `ghcr.io/<you>/<service>:<git-sha>`.
3. **Actions bumps the tag** in `deploy/<service>/kustomization.yaml` and commits it back (`[skip ci]`).
4. **Argo CD sees the new commit** (polls every 3 minutes, or instantly via a webhook later) and syncs the change into the cluster.
5. **Kubernetes rolls the Deployment**; Argo CD shows it Healthy or Degraded.

Platform changes (a Kafka setting, a new chaos experiment) follow the same road minus steps 1–3: edit YAML under `platform/`, push, Argo CD applies it.

**Repo layout (one monorepo)**

```
lab/
  .github/workflows/   one workflow per service + shared build template
  services/            gateway-node, order-dotnet, inventory-java, payment-rust, event-generator-rust, stream-processor-java, dashboard-node
  deploy/              kustomize base + image tag per service
  platform/            Argo CD apps: cilium, metallb, rabbitmq, strimzi, kafka-connect, cnpg, cassandra, redis, observability, chaos-mesh
  experiments/         chaos YAML + k6 scripts + one markdown card per experiment
  bootstrap/           one-time scripts: Hyper-V switches, hub firewall (nftables), VM prep, k3s, Argo CD
```

**Secrets:** the repo is public, so never commit a plain secret, not even for a minute (Git history keeps it). Use Sealed Secrets (encrypted in Git, decrypted only inside the cluster). That's also your first security exercise.

## Sample system: order saga + clickstream pipeline

Two halves on purpose. The top half is a transactional order flow (place order, reserve stock, take payment) that needs a distributed transaction. The bottom half is a high-volume event pipeline that only Kafka handles well.

&#91;embedded content: sample system · 7 services, 4 languages, RabbitMQ for commands, Kafka for streams\]

**Order saga (RabbitMQ):** order-service saves the order and an outbox row in one Postgres transaction. The relay sends `reserve-stock` to inventory, then `charge-payment` to payment (a fake provider you can make slow or flaky). Any failure sends compensating commands back up the chain.

**Stream pipeline (Kafka):** the generator floods `clicks`; payment-service publishes `payments`; Debezium streams inventory changes into `cdc.inventory`. The stream processor turns these into `sales` per minute and `fraud-alerts`. The dashboard shows them live, and Kafka Connect stores everything in Cassandra.

| Service | Language | Data | Practice focus |
| --- | --- | --- | --- |
| gateway | Node.js (Fastify) | — | Distributed rate limiting and sessions in Redis, JWT, timeouts, circuit breaker |
| order-service | .NET 10 | PostgreSQL | Outbox, saga orchestration over RabbitMQ, DB failover handling |
| inventory-service | Java (Spring Boot) | PostgreSQL | Competing consumers, idempotent command handling, cache-aside reads through Redis |
| payment-service | Rust (axum, lapin, rdkafka) | PostgreSQL + Redis | Idempotency keys, backoff + jitter, poison messages, publishes to Kafka |
| event-generator | Rust | — | Producer tuning: batching, compression, `acks`, keys; doubles as Kafka load test |
| stream-processor | Java (Kafka Streams) | Kafka state stores | Windows, joins, exactly-once, state restore |
| dashboard | Node.js | Cassandra | Consumer groups, lag, rebalances, Cassandra reads at different consistency levels |

Each service stays small (a few hundred lines). The lab is about what happens between services, not inside them.

## Curriculum

Nine modules (0–8), in order: each one adds the component the next module breaks. Every experiment below becomes a card in `experiments/` with hypothesis, fault, what you saw, fix.

### Module 0 — Foundation

- [ ] Hyper-V switches created; hub VM routing, NAT, DNS and default-deny firewall working
- [ ] 3 lab nodes + tester on their spokes; each can reach only what the policy allows
- [ ] k3s HA cluster with Cilium; `kubectl get nodes` shows 3 Ready
- [ ] Argo CD installed; one hello-world service deployed by `git push`
- [ ] Grafana reachable through the ingress VIP; tester can hit hello-world on 443 and nothing else
- [ ] Clean checkpoint taken of every VM

**Done when:** a commit to `main` reaches the cluster in under 5 minutes with no manual step.

### Module 1 — Networking (hub-spoke)

| Experiment | How to inject | What to learn |
| --- | --- | --- |
| Trace one request end to end | `tcpdump` on tester, hub (both spoke NICs) and lab node + Hubble UI | Every hop: tester → hub NAT/forward → MetalLB VIP → node → pod, and where SNAT happens |
| Asymmetric routing | Give one lab node a second route that bypasses the hub | Stateful firewall drops return traffic — the same bug class as your AKS `externalTrafficPolicy` fix |
| Firewall rule debugging | Block 443 for one minute, read hub drop logs | Find a blocked flow from logs, not guesswork |
| WAN latency and loss between spokes | `tc netem` on the hub's spoke-test NIC (50 ms, 1% loss) | How a slow link changes load-test results and timeouts |
| Latency inside the cluster | Chaos Mesh NetworkChaos between nodes (100 ms, 5% loss) | Retries and timeouts amplifying latency |
| Partition node3 from the others | NetworkChaos partition / iptables DROP | What etcd, Kafka, RabbitMQ, Postgres and Cassandra each do on the minority side |
| DNS failure | Stop dnsmasq on the hub; scale CoreDNS to 0 | Which clients cache, which fail at once; split DNS between hub and cluster |
| MTU mismatch | Lower MTU on the hub's spoke-lab NIC | Why small requests work and large ones hang |
| Hub as single point of failure | Shut down the hub VM | Everything external stops, in-cluster traffic keeps going — why real hubs run in pairs |
| Zero-trust inside the spoke | Cilium default-deny + per-service allow rules | Only declared service-to-service paths work |

### Module 2 — RabbitMQ: commands between services

| Experiment | How to inject | What to learn |
| --- | --- | --- |
| Lose the quorum-queue leader | Delete the RabbitMQ pod holding the leader | Raft leader election; publisher confirms block, then resume |
| Lose 2 of 3 nodes | Kill 2 pods | Quorum queue becomes unavailable instead of losing messages |
| Partition one RabbitMQ node | NetworkChaos partition | `pause_minority` behaviour vs classic mirrored queues |
| Fire-and-forget vs confirms | Kill broker mid-load with and without publisher confirms | Count lost commands |
| Duplicate delivery | Kill consumer after processing, before ack | At-least-once → idempotent handlers in inventory and payment |
| Poison command | Send a malformed `charge-payment` | Delivery limit + dead-letter exchange + delayed retry queue |
| Slow consumer | Make payment take 2 s per message | Prefetch, queue growth, memory alarm, backpressure to publishers |
| Competing consumers | Scale inventory to 3 replicas | Throughput gain and loss of ordering |

### Module 3 — Kafka: stream processing

| Experiment | How to inject | What to learn |
| --- | --- | --- |
| Throughput baseline | Generator from 2k to 20k events/s; vary batch size, compression, partitions | Where Kafka saturates on your hardware (disk, network, CPU) |
| `acks=1` vs `acks=all` | Kill partition leader mid-load | Count lost events — why `acks=all` + `min.insync.replicas=2` |
| Lose 2 of 3 brokers | Kill 2 broker pods | Producers block instead of losing data — durability over availability |
| Ordering per key | Key `clicks` by `sessionId` vs no key | Order exists only inside a partition |
| Late and out-of-order events | Generator emits 5% of events 2 minutes late | Event time, grace period, which events a window drops |
| Kill the stream processor | Delete the Kafka Streams pod mid-window | State-store restore from changelog topic; recovery time |
| Exactly-once | Toggle `processing.guarantee=exactly_once_v2`, then kill pods | Whether `sales` totals stay correct after crashes |
| Rebalance storm | Scale dashboard consumers up/down under load | Lag spikes; cooperative-sticky assignor |
| CDC | Update stock rows in Postgres | Debezium events, compacted topic, stream-table join |
| Replay | Reset dashboard offsets to 3 days ago | Rebuild a read model from the log; retention sizing |
| Schema change | Add/remove a field in Apicurio | Backward/forward compatibility across Rust, Java and Node consumers |

### Module 4 — Distributed databases

| Experiment | How to inject | What to learn |
| --- | --- | --- |
| Postgres primary dies | Delete primary pod / stop node | Failover time, client reconnect, lost writes with async replication |
| Sync vs async replication | Switch CNPG synchronous setting, re-run | Latency cost of zero data loss |
| Replication lag | Heavy write load, read from replica | Read-your-writes violated; fix by routing or session tokens |
| Postgres split brain | Partition primary from the others | How CNPG fences the old primary |
| Cassandra consistency levels | Write at `ONE`, read at `ONE`, with one node partitioned | Stale reads; then `QUORUM`/`QUORUM` (R + W > N) removes them |
| Cassandra node down, then back | Stop a node for 10 min while writing | Hinted handoff, read repair, why `nodetool repair` exists |
| Cassandra clock skew | TimeChaos +30 s on one node | Last-write-wins silently drops newer writes |
| Hot partition | Partition key = `productId` with one best-seller | One node saturated; redesign the key (bucketing) |
| Redis shard primary failover | Kill master | Compare with CNPG; risk of losing acknowledged writes |

### Module 5 — Redis: distributed cache

Run every experiment under k6 load from the tester, and watch three numbers: cache hit ratio, Postgres QPS, and p99 latency at the gateway.

**Cache correctness**

| Issue | How to provoke it | Fix / what to learn |
| --- | --- | --- |
| Stale data | Update stock in Postgres without touching the cache | Invalidate on write, short TTL, or evict from the Debezium CDC stream |
| Invalidation race | Concurrent read-miss + write: the old value is written back after the delete | Versioned values with set-if-newer (Lua), or delayed double delete |
| Cache + DB dual write | Write DB then cache; kill the pod in between | Delete, don't update, the cache; let the next read refill it |
| Cold cache | `FLUSHALL` or restart all shards under load | DB load spike; warm-up job, RDB/AOF persistence trade-off |

**Load-shaped failures**

| Issue | How to provoke it | Fix / what to learn |
| --- | --- | --- |
| Cache stampede | One hot key expires while k6 hits it | Single-flight lock per key, or early probabilistic refresh |
| Cache avalanche | Warm 100k keys with the same TTL | Mass expiry → DB spike; add TTL jitter |
| Cache penetration | k6 requests random product IDs that don't exist | Every request hits the DB; negative caching, Bloom filter |
| Hot key | 80% of traffic on one best-seller | One shard at 100% CPU; local in-process L1 cache, key copies |
| Big key | A 50 MB hash for one category | Latency spikes, slow failover and slot migration; split the key, `UNLINK` |
| Memory full | `maxmemory 256mb`, keep writing | Compare `allkeys-lru`, `volatile-ttl` and `noeviction` (write errors) |
| Slow command | `KEYS *` on a large shard | Single thread blocks every client; `SCAN`, `SLOWLOG` |

**Cluster behaviour**

| Issue | How to provoke it | Fix / what to learn |
| --- | --- | --- |
| Lost writes on failover | Write, then kill the shard primary before it replicates | Async replication loses acknowledged writes; `WAIT`, `min-replicas-to-write` |
| Split brain | Partition a primary away from the majority | It keeps accepting writes until `cluster-node-timeout`; those writes vanish on heal |
| Resharding under load | Move slots between shards while k6 runs | `MOVED`/`ASK` redirects; clients must refresh slot maps |
| Cross-slot operations | `MGET` keys on different shards | `CROSSSLOT` error; hash tags like `{order:42}` |
| Connection storm | Fail a shard with 30 pods connected | Reconnect burst; pooling and backoff in all 4 languages' clients |

**Redis beyond caching**

| Issue | How to provoke it | Fix / what to learn |
| --- | --- | --- |
| Distributed lock safety | Lock with `SET NX PX`, freeze the holder past the TTL (Chaos Mesh pod pause) | Two holders at once; fencing token checked in Postgres |
| Distributed rate limiter | 3 gateway replicas; fixed vs sliding window in Lua | Accuracy across replicas; fail-open vs fail-closed when Redis is down |

### Module 6 — Distributed-systems problems

| Problem | Provoke it | Fix pattern |
| --- | --- | --- |
| Dual write (DB + broker) | Crash between DB commit and publish | Transactional outbox (RabbitMQ) or CDC (Kafka) |
| Distributed transaction | Payment fails after stock reserved | Saga with compensating commands |
| Duplicate requests | Client retries on timeout | Idempotency key table |
| Retry storm | Slow payment service, aggressive retries | Exponential backoff + jitter, retry budget |
| Cascading failure | Payment hangs, gateway threads fill | Timeouts, circuit breaker, bulkheads |
| Clock skew | TimeChaos (+30 s on one node) | Don't order by wall clock; use offsets, versions, logical clocks |
| Thundering herd | Cache expires under load | Request coalescing, jittered TTL |
| Consistency check | Record a history of operations, run a Jepsen-style checker | Measure, don't assume, what guarantee you have |

### Module 7 — Performance

| Test | Shape (k6) | Question it answers |
| --- | --- | --- |
| Load | Ramp to expected RPS, hold 10 min | Do we meet the SLO (e.g. p99 < 300 ms)? |
| Stress | Step up until errors > 1% | Where is the breaking point, and which component breaks first? |
| Spike | 10× traffic for 1 min | Does autoscaling and Kafka buffering absorb it? |
| Soak | Moderate load for 4–8 h | Memory leaks, connection pool exhaustion, disk growth |
| Chaos under load | Load test + broker or DB kill | Error budget burned by one failure |

### Module 8 — Security

| Area | Exercise |
| --- | --- |
| Reconnaissance | From the tester: `nmap` the lab spoke in normal mode (only 443 open) and in pentest mode; compare |
| Network detection | Suricata on the hub flags the nmap and ZAP traffic; tune one rule |
| Supply chain | Trivy image scan fails the build on critical CVEs |
| Cluster | kube-bench CIS report; fix findings; Pod Security "restricted" |
| Segmentation | Cilium default-deny verified: a compromised pod can't reach Postgres or Cassandra |
| Transport | mTLS between services; TLS + auth on RabbitMQ, Kafka (SASL/SCRAM + topic ACLs) and Cassandra |
| Data | Least-privilege DB roles per service; secrets only via Sealed Secrets |
| App | OWASP ZAP baseline + API scan on the gateway; rate limiting and JWT auth hold under k6 abuse traffic |
| Runtime | Falco alerts on a shell spawned in a container |

## Observability and test toolkit

Install observability in Module 0, before anything else: a failure you can't see is a failure you can't learn from. All 4 languages export through OpenTelemetry, so one trace follows a request from Node through .NET, Kafka, Java and Rust.

| Need | Tool |
| --- | --- |
| Metrics + alerts | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) |
| Logs | Loki + Alloy; hub firewall and Suricata logs shipped in too |
| Traces | OpenTelemetry Collector → Tempo |
| Network flows | Cilium Hubble UI; `tcpdump` on the hub |
| RabbitMQ | Management UI + Prometheus plugin (queue depth, unacked, confirms) |
| Kafka | Kafka UI (kafbat), Strimzi Kafka Exporter for consumer lag |
| Databases | CNPG and K8ssandra (Cassandra) Grafana dashboards |
| Fault injection | Chaos Mesh, `tc netem` on the hub, Toxiproxy for app-level faults |
| Load / stress | k6 on the tester VM, results pushed to Prometheus through the ingress |
| Security scans | nmap, OWASP ZAP (tester), Suricata (hub), Trivy, kube-bench, Falco |

One Grafana dashboard per module with the 4 golden signals (latency, traffic, errors, saturation) plus that module's key metric — ISR count, replication lag, consumer lag, RabbitMQ queue depth, Cassandra dropped mutations.

## Build order and open questions

Build one layer, prove it with one experiment, then add the next. Never install the whole stack at once — when it fails you won't know which layer did it.

1. **Network** — Hyper-V switches, hub VM (routing, NAT, DNS, firewall), tester VM, 3 lab VMs resized to 7 GB; checkpoint.
2. **Cluster** — k3s HA, Cilium (CNI + LB IPs + Gateway API); tester reaches the VIP through the hub. ✅ Done 2026-10-21
3. **Delivery** — GitHub repo, Argo CD, hello-world via push; observability stack → **Module 0 done**, then Module 1. (Repo, Argo CD, cert-manager ✅ 2026-10-21; push-to-deploy and observability next)
4. **RabbitMQ + Postgres** — order, inventory, payment saga → Module 2.
5. **Kafka** — Strimzi, generator, stream processor, dashboard → Module 3.
6. **Cassandra + Kafka Connect** (Debezium, sink) → Module 4.
7. **Redis Cluster** — cache-aside in inventory, rate limiter in gateway, saga lock → Module 5.
8. **Module 6** failure patterns across the whole system.
9. **Module 7** performance, then **Module 8** security; re-run Module 7 to measure what security costs (TLS, policies).

**Open questions**

- Is the hypervisor Hyper-V — confirmed; the switch types above are Hyper-V's.
- How many physical cores does the host have — 12 (confirmed): 15 vCPU across 5 VMs leaves headroom, so CPU is not the bottleneck; RAM is.
- Public or private GitHub repo — public (confirmed): make GHCR packages public too, so the cluster needs no pull secret.
- Clickstream shop, confirmed for the Kafka module.
