# M1-04 — WAN latency and loss between the spokes

**Date:** 2026-10-21 · **Module:** 1 Networking · **Status:** done (one open item: IPv6 negative DNS answers)

## Hypothesis

With `tc netem` on the hub's spoke-test link (both directions):
1. **Latency multiplies.** A fresh HTTPS request costs ~3 round trips (TCP + TLS 1.3 + HTTP), so +50 ms RTT ≈ +150 ms. A request on a reused connection pays ~1 RTT.
2. **Loss hits the tail, not the median.** With ~1% loss the median doesn't move. A lost SYN/SYN-ACK waits for TCP's 1 s initial retransmit, so a client with a 1 s timeout sees ~2% slow or failed requests.

## Setup

- `./run.sh wan <ms> <loss%>`: netem on hub eth3 egress (towards the tester), and on eth3 ingress via an `ifb0` redirect (towards the lab). Both directions are shaped. Ping across the hub with `wan 25 0.5`: **RTT 50.4 ms**.
- `./run.sh measure`: 200–400 sequential **fresh** requests from the tester to `https://hello.apps.lab` (new DNS + TCP + TLS each), timeout 5 s. Records `time_connect`, `time_appconnect`, `time_total`. ">1 s" = what a client with a 1 s timeout would have seen.
- `./run.sh reuse`: 50 requests on one kept-alive connection.
- The tester's DNS server is the hub (10.20.0.1), so **DNS also crosses the WAN**.

## Observed

| Scenario (each way) | n | failed (5 s) | >1 s | TCP done p50 | TLS done p50 | total p50 | p95 | p99 | max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 200 | 0 | 0 | 2 ms | 5 ms | **7 ms** | 8 | 9 | 9 |
| +25 ms (RTT +50) | 200 | 0 | 0 | **102 ms** | 156 ms | **208 ms** | 209 | 209 | 211 |
| +25 ms, 0.5% loss (~1% RTT) | 200 | **7** | 2 | 102 | 156 | 208 | 210 | **564** | 1253 |
| +25 ms, 2.5% loss (~5% RTT) | 200 | **18** | 11 | 102 | 156 | 209 | **1211** | 1262 | 2254 |

Re-runs after the DNS TTL fix (below), n=400: ~1% loss → 7 failed, 4 >1 s, p99 558 ms; ~5% loss → 20 failed, 23 >1 s, p95 1213 ms. The same shape.

| Reused connection | first request | others p50 |
| --- | --- | --- |
| baseline | 7 ms | **1 ms** |
| RTT +50 ms | 209 ms | **52 ms** |

**Failed requests**: every one shows `connect=0.000 total=5.00`. They never reached TCP; they were stuck in **name resolution** until the 5 s timeout.
**Slow successes (>1 s)**: every one shows `connect≈1.10–1.15 s`, i.e. a lost SYN or SYN-ACK waiting for the 1 s initial RTO.

## Result

1. **Partly refuted: a fresh request costs 4 RTT, not 3.** The cost is DNS 50 + TCP 50 + TLS 50 + HTTP 50 = 208 ms. I forgot that DNS crosses the same link. A reused connection pays exactly 1 RTT (52 ms), so **connection reuse is worth 4× under WAN latency**.
2. **Confirmed for the tail:** p50 is unchanged under loss, while p99 goes 209 → 564 ms (1%) and p95 209 → 1211 ms (5%). The >1 s requests are exactly the SYN/SYN-ACK retransmits.
3. **Not predicted: outright failures** (3.5% at ~1% loss) come from **DNS over UDP**. A lost query has no TCP retransmit behind it, and the request stalled for the full 5 s. That's worse than the TCP loss it rides on.

## Why DNS was in every request: two findings

**a) TTL 0 everywhere.** The hub's dnsmasq answers its own names (`*.apps.lab`, `<vm>.lab`) with TTL 0 by default, and the **Hyper-V Default Switch's DNS proxy returns TTL 0 for every upstream name** (github.com: 0 from 172.27.192.1, a normal TTL from 1.1.1.1). So no client could cache anything.
**Fix (kept):** `local-ttl=60` and `min-cache-ttl=60` in `bootstrap/hub/lab-dns.conf`. Now IPv4 lookups cache: `getent ahostsv4 hello.apps.lab` 53 ms → **3 ms** on the second call.

**b) IPv6 negative answers can't be cached (open).** curl and most clients look up A **and** AAAA. For `hello.apps.lab`, dnsmasq answers AAAA with `NXDOMAIN` and **no SOA**. Hosts-file names (`lab-node1.lab`) get `NOERROR`/no data, also without an SOA. Without an SOA, RFC 2308 forbids caching a negative answer, so the AAAA half goes to the hub on **every** request:

| Lookup under RTT +50 ms | 1st | 2nd | 3rd |
| --- | --- | --- | --- |
| `getent ahostsv4` (A only) | 53 ms | 3 ms | 3 ms |
| `getent ahosts` (A + AAAA) | 54 ms | 54 ms | 54 ms |
| curl `time_namelookup` | 51 ms | 51 ms | 51 ms |
| `curl -4` | 0.6 ms | 0.5 ms | |

`NXDOMAIN` for a name that *has* an A record is also semantically wrong (RFC 8020: "nothing exists at or below this name"). dnsmasq only adds SOAs to negative answers in authoritative mode, which can't serve the `*.apps.lab` wildcard. **Options for later:** an authoritative server for `lab` (e.g. CoreDNS on the hub with a real zone + SOA), explicit records instead of the wildcard, or IPv4-only clients where it matters. For services *inside* the cluster this doesn't apply (CoreDNS answers properly).

## Lessons

- **Count every round trip, DNS included.** Under WAN latency, a fresh HTTPS request is DNS + TCP + TLS + HTTP. Connection pooling and keep-alive aren't micro-optimisations; they're the 4× difference here.
- **Loss doesn't move the median; it moves p95/p99**, in 1 s steps (the initial RTO). Watch percentiles, never averages.
- **DNS over UDP is the weakest link under loss.** A lost query stalls the caller for the resolver's whole timeout, here 5 s.
- **Check TTLs.** TTL 0 from an innocent-looking upstream (Hyper-V's DNS proxy) silently turned every request into a DNS round trip.
- **Timeouts must exceed the retransmit schedule.** With a 1 s client timeout, every lost SYN is a failure; with 1.5–2 s it's a slow success.
