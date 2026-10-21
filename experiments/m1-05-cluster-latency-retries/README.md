# M1-05 — Latency inside the cluster: how timeouts and retries amplify it

**Date:** 2026-10-21 · **Module:** 1 Networking · **Status:** done

## Hypothesis

With 100 ms delay and 5% loss on every hello pod, a depth-3 call chain (`tester → gateway → hello → hello → hello → hello`):
1. **Naive per-hop timeouts with retries fail almost completely**, and the lower hops get **many times more requests** than the client sent, up to (1+retries)^depth = 27× at the leaf with 2 retries.
2. **Deadline propagation** (one budget for the whole chain; every hop uses only what's left, and doesn't start an attempt it can't finish) keeps load near 1× and turns hopeless retries into fast failures.

## Setup

- `hello` gained `/chain?depth=N&timeout_ms=T&retries=R` (fixed per-try timeout, retry every failure) and `/chain?depth=N&retries=R&budget_ms=B` (absolute deadline in an `x-deadline-ms` header, jittered 10–30 ms backoff, no attempt without time left). It calls itself through the `hello` Service. Counters: `hello_requests_total{path,depth,code}`, `hello_downstream_attempts_total{result}` (also scraped by Prometheus).
- 2 hello pods (one on lab-node2, one on lab-node3). Node 24 `fetch`, keep-alive on.
- Fault (`chaos-slow-net.yaml`): Chaos Mesh `NetworkChaos` netem on **egress of every hello pod**: 100 ms delay, 5% loss. A pod-to-pod call pays the delay twice (request out of the caller, reply out of the callee).
- `./run.sh scenario`: 30–40 sequential requests from the tester (client timeout 3 s). Load per depth is read **directly from the pods' counters** before and after, so it's exact.

## Observed

| Scenario | Query | OK | client p50 | p95 | served d3 / d2 / d1 / leaf | leaf ÷ client |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | timeout 300 ms, 2 retries | **40/40** | 12 ms | 18 ms | 40 / 40 / 40 / 40 | 1.0× |
| chaos, no retries | timeout 300 ms, 0 retries | 0/40 | 408 ms | 509 ms | 40 / 0 / 0 / 0 | 0 |
| chaos, naive | timeout 300 ms, 2 retries | 0/40 | 1109 ms | 2130 ms | 40 / 0 / 0 / 0 | 0 |
| chaos, naive | **timeout 700 ms**, 2 retries | **8/30** | 2310 ms | 2614 ms | 30 / **58 / 86 / 76** | **2.5×** |
| chaos, naive | timeout 1000 ms, 2 retries | 23/30 | 1016 ms | 3003 ms | 30 / 46 / 66 / 68 | 2.3× |
| chaos, **deadline budget** | budget 2500 ms, 2 retries | **35/40** | 1115 ms | 2721 ms | 40 / 40 / 40 / 38 | **0.9×** |

Across the naive runs: 500 downstream attempts timed out against 458 that succeeded.

## Result

1. **Amplification: confirmed, but not in the way I expected.** With 700 ms per try, the load grows at every level: 30 → 58 → 86 → 76. Each upper hop gives up and retries while the hop below it is still working on the abandoned call, which nobody cancels. The leaf ran **2.5×** the client's traffic, and only 8 of 30 requests succeeded: **more load and fewer successes at the same time**. The worst-case 27× didn't happen because loss is partial and many retries succeed. The shape is the same as a retry storm.
2. **A timeout shorter than connection setup does no work at all.** At 300 ms per try, nothing ever reached depth 2. A fresh pod-to-pod call costs DNS (~100 ms) + SYN (100) + SYN-ACK (100) ≈ 300 ms *before the request is sent*. Every attempt was aborted in the handshake. Zero amplification, zero success: retries that can never succeed are pure waste.
3. **Deadline propagation: confirmed.** 35/40 succeeded, and the load stayed at ~1× at every depth. One budget for the whole chain means a lower hop never keeps working on a call the caller has already given up on, and nobody starts an attempt that can't finish.

## Finding: DNS was the biggest latency amplifier

The first `budget` run failed **all 40** requests, with `attempts: 1` at the first hop. DNS had eaten the budget. Measured inside a hello pod under the same chaos (`dns.lookup`, 5 tries):

| Name | Lookup times (ms) |
| --- | --- |
| `hello.demo.svc.cluster.local` | 3011, 505, 3006, 503, 503 |
| `hello.demo.svc.cluster.local.` (trailing dot) | 101, 101, 2602, 2603, 101 |

Kubernetes sets `ndots:5`, and this name has 4 dots, so the resolver **walks the search list first** (`…cluster.local.demo.svc.cluster.local`, etc.), A and AAAA each, every query paying +100 ms and 5% loss. A lost UDP query costs the resolver's ~2.5 s retry. Node's `fetch` doesn't cache DNS, and a new connection is opened after every aborted attempt, so this hit nearly every retry.

**Fix (kept):** `DOWNSTREAM=http://hello.demo.svc.cluster.local.` in the Deployment (FQDN, trailing dot, one query). All the results above are with this fix.

## Fix

- **Propagate deadlines, don't stack timeouts.** One budget for the request, passed down; each hop's timeout = time remaining; don't retry if the remainder can't cover an attempt. (gRPC deadlines do exactly this; for HTTP, a header like `x-deadline-ms`.)
- **Retry at one layer only**, ideally the edge, with jittered backoff and a retry budget. Retrying at every hop multiplies the load.
- **A per-try timeout must exceed connection setup** (DNS + TCP handshake under the worst expected latency), or the retries just burn handshakes.
- **Fully qualified names** (trailing dot) or lower `ndots` for service-to-service calls, and **connection reuse**, so DNS isn't on every retry.

## Re-run

The deadline-budget row is the re-run of the naive rows under the same fault: 35/40 OK at 0.9× load, against 8/30 OK at 2.5× load (700 ms per-try). Run `./run.sh experiment` for the full set (~2.5 min), and `./run.sh scenario <label> "<query>"` for single cases.

## Lessons

- Under latency, **timeouts + retries at every hop amplify load downward and reduce success**. It's the cascading-failure mechanism Module 6 will build on (retry storm, circuit breaker).
- Timeouts that are too short don't protect anything; they turn every call into a failed handshake.
- **DNS is part of every call's latency budget.** Under packet loss, the `ndots:5` search walk can cost seconds per lookup.
- Measure load at each depth, not just client success: the client sees "slow and failing", the leaf sees "2.5× traffic". Both are the same incident.
