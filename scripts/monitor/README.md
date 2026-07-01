# Prod monitor scripts

Watchdogs that run as launchd agents on the always-on dev-Mac and SSH into prod
`.252` to check health. Each agent posts to the prod Discord webhook when it
detects a fault and posts a recovery when it clears.

The scripts live in this repo but are **deployed** to `~/oe-ops/` on the Mac
alongside the existing `error-watch-prod`, `premarket-prod`, `liveness-prod`,
and `rebalance-prod` agents. They reuse the same secret files:

- `~/oe-ops/.prod-ssh-pw` — SSH password for `abhinav@192.168.100.252`
- `~/oe-ops/.prod-discord-webhook` — prod Discord webhook URL

## `prod-spot-freshness-watch.sh` — silent gateway-freeze detector

Closes the blind spot that let prod feed-gateway wedge silently for 9.5 hours
during market hours on 2026-07-01. The existing monitors could not catch it:

- `error-watch-prod` — no ERROR/Exception was logged.
- `prod-rebalance-watch` — Streams apps stayed RUNNING.
- `prod-liveness-watch` — the raw Kafka topic offset kept growing (the feed was
  fine; only the *gateway forwarding* stopped).

This one reads the gateway's own Prometheus gauge
`options_edge_gateway_last_forward_age_seconds` (age of the last forwarded
selected-source record — bumped on every SPX price / snapshot forward). During
market hours this is normally sub-second. If it climbs past 90s, the gateway is
wedged even though pods still read Ready.

Falls back to the `/healthz` field `lastSelectedForwardAgeSeconds` if `/metrics`
is unavailable.

### Behaviour

- Runs every 60s (launchd `com.optionsedge.spot-freshness-prod`).
- Market-hours gate: Mon–Fri 09:30–16:00 ET (silent no-op outside).
- Alerts once when age ≥ 90s; re-alerts at most once every 5 min while the
  freeze persists (`SPOT_FRESHNESS_DEDUPE_SEC`, default 300).
- Posts `✅ PROD SPOT RECOVERED` when age drops back under threshold.
- Silent no-op if the SSH gather fails — never false-alarms on our own blip.
- **Post-open grace (Codex P2 fix):** during the first 180s after 09:30 ET the
  gauge still reflects the overnight age (hours), so the very first sample
  after the bell would always exceed the threshold. In the grace window the
  script logs the observation and exits without alerting *or* touching state
  (so no spurious `PROD SPOT RECOVERED` can fire mid-grace either). Tunable
  via `SPOT_FRESHNESS_OPEN_GRACE_SEC` (default 180, set 0 to disable).

### Environment overrides (for local testing)

- `SPOT_FRESHNESS_FORCE=1` — bypass the market-hours gate.
- `SPOT_FRESHNESS_THRESHOLD_SEC` — override the 90s threshold.
- `SPOT_FRESHNESS_DEDUPE_SEC` — override the 300s dedupe window.
- `SPOT_FRESHNESS_OPEN_GRACE_SEC` — override the 180s post-open grace period
  (set to `0` to disable the grace entirely, e.g. in a test).

## Install (operator)

The launchd agent does **not** auto-install. After this PR merges, run on the
dev-Mac:

```bash
# 1. copy the script and plist into place
cp scripts/monitor/prod-spot-freshness-watch.sh ~/oe-ops/
chmod +x ~/oe-ops/prod-spot-freshness-watch.sh
cp scripts/monitor/com.optionsedge.spot-freshness-prod.plist ~/Library/LaunchAgents/

# 2. sanity-check with the market-hours gate bypassed
SPOT_FRESHNESS_FORCE=1 /opt/homebrew/bin/bash ~/oe-ops/prod-spot-freshness-watch.sh

# 3. load the agent
launchctl unload ~/Library/LaunchAgents/com.optionsedge.spot-freshness-prod.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/com.optionsedge.spot-freshness-prod.plist

# 4. tail the log
tail -f ~/oe-ops/spot-freshness-prod.log
```

## Verify a simulated freeze

To confirm the alert path works without waiting for a real freeze, lower the
threshold to 0 (so ANY forward age triggers) and force the gate:

```bash
SPOT_FRESHNESS_FORCE=1 SPOT_FRESHNESS_THRESHOLD_SEC=0 \
  /opt/homebrew/bin/bash ~/oe-ops/prod-spot-freshness-watch.sh
```

A single `🚨 PROD SPOT FROZEN` embed should appear in the prod Discord channel;
run it again immediately and it should be deduped; run it with the threshold
restored and you should see the `✅ PROD SPOT RECOVERED` post.

## Verify the post-open grace period (Codex P2)

The grace window should suppress alerts for the first 180s after 09:30 ET even
when the gauge exceeds the threshold. To confirm both branches without waiting
for the bell:

```bash
# 1. Grace ACTIVE — alert must NOT fire even at threshold 0. Expect a log line
#    "open-grace age=... — skip alert" and no Discord post.
SPOT_FRESHNESS_FORCE=1 SPOT_FRESHNESS_THRESHOLD_SEC=0 \
  SPOT_FRESHNESS_OPEN_GRACE_SEC=86400 \
  /opt/homebrew/bin/bash ~/oe-ops/prod-spot-freshness-watch.sh

# 2. Grace DISABLED — same conditions, alert SHOULD fire.
SPOT_FRESHNESS_FORCE=1 SPOT_FRESHNESS_THRESHOLD_SEC=0 \
  SPOT_FRESHNESS_OPEN_GRACE_SEC=0 \
  /opt/homebrew/bin/bash ~/oe-ops/prod-spot-freshness-watch.sh
```

Step 1 proves the grace suppresses the noisy 09:30 first-tick alert; step 2
proves the alert path itself still works when grace is disabled.
