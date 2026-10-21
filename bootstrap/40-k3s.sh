#!/usr/bin/env bash
# Build step 2: 3-server k3s (embedded etcd) + Cilium (CNI, LB IPs, Gateway API) + smoke test.
# Run from Windows Git Bash after 30-hub-firewall.sh. Safe to re-run: finished parts are skipped.
set -euo pipefail
cd "$(dirname "$0")"
MANIFESTS=../platform/cluster-bootstrap

K3S_VERSION=v1.36.5+k3s1
GATEWAY_API=v1.6.3
NODES=(10.10.0.11 10.10.0.12 10.10.0.13)
FIRST=${NODES[0]}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
on()   { local ip=$1; shift; $SSH lab@"$ip" "$@"; }
kc()   { on "$FIRST" sudo k3s kubectl "$@"; }
step() { printf '\n== %s\n' "$*"; }

# Same settings on every server; only node-ip and the join fields differ
k3s_config() { # ip [join]
    cat <<EOF
node-ip: $1
tls-san: [10.10.0.11, 10.10.0.12, 10.10.0.13, k8s.lab]
flannel-backend: none          # Cilium is the CNI
disable-network-policy: true   # Cilium enforces NetworkPolicy
disable-kube-proxy: true       # Cilium replaces kube-proxy
disable: [traefik, servicelb]  # Cilium does ingress and LoadBalancer IPs
secrets-encryption: true
etcd-expose-metrics: true
write-kubeconfig-mode: "0600"
EOF
    if [ "${2:-}" = join ]; then
        echo "server: https://$FIRST:6443"
        echo "token-file: /etc/rancher/k3s/join-token"
    else
        echo "cluster-init: true"
    fi
}

install_k3s() { # ip [join]
    if on "$1" 'systemctl is-active --quiet k3s'; then echo "k3s already running on $1"; return; fi
    k3s_config "$@" | on "$1" 'sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/config.yaml >/dev/null'
    on "$1" "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$K3S_VERSION' sh -s - server >/dev/null"
    echo "k3s $K3S_VERSION installed on $1"
}

step "k3s on $FIRST (cluster-init)"
install_k3s "$FIRST"
for i in $(seq 1 30); do kc get --raw /readyz >/dev/null 2>&1 && break; sleep 5; done

step "Gateway API $GATEWAY_API CRDs (must exist before Cilium starts)"
kc apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API/standard-install.yaml" | tail -3
kc get crd tlsroutes.gateway.networking.k8s.io -o name

step "Cilium (k3s helm-controller)"
on "$FIRST" 'sudo tee /var/lib/rancher/k3s/server/manifests/cilium.yaml >/dev/null' < "$MANIFESTS/cilium.yaml"
for i in $(seq 1 60); do kc -n kube-system get ds cilium >/dev/null 2>&1 && break; sleep 5; done
kc -n kube-system rollout status ds/cilium --timeout=10m

step "Join ${NODES[1]} and ${NODES[2]} as servers"
# Token goes node1 -> node via pipes only, never printed
for ip in "${NODES[@]:1}"; do
    if ! on "$ip" 'systemctl is-active --quiet k3s'; then
        on "$FIRST" 'sudo cat /var/lib/rancher/k3s/server/token' |
            on "$ip" 'sudo mkdir -p /etc/rancher/k3s && sudo install -m 0600 /dev/stdin /etc/rancher/k3s/join-token'
    fi
    install_k3s "$ip" join
done
kc wait --for=condition=Ready node --all --timeout=10m
kc -n kube-system rollout status ds/cilium --timeout=10m
kc -n kube-system rollout status deploy/cilium-operator --timeout=5m

step "LoadBalancer IP pool + L2 announcements"
kc apply -f - < "$MANIFESTS/lb-ipam.yaml"

step "Gateway on 10.10.0.200 with a temporary self-signed cert"
kc apply -f - < "$MANIFESTS/gateway.yaml"
if ! kc -n gateway get secret lab-gateway-tls >/dev/null 2>&1; then
    on "$FIRST" 'set -e; d=$(mktemp -d); cd $d
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=lab-gateway" \
            -addext "subjectAltName=IP:10.10.0.200,DNS:*.lab" -keyout tls.key -out tls.crt 2>/dev/null
        sudo k3s kubectl -n gateway create secret tls lab-gateway-tls --cert=tls.crt --key=tls.key
        rm -rf $d'
fi
kc apply -f - < "$MANIFESTS/hello.yaml"
kc -n hello rollout status deploy/whoami --timeout=5m
kc -n gateway wait --for=condition=Programmed gateway/lab-gateway --timeout=5m

step "Kubeconfig for Windows -> ~/.kube/lab.yaml"
mkdir -p ~/.kube
on "$FIRST" 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed "s#https://127.0.0.1:6443#https://$FIRST:6443#; s#: default\$#: lab#" > ~/.kube/lab.yaml
chmod 600 ~/.kube/lab.yaml

step "Cluster"
kc get nodes -o wide
kc get gateway -A
