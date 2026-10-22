#!/usr/bin/env bash
# M4-04: PostgreSQL split brain. The primary is partitioned from the replicas, the operator and the
# API server, while a client still reaches it. Does the old primary keep acknowledging writes after a
# replica is promoted, how long until CloudNativePG fences it, and what happens to those writes on heal?
#   ./run.sh experiment <label> [hold_s]   reset, write 15 s, partition the primary for hold_s (90),
#                                          watch once a second, heal, wait for 3 ready, analyse
#   ./run.sh sync on|off                   synchronous replication (reuses M4-02)
#   ./run.sh heal                          remove the partition
#   ./run.sh analyze <label>               acked writes per server, acks after the promotion, lost writes
# Writer: M4-01's, but every ack also names the server that acknowledged it (inet_server_addr).
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
declare -A NODE_IP=([lab-node1]=10.10.0.11 [lab-node2]=10.10.0.12 [lab-node3]=10.10.0.13)
api_for() { for n in lab-node1 lab-node2 lab-node3; do [ "$n" != "$1" ] && { echo "${NODE_IP[$n]}"; return; }; done; }
kc() { kubectl --kubeconfig "$HOME/.kube/lab.yaml" --server "https://${API:-10.10.0.11}:6443" "$@"; }
primary() { kc -n db get cluster pg-lab -o jsonpath='{.status.currentPrimary}'; }
node_of() { kc -n db get pod "$1" -o jsonpath='{.spec.nodeName}'; }
now() { date -u +%T.%N | cut -c1-12; }

case "${1:-}" in
sync)
    bash ../m4-02-pg-sync-vs-async/run.sh sync "${2:?on|off}" ;;
heal)
    kc -n db delete networkchaos m4-split-replicas m4-split-operator m4-split-apiserver --ignore-not-found >/dev/null
    echo "partition removed" ;;
analyze)
    label=${2:?label}
    kc -n db logs pg-writer > "out-$label-writer.log"
    grep -E '^[0-9]+\|' "out-$label-writer.log" | cut -d'|' -f1 | sort -n > out-acked.txt
    kc -n db exec pg-writer -- bash -c 'psql "$PGURI" -qtAX -c "select id from writes order by id"' | sort -n > out-table.txt
    lost=$(comm -23 out-acked.txt out-table.txt | wc -l)
    echo "acknowledged writes: $(wc -l < out-acked.txt), rows in table: $(wc -l < out-table.txt)"
    echo "acks per server (first ack -> last ack):"
    awk -F'|' '/^[0-9]+\|/ { n[$3]++; if (!f[$3]) f[$3] = $2; l[$3] = $2 }
               END { for (s in n) printf "  %-14s %6d  %s -> %s\n", s, n[s], f[s], l[s] }' "out-$label-writer.log"
    echo "LOST (acked, not in table): $lost"
    [ "$lost" -gt 0 ] && echo "  lost ids $(comm -23 out-acked.txt out-table.txt | head -1) .. $(comm -23 out-acked.txt out-table.txt | tail -1)"
    grep -E '^# (error|connect attempt=[2-9])' "out-$label-writer.log" | head -4 | sed 's/^/  /'
    rm -f out-acked.txt out-table.txt
    ;;
experiment)
    label=${2:?label}; hold=${3:-90}
    kc -n db delete pod pg-writer --ignore-not-found --wait >/dev/null
    kc -n db exec "$(primary)" -c postgres -- psql -qtAX -d lab -c "drop table if exists writes" >/dev/null
    sed "s#to_char(clock_timestamp(), 'HH24:MI:SS.MS')#&, inet_server_addr()#" ../m4-01-pg-failover/writer.yaml | kc apply -f - >/dev/null
    kc -n db wait --for=condition=Ready pod/pg-writer --timeout=2m >/dev/null
    old=$(primary); node=$(node_of "$old"); API=$(api_for "$node")
    echo "writer on $(node_of pg-writer), primary $old on $node ($(kc -n db get pod "$old" -o jsonpath='{.status.podIP}'))"
    sleep 15
    sed "s/__PRIMARY__/$old/" partition.yaml | kc apply -f - >/dev/null
    echo "$(now) PARTITION $old from replicas, operator, API server (client side still open)"
    # Once a second: operator's primary, each instance's role label / ready / restarts, last ack the client got
    tl="out-$label-timeline.log"; : > "$tl"
    for i in $(seq 1 "$hold"); do
        echo "$(now) primary=$(primary 2>/dev/null || echo '?') $(kc -n db get pods -l cnpg.io/cluster=pg-lab --no-headers \
            -o custom-columns=N:.metadata.name,R:.metadata.labels.role,OK:.status.containerStatuses[0].ready,RS:.status.containerStatuses[0].restartCount 2>/dev/null \
            | awk '{printf "%s:%s:%s:%s ", $1, $2, ($3 == "true" ? "ready" : "NOTREADY"), $4}') last_ack=$(kc -n db logs pg-writer --tail=1 2>/dev/null | tr -d '\n')" >> "$tl"
        sleep 1
    done
    # Compress the timeline to the lines where something other than the last ack changed
    awk '{ k = $0; sub(/^[^ ]+ /, "", k); sub(/ last_ack=.*/, "", k); if (k != p) print; p = k }' "$tl" | sed 's/^/  /'
    bash "$SELF" heal
    echo "$(now) HEALED"
    for i in $(seq 1 60); do [ "$(kc -n db get cluster pg-lab -o jsonpath='{.status.readyInstances}')" = 3 ] && break; sleep 5; done
    echo "$(now) pg-lab: $(kc -n db get cluster pg-lab -o jsonpath='{.status.readyInstances}/3 ready, primary {.status.currentPrimary}, {.status.phase}')"
    sleep 10
    bash "$SELF" analyze "$label"
    kc -n db logs "$old" -c postgres --since=10m 2>/dev/null | grep -i -E 'isolat|rewind|demot|fenc|timeline' | cut -c1-300 | tail -8 > "out-$label-oldprimary.log" || true
    kc -n db delete pod pg-writer --ignore-not-found --wait=false >/dev/null
    kc -n db exec "$(primary)" -c postgres -- psql -qtAX -d lab -c "drop table if exists writes" >/dev/null 2>&1 || true
    ;;
*)
    echo "usage: $0 experiment <label> [hold_s] | sync on|off | heal | analyze <label>" >&2; exit 2 ;;
esac
