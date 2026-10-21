# Experiments

One folder per experiment: `m<module>-<nn>-<slug>/` with a `README.md` card, plus the chaos YAML, k6 script or capture script that reproduces it.

## Card template

```markdown
# M<module>-<nn> — <title>

**Date:** YYYY-MM-DD · **Module:** <n> · **Status:** planned | done | needs re-run

## Hypothesis
What I expect to happen, specific enough to be wrong.

## Setup
State of the system before (versions, replicas, where pods run, firewall mode).

## Fault / action
Exactly what was injected or done (command or YAML in this folder).

## Observed
Raw evidence: captures, Grafana panels/queries, Hubble flows, logs. Timestamps.

## Result
Hypothesis confirmed / refuted, and why.

## Fix
What changes the behaviour (or "none, baseline").

## Re-run
Same fault after the fix, and what changed.

## Lessons
Short, reusable.
```

## Index

| Card | Module | What |
| --- | --- | --- |
| [m1-01-trace-request](m1-01-trace-request/) | 1 Networking | One HTTPS request from the tester traced at every hop: hub, ARP, Cilium, Envoy, VXLAN, pod |
| [m1-02-asymmetric-routing](m1-02-asymmetric-routing/) | 1 Networking | Replies bypass the hub: conntrack `SYN_SENT [UNREPLIED]`, connection hangs after the handshake; invalid drops now logged |
| [m1-03-firewall-debugging](m1-03-firewall-debugging/) | 1 Networking | A bad rule found from Loki alone (33 drops = 33 failures); found 1-min-late systemd timers and Grafana phoning home |
| [m1-04-wan-latency-loss](m1-04-wan-latency-loss/) | 1 Networking | netem RTT +50 ms / 1–5% loss: fresh request = 4 RTT (DNS!), loss moves p99 in 1 s steps; DNS TTL 0 fixed, IPv6 negative caching open |
| [m1-05-cluster-latency-retries](m1-05-cluster-latency-retries/) | 1 Networking | 100 ms + 5% loss on a depth-3 chain: naive retries → 2.5× leaf load, 8/30 ok; deadline budget → 0.9×, 35/40 ok; ndots DNS cost 0.5–3 s |
| [m4-01-pg-failover](m4-01-pg-failover/) | 4 Databases | Primary deleted / SIGKILLed / powered off: out of the box 3 min or never; after operator HA, client keepalives and a 15 s smart shutdown: 3 s / 23 s / 69 s, 0 lost writes |

## Tools

| Tool | Where | Use |
| --- | --- | --- |
| `tcpdump` | every VM | `ssh lab@<ip> 'sudo tcpdump -nn -i <if> ...'` |
| Hubble | cluster | `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server <relay-ip>:80 ...`, or https://hubble.apps.lab |
| Chaos Mesh | cluster | YAML in each card's folder; dashboard https://chaos.apps.lab |
| `tc netem` | hub | WAN latency and loss between spokes |
| Hub firewall | hub | `sudo lab-fw status / normal / pentest`; drops in Grafana: `{job="hub-syslog"} \|= "fw-drop"` |

**Chaos Mesh dashboard login** (security mode): Name = any label; Token from the least-privilege account `chaos-dashboard-admin` (manages experiments, reads pods/namespaces):
`kubectl --kubeconfig ~/.kube/lab.yaml -n chaos-mesh create token chaos-dashboard-admin --duration 8h | clip` (copies it; paste into the dashboard).
