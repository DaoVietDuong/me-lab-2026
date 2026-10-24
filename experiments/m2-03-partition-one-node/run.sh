#!/usr/bin/env bash
# M2-03: partition one RabbitMQ node (the quorum-queue leader) from the other two, with a publisher
# with confirms on each side.
#   ./run.sh experiment [n]   declare m2-03 with its leader on rmq-lab-server-0, start two publishers
#                     (n = 40000 each, 500/s): "min" through server-0 (seq 1..n), "maj" through server-1
#                     (seq 1000001..), partition server-0 from server-1/2 after 20 s for PART_S (90) s,
#                     sample the leader once a second, then drain and compare with each confirmed set
#   ./run.sh cleanup  remove the partition, the probe pods and the queue
# Clients can still reach every node: only RabbitMQ-to-RabbitMQ traffic is cut (partition.yaml).
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
M1=../m2-01-quorum-leader-loss
export MSYS_NO_PATHCONV=1
KCFG=$(cygpath -m "$HOME/.kube/lab.yaml" 2>/dev/null || echo "$HOME/.kube/lab.yaml")
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
now() { date -u +%T.%N | cut -c1-12; }
Q=m2-03 ISO=rmq-lab-server-0 MAJ=rmq-lab-server-1 PEERS="rmq-lab-server-1, rmq-lab-server-2" OFF=1000000
AMQPLIB=amqplib-2.2.0.tgz
AMQPLIB_SHA512=VifzN9aHs/Q3zTruVHXh2yCisQyXexBN91CQ2E5iSyUKyNjH6ilYhJGte5AXZH/Bj1PaH7SwPhyuSf6Msd2udw==
ctl() { kc -n mq exec "$MAJ" -c rabbitmq -- rabbitmqctl -q "$@"; }
admin_on() { local pod=$1; shift
    kc -n mq exec "$pod" -c rabbitmq -- sh -c 'f=/etc/rabbitmq/conf.d/11-default_user.conf
        exec rabbitmqadmin --non-interactive -u "$(sed -n "s/^default_user = //p" $f)" -p "$(sed -n "s/^default_pass = //p" $f)" "$@"' _ "$@"; }
qinfo() { ctl -t 5 list_queues name "$1" 2>/dev/null | awk -v q=$Q '$1 == q' | grep -o 'server-[0-9]' | paste -sd,; }
all_ready() { for i in $(seq 1 60); do [ "$(kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | grep -c '1/1')" = 3 ] && return; sleep 5; done; }
# M2-01's probe pod on queue m2-03, connected to $3, with a seq offset
probe() { local name=$1 mode=$2 node=$3 off=${4:-0} n=${5:-0}
    sed -e "s/__NAME__/$name/" -e "s/__MODE__/$mode/" -e "s/__NODE__/$node/" -e "s/__LEADER__/$ISO/" -e "s/__N__/$n/" \
        -e "s/value: m2-01}/value: $Q}/" -e "/name: QUEUE,/a\\        - {name: OFFSET, value: \"$off\"}" $M1/probe.yaml | kc apply -f - >/dev/null
    kc -n mq wait --for=condition=Ready "pod/$name" --timeout=2m >/dev/null; }
ended() { for i in $(seq 1 "${2:-300}"); do case $(kc -n mq get pod "$1" -o jsonpath='{.status.phase}') in Succeeded|Failed) return;; esac; sleep 1; done; }
# Per publisher: confirmed, lost (confirmed and not drained), never confirmed but drained, gap
account() { local who=$1 log=$2
    awk '$1 == "ack" {print $2}' "$log" | sort > out-acked.txt
    sent=$(grep -o 'sent [0-9]*' "$log" | tail -1 | cut -d' ' -f2)
    printf '%s: sent %s, confirmed %s, nacked %s, LOST %s, drained but never confirmed %s\n' "$who" "${sent:-?}" \
        "$(wc -l < out-acked.txt)" "$(grep -c '^nack' "$log" || true)" \
        "$(comm -23 out-acked.txt out-got-$who.txt | wc -l)" "$(comm -13 out-acked.txt out-got-$who.txt | wc -l)"
    awk '$1 == "ack" { split($3, a, ":"); ms = (a[1] * 3600 + a[2] * 60 + a[3]) * 1000; if (p && ms - p > g) { g = ms - p; at = $3 } p = ms }
         END { printf "  longest gap between confirms: %d ms (ending %s)\n", g, at }' "$log"
    grep '^#' "$log" | sed 's/^/  /'; }

case "${1:-}" in
cleanup)
    kc -n mq delete networkchaos m2-partition --ignore-not-found >/dev/null 2>&1 || true
    kc -n mq delete pod -l app=m2-probe --ignore-not-found --wait=false >/dev/null
    admin_on "$MAJ" delete queue --name $Q >/dev/null 2>&1 || true
    echo "partition removed, probe pods removed, queue deleted" ;;
experiment)
    n=${2:-40000}
    [ -f "$M1/out-$AMQPLIB" ] || curl -sSL -o "$M1/out-$AMQPLIB" "https://registry.npmjs.org/amqplib/-/$AMQPLIB"
    [ "$(openssl dgst -sha512 -binary "$M1/out-$AMQPLIB" | base64 -w0)" = "$AMQPLIB_SHA512" ] || { echo "amqplib checksum mismatch" >&2; exit 1; }
    kc -n mq create configmap m2-probe --from-file=$M1/probe.js --from-file=amqplib.tgz="$M1/out-$AMQPLIB" --dry-run=client -o yaml | kc apply -f - >/dev/null
    bash "$SELF" cleanup >/dev/null; kc -n mq wait --for=delete pod -l app=m2-probe --timeout=1m >/dev/null 2>&1 || true
    all_ready
    admin_on "$ISO" declare queue --name $Q --type quorum --durable true >/dev/null
    echo "queue $Q: leader $(qinfo leader), members $(qinfo members)"
    probe m2-pub-min publish "$ISO" 0 "$n" & probe m2-pub-maj publish "$MAJ" $OFF "$n" & wait
    echo "publishers: min -> $ISO, maj -> $MAJ; $n messages each at 500/s, window 100"
    sleep 20
    t0=$(date -u +%FT%TZ)
    sed -e "s/__ISOLATED__/$ISO/" -e "s/__PEERS__/$PEERS/" partition.yaml | kc apply -f - >/dev/null
    echo "$(now) PARTITION $ISO | $PEERS"
    trap 'kc -n mq delete networkchaos m2-partition --ignore-not-found >/dev/null 2>&1' EXIT
    # The majority's view of the leader, printed when it changes; "?" = the CLI timed out
    # Timed by the clock, not by iterations: each CLI call can hang for its 5 s timeout
    prev=""; end=$((SECONDS + ${PART_S:-90})); while [ $SECONDS -lt $end ]; do
        l=$(qinfo leader || true); l=${l:-?}
        [ "$l" != "$prev" ] && echo "$(now) leader (seen from $MAJ): $l   pods: $(kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | awk '{printf "%s ", $2}')"
        prev=$l; sleep 1
    done
    kc -n mq delete networkchaos m2-partition >/dev/null
    echo "$(now) HEALED after ${PART_S:-90} s"
    for i in $(seq 1 30); do l=$(qinfo leader || true); [ "${l:-?}" != "$prev" ] && echo "$(now) leader (seen from $MAJ): ${l:-?}"; prev=${l:-?}; sleep 1; done
    ended m2-pub-min; ended m2-pub-maj
    kc -n mq logs m2-pub-min > out-min-pub.log; kc -n mq logs m2-pub-maj > out-maj-pub.log
    all_ready
    for p in $ISO $MAJ; do
        kc -n mq logs "$p" -c rabbitmq --since-time="$t0" 2>/dev/null | sed 's/\x1b\[0m//g' \
            | grep -Ei "minority|paus|partition|node .* (down|up)|net_tick|$Q.*(leader|candidate|term|step)" \
            | sed -E 's/^([0-9-]+ )?([0-9:.]{12})[0-9]*/\2/' | cut -c1-170 > "out-rmq-$p.log" || true
        echo "  $p log:"; sed 's/^/    /' "out-rmq-$p.log" | head -25
    done
    echo "queue leader $(qinfo leader), online $(qinfo online)"
    probe m2-drain drain "$MAJ"
    ended m2-drain 600
    kc -n mq logs m2-drain > out-drain.log
    awk '$1 == "got" && $2 <  '$OFF' {print $2}' out-drain.log | sort -u > out-got-min.txt
    awk '$1 == "got" && $2 >= '$OFF' {print $2}' out-drain.log | sort -u > out-got-maj.txt
    echo "drained $(grep -c '^got' out-drain.log), distinct $(awk '$1 == "got" {print $2}' out-drain.log | sort -u | wc -l)"
    account min out-min-pub.log
    account maj out-maj-pub.log
    rm -f out-acked.txt out-got-*.txt
    bash "$SELF" cleanup >/dev/null
    ;;
*)
    echo "usage: $0 experiment [n] | cleanup" >&2; exit 2 ;;
esac
