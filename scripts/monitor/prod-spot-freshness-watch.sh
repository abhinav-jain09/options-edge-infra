#!/usr/bin/env bash
# prod-spot-freshness-watch.sh — Discord alert if the prod feed-gateway stops forwarding
# the SPX spot / index-price stream during market hours (a silent gateway freeze).
#
# WHY: on 2026-07-01 the prod feed-gateway silently wedged for ~9.5 hours during market
# hours. The chain (Kafka options.databento.raw) kept producing, the pods were Ready,
# the error-watcher was silent, and prod-liveness-watch (which measures the raw Kafka
# topic offset) also saw growth — but the gateway was not forwarding anything to
# WebSocket clients, so every UI was frozen. Nobody knew until users complained.
#
# This watchdog closes THAT gap: it reads the gateway's own
# `options_edge_gateway_last_forward_age_seconds` Prometheus gauge (the age of the last
# forwarded selected-source record — this counter is bumped on every SPX price/snapshot
# forward). During market hours the value is normally sub-second; if it exceeds 90s the
# gateway is wedged even though Kubernetes still sees it as Ready.
#
# Runs every 60s via launchd (com.optionsedge.spot-freshness-prod), gated to Mon-Fri
# 09:30-16:00 ET. Reuses the standard oe-ops secrets (ssh pw, prod Discord webhook).
# Dedupes: one alert per freeze; posts a recovery when the age drops back under 90s.
# Requires bash 4+ -> run via /opt/homebrew/bin/bash. Silent no-op outside market hours.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # launchd's PATH lacks sshpass/curl/python3

OPS=/Users/abhinav/oe-ops
WEBHOOK=$(cat "$OPS/.prod-discord-webhook" 2>/dev/null || true)
PW=$(cat "$OPS/.prod-ssh-pw" 2>/dev/null)
STATE="$OPS/.spot-freshness-prod.state"       # age=<sec>\nfrozen_since=<epoch>\nalerted=<0|1>
THRESHOLD_SEC=${SPOT_FRESHNESS_THRESHOLD_SEC:-90}
DEDUPE_WINDOW_SEC=${SPOT_FRESHNESS_DEDUPE_SEC:-300}
NOW=$(date +%s)

# Market-hours gate: Mon-Fri 09:30-16:00 ET (SPX regular session). Force with
#   SPOT_FRESHNESS_FORCE=1 for local dry-runs.
read DOW HHMM <<< "$(TZ=America/New_York date '+%u %H%M')"
if [ -z "${SPOT_FRESHNESS_FORCE:-}" ]; then
  { [ "$DOW" -le 5 ] && [ "$HHMM" -ge 0930 ] && [ "$HHMM" -le 1600 ]; } || exit 0
fi

# One SSH: exec into the feed-gateway pod and grep the metric off /metrics. Falls back
# to /healthz.lastSelectedForwardAgeSeconds if /metrics is unavailable (e.g. the gateway
# hasn't wired the counter yet in an older image).
GATHER=$(sshpass -p "$PW" ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
  abhinav@192.168.100.252 'bash -s' 2>/dev/null <<'REMOTE'
NS=options-edge
pod=$(kubectl -n $NS get pods -l app.kubernetes.io/name=feed-gateway-service --no-headers 2>/dev/null \
      | awk '$3=="Running"{print $1; exit}')
[ -z "$pod" ] && { echo "err=no-pod"; exit 0; }
# Gateway HTTP port lives on the readinessProbe path/port.
port=$(kubectl -n $NS get pod "$pod" -o jsonpath='{.spec.containers[0].readinessProbe.httpGet.port}' 2>/dev/null)
echo "$port" | grep -qE '^[0-9]+$' || port=$(kubectl -n $NS get pod "$pod" \
    -o jsonpath="{.spec.containers[0].ports[?(@.name=='$port')].containerPort}" 2>/dev/null)
[ -z "$port" ] && port=8080
metrics=$(kubectl -n $NS exec "$pod" -- sh -c "curl -sf -m4 localhost:$port/metrics" 2>/dev/null)
age=$(printf '%s\n' "$metrics" | awk '/^options_edge_gateway_last_forward_age_seconds[[:space:]]/{print $2; exit}')
if [ -z "$age" ]; then
  # Fallback to /healthz JSON field.
  health=$(kubectl -n $NS exec "$pod" -- sh -c "curl -sf -m4 localhost:$port/healthz" 2>/dev/null)
  age=$(printf '%s\n' "$health" | grep -oE '"lastSelectedForwardAgeSeconds":[0-9]+' | cut -d: -f2)
fi
[ -z "$age" ] && { echo "err=no-metric"; exit 0; }
echo "age=$age"
REMOTE
)

ERR=$(printf '%s\n' "$GATHER" | sed -n 's/^err=//p')
AGE=$(printf '%s\n' "$GATHER" | sed -n 's/^age=//p')

if [ -n "$ERR" ] || [ -z "$AGE" ]; then
  # Never false-alarm on our own gather blip — skip silently.
  echo "$(date '+%FT%T') gather failed err='$ERR' — skip"
  exit 0
fi

# Load prior state.
PREV_FROZEN_SINCE=$(sed -n 's/^frozen_since=//p' "$STATE" 2>/dev/null); PREV_FROZEN_SINCE=${PREV_FROZEN_SINCE:-0}
PREV_ALERTED_AT=$(sed -n 's/^alerted_at=//p' "$STATE" 2>/dev/null); PREV_ALERTED_AT=${PREV_ALERTED_AT:-0}

post(){
  [ -z "$WEBHOOK" ] && return
  local body=$1 title=$2 color=$3 json
  json=$(BODY="$body" TITLE="$title" CL="$color" python3 -c \
    'import json,os;print(json.dumps({"username":"OptionsEdge PROD Spot Freshness","embeds":[{"title":os.environ["TITLE"],"description":os.environ["BODY"],"color":int(os.environ["CL"])}]}))')
  curl -s -m 8 -H 'Content-Type: application/json' -d "$json" "$WEBHOOK" >/dev/null 2>&1
}

FROZEN_SINCE=$PREV_FROZEN_SINCE
ALERTED_AT=$PREV_ALERTED_AT

if [ "${AGE%.*}" -ge "$THRESHOLD_SEC" ] 2>/dev/null; then
  # frozen
  [ "$FROZEN_SINCE" = "0" ] && FROZEN_SINCE=$NOW
  SINCE_ALERT=$((NOW - ALERTED_AT))
  if [ "$ALERTED_AT" = "0" ] || [ "$SINCE_ALERT" -ge "$DEDUPE_WINDOW_SEC" ]; then
    post "SPX spot has not moved for ${AGE}s during market hours (threshold ${THRESHOLD_SEC}s). Gateway may be wedged — clients see a frozen chain. Investigate feed-gateway pod / restart via jenkins-deployer." \
         "🚨 PROD SPOT FROZEN" 15158332
    ALERTED_AT=$NOW
    echo "$(date '+%FT%T') ALERT age=${AGE}s frozen_since=${FROZEN_SINCE}"
  else
    echo "$(date '+%FT%T') still frozen age=${AGE}s (dedupe ${SINCE_ALERT}s < ${DEDUPE_WINDOW_SEC}s)"
  fi
else
  # healthy
  if [ "$ALERTED_AT" != "0" ]; then
    DURATION=$((NOW - FROZEN_SINCE))
    post "SPX spot moving again (age=${AGE}s) after ~${DURATION}s freeze." \
         "✅ PROD SPOT RECOVERED" 3066993
    echo "$(date '+%FT%T') RECOVERY age=${AGE}s freeze_duration=${DURATION}s"
  else
    echo "$(date '+%FT%T') healthy age=${AGE}s"
  fi
  FROZEN_SINCE=0
  ALERTED_AT=0
fi

printf 'age=%s\nfrozen_since=%s\nalerted_at=%s\n' "$AGE" "$FROZEN_SINCE" "$ALERTED_AT" > "$STATE"
