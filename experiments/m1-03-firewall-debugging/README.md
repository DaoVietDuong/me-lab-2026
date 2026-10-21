# M1-03 — Firewall rule debugging from the logs

**Date:** 2026-10-21 · **Module:** 1 Networking · **Status:** done

## Hypothesis

A bad firewall change (the tester → lab allow rule disappears) breaks **only** tester → VIP:443, for exactly as long as the rule is missing. Admin traffic from Windows uses a different rule and keeps working. Loki alone should name the flow (src, dst, port, interfaces) and the time window; the nft counters then show which rule should have matched.

## Setup

- Hub firewall in normal mode; drops logged as `fw-drop fwd:` and shipped by rsyslog → Alloy → Loki (`{job="hub-syslog"}`).
- Probes: the tester and Windows each request `https://hello.apps.lab` once a second (timeout 0.9 s).

## Fault

`./run.sh break 60`: `nft flush chain inet lab_fw tester_to_lab` (the one rule "443 to 10.10.0.200"). The hub restores it by itself after 60 s (`systemd-run` timer → `lab-fw normal`). `./run.sh experiment` runs the whole thing: probe 120 s, break at +20 s, diagnose.

## Observed (clean run, 08:57)

| Source | What it said |
| --- | --- |
| Tester probe | `08:56:47 ok` → `08:57:08 FAIL` → `08:58:11 ok`: **87 ok, 33 failed** |
| Windows probe (control) | **120 ok, 0 failed** |
| Loki, grouped by flow | `src=10.20.0.10 dst=10.10.0.200 dpt=443 in=eth3 out=eth2 → 33 packets`. **One flow, and 33 drops = 33 failures** (one SYN each; curl gave up before a retransmit) |
| Loki, per minute | 28 drops in 08:57–08:58, 5 in 08:58–08:59 |
| Hub, after the heal | `tcp dport 443 ip daddr 10.10.0.200 counter packets 67 … accept`: the rule is back and matching |
| Hub journal | flushed 08:57:08, `lab-fw-heal.service` ran 08:58:09 |

Diagnosis from Loki only (`./run.sh diagnose 5`):
```logql
sum by (in, out, src, dst, dpt) (count_over_time({job="hub-syslog"} |= "fw-drop fwd"
  | regexp `IN=(?P<in>\S+) OUT=(?P<out>\S*) .*SRC=(?P<src>\S+) DST=(?P<dst>\S+) .*DPT=(?P<dpt>\d+)` [5m]))
```
`IN=eth3 OUT=eth2` = spoke-test → spoke-lab, DST = the VIP, DPT = 443: exactly the traffic the `tester_to_lab` chain exists for, so that's where to look. It was empty.

## Result

**Confirmed.** Only the tester's flow broke; the outage seen by the client (~63 s) is the 60 s break plus probe granularity. Every failed request has exactly one log line, and the log lines alone point to the missing rule.

## Two side findings (both fixed)

### 1. "60 seconds" was 78–86 seconds: systemd timer accuracy

The first two runs looked wrong: failures started 20 s *before* the break, and lasted 25 s *after* the heal. Clocks were fine (all VMs within ~1 ms). The hub journal showed the real cause: the heal timer, created with `systemd-run --on-active=60s`, fired after **78 s** and **86 s**. systemd timers default to `AccuracySec=1min` and may fire up to a minute late, to batch wake-ups. Run 2 started while run 1's break was still in force.

**This also applied to the firewall deploy's safety net** (`lab-fw apply --guard`, "rolls back in 60 s"). It could have taken up to ~2 minutes.
**Fix:** `--timer-property=AccuracySec=1s` on both. Re-measured: heal 21 s for 20 s; guard rollback **61 s for 60 s**.

### 2. A real blocked flow nobody had noticed: Grafana → grafana.com

The very first `diagnose` showed another flow: `src=10.10.0.13 (lab-node3) dst=34.120.177.193 dpt=443 in=eth2 out=eth0`, an egress attempt the allowlist blocks.
- `dig` on the hub: 34.120.177.193 = **grafana.com**. Grafana runs on lab-node3.
- Grafana's log: `plugin.backgroundinstaller … Failed to install plugin pluginId=grafana-metricsdrilldown-app … https://grafana.com/api/plugins/…`, retried every 10 s. **239 drops in 2 hours**.
- Allowing grafana.com just moved the block. The plugin files come from **storage.googleapis.com** (13 new blocked IPs, exactly what that name resolved to).
- **Decision:** don't allow GCS. That would open egress to *any* bucket, a classic exfiltration path. Instead Grafana gets `plugins.preinstall_disabled: true`, and grafana.com stays off the list. Result: **0** egress drops from node3 afterwards.

## Lessons

- **Debug the firewall from the logs:** group drops by `(in, out, src, dst, dpt)`. Interfaces tell you which zones, DST + DPT tell you which rule should have matched, and per-minute counts give you the window.
- **Count the drops against the failures.** 33 = 33 here means nothing else was in play.
- **Short timers in systemd need `AccuracySec`.** Any safety mechanism with a deadline ("roll back in 60 s") should be measured, not assumed.
- **A default-deny egress policy finds the chatty software for you.** Grafana phoning home was invisible until the drop logs were grouped. When something is blocked, the fix isn't always to allow it.
