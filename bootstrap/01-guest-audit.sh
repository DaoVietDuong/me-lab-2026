#!/usr/bin/env bash
# Read-only audit of an old VM before it is deleted. Changes nothing.
# Run from Windows:  ssh <user>@<ip> 'bash -s' < bootstrap/01-guest-audit.sh > bootstrap/audit/<vm>.txt
set -u

section() { printf '\n## %s\n' "$1"; }

echo "# Guest audit - $(hostname) - $(date -Is)"

section "OS"
lsb_release -ds 2>/dev/null || cat /etc/os-release
uname -r
uptime

section "Disk"
df -h -x tmpfs -x devtmpfs -x squashfs

section "Home directories (largest first)"
sudo -n du -sh /home/* /root 2>/dev/null | sort -rh || du -sh /home/* 2>/dev/null | sort -rh

section "Files in home dirs changed in the last 180 days (top 200, no dot-caches)"
find /home -xdev -type f -mtime -180 -not -path '*/.cache/*' -not -path '*/.local/share/Trash/*' 2>/dev/null | head -200

section "Kubernetes / container leftovers"
for p in /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/kubernetes /etc/cni /opt/cni /var/lib/etcd \
         /var/lib/docker /var/lib/containerd /var/snap/microk8s; do
    [ -e "$p" ] && echo "present: $p ($(sudo -n du -sh "$p" 2>/dev/null | cut -f1))"
done
command -v k3s kubectl docker containerd microk8s 2>/dev/null
snap list 2>/dev/null

section "Running and enabled services (non-default)"
systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'
echo "--- enabled:"
systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend | awk '{print $1}'

section "Listening ports"
ss -tulnp 2>/dev/null | head -50

section "Network"
ip -br addr
ip route
ls -l /etc/netplan/ && sudo -n cat /etc/netplan/*.yaml 2>/dev/null
resolvectl status 2>/dev/null | head -30

section "Firewall rule counts"
echo "iptables lines: $(sudo -n iptables-save 2>/dev/null | wc -l)"
echo "nft lines: $(sudo -n nft list ruleset 2>/dev/null | wc -l)"

section "Time and swap"
timedatectl 2>/dev/null
swapon --show

section "Crontabs"
crontab -l 2>/dev/null
ls /etc/cron.d 2>/dev/null

section "Manually installed packages"
apt-mark showmanual 2>/dev/null | head -300
