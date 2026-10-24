#!/usr/bin/env bash
# M2-02: lose 2 of 3 RabbitMQ nodes (the quorum-queue leader and one follower) while a publisher with
# confirms is sending through the third.
#   ./run.sh experiment <kill2|freeze2> [n]   declare m2-02 with its leader on rmq-lab-server-0, publish n
#                     (40000) messages at 500/s through server-1, fault server-0 and server-2 after 20 s,
#                     sample pod readiness once a second, then drain the queue and compare it with the
#                     confirmed set
#   ./run.sh cleanup  remove the probe pods and the queue
# Faults: kill2   = Chaos Mesh pod-kill of both, grace 0 (SIGKILL); Kubernetes restarts them
#         freeze2 = SIGSTOP both Erlang VMs for FREEZE_S (90) seconds, sent from their nodes: longer than
#                   net_ticktime (60 s), so server-1 finds itself in a minority and pause_minority acts
# Reuses M2-01's probe.js and probe.yaml. The publisher doesn't reconnect: once its connection closes it
# stops, so every message it sent is either confirmed or unconfirmed, and "lost" = confirmed and missing.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
M1=../m2-01-quorum-leader-loss
export MSYS_NO_PATHCONV=1
KCFG=$(cygpath -m "$HOME/.kube/lab.yaml" 2>/dev/null || echo "$HOME/.kube/lab.yaml")
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
now() { date -u +%T.%N | cut -c1-12; }
Q=m2-02 LEADER=rmq-lab-server-0 OTHER=rmq-lab-server-2 PUB=rmq-lab-server-1
AMQPLIB=amqplib-2.2.0.tgz
AMQPLIB_SHA512=VifzN9aHs/Q3zTruVHXh2yCisQyXexBN91CQ2E5iSyUKyNjH6ilYhJGte5AXZH/Bj1PaH7SwPhyuSf6Msd2udw==
ctl() { kc -n mq exec "$PUB" -c rabbitmq -- rabbitmqctl -q "$@"; }
admin_on() { local pod=$1; shift
    kc -n mq exec "$pod" -c rabbitmq -- sh -c 'f=/etc/rabbitmq/conf.d/11-default_user.conf
        exec rabbitmqadmin --non-interactive -u "$(sed -n "s/^default_user = //p" $f)" -p "$(sed -n "s/^default_pass = //p" $f)" "$@"' _ "$@"; }
qinfo() { ctl -t 5 list_queues name "$1" 2>/dev/null | awk -v q=$Q '$1 == q' | grep -o 'server-[0-9]' | paste -sd,; }
all_ready() { for i in $(seq 1 60); do [ "$(kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | grep -c '1/1')" = 3 ] && return; sleep 5; done; }
# M2-01's probe pod, but next to the surviving broker (pod affinity to server-1) instead of away from the
# leader, and on queue m2-02
probe() { local name=$1 mode=$2 n=${3:-0}
    sed -e "s/__NAME__/$name/" -e "s/__MODE__/$mode/" -e "s/__NODE__/$PUB/" -e "s/__LEADER__/$PUB/" -e "s/__N__/$n/" \
        -e 's/podAntiAffinity:/podAffinity:/' -e "s/value: m2-01/value: $Q/" $M1/probe.yaml | kc apply -f - >/dev/null
    kc -n mq wait --for=condition=Ready "pod/$name" --timeout=2m >/dev/null; }
# Wait until a pod has ended, either way (the publisher exits 1 when its connection is closed)
ended() { for i in $(seq 1 "${2:-300}"); do case $(kc -n mq get pod "$1" -o jsonpath='{.status.phase}') in Succeeded|Failed) return;; esac; sleep 1; done; }
ready_line() { kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | awk '{ sub(/rmq-lab-/, "", $1); printf "%s %s  ", $1, $2 }'; }

case "${1:-}" in
cleanup)
    kc -n mq delete pod -l app=m2-probe --ignore-not-found --wait=false >/dev/null
    kc -n mq delete podchaos m2-kill-two --ignore-not-found >/dev/null 2>&1 || true
    admin_on "$PUB" delete queue --name $Q >/dev/null 2>&1 || true
    echo "probe pods removed, queue deleted" ;;
experiment)
    fault=${2:?kill2|freeze2}; n=${3:-40000}; label=$fault
    [ -f "$M1/out-$AMQPLIB" ] || curl -sSL -o "$M1/out-$AMQPLIB" "https://registry.npmjs.org/amqplib/-/$AMQPLIB"
    [ "$(openssl dgst -sha512 -binary "$M1/out-$AMQPLIB" | base64 -w0)" = "$AMQPLIB_SHA512" ] || { echo "amqplib checksum mismatch" >&2; exit 1; }
    kc -n mq create configmap m2-probe --from-file=$M1/probe.js --from-file=amqplib.tgz="$M1/out-$AMQPLIB" --dry-run=client -o yaml | kc apply -f - >/dev/null
    bash "$SELF" cleanup >/dev/null; kc -n mq wait --for=delete pod -l app=m2-probe --timeout=1m >/dev/null 2>&1 || true
    all_ready
    admin_on "$LEADER" declare queue --name $Q --type quorum --durable true >/dev/null
    echo "queue $Q: leader $(qinfo leader), members $(qinfo members)"
    probe m2-pub publish "$n"
    echo "publisher on $(kc -n mq get pod m2-pub -o jsonpath='{.spec.nodeName}') -> $PUB, $n messages at 500/s, window 100"
    sleep 20
    t0=$(date -u +%FT%TZ)
    echo "$(now) FAULT $fault on $LEADER + $OTHER"
    case "$fault" in
        kill2)   sed "s/__POD__/$LEADER, $OTHER/" ../m4-01-pg-failover/pod-kill.yaml | sed -e 's/namespace: db/namespace: mq/' \
                     -e 's/m4-kill-primary/m2-kill-two/' -e 's/mode: one/mode: all/' -e 's/db: \[/mq: [/' | kc apply -f - >/dev/null ;;
        freeze2) frz() { local sig=$1 p ip; for p in $LEADER $OTHER; do
                         ip=$(kc get node "$(kc -n mq get pod "$p" -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
                         ssh -o BatchMode=yes lab@"$ip" "sudo pkill -$sig -o -x beam.smp"; done; }
                 trap 'frz CONT' EXIT; frz STOP
                 ( sleep "${FREEZE_S:-90}"; frz CONT; echo "$(now) RESUMED after ${FREEZE_S:-90} s" ) & ;;
        *) echo "unknown fault $fault" >&2; exit 2 ;;
    esac
    # Readiness as Kubernetes sees it, printed when it changes, until all are back and the publisher ended
    prev=""; for i in $(seq 1 240); do
        cur="$(ready_line) pub $(kc -n mq get pod m2-pub -o jsonpath='{.status.phase}')"
        [ "$cur" != "$prev" ] && echo "$(now) $cur"; prev=$cur
        [ "$i" -gt 30 ] && [[ "$cur" != *0/1* ]] && [[ "$cur" != *Running* ]] && break
        sleep 1
    done
    ended m2-pub
    kc -n mq logs m2-pub > "out-$label-pub.log"
    wait
    all_ready
    # server-1's view: membership, partition handling and the queue's Raft elections
    kc -n mq logs "$PUB" -c rabbitmq --since-time="$t0" 2>/dev/null \
        | grep -Ei "minority|paus|partition|node .* (down|up)|net_tick|$Q.*(leader|candidate|term)" \
        | sed -E 's/^([0-9-]+ )?([0-9:.]{12})[0-9]*/\2/' | cut -c1-170 > "out-$label-rmq.log" || true
    sed 's/^/  rmq: /' "out-$label-rmq.log" | head -40
    echo "queue leader $(qinfo leader), online $(qinfo online)"
    probe m2-drain drain
    ended m2-drain 600
    kc -n mq logs m2-drain > "out-$label-drain.log"
    grep '^#' "out-$label-pub.log" | sed 's/^/  pub: /'
    awk '$1 == "ack" {print $2}' "out-$label-pub.log" | sort > out-acked.txt
    awk '$1 == "got" {print $2}' "out-$label-drain.log" | sort > out-got.txt
    sent=$(grep -o 'sent [0-9]*' "out-$label-pub.log" | tail -1 | cut -d' ' -f2); sent=${sent:-$n}
    echo "sent $sent, confirmed $(wc -l < out-acked.txt), nacked $(grep -c '^nack' "out-$label-pub.log" || true), in queue $(wc -l < out-got.txt) ($(sort -u out-got.txt | wc -l) distinct)"
    echo "LOST (confirmed, not in queue): $(comm -23 out-acked.txt <(sort -u out-got.txt) | wc -l)    in queue but never confirmed: $(comm -13 out-acked.txt <(sort -u out-got.txt) | wc -l)    duplicates: $(( $(wc -l < out-got.txt) - $(sort -u out-got.txt | wc -l) ))"
    awk '$1 == "ack" { split($3, a, ":"); ms = (a[1] * 3600 + a[2] * 60 + a[3]) * 1000; if (p && ms - p > g) { g = ms - p; at = $3 } p = ms; last = $3 }
         END { printf "longest gap between confirms: %d ms (ending %s), last confirm %s\n", g, at, last }' "out-$label-pub.log"
    rm -f out-acked.txt out-got.txt
    bash "$SELF" cleanup >/dev/null
    ;;
*)
    echo "usage: $0 experiment <kill2|freeze2> [n] | cleanup" >&2; exit 2 ;;
esac
