# bootstrap

One-time scripts that build the lab's 5 VMs on Hyper-V. VM settings live in `lab.config.ps1`.

| Order | Script | Shell | What it does |
| --- | --- | --- | --- |
| 0 | (once) `Add-LocalGroupMember -Group "Hyper-V Administrators" -Member $env:USERNAME`, sign out/in | admin | Lets normal shells manage Hyper-V |
| 0 | `ssh-keygen -t ed25519` | normal | Key that every VM trusts (password SSH is off) |
| 1 | `00-inventory.ps1` | normal | Read-only report of existing VMs → `audit/host-inventory.txt` |
| 1 | `ssh <user>@<ip> 'bash -s' < 01-guest-audit.sh > audit/<vm>.txt` | normal | Read-only audit inside an old VM |
| 2 | `10-host.ps1` | **admin** | Folders on E:, switches, host IP 10.0.0.1, routes to spokes |
| 3 | `15-golden.ps1` | normal | Downloads + verifies Ubuntu 24.04, installs the read-only golden disk (type `yes` once on the console) |
| 4 | `20-vms.ps1 -Start` | normal | 5 VMs from the golden disk, each with its own cloud-init seed; hub boots first |

| 5 | `bash 30-hub-firewall.sh` | Git Bash | Default-deny hub firewall + egress allowlist (`hub/`); rolls back by itself in 60 s if it locks out SSH |
| 6 | `bash 40-k3s.sh` | Git Bash | 3-server k3s + Cilium + LB pool + `lab-gateway` on 10.10.0.200 + whoami smoke test; kubeconfig → `~/.kube/lab.yaml` |
| 7 | `bash 50-argocd.sh` | Git Bash | Argo CD + root app; from here on everything under `platform/` is deployed by pushing to GitHub |
| 8 | `bash 60-observability.sh` | Git Bash | Grafana admin secret (out of Git) + hub rsyslog → Alloy; the stack itself syncs from `platform/apps/` |

After step 4, from Windows: `ssh lab@10.0.0.2` (hub), `ssh lab@10.10.0.11` (lab-node1, via the hub), `ssh lab@10.20.0.10` (tester).

## Hub firewall (`lab-fw` on the hub)

| Command | Effect |
| --- | --- |
| `sudo lab-fw status` | Tester mode, egress set sizes, last 10 drops |
| `sudo lab-fw pentest` / `normal` | Tester → lab: every port / only 443 to the ingress VIP 10.10.0.200 |
| `sudo lab-fw apply` | Reload `/etc/nftables.conf` (after editing it or `egress.conf`) |
| `journalctl -k -g fw-drop` | Every dropped packet, with interfaces, addresses and ports |

**Lab egress is by domain:** the nodes use the hub's dnsmasq for DNS, and dnsmasq adds the IPs of the domains in `hub/egress.conf` to the firewall's allow sets. Anything else is dropped. If an image pull or Helm install fails, look for `fw-drop fwd` lines with `IN=eth2 OUT=eth0`, add the domain, and re-run step 5.
