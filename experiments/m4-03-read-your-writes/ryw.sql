-- M4-03: read-your-writes, measured from INSIDE the reading server so nothing else adds delay.
-- Runs in a session on the read target (a replica via pg-lab-ro, or the primary via pg-lab-rw).
-- Each iteration: write one row on the primary through dblink (committed when the call returns),
-- then read it locally at once. Created on the primary by run.sh setup; CALLed on the read target.
-- Parameters:
--   rw    connection string of the primary          n    iterations
--   mode  plain | lsnwait (wait until this server has replayed the write's LSN, then read)
--   sc    synchronous_commit for the writes ('' = server default)
-- A PROCEDURE that COMMITs after every iteration, so each check runs in its own short
-- transaction. (Run as one DO block it held a single snapshot for the whole run, and under write
-- load the replica cancelled it: "canceling statement due to conflict with recovery".)
CREATE OR REPLACE PROCEDURE ryw_probe(n int, mode text, sc text, rw text)
LANGUAGE plpgsql AS $$
DECLARE
  new_id bigint;
  lsn    pg_lsn;
  t_commit timestamptz;
  stale  int := 0;
  waits  double precision[] := '{}';
  commits double precision[] := '{}';
  p50 numeric; p99 numeric; pmax numeric; c50 numeric;
BEGIN
  PERFORM dblink_connect('w', rw);
  IF sc <> '' THEN PERFORM dblink_exec('w', 'set synchronous_commit = ' || sc); END IF;

  FOR i IN 1..n LOOP
    t_commit := clock_timestamp();
    SELECT x INTO new_id FROM dblink('w', 'insert into ryw default values returning id') AS t(x bigint);
    commits := commits || extract(epoch FROM clock_timestamp() - t_commit) * 1000;
    -- Primary's WAL position right after the commit: covers the commit record
    SELECT l INTO lsn FROM dblink('w', 'select pg_current_wal_lsn()') AS t(l pg_lsn);

    t_commit := clock_timestamp();   -- from here: how long until the row is visible on THIS server
    -- Every poll ends with COMMIT: waiting inside ONE transaction on a replica holds a snapshot that
    -- blocks replay under write load, i.e. it blocks the very change being waited for (until the
    -- 30 s max_standby_streaming_delay cancels it). Seen in M4-03.
    IF mode = 'lsnwait' AND pg_is_in_recovery() THEN
      LOOP
        EXIT WHEN pg_last_wal_replay_lsn() >= lsn;
        COMMIT; PERFORM pg_sleep(0.0005);
      END LOOP;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ryw WHERE id = new_id) THEN
      stale := stale + 1;            -- the first read missed the write we just committed
      LOOP
        COMMIT; PERFORM pg_sleep(0.0005);
        EXIT WHEN EXISTS (SELECT 1 FROM ryw WHERE id = new_id);
      END LOOP;
    END IF;
    waits := waits || extract(epoch FROM clock_timestamp() - t_commit) * 1000;
    COMMIT;                          -- end this short read transaction, take a fresh snapshot next time
  END LOOP;
  PERFORM dblink_disconnect('w');

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY w), percentile_cont(0.99) WITHIN GROUP (ORDER BY w), max(w)
    INTO p50, p99, pmax FROM unnest(waits) w;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY c) INTO c50 FROM unnest(commits) c;
  RAISE NOTICE 'RESULT reader=% n=% stale_first_reads=% (% pct) | until visible p50 % ms p99 % ms max % ms | commit p50 % ms',
    CASE WHEN pg_is_in_recovery() THEN 'replica ' || inet_server_addr() ELSE 'primary' END,
    n, stale, round(100.0 * stale / n, 1), round(p50, 2), round(p99, 2), round(pmax, 2), round(c50, 2);
END $$;
