#!/usr/bin/env bash
# M2-01: lose the quorum-queue leader while a publisher with confirms is sending.
#   ./run.sh experiment <none|delete|kill|freeze> [n]   declare m2-01 with its leader on rmq-lab-server-0, publish n
#                     (40000) messages at 500/s through server-1, fault the leader after 20 s, watch the
#                     leader once a second, then drain the queue and compare it with the confirmed set
#   ./run.sh cleanup  remove the probe pods and the queue
# Faults: none   = baseline
#         delete = kubectl delete pod (graceful: the operator's preStop hook, then RabbitMQ shutdown)
#         kill   = Chaos Mesh pod-kill, grace 0 (SIGKILL)
#         freeze = SIGSTOP the leader's Erlang VM for FREEZE_S (60) seconds, sent from the node: a hung node
#                  whose sockets stay open (the kernel still completes TCP handshakes), unlike delete/kill
# probe.js logs every confirm and the drain lists every message, so "lost" means confirmed and then
# missing. Not the queue depth from list_queues: it comes from stats that lag (9294 shown, 10000 there).
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
# Git Bash on Windows would turn the in-pod /etc/... paths into C:/Program Files/Git/etc/..., so path
# conversion is off and the kubeconfig path is given in Windows form (cygpath only exists there)
export MSYS_NO_PATHCONV=1
KCFG=$(cygpath -m "$HOME/.kube/lab.yaml" 2>/dev/null || echo "$HOME/.kube/lab.yaml")
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
now() { date -u +%T.%N | cut -c1-12; }
LEADER=rmq-lab-server-0 PUB=rmq-lab-server-1
AMQPLIB=amqplib-2.2.0.tgz
AMQPLIB_SHA512=VifzN9aHs/Q3zTruVHXh2yCisQyXexBN91CQ2E5iSyUKyNjH6ilYhJGte5AXZH/Bj1PaH7SwPhyuSf6Msd2udw==
# rabbitmqctl / rabbitmqadmin on a node that survives; admin credentials read inside the pod, never printed
ctl() { kc -n mq exec "$PUB" -c rabbitmq -- rabbitmqctl -q "$@"; }
admin_on() { local pod=$1; shift
    kc -n mq exec "$pod" -c rabbitmq -- sh -c 'f=/etc/rabbitmq/conf.d/11-default_user.conf
        exec rabbitmqadmin --non-interactive -u "$(sed -n "s/^default_user = //p" $f)" -p "$(sed -n "s/^default_pass = //p" $f)" "$@"' _ "$@"; }
leader() { ctl -t 5 list_queues name leader 2>/dev/null | awk '$1 == "m2-01" { sub(/^rabbit@/, "", $2); sub(/\..*/, "", $2); print $2 }'; }
members() { ctl list_queues name "$1" 2>/dev/null | awk '$1 == "m2-01"' | grep -o 'server-[0-9]' | paste -sd,; }
all_ready() { for i in $(seq 1 60); do [ "$(kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | grep -c '1/1')" = 3 ] && return; sleep 5; done; }
# Run probe.js in a pod (publish or drain) and wait for it to finish
probe() { local name=$1 mode=$2 n=${3:-0}
    sed -e "s/__NAME__/$name/" -e "s/__MODE__/$mode/" -e "s/__NODE__/$PUB/" -e "s/__LEADER__/$LEADER/" -e "s/__N__/$n/" probe.yaml | kc apply -f - >/dev/null
    kc -n mq wait --for=condition=Ready "pod/$name" --timeout=2m >/dev/null; }
finished() { kc -n mq wait --for=jsonpath='{.status.phase}'="$2" "pod/$1" --timeout="${3:-5m}" >/dev/null 2>&1; }

case "${1:-}" in
cleanup)
    kc -n mq delete pod -l app=m2-probe --ignore-not-found --wait=false >/dev/null
    kc -n mq delete podchaos m2-kill-leader --ignore-not-found >/dev/null 2>&1 || true
    admin_on "$PUB" delete queue --name m2-01 >/dev/null 2>&1 || true
    echo "probe pods removed, queue deleted" ;;
experiment)
    fault=${2:?none|delete|kill|freeze}; n=${3:-40000}; label=$fault
    # amqplib from the npm registry, checked against its published sha512 (the pods can't reach npm)
    [ -f "out-$AMQPLIB" ] || curl -sSL -o "out-$AMQPLIB" "https://registry.npmjs.org/amqplib/-/$AMQPLIB"
    [ "$(openssl dgst -sha512 -binary "out-$AMQPLIB" | base64 -w0)" = "$AMQPLIB_SHA512" ] || { echo "amqplib checksum mismatch" >&2; exit 1; }
    kc -n mq create configmap m2-probe --from-file=probe.js --from-file=amqplib.tgz="out-$AMQPLIB" --dry-run=client -o yaml | kc apply -f - >/dev/null
    bash "$SELF" cleanup >/dev/null; kc -n mq wait --for=delete pod -l app=m2-probe --timeout=1m >/dev/null 2>&1 || true
    all_ready
    # Declared through the HTTP API of server-0: quorum queue leaders are placed client-local
    admin_on "$LEADER" declare queue --name m2-01 --type quorum --durable true >/dev/null
    echo "queue m2-01: leader $(leader), members $(members members)"
    probe m2-pub publish "$n"
    echo "publisher on $(kc -n mq get pod m2-pub -o jsonpath='{.spec.nodeName}') -> $PUB, $n messages at 500/s, window 100"
    sleep 20
    old=$(leader)
    echo "$(now) FAULT $fault on $old"
    case "$fault" in
        none)   ;;
        delete) kc -n mq delete pod "$old" --wait=false >/dev/null ;;
        freeze) node_ip=$(kc get node "$(kc -n mq get pod "$old" -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
                # PID 1 in the container ignores SIGSTOP sent from inside it, so signal the host process
                frz() { ssh -o BatchMode=yes lab@"$node_ip" "sudo pkill -$1 -o -x beam.smp"; }
                trap 'frz CONT' EXIT; frz STOP
                ( sleep "${FREEZE_S:-60}"; frz CONT; echo "$(now) RESUMED $old after ${FREEZE_S:-60} s" ) & ;;
        kill)   sed "s/__POD__/$old/" ../m4-01-pg-failover/pod-kill.yaml | sed -e 's/namespace: db/namespace: mq/' -e 's/m4-kill-primary/m2-kill-leader/' -e 's/db: \[/mq: [/' | kc apply -f - >/dev/null ;;
    esac
    if [ "$fault" != none ]; then
        for i in $(seq 1 60); do
            l=$(leader || true)
            if [ -n "$l" ] && [ "$l" != "$old" ]; then echo "$(now) NEW LEADER $l after ~${i} s"; break; fi
            sleep 1
        done
    fi
    finished m2-pub Succeeded || echo "publisher did not finish cleanly (phase $(kc -n mq get pod m2-pub -o jsonpath='{.status.phase}'))"
    kc -n mq logs m2-pub > "out-$label-pub.log"
    all_ready
    echo "queue depth (stats, may lag) $(ctl list_queues name messages | awk '$1 == "m2-01" {print $2}'), leader $(leader), online $(members online)"
    probe m2-drain drain
    finished m2-drain Succeeded 10m || echo "drain did not finish cleanly"
    kc -n mq logs m2-drain > "out-$label-drain.log"
    grep '^#' "out-$label-pub.log" | sed 's/^/  pub: /'
    awk '$1 == "ack" {print $2}' "out-$label-pub.log" | sort > out-acked.txt
    awk '$1 == "got" {print $2}' "out-$label-drain.log" | sort > out-got.txt
    echo "confirmed $(wc -l < out-acked.txt), nacked $(grep -c '^nack' "out-$label-pub.log" || true), in queue $(wc -l < out-got.txt) ($(sort -u out-got.txt | wc -l) distinct)"
    echo "LOST (confirmed, not in queue): $(comm -23 out-acked.txt <(sort -u out-got.txt) | wc -l)    in queue but never confirmed: $(comm -13 out-acked.txt <(sort -u out-got.txt) | wc -l)    duplicates: $(( $(wc -l < out-got.txt) - $(sort -u out-got.txt | wc -l) ))"
    missing=$(comm -23 <(seq 1 "$n" | sort) <(sort -u out-got.txt))
    [ -n "$missing" ] && echo "  missing from queue: $(echo "$missing" | wc -l) messages, seq $(echo "$missing" | sort -n | head -1) .. $(echo "$missing" | sort -n | tail -1), of which confirmed: $(comm -12 <(echo "$missing") out-acked.txt | wc -l)"
    # Longest pause between consecutive confirms (the publisher's view of the leader change)
    awk '$1 == "ack" { split($3, a, ":"); ms = (a[1] * 3600 + a[2] * 60 + a[3]) * 1000; if (p && ms - p > g) { g = ms - p; at = $3 } p = ms }
         END { printf "longest gap between confirms: %d ms (ending %s)\n", g, at }' "out-$label-pub.log"
    rm -f out-acked.txt out-got.txt
    bash "$SELF" cleanup >/dev/null
    ;;
*)
    echo "usage: $0 experiment <none|delete|kill|freeze> [n] | cleanup" >&2; exit 2 ;;
esac
