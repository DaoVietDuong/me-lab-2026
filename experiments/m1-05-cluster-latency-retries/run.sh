#!/usr/bin/env bash
# M1-05: latency inside the cluster, and how per-hop timeouts + retries amplify it.
#   ./run.sh chaos on|off            100 ms delay + 5% loss on every hello pod (Chaos Mesh NetworkChaos)
#   ./run.sh scenario <label> <query> [n]
#                                    n requests from the tester to /chain?<query>; reports client success and latency,
#                                    and how many requests the pods served at each depth (exact, from their counters)
#   ./run.sh experiment              baseline vs. chaos with naive retries, no retries, and a deadline budget
# Run from Windows Git Bash.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
TESTER="ssh -o BatchMode=yes lab@10.20.0.10"

served() { # total /chain requests served per depth, summed over all hello pods -> "d0 d1 d2 d3"
    for p in $($KC -n demo get pods -l app=hello -o name); do
        $KC -n demo exec "$p" -- wget -qO- localhost:8080/metrics 2>/dev/null
    done | awk 'index($0, "hello_requests_total{path=\"/chain\"") == 1 { if (match($0, /depth="([0-9]+)"/, m)) s[m[1]] += $NF }
        END { printf "%d %d %d %d\n", s[0], s[1], s[2], s[3] }'
}

case "${1:-}" in
chaos)
    if [ "${2:-}" = on ]; then
        $KC apply -f chaos-slow-net.yaml >/dev/null
        for i in $(seq 1 30); do
            [ "$($KC -n demo get networkchaos m1-05-slow-net -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}')" = True ] && break; sleep 2
        done
        echo "chaos on: 100 ms + 5% loss on $($KC -n demo get pods -l app=hello --no-headers | wc -l) hello pods"
    else
        $KC -n demo delete networkchaos m1-05-slow-net --ignore-not-found >/dev/null; echo "chaos off"
    fi
    ;;
scenario)
    label=$2; query=$3; n=${4:-40}
    read -r b0 b1 b2 b3 < <(served)
    $TESTER "for i in \$(seq $n); do curl -s -o /dev/null -m 3 --cacert /tmp/lab-root-ca.crt -w '%{http_code} %{time_total}\n' 'https://hello.apps.lab/chain?$query'; done" > "out-$label.txt" || true
    sleep 3   # let abandoned downstream calls finish and be counted
    read -r a0 a1 a2 a3 < <(served)
    awk -v label="$label" -v q="$query" -v d0=$((a0-b0)) -v d1=$((a1-b1)) -v d2=$((a2-b2)) -v d3=$((a3-b3)) '
        { n++; if ($1 == 200) ok++; t[n] = $2 } END {
            asort(t)
            printf "%-22s %-40s ok %2d/%d | client p50 %5.0f ms  p95 %5.0f ms | served depth3 %3d  depth2 %3d  depth1 %3d  leaf %3d | leaf/client %.1fx\n",
                label, q, ok, n, t[int(n*.5+.5)]*1000, t[int(n*.95+.5)]*1000, d3, d2, d1, d0, d0/n }' "out-$label.txt"
    ;;
experiment)
    bash "$SELF" chaos off >/dev/null
    bash "$SELF" scenario baseline        "depth=3&timeout_ms=300&retries=2"
    bash "$SELF" chaos on
    bash "$SELF" scenario chaos_no_retry  "depth=3&timeout_ms=300&retries=0"
    bash "$SELF" scenario chaos_naive     "depth=3&timeout_ms=300&retries=2"
    bash "$SELF" scenario chaos_naive_700ms "depth=3&timeout_ms=700&retries=2" 30
    bash "$SELF" scenario chaos_budget    "depth=3&retries=2&budget_ms=2500"
    bash "$SELF" chaos off
    ;;
*)
    echo "usage: $0 chaos on|off | scenario <label> <query> [n] | experiment" >&2; exit 2 ;;
esac
