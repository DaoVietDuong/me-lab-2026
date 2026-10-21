#!/usr/bin/env bash
# M1-04: emulate a WAN between the spokes with tc netem on the hub's spoke-test NIC (eth3), both directions.
#   ./run.sh wan <one-way delay ms> <one-way loss %>   e.g. "wan 25 0.5" = RTT +50 ms, ~1% round-trip loss
#   ./run.sh clear
#   ./run.sh measure <label> [n]       n fresh HTTPS requests from the tester (new TCP + TLS each), timeout 5 s
#   ./run.sh reuse <label> [n]         n requests on ONE kept-alive connection
#   ./run.sh experiment                baseline, +50 ms RTT, +50 ms with ~1% and ~5% loss
# Egress shaping is plain netem on eth3; ingress goes through an ifb device so it can be shaped too.
# A safety timer clears everything after 20 min. Run from Windows Git Bash.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
S="ssh -o BatchMode=yes"
HUB=lab@10.0.0.2
TESTER=lab@10.20.0.10
URL=https://hello.apps.lab/

case "${1:-}" in
wan)
    d=${2:?delay ms}; l=${3:?loss %}
    $S $HUB "set -e
        sudo modprobe ifb; sudo ip link add ifb0 type ifb 2>/dev/null || true; sudo ip link set ifb0 up
        sudo tc qdisc replace dev eth3 root netem delay ${d}ms loss ${l}%
        sudo tc qdisc replace dev eth3 handle ffff: ingress
        sudo tc filter replace dev eth3 parent ffff: protocol all matchall action mirred egress redirect dev ifb0
        sudo tc qdisc replace dev ifb0 root netem delay ${d}ms loss ${l}%
        sudo systemctl stop lab-wan-clear.timer 2>/dev/null || true
        sudo systemd-run --quiet --unit lab-wan-clear --on-active=20min --timer-property=AccuracySec=1s \
            /bin/sh -c 'tc qdisc del dev eth3 root; tc qdisc del dev eth3 ingress; ip link del ifb0' || true
        echo \"WAN on eth3: ${d} ms + ${l}% loss each way (auto-clear in 20 min)\"; tc qdisc show dev eth3 | grep netem; tc qdisc show dev ifb0 | grep netem"
    ;;
clear)
    $S $HUB 'sudo tc qdisc del dev eth3 root 2>/dev/null; sudo tc qdisc del dev eth3 ingress 2>/dev/null; sudo ip link del ifb0 2>/dev/null
        sudo systemctl stop lab-wan-clear.timer 2>/dev/null; echo "WAN cleared: $(tc qdisc show dev eth3 | head -1)"'
    ;;
measure)
    label=${2:?label}; n=${3:-200}
    # time_connect = TCP done, time_appconnect = TLS done, time_total = response complete (seconds)
    $S $TESTER "for i in \$(seq $n); do curl -s -o /dev/null -m 5 --cacert /tmp/lab-root-ca.crt \
        -w '%{time_connect} %{time_appconnect} %{time_total} %{http_code}\n' $URL; done" > "out-$label.txt" || true
    awk -v label="$label" '
        function pct(a, n, p,  i) { i = int(n * p + 0.5); if (i < 1) i = 1; if (i > n) i = n; return a[i] * 1000 }
        { n++; if ($4 != 200) fail++; else { ok++; c[ok] = $1; t[ok] = $2; tot[ok] = $3; if ($3 > 1) over1++ } }
        END {
            asort(c); asort(t); asort(tot)
            printf "%-16s n=%d failed=%d >1s=%d (%.1f%%) | TCP p50 %.0f ms | TLS done p50 %.0f ms | total p50 %.0f  p95 %.0f  p99 %.0f  max %.0f ms\n",
                label, n, fail, over1, 100 * over1 / n, pct(c, ok, .5), pct(t, ok, .5), pct(tot, ok, .5), pct(tot, ok, .95), pct(tot, ok, .99), pct(tot, ok, 1)
        }' "out-$label.txt"
    ;;
reuse)
    label=${2:?label}; n=${3:-50}
    # One curl, n URLs: curl keeps the connection alive between them, so only the first pays TCP + TLS
    $S $TESTER "curl -s --cacert /tmp/lab-root-ca.crt -m 30 -w '%{time_total} %{num_connects}\n' \$(for i in \$(seq $n); do printf -- '-o /dev/null $URL '; done)" > "out-reuse-$label.txt" || true
    awk -v label="$label" '{ n++; tot[n] = $1; conns += $2 } END {
        first = tot[1]; for (i = 2; i <= n; i++) rest[i-1] = tot[i]; asort(rest)
        printf "%-16s reused connection: %d requests, %d new connection(s) | first %.0f ms | others p50 %.0f ms\n", label, n, conns, first * 1000, rest[int((n-1)/2)] * 1000 }' "out-reuse-$label.txt"
    ;;
experiment)
    bash "$SELF" clear >/dev/null
    bash "$SELF" measure baseline;                                   bash "$SELF" reuse baseline
    bash "$SELF" wan 25 0   >/dev/null; bash "$SELF" measure rtt+50ms;          bash "$SELF" reuse rtt+50ms
    bash "$SELF" wan 25 0.5 >/dev/null; bash "$SELF" measure rtt+50ms_loss1%
    bash "$SELF" wan 25 2.5 >/dev/null; bash "$SELF" measure rtt+50ms_loss5%
    bash "$SELF" clear
    ;;
*)
    echo "usage: $0 wan <ms> <loss%> | clear | measure <label> [n] | reuse <label> [n] | experiment" >&2; exit 2 ;;
esac
