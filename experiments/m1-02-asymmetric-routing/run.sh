#!/usr/bin/env bash
# M1-02: asymmetric routing through a stateful firewall.
#   ./run.sh break     tester gets a back-door NIC on spoke-lab; the VIP node replies through it (bypassing the hub)
#   ./run.sh probe     one request from the tester, captured on both tester NICs and both hub NICs + hub conntrack
#   ./run.sh restore   remove the route, the address and the NIC
# Run from Windows Git Bash (needs Hyper-V rights for the NIC).
set -euo pipefail
cd "$(dirname "$0")"
S="ssh -o BatchMode=yes"
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
BYPASS_IP=10.10.0.250
BYPASS_MAC=00155D0A0211          # Hyper-V format; 00:15:5d:0a:02:11 inside the guest
declare -A NODE_IP=([lab-node1]=10.10.0.11 [lab-node2]=10.10.0.12 [lab-node3]=10.10.0.13)
vip_node_ip() { echo "${NODE_IP[$($KC -n kube-system get lease cilium-l2announce-gateway-cilium-gateway-lab-gateway -o jsonpath='{.spec.holderIdentity}')]}"; }

case "${1:-}" in
break)
    powershell -NoProfile -Command "if (-not (Get-VMNetworkAdapter -VMName tester -Name bypass -ErrorAction SilentlyContinue)) { Add-VMNetworkAdapter -VMName tester -Name bypass -SwitchName spoke-lab -StaticMacAddress $BYPASS_MAC }"
    sleep 5
    # /32 and no subnet route: the tester still reaches the VIP through the hub, only replies use the back door
    $S lab@10.20.0.10 "IF=\$(ip -o link | awk -F': ' '/00:15:5d:0a:02:11/{print \$2}'); sudo ip link set \$IF up; sudo ip addr replace $BYPASS_IP/32 dev \$IF; ip route get 10.10.0.200 | head -1"
    $S lab@"$(vip_node_ip)" "sudo ip route replace 10.20.0.10/32 via $BYPASS_IP dev eth0; ip route get 10.20.0.10 | head -1"
    ;;
probe)
    OUT=out; rm -rf "$OUT"; mkdir -p "$OUT"
    F='host 10.10.0.200 and tcp port 443'
    cap() { $S lab@"$1" "sudo timeout 14 tcpdump -l -nn -tttt -i $2 -c 8 '$F' 2>/dev/null" > "$OUT/$3.txt" & }
    cap 10.20.0.10 eth0 1-tester-eth0
    $S lab@10.20.0.10 'ip link show eth1 >/dev/null 2>&1' && cap 10.20.0.10 eth1 2-tester-eth1-bypass
    cap 10.0.0.2 eth3 3-hub-eth3-in
    cap 10.0.0.2 eth2 4-hub-eth2-out
    sleep 3
    ( sleep 2; $S lab@10.0.0.2 "sudo conntrack -L -p tcp -s 10.20.0.10 --dst 10.10.0.200 --dport 443 2>/dev/null" > "$OUT/5-hub-conntrack.txt" ) &
    $S lab@10.20.0.10 "curl -s -o /dev/null -w 'http=%{http_code} total=%{time_total}s' -m 8 --cacert /tmp/lab-root-ca.crt https://hello.apps.lab/; echo \" exit=\$?\"" > "$OUT/0-curl.txt" || true
    wait
    $S lab@10.0.0.2 "sudo nft list chain inet lab_fw forward | grep -oE 'ct state invalid counter packets [0-9]+'" > "$OUT/6-hub-invalid-counter.txt"
    for f in "$OUT"/*.txt; do echo "===== $(basename "$f" .txt)"; cat "$f"; done
    ;;
restore)
    $S lab@"$(vip_node_ip)" "sudo ip route del 10.20.0.10/32 2>/dev/null; ip route get 10.20.0.10 | head -1"
    $S lab@10.20.0.10 "sudo ip addr del $BYPASS_IP/32 dev eth1 2>/dev/null; true"
    powershell -NoProfile -Command "Get-VMNetworkAdapter -VMName tester -Name bypass -ErrorAction SilentlyContinue | Remove-VMNetworkAdapter"
    ;;
*)
    echo "usage: $0 break | probe | restore" >&2; exit 2 ;;
esac
