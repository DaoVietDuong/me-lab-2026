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
