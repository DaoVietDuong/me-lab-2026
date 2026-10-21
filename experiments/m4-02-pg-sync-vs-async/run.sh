#!/usr/bin/env bash
# M4-02: synchronous vs asynchronous replication - what it costs, and what it buys.
#   ./run.sh sync on|off           synchronous replication: commit waits for ANY 1 replica to flush (CNPG, dataDurability required)
#   ./run.sh lag on|off            300 ms delay on primary -> replica traffic (Chaos Mesh)
#   ./run.sh measure <label>       unthrottled single writer for 25 s: commits/s and per-commit latency
#   ./run.sh failtest <label>      writer at ~300/s, SIGKILL the primary, count lost acknowledged writes
#   ./run.sh experiment            all four throughput cases, then the kill test async vs sync, under lag
# Reuses M4-01's writer, analysis and cleanup. Run from Windows Git Bash.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
M4=../m4-01-pg-failover/run.sh
kc() { kubectl --kubeconfig "$HOME/.kube/lab.yaml" "$@"; }
primary() { kc -n db get cluster pg-lab -o jsonpath='{.status.currentPrimary}'; }
psql_p() { kc -n db exec "$(primary)" -c postgres -- psql -qtAX "$@"; }

case "${1:-}" in
sync)
    if [ "$2" = on ]; then
        kc -n db patch cluster pg-lab --type merge -p '{"spec":{"postgresql":{"synchronous":{"method":"any","number":1,"dataDurability":"required"}}}}' >/dev/null
    else
        kc -n db patch cluster pg-lab --type json -p '[{"op":"remove","path":"/spec/postgresql/synchronous"}]' >/dev/null 2>&1 || true
    fi
    want=$([ "$2" = on ] && echo yes || echo no)
    for i in $(seq 1 60); do
        s=$(psql_p -c "show synchronous_standby_names" 2>/dev/null || true)
        { [ "$want" = yes ] && [ -n "$s" ]; } || { [ "$want" = no ] && [ -z "$s" ]; } && break; sleep 2
    done
    echo "sync $2: synchronous_standby_names='$(psql_p -c 'show synchronous_standby_names')'  states: $(psql_p -c "select string_agg(application_name||'='||sync_state, ' ') from pg_stat_replication")"
    ;;
lag)
    if [ "$2" = on ]; then
        sed "s/__PRIMARY__/$(primary)/" lag.yaml | kc apply -f - >/dev/null
        for i in $(seq 1 30); do
            [ "$(kc -n db get networkchaos m4-replica-lag -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}')" = True ] && break; sleep 2
        done
        echo "lag on: 300 ms primary ($(primary)) -> replicas; replay lag now: $(psql_p -c "select string_agg(application_name||' '||coalesce(replay_lag::text,'-'), ', ') from pg_stat_replication")"
    else
        kc -n db delete networkchaos m4-replica-lag --ignore-not-found >/dev/null; echo "lag off"
    fi
    ;;
measure)
    label=$2
    RATE_SLEEP=0 bash "$M4" reset >/dev/null
    sleep 25
    kc -n db logs pg-writer > "out-$label.log"
    bash "$M4" cleanup >/dev/null
    # Commits per second between 5 s and 25 s after the first ack (server timestamps HH:MM:SS.mmm)
    awk -F'|' -v label="$label" '
        /^[0-9]+\|/ { split($2, t, ":"); s = t[1]*3600 + t[2]*60 + t[3]; if (!first) first = s
                      if (s >= first + 5 && s < first + 25) n++ }
        END { r = n / 20; printf "%-14s %7.1f commits/s  (%6.1f ms per commit)\n", label, r, (r > 0 ? 1000 / r : 0) }' "out-$label.log"
    ;;
failtest)
    label=$2
    bash "$M4" reset >/dev/null
    sleep 15
    old=$(primary)
    echo "$(date -u +%T) SIGKILL primary $old  (replay lag at that moment: $(psql_p -c "select string_agg(application_name||' '||coalesce(replay_lag::text,'-'), ', ') from pg_stat_replication"))"
    sed "s/__POD__/$old/" ../m4-01-pg-failover/pod-kill.yaml | kc apply -f - >/dev/null
    for i in $(seq 1 90); do p=$(primary 2>/dev/null || true); [ -n "$p" ] && [ "$p" != "$old" ] && break; sleep 1; done
    echo "$(date -u +%T) new primary $(primary)"
    kc -n db delete networkchaos m4-replica-lag --ignore-not-found >/dev/null   # the lag targeted the old primary
    sleep 20
    kc -n db delete podchaos m4-kill-primary --ignore-not-found >/dev/null
    echo "== $label"; bash "$M4" analyze | grep -E 'acknowledged|LOST|outage'
    bash "$M4" cleanup >/dev/null
    for i in $(seq 1 60); do [ "$(kc -n db get cluster pg-lab -o jsonpath='{.status.readyInstances}')" = 3 ] && break; sleep 3; done
    ;;
experiment)
    bash "$SELF" lag off >/dev/null; bash "$SELF" sync off
    bash "$SELF" measure async_nolag
    bash "$SELF" sync on;  bash "$SELF" measure sync_nolag
    bash "$SELF" lag on;   bash "$SELF" measure sync_lag300
    bash "$SELF" sync off; bash "$SELF" measure async_lag300
    echo "--- kill the primary while replicas lag 300 ms"
    bash "$SELF" lag on;  bash "$SELF" failtest async_lag300
    bash "$SELF" sync on; bash "$SELF" lag on; bash "$SELF" failtest sync_lag300
    bash "$SELF" lag off; bash "$SELF" sync off
    ;;
*)
    echo "usage: $0 sync on|off | lag on|off | measure <label> | failtest <label> | experiment" >&2; exit 2 ;;
esac
