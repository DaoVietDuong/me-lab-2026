# me-lab-2026 — distributed systems practice lab

A home lab for breaking distributed systems on purpose and proving each fix with metrics. It runs on one Windows Hyper-V host: 5 VMs in a hub-and-spoke network, with a 3-node k3s cluster that will host a polyglot order system on RabbitMQ, Kafka, PostgreSQL, Cassandra and Redis.

| Doc | What it is |
| --- | --- |
| [docs/PLAN.md](docs/PLAN.md) | The practice plan: goals, design decisions, curriculum (Modules 0–8) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | What is built right now, how it fits together, and status |
| [bootstrap/README.md](bootstrap/README.md) | How to rebuild the environment from scratch, script by script |

## Layout

```
bootstrap/   one-time scripts: Hyper-V host, golden image, VMs, hub firewall, k3s
platform/    cluster components (Cilium, gateway, ...) — Argo CD will manage these
docs/        the plan
```

Coming with Build step 3: `services/`, `deploy/`, `experiments/`, `.github/workflows/`.
