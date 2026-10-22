# Lab environment — architecture and status

*Last updated: 2026-10-21. Status of what is built, not the plan. The plan is [docs/PLAN.md](docs/PLAN.md).*

## Status at a glance

| Build step (from the plan) | State |
| --- | --- |
| 0. Old VMs retired (3 × Ubuntu 22.04 k8s VMs on C:) | ✅ Done — deleted, 35 GB freed on C: |
| 1. Network: switches, hub, tester, 3 lab VMs, hub firewall | ✅ Done — tested, `clean-base` checkpoints taken |
| 2. Cluster: k3s HA + Cilium (CNI, LB IPs, Gateway API) | ✅ Done — tester reaches `https://10.10.0.200` through the hub, nothing else |
| 3a. GitHub repo, Argo CD (app of apps), cert-manager + lab CA, `*.apps.lab` DNS | ✅ Done — all 5 Argo CD apps Synced/Healthy |
| 3b. Push-to-deploy (Actions → GHCR → Argo CD) | ✅ Done — `git push` → new version serving in **186 s** (target < 5 min) |
| 3c. Observability: Prometheus, Grafana, Loki, Tempo, Alloy | ✅ Done — metrics, logs, hub firewall drops and traces verified end to end |
| **Module 0 — Foundation** | ✅ **Complete** (2026-10-21) |
| Module 4 — Distributed databases | 🔄 **In progress**: PostgreSQL (CloudNativePG 1.30.1, PG 18.6, 3 instances) running; [M4-01 primary failover](experiments/m4-01-pg-failover/), [M4-02 sync vs async](experiments/m4-02-pg-sync-vs-async/), [M4-03 read-your-writes](experiments/m4-03-read-your-writes/), [M4-04 split brain](experiments/m4-04-pg-split-brain/) done; CoreDNS single replica = accepted risk (decided 2026-10-22). Cassandra omitted (2026-10-23), so Module 4 is closed on the Postgres side |
| Module 1 — Networking experiments | 🔄 **In progress**: Chaos Mesh 2.8.5 installed and verified (100 ms injected → median 30 → 132 ms); [M1-01 trace a request](experiments/m1-01-trace-request/), [M1-02 asymmetric routing](experiments/m1-02-asymmetric-routing/), [M1-03 firewall debugging](experiments/m1-03-firewall-debugging/), [M1-04 WAN latency/loss](experiments/m1-04-wan-latency-loss/), [M1-05 cluster latency + retries](experiments/m1-05-cluster-latency-retries/) done |
| 4. RabbitMQ + Postgres (Module 2) | 🔄 **In progress**: RabbitMQ Cluster Operator 2.23.1 + RabbitMQ 4.3.7, 3 nodes, quorum queues; [M2-01 quorum leader loss](experiments/m2-01-quorum-leader-loss/) done. Saga services next |
| 5–9. Kafka, Redis, Modules 6–8 | Not started (Cassandra omitted) |

## Topology

```
                         Internet
                            │
            ┌───────────────┴────────────────┐
            │ Windows host BOLUNGMAT         │  32 GB RAM, 12 cores, Hyper-V
            │  Default Switch (NAT, DHCP)    │  172.27.192.0/20
            │  vEthernet (lab-mgmt) 10.0.0.1 │  routes 10.10/24 + 10.20/24 → 10.0.0.2
            └───────┬───────────────┬────────┘
                    │eth0 (DHCP)    │ lab-mgmt 10.0.0.0/24 (Internal)
                    │               │eth1 10.0.0.2
              ┌─────┴───────────────┴─────┐
              │ hub                       │  nftables default-deny + NAT
              │ 1 vCPU · 1 GB · 8 GB      │  dnsmasq (DNS *.lab + egress allowlist)
              │                           │  chrony (time source for spokes)
              └─────┬───────────────┬─────┘
          eth2 10.10.0.1      eth3 10.20.0.1
                    │               │
   spoke-lab 10.10.0.0/24     spoke-test 10.20.0.0/24
   (Private switch)           (Private switch)
     │        │        │            │
 lab-node1 lab-node2 lab-node3    tester
 .11       .12       .13          .10
 4 vCPU · 5 GB · 24 GB each       2 vCPU · 2 GB · 14 GB
 └── k3s cluster (3 servers, etcd) ┘
 LoadBalancer VIPs .200–.220 (Cilium); lab-gateway = .200:443
```

*Private* switches mean nothing reaches a spoke except through the hub — not even Windows. Traffic inside a spoke (node ↔ node) is plain L2 and never crosses the hub.

## VMs

All VMs: Hyper-V Gen 2, Secure Boot (Microsoft UEFI CA), **static memory**, automatic checkpoints off, Ubuntu **24.04.5** server minimal, UTC, swap off, user `lab` (SSH key only, passwordless sudo; console password set for the Hyper-V console).

| VM | vCPU | RAM | Disk | NICs → address | Role |
| --- | --- | --- | --- | --- | --- |
| hub | 1 | 1 GB | 8 GB | eth0 Default Switch (DHCP) · eth1 10.0.0.2 · eth2 10.10.0.1 · eth3 10.20.0.1 | Router, firewall, NAT, DNS, NTP |
| lab-node1 | 4 | 5 GB | 24 GB | eth0 10.10.0.11 | k3s server + etcd |
| lab-node2 | 4 | 5 GB | 24 GB | eth0 10.10.0.12 | k3s server + etcd |
| lab-node3 | 4 | 5 GB | 24 GB | eth0 10.10.0.13 | k3s server + etcd |
| tester | 2 | 2 GB | 14 GB | eth0 10.20.0.10 | Load and attack source (k6, ZAP, nmap — not installed yet) |
| **Total** | 15 | **18 GB** | 94 GB | | |

Static MACs `00:15:5d:0a:xx:xx` are set per NIC so cloud-init can name the interfaces. All values are in [bootstrap/lab.config.ps1](bootstrap/lab.config.ps1).

**Storage:** `E:\HyperV\lab\<vm>\` (disks + config), ISO cache `E:\HyperV\iso\`. Each VM disk is a full copy of the read-only golden disk `E:\HyperV\lab\golden-2404.vhdx`, not a differencing disk.

**Checkpoints:** one `clean-base` per VM (hub refreshed after the firewall was installed). These are Standard checkpoints, so they include memory.

## Hub services

| Service | Listens on | Purpose |
| --- | --- | --- |
| sshd | eth1 (lab-mgmt) only | Administration from Windows |
| dnsmasq | eth1, eth2, eth3 :53 | `*.lab` names for all VMs (TTL 60); forwards everything else upstream (cached ≥ 60 s; Hyper-V's DNS proxy sends TTL 0); fills the egress allowlist. Known gap: AAAA answers carry no SOA, so clients can't cache them (M1-04) |
| chrony | eth2, eth3 :123 | Spokes sync time from the hub, and the hub syncs from public NTP. This is where the clock-skew experiments will hook in |
| nftables | — | Default-deny filter + NAT to eth0 |

## Firewall policy (as built)

| From → to | Allowed | Verified |
| --- | --- | --- |
| Windows → hub | SSH 22 | ✅ |
| Windows → spokes | TCP 22, 443, 6443; ping | ✅ SSH to every VM |
| tester → lab, **normal** mode | TCP 443 to 10.10.0.200 only | ✅ node1:22 blocked |
| tester → lab, **pentest** mode | Everything | ✅ node1:22 open |
| lab → tester | Nothing | ✅ blocked |
| lab → internet | TCP 443 to allowlisted domains; TCP 80 to `ubuntu.com` (apt) | ✅ github.com, ghcr.io, apt OK; example.com blocked |
| lab → external DNS | Nothing (DNS only via hub) | ✅ 1.1.1.1:53 blocked |
| tester → internet | TCP 80, 443 | ✅ |
| Spokes → hub | DNS 53, NTP 123, ICMP | ✅ |

Everything else is dropped and logged: `journalctl -k -g fw-drop` on the hub. Invalid-state packets (e.g. asymmetric routing, M1-02) are logged too, as `fw-drop invalid:`.

**Domain egress:** the firewall's `egress_https4` / `egress_http4` sets are filled by dnsmasq (`nftset=`) whenever a lab node resolves a listed domain or its subdomains: GitHub, GHCR, Docker Hub, Quay, registry.k8s.io, pkg.dev, k3s.io, jetstack, cilium, chaos-mesh, k8ssandra, strimzi, ubuntu.com. List: [bootstrap/hub/egress.conf](bootstrap/hub/egress.conf).

**Control on the hub:** `sudo lab-fw status | normal | pentest | apply`. Reloads keep the learned IPs, and mode switches only touch the tester → lab chain.

## Kubernetes cluster

| Layer | As built | Notes |
| --- | --- | --- |
| Kubernetes | k3s **v1.36.5+k3s1**, 3 servers, embedded etcd (3 members) | Survives one node loss. flannel, kube-proxy, Traefik and servicelb are disabled |
| CNI | Cilium **1.20.3** (k3s HelmChart), VXLAN tunnel, BPF masquerade | Pod CIDRs 10.42.0–2.0/24 per node, services 10.43.0.0/16 |
| Service routing | Cilium kube-proxy replacement (eBPF) | No kube-proxy DaemonSet |
| LoadBalancer IPs | Cilium LB IPAM pool `spoke-lab` 10.10.0.200–220 + L2 announcements on eth0 | One node answers ARP per VIP, chosen by a Kubernetes lease (`cilium-l2announce-*`); now lab-node1 |
| Ingress | Gateway API **v1.6.3** CRDs, `gateway/lab-gateway` (class `cilium`) HTTPS :443 on 10.10.0.200 | Cert `*.apps.lab` + IP 10.10.0.200 from the lab CA (cert-manager, renews automatically) |
| Smoke test | `hello/whoami` × 2 behind HTTPRoute `/` | Shows which pod answered and the client IP (`X-Forwarded-For: 10.20.0.10`) |
| Observability | Hubble relay + UI installed (not exposed yet) | |
| Other | Secrets encryption at rest on; etcd metrics exposed; metrics-server and local-path (k3s defaults) | |

API: `https://10.10.0.11:6443` (TLS SANs cover all three node IPs and `k8s.lab`). Cilium reaches the API on `127.0.0.1:6443`, which every node has because every node is a server.

**Resource use after install:** about 1.1–1.6 GB used per node, 3.3–3.8 GB still available.

Manifests: [platform/cluster-bootstrap/](platform/cluster-bootstrap/). They are applied by `bootstrap/40-k3s.sh` and will be handed over to Argo CD in step 3.

**Verified:** tester → `https://10.10.0.200` works (requests split across both whoami pods). Tester → :80 on the VIP, the API on 6443 and the nodes' 443 are all blocked by the hub. Windows → the VIP and the API work. All 3 Cilium agents report 3/3 nodes healthy.

## GitOps and certificates

Repo: **https://github.com/DaoVietDuong/me-lab-2026** (public). Argo CD pulls over HTTPS and needs no credentials and no inbound port.

```
platform/apps/root.yaml   (applied once by bootstrap/50-argocd.sh)
  └─ root ── syncs platform/apps/ ──┬─ argocd               platform/argocd        (Argo CD manages itself; prune off)
                                    ├─ cert-manager         Helm chart jetstack v1.21.2 (sync wave -1)
                                    ├─ cert-manager-config  platform/cert-manager  (lab CA + gateway cert)
                                    ├─ cluster-bootstrap    platform/cluster-bootstrap (LB pool, gateway, routes, whoami)
                                    └─ root                 (itself)
```

| Component | As built | Notes |
| --- | --- | --- |
| Argo CD | **v3.5.6**, upstream manifests + kustomize patches | Redis image from Docker Hub instead of public.ecr.aws (not in the egress allowlist); Dex and notifications removed; TLS ends at the gateway (`server.insecure`); server-side diff on |
| cert-manager | **v1.21.2** | CRDs kept if the app is deleted |
| Lab root CA | `cert-manager/lab-root-ca`, ECDSA P-256, valid to 2036 | Created in-cluster: the key is never in Git. **Name constraints (critical): only `*.lab` and 10.10.0.0/24** |
| Issuer | ClusterIssuer `lab-ca` | Use it for every lab certificate |

**Not managed by Argo CD:** Cilium. It stays with k3s's helm-controller, because the CNI must be running before Argo CD can start. Its source is still in Git (`platform/cluster-bootstrap/cilium.yaml`), excluded from the `cluster-bootstrap` app.

**Change the platform** by committing to `main`. Argo CD polls every **60 s** (`timeout.reconciliation`), and self-heal reverts manual `kubectl` edits to managed objects.

## CI/CD: push to deploy

```
git push (services/hello/**)
  └─ .github/workflows/hello.yml ── calls ── _build.yml (one shared template for every service)
       test stage → build → Trivy (fixable CRITICAL fails) → push ghcr.io/daovietduong/hello:<sha12>
       → commit "deploy(hello): <sha12> [skip ci]" to deploy/hello/kustomization.yaml
  └─ Argo CD app "hello" sees the bump (≤ 60 s) → rolling update (maxUnavailable 0)
```

| Piece | As built |
| --- | --- |
| Images | `ghcr.io/daovietduong/<service>:<first 12 chars of the commit SHA>`. **Public**: they inherit the repo's visibility, so the nodes pull with no credentials |
| Supply chain | Every action pinned to a full commit SHA; Trivy runs from its own image pinned by digest; the workflow token is read-only by default, and the build job gets only `contents: write` + `packages: write` |
| Tests | Each service's Dockerfile has a `test` stage that CI builds first, the same for every language |
| Concurrency | Tag bumps share one concurrency group and `pull --rebase` before pushing, so two services building at once can't lose a bump |
| Measured | CI 62 s; push → new version serving 186 s |

**Add a service:** create `services/<name>/` (Dockerfile with a `test` stage), `deploy/<name>/` (kustomization with `newTag`), `.github/workflows/<name>.yml` (copy `hello.yml`), and `platform/apps/<name>.yaml`.

**Deployed now:** `hello` (namespace `demo`, https://hello.apps.lab), with `/chain` (a self-calling call chain with timeouts, retries or a deadline budget) and `/metrics` (scraped by Prometheus). It runs as UID 1000, non-root, with a read-only root filesystem, all capabilities dropped and the RuntimeDefault seccomp profile.

## Observability

All in namespace `observability`, all Argo CD apps.

```
pods ─ stdout ─▶ /var/log/pods ─▶ Alloy (DaemonSet, node-local) ─┐
hub rsyslog ─ fw-drop, TCP 1514 ─▶ 10.10.0.201 (LB) ─▶ Alloy ────┼─▶ Loki ──┐
services ─ OTLP 4317/4318 ─▶ alloy.observability.svc ─▶ Tempo ───┼─────────┼─▶ Grafana  https://grafana.apps.lab
targets ◀─ scrape 30 s ─ Prometheus ─▶ Alertmanager ─────────────┘         │   (Loki ⇄ Tempo linked by trace_id)
k6 ─ remote write ─▶ Prometheus (receiver enabled, Module 7) ──────────────┘
```

| Component | Chart | Mode / retention | Memory now |
| --- | --- | --- | --- |
| Prometheus | kube-prometheus-stack **92.11.0** | 1 replica, 3 d or 2 GB, 3 Gi PVC, scrape 30 s | ~660 Mi |
| Grafana | (bundled) | Admin from secret `grafana-admin` (**not in Git**) | ~500 Mi (3 containers) |
| Alertmanager, operator, kube-state-metrics, node-exporter | (bundled) | | small |
| Loki | grafana/loki **7.3.0** | Single binary, filesystem, 72 h, 3 Gi PVC, no caches | ~150 Mi |
| Tempo | grafana-community/tempo **3.2.0** | Single binary, local, 24 h, 2 Gi PVC | small |
| Alloy | grafana/alloy **1.14.0** | DaemonSet: pod logs (own node only), hub syslog, OTLP → Tempo | ~60–80 Mi each |

**Scraped:** apiserver, kubelet, CoreDNS, etcd (via ScrapeConfig `etcd` → `10.10.0.1x:2381`), node-exporter, kube-state-metrics and the stack itself. All targets up, no alerts firing. Not scraped: kube-controller-manager and kube-scheduler (inside the k3s process, bound to 127.0.0.1) and kube-proxy (none; Cilium).

**Verified 2026-10-21:** every target `up`. Pod logs from every namespace reach Loki. A tester → node1:22 drop on the hub showed up in Loki (`{job="hub-syslog"}`) ~15 s later. A test OTLP trace sent to Alloy could be fetched from Tempo after 5 s.

**Use it:**
- Logs: Grafana → Explore → Loki → `{namespace="demo"}`, or the hub firewall: `{job="hub-syslog"} |= "fw-drop"`
- Send traces from a service: `OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.observability.svc:4318`
- Grafana password: `kubectl --kubeconfig ~/.kube/lab.yaml -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`

**Resource use after the stack:** nodes use 2.6–3.0 GB of 4.9 GB, with **1.9–2.3 GB available** each. Windows has ~3.6 GB free with all VMs running.

## Access

```bash
ssh lab@10.0.0.2      # hub
ssh lab@10.10.0.11    # lab-node1 (also .12, .13) — routed through the hub
ssh lab@10.20.0.10    # tester
kubectl --kubeconfig ~/.kube/lab.yaml get nodes      # from Windows
curl -k https://10.10.0.200/                         # the gateway, from Windows or the tester
```

| URL (Windows or tester) | What |
| --- | --- |
| https://argocd.apps.lab | Argo CD UI. User `admin`; password: `kubectl --kubeconfig ~/.kube/lab.yaml -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| https://hubble.apps.lab | Hubble UI: live flow map |
| https://grafana.apps.lab | Grafana: metrics, logs, traces. User `admin`, password command in [Observability](#observability) |
| https://chaos.apps.lab | Chaos Mesh dashboard. Token: `kubectl --kubeconfig ~/.kube/lab.yaml -n chaos-mesh create token chaos-dashboard-admin --duration 8h \| clip` (Name: any label) |
| https://hello.apps.lab | The push-to-deploy service; shows the version (commit SHA) and the pod that answered |
| https://whoami.apps.lab (or any other name) | Smoke test (catch-all route) |

**Name resolution:** the hub's dnsmasq answers `*.apps.lab` → 10.10.0.200 and `<vm>.lab` → the VM's IP. Windows sends only `.lab` queries to the hub (NRPT rule from `10-host.ps1`); all other DNS is unchanged.

**Trust the lab CA** (optional, removes browser warnings): the CA cert is at `~/.kube/lab-root-ca.crt`. Import it for your user only:
`Import-Certificate -FilePath $HOME\.kube\lab-root-ca.crt -CertStoreLocation Cert:\CurrentUser\Root`. Because of the name constraints, it can't vouch for any site outside `.lab`. Windows curl (Schannel) also needs `--ssl-no-revoke`, since the lab CA publishes no revocation list.
Key: `~/.ssh/id_ed25519` on Windows. Password SSH is refused everywhere. Windows kubectl is v1.34, two minor versions behind the cluster (v1.36). Most commands work, but upgrade it when convenient (`winget upgrade Kubernetes.kubectl`).

## How it is built (reproducible)

Scripts in [bootstrap/](bootstrap/) (run order in [bootstrap/README.md](bootstrap/README.md)):

| Script | Does |
| --- | --- |
| `00-inventory.ps1`, `01-guest-audit.sh` | Read-only audit of what exists |
| `10-host.ps1` (admin) | Folders on E:, switches, host IP 10.0.0.1, persistent routes |
| `15-golden.ps1` | Downloads + SHA256-verifies Ubuntu, unattended install into the golden disk |
| `20-vms.ps1 -Start` | 5 VMs from the golden disk; each gets a cloud-init seed ISO (hostname, user, key, network, hub roles) |
| `30-hub-firewall.sh` | Installs the default-deny firewall; auto-rollback in 60 s if SSH is lost |
| `40-k3s.sh` | k3s on node1 → Gateway API CRDs → Cilium → join node2/3 → LB pool → gateway + whoami → Windows kubeconfig |
| `50-argocd.sh` | Argo CD from `platform/argocd`, then the root app; waits until every app is Synced/Healthy |
| `60-observability.sh` | Out-of-Git parts: Grafana admin secret (random, never printed) and hub rsyslog → Alloy |

## Deviations from the plan

| Plan | As built | Why |
| --- | --- | --- |
| Lab nodes 7 GB, tester 3 GB | **5 GB and 2 GB** | Windows uses ~12 GB, not 7; lab-node3 couldn't start at 7 GB. |
| — | Golden image + cloud-init seeds | Five identical, rebuildable VMs from one unattended install |
| "HTTPS to github.com, ghcr.io and registries" | Implemented as a DNS-driven allowlist; apt also allowed on HTTP 80 | nftables can't match domain names; Ubuntu mirrors use HTTP |
| MetalLB | **Cilium LB IPAM + L2 announcements** | Same ARP mechanism without extra pods; Cilium already runs on every node |
| ingress-nginx | **Cilium Gateway API** | ingress-nginx was archived in March 2026 (no security fixes); Gateway API is the current standard |
| OpenTelemetry Collector → Tempo | **Alloy** receives OTLP and forwards to Tempo | Alloy is an OTel Collector distribution and already runs on every node for logs: one fewer component |
| Grafana's Tempo chart | **grafana-community/tempo** | The grafana/helm-charts copy is deprecated |

## Known limits and watch-outs

- **RAM is the bottleneck.** With all 5 VMs running, Windows has ~2–4 GB free. Close Chrome/Discord during heavy experiments. Run one module's stack at a time; Kafka + Cassandra together will be tight at 15 GB of node RAM.
- **Blocked downloads are expected** when new charts or images come in. Look for `fw-drop fwd ... IN=eth2 OUT=eth0` on the hub, add the domain to `egress.conf`, re-run `30-hub-firewall.sh`.
- **Cilium is now a big blast radius:** pod networking, service routing, LB IPs and ingress all depend on it. A broken Cilium agent on a node takes all four down on that node.
- **Joining a node causes a short burst of hub drops** (`DST=10.42.x.x DPT=10250`). The new node's API server sends traffic to pod IPs before its Cilium agent is up, so it leaves via the default route to the hub. This stops once the agent runs. It's harmless, and a nice example of why the firewall logs are worth reading.
- **Hub is a single point of failure** by design (Module 1 experiment): if it is off, nothing external works, but node ↔ node traffic continues.
- All VMs share one physical machine: CPU and disk contention between them are real. Keep that in mind when reading performance numbers.

## Next step

**Module 1 — Networking**, the first breaking experiments (see [docs/PLAN.md](docs/PLAN.md)): trace one request end to end (tester → hub → VIP → pod) with `tcpdump` and Hubble; asymmetric routing; firewall debugging from the drop logs (now in Loki); WAN latency/loss with `tc netem` on the hub; Chaos Mesh for in-cluster latency and partitions; DNS failure; MTU mismatch; hub as SPOF; Cilium default-deny. Each experiment gets a card in `experiments/` and a Grafana dashboard. Chaos Mesh is the first thing to install for it.
