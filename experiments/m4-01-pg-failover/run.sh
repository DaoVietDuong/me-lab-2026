#!/usr/bin/env bash
# M4-01/02: PostgreSQL primary failure under a steady write load; failover time and lost acknowledged writes.
#   ./run.sh experiment <delete|kill|poweroff>   reset, write 15 s, inject the fault, watch, analyse
#   ./run.sh reset          new writer pod, empty table
#   ./run.sh analyze        failover gap and lost/ambiguous writes from the writer log vs. the table
#   ./run.sh restore        start any lab VM that is off, wait for the cluster to be whole again
# Faults: delete   = kubectl delete pod (graceful: PostgreSQL gets a clean shutdown)
#         kill     = Chaos Mesh pod-kill, grace 0 (SIGKILL, like the process crashing)
#         poweroff = Hyper-V Stop-VM -TurnOff on the primary's node (pulling the power cord)
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
declare -A NODE_IP=([lab-node1]=10.10.0.11 [lab-node2]=10.10.0.12 [lab-node3]=10.10.0.13)
# Talk to the API through a node that will survive: avoid the primary's node
api_for() { for n in lab-node1 lab-node2 lab-node3; do [ "$n" != "$1" ] && { echo "${NODE_IP[$n]}"; return; }; done; }
kc() { kubectl --kubeconfig "$HOME/.kube/lab.yaml" --server "https://${API:-10.10.0.11}:6443" "$@"; }
primary() { kc -n db get cluster pg-lab -o jsonpath='{.status.currentPrimary}'; }
node_of() { kc -n db get pod "$1" -o jsonpath='{.spec.nodeName}'; }

case "${1:-}" in
reset)
    kc -n db delete pod pg-writer --ignore-not-found --wait >/dev/null
    kc -n db exec "$(primary)" -c postgres -- psql -qtAX -d lab -c "drop table if exists writes" >/dev/null
    kc apply -f writer.yaml >/dev/null
    kc -n db wait --for=condition=Ready pod/pg-writer --timeout=2m >/dev/null
    echo "writer on $(kc -n db get pod pg-writer -o jsonpath='{.spec.nodeName}'), primary $(primary) on $(node_of "$(primary)")"
    ;;
analyze)
    kc -n db logs pg-writer > out-writer.log
    grep -E '^[0-9]+\|' out-writer.log | cut -d'|' -f1 | sort -n > out-acked.txt
    kc -n db exec pg-writer -- bash -c 'psql "$PGURI" -qtAX -c "select id from writes order by id"' | sort -n > out-table.txt
    lost=$(comm -23 out-acked.txt out-table.txt | wc -l)
    ambiguous=$(comm -13 out-acked.txt out-table.txt | wc -l)
    echo "acknowledged writes: $(wc -l < out-acked.txt), rows in table: $(wc -l < out-table.txt)"
    echo "LOST (acked, not in table): $lost    ambiguous (in table, never acked): $ambiguous"
    [ "$lost" -gt 0 ] && echo "  lost ids: $(comm -23 out-acked.txt out-table.txt | head -5 | paste -sd' ')$( [ "$lost" -gt 5 ] && echo ' ...')"
    # Write outage as the client saw it: last ack before the first error -> first ack after the last reconnect
    awk -F'|' '/^[0-9]+\|/ { t = $2; if (gap && !after) { after = t } ; if (!gap) before = t }
              /^# error|^# disconnected/ { if (!gap) gap = 1 }
              END { printf "client write outage: last ack %s -> next ack %s\n", before, after }' out-writer.log
    grep -E '^# (error|connect attempt=[2-9])' out-writer.log | head -4 | sed 's/^/  /'
    ;;
restore)
    powershell -NoProfile -Command "Get-VM lab-node* | Where-Object State -eq 'Off' | ForEach-Object { Start-VM \$_; 'started ' + \$_.Name }"
    API=10.10.0.11
    for i in $(seq 1 60); do [ "$(kc get nodes --no-headers 2>/dev/null | grep -c ' Ready')" = 3 ] && break; sleep 5; done
    kc get nodes --no-headers | awk '{print "  " $1, $2}'
    for i in $(seq 1 60); do [ "$(kc -n db get cluster pg-lab -o jsonpath='{.status.readyInstances}')" = 3 ] && break; sleep 5; done
    echo "pg-lab: $(kc -n db get cluster pg-lab -o jsonpath='{.status.readyInstances}/3 ready, primary {.status.currentPrimary}, {.status.phase}')"
    ;;
experiment)
    fault=${2:?delete|kill|poweroff}
    bash "$SELF" reset
    sleep 15
    old=$(primary); node=$(node_of "$old"); API=$(api_for "$node")
    echo "$(date -u +%T.%N | cut -c1-12) FAULT $fault on $old ($node)"
    case "$fault" in
        delete)   kc -n db delete pod "$old" --wait=false >/dev/null ;;
        kill)     sed "s/__POD__/$old/" pod-kill.yaml | kc apply -f - >/dev/null ;;
        poweroff) powershell -NoProfile -Command "Stop-VM -Name $node -TurnOff -Force" ;;
    esac
    # Watch the operator's view of the primary, once a second
    for i in $(seq 1 120); do
        p=$(primary 2>/dev/null || echo "?")
        if [ "$p" != "$old" ] && [ -n "$p" ] && [ "$p" != "?" ]; then
            echo "$(date -u +%T.%N | cut -c1-12) NEW PRIMARY $p after ~${i} s"; break
        fi; sleep 1
    done
    sleep 20
    kc -n db delete podchaos m4-kill-primary --ignore-not-found >/dev/null 2>&1 || true
    API=$(api_for "$node") bash "$SELF" analyze
    ;;
*)
    echo "usage: $0 experiment <delete|kill|poweroff> | reset | analyze | restore" >&2; exit 2 ;;
esac
