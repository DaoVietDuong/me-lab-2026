#!/usr/bin/env bash
# M4-03: replication lag and read-your-writes (the CQRS read side right after a write).
#   ./run.sh setup | teardown        client pod, dblink, table ryw, procedure ryw_probe (teardown removes all)
#   ./run.sh ryw <label> <ro|rw> <plain|lsnwait> [synchronous_commit] [n]
#        in-server probe (ryw.sql): a session ON the read target writes via dblink, reads locally at once.
#        Sub-millisecond precision; only valid without network faults (the fault would delay its own replies).
#   ./run.sh ext <label> <plain|lsnwait|primary> [synchronous_commit] [n]
#        client-pod probe: write on pg-lab-rw, read on pg-lab-ro (or the primary). Each query is a new psql
#        (a few ms overhead), so use it for the 300 ms lag cases, where clients aren't delayed.
#   ./run.sh load start|stop         pgbench write load on the primary (8 clients) in the background
#   ./run.sh longread                under load: hold one snapshot 60 s on a replica, watch its replay lag
#   ./run.sh sync off|any1|any2      quorum synchronous replication with 1 or 2 standbys
#   ./run.sh experiment              all scenarios, then teardown
#   ./run.sh lagpart                 only the 300 ms lag scenarios (setup + teardown included)
# Lag: M4-02's fault (300 ms on primary -> replica traffic only). Run from Windows Git Bash.
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"
LAG=../m4-02-pg-sync-vs-async/run.sh
kc() { kubectl --kubeconfig "$HOME/.kube/lab.yaml" "$@"; }
primary() { kc -n db get cluster pg-lab -o jsonpath='{.status.currentPrimary}'; }
super() { kc -n db exec "$(primary)" -c postgres -- psql -qtAX -d lab "$@"; }
client() { kc -n db exec ryw-client -- bash -c "$1"; }

case "${1:-}" in
setup)
    super -c "create extension if not exists dblink" -c "drop procedure if exists ryw_probe" -c "drop table if exists ryw" >/dev/null
    kc apply -f client.yaml >/dev/null && kc -n db wait --for=condition=Ready pod/ryw-client --timeout=2m >/dev/null
    client 'psql "$PGURI" -qtAX -c "create table ryw (id bigserial primary key, at timestamptz not null default clock_timestamp())"'
    kc -n db cp ryw.sql ryw-client:/tmp/ryw.sql
    client 'psql "$PGURI" -qX -v ON_ERROR_STOP=1 -f /tmp/ryw.sql'
    echo "setup done: dblink, table ryw, procedure ryw_probe, client pod on $(kc -n db get pod ryw-client -o jsonpath='{.spec.nodeName}')"
    ;;
ryw)
    label=$2; target=$3; mode=$4; sc=${5:-}; n=${6:-300}
    # Same app user and password; only the host differs. The primary's URI goes in as a psql variable on stdin.
    out=$(client "U=\${PGURI/pg-lab-rw/pg-lab-$target}
        echo \"call ryw_probe($n, '$mode', '$sc', :'rw');\" | psql \"\$U\" -qX -v ON_ERROR_STOP=1 -v rw=\"\$PGURI\" 2>&1" |
        grep -oE 'RESULT .*|ERROR.*' || true)
    printf '%-28s %s\n' "$label" "${out#RESULT }"
    ;;
ext)
    label=$2; mode=$3; sc=${4:-}; n=${5:-40}
    # Per iteration: commit on the primary, then read at once on the read side; poll until visible.
    # Output per line: <stale 0|1> <ms until visible> <ms commit>
    client "W=\$PGURI; R=\${PGURI/pg-lab-rw/pg-lab-ro}; [ '$mode' = primary ] && R=\$PGURI
        ms() { echo \$(( (\$(date +%s%N) - \$1) / 1000000 )); }
        for i in \$(seq $n); do
          t=\$(date +%s%N)
          id=\$(psql \"\$W\" -qtAX -c \"set synchronous_commit = '${sc:-on}'\" -c 'insert into ryw default values returning id')
          c=\$(ms \$t); t=\$(date +%s%N); stale=0
          if [ '$mode' = lsnwait ]; then
            lsn=\$(psql \"\$W\" -qtAX -c 'select pg_current_wal_lsn()'); t=\$(date +%s%N)
            until [ \"\$(psql \"\$R\" -qtAX -c \"select pg_last_wal_replay_lsn() >= '\$lsn'\")\" = t ]; do :; done
          fi
          if [ \"\$(psql \"\$R\" -qtAX -c \"select count(*) from ryw where id = \$id\")\" = 0 ]; then
            stale=1; until [ \"\$(psql \"\$R\" -qtAX -c \"select count(*) from ryw where id = \$id\")\" = 1 ]; do :; done
          fi
          echo \"\$stale \$(ms \$t) \$c\"
        done" > "out-ext-$label.txt"
    awk -v label="$label" '{ n++; s += $1; v[n] = $2; c[n] = $3 } END { asort(v); asort(c)
        printf "%-28s n=%d stale_first_reads=%d (%.1f pct) | until visible p50 %d ms p99 %d ms | commit p50 %d ms (both incl. ~47 ms psql start-up)\n",
            label, n, s, 100 * s / n, v[int(n * .5 + .5)], v[int(n * .99 + .5)], c[int(n * .5 + .5)] }' "out-ext-$label.txt"
    ;;
load)
    if [ "$2" = start ]; then
        client 'pgbench "$PGURI" -i -q -s 2 >/dev/null 2>&1; nohup pgbench "$PGURI" -n -N -c 8 -j 2 -T 600 > /tmp/pgbench.log 2>&1 &'
        sleep 5; echo "load on: pgbench 8 clients; replica lag now: $(super -c "select string_agg(application_name||' '||pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)||' B', ', ') from pg_stat_replication")"
    else
        client 'pkill pgbench || true; psql "$PGURI" -qtAX -c "drop table if exists pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history" >/dev/null'
        echo "load off"
    fi
    ;;
longread)
    # One REPEATABLE READ snapshot held for 60 s on a replica while pgbench writes on the primary.
    # Replay must either wait for it (the replica falls behind) or cancel it (max_standby_streaming_delay).
    client 'U=${PGURI/pg-lab-rw/pg-lab-ro}; psql "$U" -qX -c "begin isolation level repeatable read" \
        -c "select inet_server_addr() as replica, count(*) as accounts from pgbench_accounts" \
        -c "select pg_sleep(60)" -c "select count(*) from pgbench_accounts" -c "commit" > /tmp/longread.log 2>&1 &'
    for i in $(seq 1 14); do
        sleep 5
        echo "  +$((i*5))s replay lag: $(super -c "select string_agg(application_name||' '||coalesce(round(extract(epoch from replay_lag))::text||' s','-')||' / '||pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), ',  ') from pg_stat_replication")"
    done
    echo "  long read on the replica said:"; client 'grep -E "ERROR|DETAIL|10\." /tmp/longread.log | head -4' | sed 's/^/    /'
    ;;
sync)
    case "$2" in
        off)  kc -n db patch cluster pg-lab --type json -p '[{"op":"remove","path":"/spec/postgresql/synchronous"}]' >/dev/null 2>&1 || true ;;
        any1) kc -n db patch cluster pg-lab --type merge -p '{"spec":{"postgresql":{"synchronous":{"method":"any","number":1,"dataDurability":"required"}}}}' >/dev/null ;;
        any2) kc -n db patch cluster pg-lab --type merge -p '{"spec":{"postgresql":{"synchronous":{"method":"any","number":2,"dataDurability":"required"}}}}' >/dev/null ;;
    esac
    want=$(case "$2" in off) echo "";; any1) echo "ANY 1";; any2) echo "ANY 2";; esac)
    for i in $(seq 1 60); do s=$(super -c "show synchronous_standby_names"); [ "${s%% (*}" = "$want" ] && break; sleep 2; done
    echo "sync $2: '$(super -c 'show synchronous_standby_names')'"
    ;;
teardown)
    bash "$SELF" load stop >/dev/null 2>&1 || true
    kc -n db delete pod ryw-client --ignore-not-found --wait=false >/dev/null
    super -c "drop procedure if exists ryw_probe" -c "drop table if exists ryw" -c "drop extension if exists dblink" >/dev/null
    echo "teardown done"
    ;;
lagpart)
    bash "$LAG" lag off >/dev/null; bash "$SELF" sync off >/dev/null
    bash "$SELF" setup >/dev/null
    bash "$SELF" ext nolag_baseline        plain
    bash "$LAG" lag on
    bash "$SELF" ext lag_replica           plain
    bash "$SELF" ext lag_FIX_read_primary  primary
    bash "$SELF" ext lag_FIX_lsn_wait      lsnwait
    bash "$SELF" sync any1; bash "$LAG" lag on
    bash "$SELF" ext lag_remote_apply_ANY1 plain remote_apply 30
    bash "$SELF" sync any2; bash "$LAG" lag on
    bash "$SELF" ext lag_remote_apply_ANY2 plain remote_apply 30
    bash "$LAG" lag off; bash "$SELF" sync off
    bash "$SELF" teardown
    ;;
experiment)
    bash "$LAG" lag off >/dev/null; bash "$SELF" sync off
    bash "$SELF" setup
    echo "--- no network fault (in-server probe, sub-ms)"
    bash "$SELF" ryw idle_replica ro plain
    bash "$SELF" load start
    bash "$SELF" ryw load_replica ro plain
    echo "--- one long read transaction on a replica under the same load"; bash "$SELF" longread
    bash "$SELF" load stop
    bash "$SELF" teardown >/dev/null
    echo "--- replicas 300 ms behind (client-pod probe)"
    bash "$SELF" lagpart
    ;;
*)
    echo "usage: $0 setup | ryw <label> <ro|rw> <plain|lsnwait> [sc] [n] | ext <label> <plain|lsnwait|primary> [sc] [n] | load start|stop | longread | sync off|any1|any2 | teardown | lagpart | experiment" >&2; exit 2 ;;
esac
