# M1-01 — Trace one request end to end

**Date:** 2026-10-21 · **Module:** 1 Networking · **Status:** done (baseline, no fault)

## Hypothesis

A request from the tester to `https://hello.apps.lab`:
1. crosses the hub **without NAT** (source stays 10.20.0.10, because the hub only routes and filters between spokes),
2. reaches the node that Cilium elected to answer ARP for the VIP 10.10.0.200,
3. is handed by Cilium's eBPF to **Envoy** on that node, which ends TLS and opens a **new** TCP connection to a hello pod, possibly on another node through VXLAN,
4. so the pod sees Envoy's address, not the tester's. The client IP survives only in `X-Forwarded-For`.

## Setup

- VIP 10.10.0.200 ARP owner (lease `cilium-l2announce-gateway-cilium-gateway-lab-gateway`): **lab-node1**
- hello pods: `…n2h7k` 10.42.1.84 on lab-node2, `…q5brq` 10.42.2.49 on lab-node3. **Neither is on the VIP node.**
- Hub firewall: normal mode (tester → lab only TCP 443 to the VIP)
- Cilium 1.20.3, VXLAN tunnel, kube-proxy replacement; lab-node1's Cilium ingress IP: 10.42.0.194

## Action

`./trace.sh`: tcpdump on every hop at once (SYN/SYN-ACK only), the hub's ARP entry for the VIP cleared first, then one `curl` from the tester. Hubble L7 flows from the relay afterwards.

## Observed

```
tester 10.20.0.10:45014
  │ SYN → 10.10.0.200:443                                   (tester eth0)
  ▼
hub  eth3 in ── nft forward: accept "tester->lab: 443 to VIP" ── eth2 out
  │ ARP who-has 10.10.0.200 → reply 00:15:5d:0a:01:11 (= lab-node1 eth0)
  │ SYN 10.20.0.10:45014 → 10.10.0.200:443  (unchanged: no NAT)
  ▼
lab-node1 eth0 ── Cilium eBPF: VIP is a Gateway → redirect to local Envoy
  │ Envoy: TCP + TLS from the tester, reads the HTTP request, picks a backend
  │ NEW connection: 10.42.0.194:34099 (node1 ingress IP) → 10.42.2.49:8080
  │ VXLAN 10.10.0.11 → 10.10.0.13 :8472, inner SYN mss 1410
  ▼
lab-node3 ── hello-…q5brq:8080 answers → back the same way
```

Key lines (from the two runs on 2026-10-21):

| Hop | Capture |
| --- | --- |
| tester eth0 | `08:04:22.030231 10.20.0.10.32936 > 10.10.0.200.443: Flags [S] … mss 1460` |
| hub eth3 (in) | `08:04:22.029687 10.20.0.10.32936 > 10.10.0.200.443: Flags [S]` |
| hub eth2 (out) | `ARP, Request who-has 10.10.0.200 tell 10.10.0.1` → `Reply 10.10.0.200 is-at 00:15:5d:0a:01:11` then `10.20.0.10.32936 > 10.10.0.200.443: Flags [S]` |
| VIP node eth0 | `08:05:06.958021 10.20.0.10.45014 > 10.10.0.200.443: Flags [S]` |
| VXLAN node1 → node3 | `08:05:06.962805 10.10.0.11.39112 > 10.10.0.13.8472: OTV … 10.42.0.194.34099 > 10.42.2.49.8080: Flags [S] … mss 1410` |
| Hubble L7 (node1) | `10.20.0.10:45014 (ingress) -> demo/hello-…q5brq:8080 http-request FORWARDED (GET https://hello.apps.lab/)` then `http-response … 200 2ms` |
| Response | `{"service":"hello","version":"3da954aea674","pod":"hello-6695cbcc9d-q5brq",…}` |

## Result

**Confirmed**, all four points:

1. **No NAT on the hub.** The SYN leaves eth2 with the same source 10.20.0.10:32936 it arrived with on eth3. (The hub masquerades only toward the internet, on eth0.)
2. **ARP decides the node.** The hub asked who has 10.10.0.200, and lab-node1's MAC answered, because lab-node1 holds the L2-announcement lease. This is the MetalLB-style L2 behaviour, done by the Cilium agent.
3. **Envoy is a full proxy, not NAT.** Node1 receives the tester's SYN at .958, but the upstream SYN to the pod only leaves at .962, about 4.8 ms later. Envoy first finishes TCP + TLS with the tester, reads the HTTP request, and only then connects to a backend. Upstream, it uses node1's **ingress IP 10.42.0.194** as its source.
4. **The client IP survives only at L7.** The pod sees 10.42.0.194. The tester's address is in `X-Forwarded-For` (and in Hubble's L7 record, which matches on source port 45014).

Also seen:
- **Cross-node hop.** Neither hello pod is on the VIP node, so every request pays one VXLAN hop (node1 → node2/3).
- **VXLAN costs 50 bytes.** The inner SYN advertises `mss 1410` versus `mss 1460` outside: VXLAN's 50-byte overhead, accounted for automatically by Cilium setting a 1450 MTU inside pods. Remember this for the MTU experiment.
- **Envoy reuses upstream connections.** Right after a burst of requests, a traced request produced *no* new SYN to the pod, because it rode an existing Envoy → pod connection. Envoy keeps a connection pool per backend. Under load, the tester's TCP connections and the pod's TCP connections are not 1:1. That's why `trace.sh` matches all packets to the hello pods' IPs, not just SYNs.
- **Load balancing per request.** Successive runs went to different pods (`…q5brq` on node3, then `…n2h7k` on node2). Envoy picks a backend for each request, not per client.
- **Clocks disagree.** The hub logged the SYN on eth3 (.029687) *before* the tester logged sending it (.030231). Each VM's clock is independent (chrony via the hub), so sub-millisecond ordering across machines isn't trustworthy. That's the clock-skew lesson in miniature.

## Fix

None (baseline). Things to try from here:
- **Keep traffic on the VIP node:** run a hello pod on the VIP node (or set the Gateway's backend to prefer local endpoints) and see the VXLAN hop disappear.
- **Move the VIP:** cordon or stop lab-node1 and watch the lease move to another node; measure how long the VIP is unreachable (→ Module 1 "partition" and Module 7).

## Re-run

Not needed for a baseline. Re-run `./trace.sh` after any network change (Cilium upgrade, native routing, MTU change) and compare.

## Lessons

- In this lab, "where does SNAT happen?" has a surprising answer: **nowhere on the path into the cluster**. The hub only routes, Cilium only redirects, and the address change comes from Envoy opening a second connection. Rate limiting and logging by client IP must therefore use `X-Forwarded-For`, not the TCP source.
- The ARP owner of a VIP is a single node. All gateway traffic enters there, whatever the pod placement.
- Filtering inside VXLAN with tcpdump: inner TCP ports sit at `udp[50:2]`/`udp[52:2]` and the flags byte at `udp[63]` (8 UDP + 8 VXLAN + 14 Ethernet + 20 IP bytes).
