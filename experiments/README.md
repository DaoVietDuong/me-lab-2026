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
| [m4-02-pg-sync-vs-async](m4-02-pg-sync-vs-async/) | 4 Databases | Sync costs 44% (healthy) to 99.6% (300 ms lag) of write throughput; under lag a kernel crash lost 90 acked writes with async, 0 with sync; SIGKILL loses none; CoreDNS (1 replica) SPOF stretched a sync failover to 151 s |
| [m4-03-read-your-writes](m4-03-read-your-writes/) | 4 Databases | Immediate replica reads are stale 96–98 % even idle (lag 1.2 ms); 100 % under 300 ms lag. Fixes: read primary / LSN wait (read waits) / remote_apply (write waits); ANY 1 not enough with one slow replica (62.5 % stale). A long replica read stalls replay to 28 s, then is cancelled |
| [m4-04-pg-split-brain](m4-04-pg-split-brain/) | 4 Databases | Primary partitioned from replicas/operator/API, client still connected: never two primaries (old one fenced first), but async lost all 12,164 writes acked in the 41 s before the fence (isolation 6 s + liveness 20 s + smart shutdown 15 s); sync: 0 lost, 100 s outage |
| [m2-01-quorum-leader-loss](m2-01-quorum-leader-loss/) | 2 RabbitMQ | Quorum-queue leader deleted / SIGKILLed / frozen under a 500 msg/s publisher with confirms: 0 of 130k confirmed lost, 0 duplicates; confirms paused < 0.1 s (loud) vs 6.5 s (SIGSTOP: Ra elects at 6.9 s, Erlang declares the node down only at 60 s); no liveness probe, TCP readiness passes a frozen broker |
| [m2-02-lose-two-nodes](m2-02-lose-two-nodes/) | 2 RabbitMQ | Leader + one follower killed / frozen: 0 of 80k confirmed lost; confirms just stop (40 s / 93 s) with no error, no closed connection, all pods Ready while frozen. `pause_minority` is ignored with Khepri (dead config; the operator sets it by default) |
| [m2-03-partition-one-node](m2-03-partition-one-node/) | 2 RabbitMQ | Leader cut off from the other two (clients still connected): majority elects in 9.2 s, its publisher pauses 8.6 s; the client on the isolated old leader gets no confirm and no error for the whole 229 s partition; on heal the old leader steps down and drops its term-1 tail, 0 of 80k lost, 0 duplicates. CLI blind for 67 s |
| [m2-04-confirms-vs-fire-and-forget](m2-04-confirms-vs-fire-and-forget/) | 2 RabbitMQ | Kill the publisher's broker (the leader): fire-and-forget silently loses the last 1 (500/s) / 15 (5k/s) sent; confirms lose 0 and nack the whole window on close, of which 80–90 % had in fact landed → resend = duplicates. Window 100 caps confirms at 3.7k/s |

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
