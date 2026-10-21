#!/usr/bin/env bash
# M1-03: a bad firewall change, found from the logs.
#   ./run.sh break [seconds]   empty the hub's tester->lab chain (the "443 to the VIP" allow); the hub
#                              restores it by itself after N seconds (default 60) via a systemd-run timer
#   ./run.sh probe [seconds]   one request per second from the tester AND from Windows (control), with timestamps
#   ./run.sh diagnose [min]    what Loki says: dropped flows grouped by src/dst/port/interfaces, per minute
#   ./run.sh experiment        probe 120 s, break at +20 s for 60 s, then diagnose
# Run from Windows Git Bash.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
S="ssh -o BatchMode=yes"
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
CA="--ssl-no-revoke --cacert $HOME/.kube/lab-root-ca.crt"

grafana() { # path, curl args... -> Grafana API as admin (password read from the cluster, never printed)
    curl -s $CA -m 30 -u "admin:$($KC -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)" \
        "https://grafana.apps.lab$1" "${@:2}"
}

case "${1:-}" in
break)
    secs=${2:-60}
    $S lab@10.0.0.2 "sudo systemctl stop lab-fw-heal.timer 2>/dev/null; true
        sudo nft flush chain inet lab_fw tester_to_lab
        sudo systemd-run --quiet --unit lab-fw-heal --on-active=${secs}s --timer-property=AccuracySec=1s /usr/local/sbin/lab-fw normal
        echo \"\$(date -u +%T) tester->lab chain flushed; auto-restore in ${secs}s\""
    ;;
probe)
    secs=${2:-120}
    $S lab@10.20.0.10 "for i in \$(seq $secs); do printf '%s tester  %s\n' \"\$(date -u +%T)\" \"\$(curl -s -o /dev/null -w '%{http_code}' -m 0.9 --cacert /tmp/lab-root-ca.crt https://hello.apps.lab/)\"; sleep 1; done" > out-tester.txt &
    for i in $(seq "$secs"); do printf '%s windows %s\n' "$(date -u +%T)" "$(curl -s $CA -o /dev/null -w '%{http_code}' -m 0.9 https://hello.apps.lab/)"; sleep 1; done > out-windows.txt
    wait
    for f in out-tester.txt out-windows.txt; do
        echo "== $f: $(grep -c ' 200$' $f) ok, $(grep -vc ' 200$' $f) failed"
        # first and last failure = the outage window as the client saw it
        grep -v ' 200$' "$f" | sed -n '1p;$p' || true
    done
    ;;
diagnose)
    mins=${2:-5}
    start="$(( $(date +%s) - mins*60 ))000000000"
    echo "== Dropped forwarded flows in the last ${mins} min (Loki: {job=\"hub-syslog\"} |= \"fw-drop fwd\")"
    q='sum by (in, out, src, dst, dpt) (count_over_time({job="hub-syslog"} |= "fw-drop fwd" | regexp `IN=(?P<in>\S+) OUT=(?P<out>\S*) .*SRC=(?P<src>\S+) DST=(?P<dst>\S+) .*DPT=(?P<dpt>\d+)` ['"${mins}"'m]))'
    grafana /api/datasources/proxy/uid/loki/loki/api/v1/query --get --data-urlencode "query=$q" |
        grep -oE '"metric":\{[^}]*\},"value":\[[0-9.]+,"[0-9]+"' |
        sed -E 's/"metric":\{//; s/\},"value":\[[0-9.]+,"([0-9]+)"/  -> \1 packets/; s/"//g' | sort -t'>' -k2 -rn
    echo "== Per minute, tester -> VIP:443"
    q2='sum(count_over_time({job="hub-syslog"} |= "fw-drop fwd" |= "SRC=10.20.0.10" |= "DST=10.10.0.200" |= "DPT=443" [1m]))'
    grafana /api/datasources/proxy/uid/loki/loki/api/v1/query_range --get --data-urlencode "query=$q2" \
        --data-urlencode "start=$start" --data-urlencode "step=60" |
        grep -oE '\[[0-9]+,"[0-9]+"\]' | tr -d '[]"' | while IFS=, read -r ts n; do echo "  $(date -u -d @"$ts" +%T)  $n"; done
    echo "== Hub: which rule is (now) there, and how often it matched"
    $S lab@10.0.0.2 "sudo nft list chain inet lab_fw tester_to_lab | grep -E 'accept|counter' || echo '  (chain empty)'"
    ;;
experiment)
    bash "$SELF" probe 120 > probe.txt &
    sleep 20; bash "$SELF" break 60
    wait; cat probe.txt
    sleep 20   # let rsyslog -> Alloy -> Loki catch up
    bash "$SELF" diagnose 4
    ;;
*)
    echo "usage: $0 break [s] | probe [s] | diagnose [min] | experiment" >&2; exit 2 ;;
esac
