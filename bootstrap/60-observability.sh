#!/usr/bin/env bash
# Build step 3c: the out-of-Git pieces of observability. The stack itself is Argo CD apps in platform/apps/.
#  1. Grafana admin secret (random password, generated on lab-node1, never printed)
#  2. Hub rsyslog -> Alloy (firewall drops into Loki)
# Run from Windows Git Bash. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
step() { printf '\n== %s\n' "$*"; }

step "Grafana admin secret"
$KC create namespace observability --dry-run=client -o yaml | $KC apply -f - >/dev/null
if $KC -n observability get secret grafana-admin >/dev/null 2>&1; then
    echo "exists: observability/grafana-admin"
else
    # Generated and stored inside the cluster; it never passes through this terminal
    ssh -o BatchMode=yes lab@10.10.0.11 'sudo k3s kubectl -n observability create secret generic grafana-admin \
        --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)"' >/dev/null
    echo "created: observability/grafana-admin"
fi

step "Hub: forward firewall drops to Alloy (10.10.0.201:1514)"
scp -q hub/rsyslog-lab.conf lab@10.0.0.2:/tmp/
ssh -o BatchMode=yes lab@10.0.0.2 'set -e
    dpkg -s rsyslog >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsyslog >/dev/null
    sudo install -m 0644 /tmp/rsyslog-lab.conf /etc/rsyslog.d/60-lab-loki.conf
    sudo rsyslogd -N1 2>&1 | grep -iE "error" && exit 1 || true
    sudo systemctl restart rsyslog && systemctl is-active rsyslog'

step "Grafana login"
echo "URL:      https://grafana.apps.lab   (user admin)"
echo "Password: $KC -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
