#!/usr/bin/env bash
# M1-01: capture one HTTPS request from the tester at every hop at the same time.
# Run from Windows Git Bash. Output: ./out/<hop>.txt
set -euo pipefail
cd "$(dirname "$0")"
S="ssh -o BatchMode=yes"
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
OUT=out; rm -rf "$OUT"; mkdir -p "$OUT"

declare -A NODE_IP=([lab-node1]=10.10.0.11 [lab-node2]=10.10.0.12 [lab-node3]=10.10.0.13)
VIP_NODE=$($KC -n kube-system get lease cilium-l2announce-gateway-cilium-gateway-lab-gateway -o jsonpath='{.spec.holderIdentity}')
echo "VIP 10.10.0.200 answered by: $VIP_NODE"
$KC -n demo get pods -l app=hello -o custom-columns=POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName --no-headers

# SYN / SYN-ACK only, to keep the captures readable
SYN='tcp[tcpflags] & (tcp-syn) != 0'
# Inside VXLAN (UDP 8472) the inner IP source/destination sit at udp[42:4]/udp[46:4]
# (8 UDP + 8 VXLAN + 14 Ethernet bytes, then IP offsets 12/16). Match the hello pods' IPs.
# Not SYN-only: Envoy reuses upstream connections, so a request often rides an existing one.
iphex() { local IFS=.; set -- $1; printf '0x%02x%02x%02x%02x' "$1" "$2" "$3" "$4"; }
INNER="udp port 8472 and ("
for ip in $($KC -n demo get pods -l app=hello -o jsonpath='{.items[*].status.podIP}'); do
    INNER+="udp[42:4] = $(iphex "$ip") or udp[46:4] = $(iphex "$ip") or "
done
INNER="${INNER% or }) and udp[52:2] = 8080"   # only packets towards the pod (requests)

cap() { $S lab@"$1" "sudo timeout 15 tcpdump -l -nn -tttt -i $2 -c $3 '$4' 2>/dev/null" > "$OUT/$5.txt" & }
$S lab@10.0.0.2 'sudo ip neigh del 10.10.0.200 dev eth2 2>/dev/null; true'   # so the ARP exchange shows
cap 10.20.0.10 eth0 2 "tcp port 443 and $SYN"                               1-tester
cap 10.0.0.2   eth3 2 "host 10.20.0.10 and tcp port 443 and $SYN"          2-hub-in-eth3
cap 10.0.0.2   eth2 4 "(host 10.10.0.200 and tcp port 443 and $SYN) or arp" 3-hub-out-eth2
cap "${NODE_IP[$VIP_NODE]}" eth0 2 "dst host 10.10.0.200 and tcp port 443 and $SYN" 4-vip-node
for n in "${!NODE_IP[@]}"; do cap "${NODE_IP[$n]}" eth0 2 "$INNER" "5-vxlan-$n"; done
sleep 4
$S lab@10.20.0.10 "curl -s --cacert /tmp/lab-root-ca.crt -H 'Connection: close' https://hello.apps.lab/" | tee "$OUT/0-response.txt"
wait

RELAY=$($KC -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}')
$KC -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server "$RELAY:80" --type l7 \
    --since 30s --print-node-name -o compact 2>/dev/null | grep 'demo/hello' > "$OUT/6-hubble-l7.txt" || true

for f in "$OUT"/*.txt; do echo "===== $(basename "$f" .txt)"; cat "$f"; done
