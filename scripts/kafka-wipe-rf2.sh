#!/usr/bin/env bash
# Empty all high-volume (delete-policy) topics via delete-records, then raise EVERY
# topic to RF=2 by adding a target broker as a replica. Designed for a 2-node
# cluster where a full RF=2 backfill of historical data is infeasible over the link:
# emptying first means the new replica copies ~nothing.
#
# Compacted topics (cleanup.policy contains "compact") are NOT delete-records'd
# (unsupported); they are small and get replicated as-is by the reassignment.
#
# Env:
#   BOOTSTRAP (default 192.168.100.252:9092), KAFKA_BIN, ADD_BROKER (default 4),
#   RF (default 2), DRY_RUN (default true), BACKUP_DIR
set -euo pipefail
BOOTSTRAP="${BOOTSTRAP:-192.168.100.252:9092}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/current/bin}"
ADD="${ADD_BROKER:-4}"
RF="${RF:-2}"
DRY_RUN="${DRY_RUN:-true}"
BK="${BACKUP_DIR:-/home/options-edge/backups/kafka-wipe-$(date +%Y%m%d-%H%M%S)}"
T="$KAFKA_BIN/kafka-topics.sh"
RP="$KAFKA_BIN/kafka-reassign-partitions.sh"
DR="$KAFKA_BIN/kafka-delete-records.sh"
mkdir -p "$BK"

echo "== backup current topic state -> $BK =="
"$T" --bootstrap-server "$BOOTSTRAP" --describe > "$BK/describe-before.txt"
mapfile -t ALL < <("$T" --bootstrap-server "$BOOTSTRAP" --list)
echo "topics total: ${#ALL[@]}"

# Build delete-records JSON for non-internal, non-compacted topics.
del_json="$BK/delete-records.json"
reassign_json="$BK/reassign-rf2.json"
python3 - "$BOOTSTRAP" "$KAFKA_BIN" "$ADD" "$RF" "$del_json" "$reassign_json" <<'PY'
import json, re, subprocess, sys
bootstrap, kbin, add, rf, del_path, re_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
T = f"{kbin}/kafka-topics.sh"
def run(a): return subprocess.run(a, capture_output=True, text=True, check=True).stdout
desc = run([T,"--bootstrap-server",bootstrap,"--describe"])
topics = {}
for line in desc.splitlines():
    m = re.match(r"Topic:\s*(\S+)\s+TopicId.*PartitionCount:\s*(\d+).*Configs:\s*(.*)$", line)
    if m:
        topics[m.group(1)] = {"parts": int(m.group(2)), "configs": m.group(3), "partitions": {}}
        continue
    m = re.search(r"Topic:\s*(\S+)\s+Partition:\s*(\d+)\s+Leader:\s*(\S+)\s+Replicas:\s*([\d,]+)", line)
    if m and m.group(1) in topics:
        topics[m.group(1)]["partitions"][int(m.group(2))] = [int(x) for x in m.group(4).split(",")]
del_parts, re_parts = [], []
for t, info in topics.items():
    compacted = "cleanup.policy=compact" in info["configs"]
    internal = t.startswith("__")
    for p, reps in info["partitions"].items():
        if not internal and not compacted:
            del_parts.append({"topic": t, "partition": p, "offset": -1})
        new = reps + [add] if add not in reps else reps
        re_parts.append({"topic": t, "partition": p, "replicas": new})
json.dump({"partitions": del_parts, "version": 1}, open(del_path, "w"))
json.dump({"version": 1, "partitions": re_parts}, open(re_path, "w"))
print(f"delete-records partitions: {len(del_parts)}  |  reassign partitions: {len(re_parts)}")
PY

echo "== plan =="
echo "delete-records json: $del_json"
echo "reassign json: $reassign_json"
if [ "$DRY_RUN" = "true" ]; then
  echo "DRY_RUN=true -> not executing. Review the JSON files above."
  exit 0
fi

echo "== emptying delete-policy topics (delete-records) =="
"$DR" --bootstrap-server "$BOOTSTRAP" --offset-json-file "$del_json"

echo "== executing RF=$RF reassignment =="
"$RP" --bootstrap-server "$BOOTSTRAP" --reassignment-json-file "$reassign_json" --execute

echo "== waiting for reassignment to complete =="
for i in $(seq 1 480); do
  out="$("$RP" --bootstrap-server "$BOOTSTRAP" --reassignment-json-file "$reassign_json" --verify 2>/dev/null || true)"
  if ! grep -q "is still in progress" <<<"$out"; then echo "$out" | grep -v Throttle | tail -5; echo "DONE"; break; fi
  sleep 10
done
