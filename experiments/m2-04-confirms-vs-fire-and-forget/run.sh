#!/usr/bin/env bash
# M2-04: kill the broker a publisher is connected to (also the quorum-queue leader), with and without
# publisher confirms, and count what the publisher believed was sent but isn't in the queue.
#   ./run.sh experiment <confirm|fire> <kill|delete> [n]   declare m2-04 with its leader on server-0,
#                     publish n (20000) at RATE (500)/s through server-0, fault server-0 after 20 s,
#                     then drain through server-1 and compare
#   ./run.sh cleanup  remove the probe pods, the chaos and the queue
# "Promised" = what the publisher can claim was delivered: confirmed (confirm), or written to the
# socket (fire: a client without confirms knows nothing more). LOST = promised and not in the queue.
# The publisher doesn't reconnect, so the run ends for it when its broker dies.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
M1=../m2-01-quorum-leader-loss
export MSYS_NO_PATHCONV=1
KCFG=$(cygpath -m "$HOME/.kube/lab.yaml" 2>/dev/null || echo "$HOME/.kube/lab.yaml")
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
now() { date -u +%T.%N | cut -c1-12; }
Q=m2-04 LEADER=rmq-lab-server-0 SURV=rmq-lab-server-1
AMQPLIB=amqplib-2.2.0.tgz
AMQPLIB_SHA512=VifzN9aHs/Q3zTruVHXh2yCisQyXexBN91CQ2E5iSyUKyNjH6ilYhJGte5AXZH/Bj1PaH7SwPhyuSf6Msd2udw==
ctl() { kc -n mq exec "$SURV" -c rabbitmq -- rabbitmqctl -q "$@"; }
admin_on() { local pod=$1; shift
    kc -n mq exec "$pod" -c rabbitmq -- sh -c 'f=/etc/rabbitmq/conf.d/11-default_user.conf
        exec rabbitmqadmin --non-interactive -u "$(sed -n "s/^default_user = //p" $f)" -p "$(sed -n "s/^default_pass = //p" $f)" "$@"' _ "$@"; }
qinfo() { ctl -t 5 list_queues name "$1" 2>/dev/null | awk -v q=$Q '$1 == q' | grep -o 'server-[0-9]' | paste -sd,; }
all_ready() { for i in $(seq 1 60); do [ "$(kc -n mq get pods -l app.kubernetes.io/name=rmq-lab --no-headers | grep -c '1/1')" = 3 ] && return; sleep 5; done; }
# M2-01's probe pod on queue m2-04, connected to $3, kept off the leader's node
probe() { local name=$1 mode=$2 node=$3 n=${4:-0}
    sed -e "s/__NAME__/$name/" -e "s/__MODE__/$mode/" -e "s/__NODE__/$node/" -e "s/__LEADER__/$LEADER/" -e "s/__N__/$n/" \
        -e "s/value: m2-01}/value: $Q}/" -e "s/name: RATE, value: \"500\"/name: RATE, value: \"${RATE:-500}\"/" $M1/probe.yaml | kc apply -f - >/dev/null
    kc -n mq wait --for=condition=Ready "pod/$name" --timeout=2m >/dev/null; }
ended() { for i in $(seq 1 "${2:-300}"); do case $(kc -n mq get pod "$1" -o jsonpath='{.status.phase}') in Succeeded|Failed) return;; esac; sleep 1; done; }

case "${1:-}" in
cleanup)
    kc -n mq delete pod -l app=m2-probe --ignore-not-found --wait=false >/dev/null
    kc -n mq delete podchaos m2-kill-leader --ignore-not-found >/dev/null 2>&1 || true
    admin_on "$SURV" delete queue --name $Q >/dev/null 2>&1 || true
    echo "probe pods removed, queue deleted" ;;
experiment)
    mode=${2:?confirm|fire}; fault=${3:?kill|delete}; n=${4:-20000}; label=$mode-$fault${RATE:+-$RATE}
    case "$mode" in confirm) pmode=publish ;; fire) pmode=fire ;; *) echo "unknown mode $mode" >&2; exit 2 ;; esac
    [ -f "$M1/out-$AMQPLIB" ] || curl -sSL -o "$M1/out-$AMQPLIB" "https://registry.npmjs.org/amqplib/-/$AMQPLIB"
    [ "$(openssl dgst -sha512 -binary "$M1/out-$AMQPLIB" | base64 -w0)" = "$AMQPLIB_SHA512" ] || { echo "amqplib checksum mismatch" >&2; exit 1; }
    kc -n mq create configmap m2-probe --from-file=$M1/probe.js --from-file=amqplib.tgz="$M1/out-$AMQPLIB" --dry-run=client -o yaml | kc apply -f - >/dev/null
    bash "$SELF" cleanup >/dev/null; kc -n mq wait --for=delete pod -l app=m2-probe --timeout=1m >/dev/null 2>&1 || true
    all_ready
    admin_on "$LEADER" declare queue --name $Q --type quorum --durable true >/dev/null
    echo "queue $Q: leader $(qinfo leader), members $(qinfo members)"
    probe m2-pub "$pmode" "$LEADER" "$n"
    echo "publisher ($mode) -> $LEADER, $n messages at ${RATE:-500}/s"
    sleep 20
    echo "$(now) FAULT $fault on $LEADER"
    case "$fault" in
        delete) kc -n mq delete pod "$LEADER" --wait=false >/dev/null ;;
        kill)   sed "s/__POD__/$LEADER/" ../m4-01-pg-failover/pod-kill.yaml | sed -e 's/namespace: db/namespace: mq/' \
                    -e 's/m4-kill-primary/m2-kill-leader/' -e 's/db: \[/mq: [/' | kc apply -f - >/dev/null ;;
        *) echo "unknown fault $fault" >&2; exit 2 ;;
    esac
    ended m2-pub
    kc -n mq logs m2-pub > "out-$label-pub.log"
    all_ready
    echo "queue leader $(qinfo leader), online $(qinfo online)"
    probe m2-drain drain "$SURV"
    ended m2-drain 600
    kc -n mq logs m2-drain > "out-$label-drain.log"
    grep '^#' "out-$label-pub.log" | sed 's/^/  pub: /'
    if [ "$mode" = confirm ]; then promised=ack; else promised=sent; fi
    awk -v k=$promised '$1 == k {print $2}' "out-$label-pub.log" | sort > out-promised.txt
    awk '$1 == "got" {print $2}' "out-$label-drain.log" | sort > out-got-all.txt
    sort -u out-got-all.txt > out-got.txt
    sent=$(grep -o 'sent [0-9]*' "out-$label-pub.log" | tail -1 | cut -d' ' -f2)
    echo "sent ${sent:-?}, promised ($promised) $(wc -l < out-promised.txt), in queue $(wc -l < out-got-all.txt) ($(wc -l < out-got.txt) distinct)"
    lost=$(comm -23 out-promised.txt out-got.txt)
    echo "LOST (promised, not in queue): $(printf '%s' "$lost" | grep -c . || true)    in queue but not promised: $(comm -13 out-promised.txt out-got.txt | wc -l)"
    [ -n "$lost" ] && echo "  lost seq range: $(echo "$lost" | sort -n | head -1) .. $(echo "$lost" | sort -n | tail -1)"
    # When the lost ones were sent, relative to the last line the publisher logged
    [ -n "$lost" ] && awk -v k=$promised 'NR == FNR { l[$1] = 1; next } $1 == k && ($2 in l) { if (!f) f = $3; t = $3 } $1 == k { last = $3 }
        END { printf "  lost ones %s between %s and %s; publisher last logged %s\n", (k == "ack" ? "confirmed" : "sent"), f, t, last }' <(echo "$lost") "out-$label-pub.log"
    rm -f out-promised.txt out-got.txt out-got-all.txt
    bash "$SELF" cleanup >/dev/null
    ;;
*)
    echo "usage: $0 experiment <confirm|fire> <kill|delete> [n] | cleanup" >&2; exit 2 ;;
esac
