# M1-02 — Asymmetric routing through a stateful firewall

**Date:** 2026-10-21 · **Module:** 1 Networking · **Status:** done

## Hypothesis

If replies take a different path from requests, the hub's stateful firewall sees only half of each connection. It sees the tester's SYN but never the SYN-ACK, so it marks the tester's next packets `ct state invalid` and drops them. Both ends complete the TCP handshake from their own point of view, then the connection hangs. And since the hub dropped invalid packets **without logging**, Grafana/Loki would show nothing.

The same bug class as the AKS `externalTrafficPolicy` fix: return traffic leaving by a path the stateful device doesn't see.

## Setup

- Normal path: tester 10.20.0.10 → hub (eth3 → eth2) → VIP 10.10.0.200 on lab-node1, and back the same way.
- Hub: `nf_conntrack_tcp_loose = 1` (conntrack may pick up mid-stream connections, a possible reason for the hypothesis to fail).
- Tester `rp_filter = 2` (loose): it will accept a reply arriving on a different NIC.

## Fault

`./run.sh break`:
1. Hot-add a NIC to the tester on spoke-lab: `eth1` = `10.10.0.250/32`. It's a /32 with no subnet route, so the tester **still sends to the VIP via the hub**.
2. On the VIP node (lab-node1): `ip route add 10.20.0.10/32 via 10.10.0.250`. **Replies skip the hub.**

```
request:  tester eth0 ──▶ hub eth3 ─[nft: NEW, accept 443 to VIP]─▶ hub eth2 ──▶ lab-node1
reply:    tester eth1 ◀────────────── (spoke-lab, direct) ◀──────────────────────── lab-node1
```

## Observed (`./run.sh probe`, 08:25:34)

| Where | What |
| --- | --- |
| tester eth0 | `[S]` → then `[.]` ACK and `[P.]` ClientHello 0:517, then the ClientHello **retransmitted** at +0.2, +0.4, +0.8, +1.7 s |
| tester eth1 (bypass) | `[S.]` SYN-ACK from 10.10.0.200, **repeated** at +1, +3, +7 s (node1 never got the ACK) |
| hub eth3 (in) | SYN, ACK, ClientHello and every retransmit **arrive** |
| hub eth2 (out) | **only the SYN** leaves; everything after it is dropped |
| hub conntrack | `SYN_SENT src=10.20.0.10 dst=10.10.0.200 sport=33044 dport=443 [UNREPLIED]` |
| curl | `exit=28` (timeout) after 8 s |
| hub `fw-drop` log | 7 lines before, **7 after**: the drops weren't logged anywhere |

## Result

**Confirmed.** The hub's conntrack entry stayed in `SYN_SENT [UNREPLIED]`, because the SYN-ACK went round it. The tester's ACK in the original direction then doesn't fit the TCP state machine and is classified `invalid`. `nf_conntrack_tcp_loose = 1` doesn't help: it lets conntrack pick up connections it has *no* entry for, but here an entry exists in the wrong state.

Both endpoints believed the handshake succeeded (the tester got a SYN-ACK; node1 got a SYN), so the failure shows up as a **hang after connect**: TLS never completes, and no RST or error appears anywhere. The worst kind to debug.

## Fix

1. **Make it visible** (permanent, `bootstrap/hub/nftables.conf`): log invalid drops in both the `input` and `forward` chains with the prefix `fw-drop invalid:` and count them. The existing rsyslog → Alloy → Loki pipeline ships anything matching `fw-drop`.
2. **Remove the cause** (`./run.sh restore`): replies must return through the same stateful hop. In Azure terms, every spoke's route table must send the return path through the same firewall as the forward path. In Kubernetes terms, `externalTrafficPolicy: Local` keeps the reply on the node that received the request.

## Re-run

| Run | Result |
| --- | --- |
| Fault in place, **with logging** | Still `exit=28`, but now the hub counter showed `ct state invalid counter packets 11`, and `fw-drop invalid: IN=eth3 OUT=eth2 SRC=10.20.0.10 DST=10.10.0.200 LEN=52 …` (the ACK) then `LEN=569` (the ClientHello). **13 lines in Loki within 2 minutes**: `{job="hub-syslog"} \|= "fw-drop invalid"` |
| After `restore` | `http=200` in ~8 ms ×3; the invalid counter unchanged (17 → 17) during a healthy request |

## Lessons

- **Asymmetric routing fails silently** unless the firewall logs invalid-state drops. Most default rule sets (including mine, until now) drop invalid without a trace.
- **The signature:** the handshake completes at both ends, the first data packet never arrives, the server retransmits its SYN-ACK and the client retransmits its first data packet, and the firewall's conntrack shows `SYN_SENT [UNREPLIED]`.
- Hot-adding a NIC to a running Gen 2 Hyper-V VM works; a /32 with no route lets a host accept replies on an interface it never sends from (with `rp_filter` loose).
- **Grafana query to keep:** `sum by (host) (count_over_time({job="hub-syslog"} |= "fw-drop invalid" [5m]))`. Alert if it's ever above zero.
