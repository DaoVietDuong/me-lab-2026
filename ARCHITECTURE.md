# Lab environment — architecture and status

*Last updated: 2026-10-21. Status of what is built, not the plan. The plan is [docs/PLAN.md](docs/PLAN.md).*

## Status at a glance

| Build step (from the plan) | State |
| --- | --- |
| 0. Old VMs retired (3 × Ubuntu 22.04 k8s VMs on C:) | ✅ Done — deleted, 35 GB freed on C: |
| 1. Network: switches, hub, tester, 3 lab VMs, hub firewall | ✅ Done — tested, `clean-base` checkpoints taken |
| 2. Cluster: k3s HA + Cilium (CNI, LB IPs, Gateway API) | ✅ Done — tester reaches `https://10.10.0.200` through the hub, nothing else |
| 3. Delivery: GitHub repo, Argo CD, observability → Module 0 | ⏭ **Next** |
| 4–9. RabbitMQ + Postgres, Kafka, Cassandra, Redis, Modules 6–8 | Not started |

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
| dnsmasq | eth1, eth2, eth3 :53 | `*.lab` names for all VMs; forwards everything else upstream; fills the egress allowlist |
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

Everything else is dropped and logged: `journalctl -k -g fw-drop` on the hub.

**Domain egress:** the firewall's `egress_https4` / `egress_http4` sets are filled by dnsmasq (`nftset=`) whenever a lab node resolves a listed domain or its subdomains: GitHub, GHCR, Docker Hub, Quay, registry.k8s.io, pkg.dev, k3s.io, jetstack, cilium, chaos-mesh, k8ssandra, strimzi, ubuntu.com. List: [bootstrap/hub/egress.conf](bootstrap/hub/egress.conf).

**Control on the hub:** `sudo lab-fw status | normal | pentest | apply`. Reloads keep the learned IPs, and mode switches only touch the tester → lab chain.

## Kubernetes cluster

| Layer | As built | Notes |
| --- | --- | --- |
| Kubernetes | k3s **v1.36.5+k3s1**, 3 servers, embedded etcd (3 members) | Survives one node loss. flannel, kube-proxy, Traefik and servicelb are disabled |
| CNI | Cilium **1.20.3** (k3s HelmChart), VXLAN tunnel, BPF masquerade | Pod CIDRs 10.42.0–2.0/24 per node, services 10.43.0.0/16 |
| Service routing | Cilium kube-proxy replacement (eBPF) | No kube-proxy DaemonSet |
| LoadBalancer IPs | Cilium LB IPAM pool `spoke-lab` 10.10.0.200–220 + L2 announcements on eth0 | One node answers ARP per VIP, chosen by a Kubernetes lease (`cilium-l2announce-*`); now lab-node1 |
| Ingress | Gateway API **v1.6.3** CRDs, `gateway/lab-gateway` (class `cilium`) HTTPS :443 on 10.10.0.200 | TLS is a **temporary self-signed** cert (`lab-gateway-tls`) until cert-manager |
| Smoke test | `hello/whoami` × 2 behind HTTPRoute `/` | Shows which pod answered and the client IP (`X-Forwarded-For: 10.20.0.10`) |
| Observability | Hubble relay + UI installed (not exposed yet) | |
| Other | Secrets encryption at rest on; etcd metrics exposed; metrics-server and local-path (k3s defaults) | |

API: `https://10.10.0.11:6443` (TLS SANs cover all three node IPs and `k8s.lab`). Cilium reaches the API on `127.0.0.1:6443`, which every node has because every node is a server.

**Resource use after install:** about 1.1–1.6 GB used per node, 3.3–3.8 GB still available.

Manifests: [platform/cluster-bootstrap/](platform/cluster-bootstrap/). They are applied by `bootstrap/40-k3s.sh` and will be handed over to Argo CD in step 3.

**Verified:** tester → `https://10.10.0.200` works (requests split across both whoami pods). Tester → :80 on the VIP, the API on 6443 and the nodes' 443 are all blocked by the hub. Windows → the VIP and the API work. All 3 Cilium agents report 3/3 nodes healthy.

## Access

```bash
ssh lab@10.0.0.2      # hub
ssh lab@10.10.0.11    # lab-node1 (also .12, .13) — routed through the hub
ssh lab@10.20.0.10    # tester
kubectl --kubeconfig ~/.kube/lab.yaml get nodes      # from Windows
curl -k https://10.10.0.200/                         # the gateway, from Windows or the tester
```
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

## Deviations from the plan

| Plan | As built | Why |
| --- | --- | --- |
| Lab nodes 7 GB, tester 3 GB | **5 GB and 2 GB** | Windows uses ~12 GB, not 7; lab-node3 couldn't start at 7 GB. |
| — | Golden image + cloud-init seeds | Five identical, rebuildable VMs from one unattended install |
| "HTTPS to github.com, ghcr.io and registries" | Implemented as a DNS-driven allowlist; apt also allowed on HTTP 80 | nftables can't match domain names; Ubuntu mirrors use HTTP |
| MetalLB | **Cilium LB IPAM + L2 announcements** | Same ARP mechanism without extra pods; Cilium already runs on every node |
| ingress-nginx | **Cilium Gateway API** | ingress-nginx was archived in March 2026 (no security fixes); Gateway API is the current standard |

## Known limits and watch-outs

- **RAM is the bottleneck.** With all 5 VMs running, Windows has ~2–4 GB free. Close Chrome/Discord during heavy experiments. Run one module's stack at a time; Kafka + Cassandra together will be tight at 15 GB of node RAM.
- **Blocked downloads are expected** when new charts or images come in. Look for `fw-drop fwd ... IN=eth2 OUT=eth0` on the hub, add the domain to `egress.conf`, re-run `30-hub-firewall.sh`.
- **Cilium is now a big blast radius:** pod networking, service routing, LB IPs and ingress all depend on it. A broken Cilium agent on a node takes all four down on that node.
- **Joining a node causes a short burst of hub drops** (`DST=10.42.x.x DPT=10250`). The new node's API server sends traffic to pod IPs before its Cilium agent is up, so it leaves via the default route to the hub. This stops once the agent runs. It's harmless, and a nice example of why the firewall logs are worth reading.
- **Hub is a single point of failure** by design (Module 1 experiment): if it is off, nothing external works, but node ↔ node traffic continues.
- All VMs share one physical machine: CPU and disk contention between them are real. Keep that in mind when reading performance numbers.

## Next step

Build step 3 (completes Module 0): a public GitHub monorepo with the plan's layout, Argo CD in the cluster pulling from it, and a hello-world service deployed by `git push` through GitHub Actions → GHCR. Then the observability stack (kube-prometheus-stack, Loki, Tempo) and Grafana behind `lab-gateway`. Before that, cert-manager with an internal CA replaces the self-signed gateway cert.
