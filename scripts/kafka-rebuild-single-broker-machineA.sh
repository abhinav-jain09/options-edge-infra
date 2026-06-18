#!/bin/bash
# Machine A (252): reduce to a single broker (broker 1 = broker+controller, rack A),
# wipe Kafka data, reformat clean. Run as root.
set -e
CID="of8tXNCLQouXqwkpADBPyg"
CFG=/opt/kafka/current/config
KB=/opt/kafka/current/bin
f="$CFG/server.properties"

echo "== stop all brokers on A =="
systemctl stop kafka kafka-broker-2 kafka-broker-3 || true

echo "== disable + mask extra brokers 2,3 =="
systemctl disable kafka-broker-2 kafka-broker-3 || true
systemctl mask kafka-broker-2 kafka-broker-3 || true

echo "== set broker.rack=A and RF defaults on broker 1 =="
set_kv() { local k="$1" v="$2"; if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >> "$f"; fi; }
set_kv broker.rack A
set_kv default.replication.factor 2
set_kv offsets.topic.replication.factor 2
set_kv transaction.state.log.replication.factor 2
set_kv transaction.state.log.min.isr 1
set_kv min.insync.replicas 1

echo "== wipe data dirs =="
rm -rf /home/kafka/kraft-combined-logs /home/kafka/kraft-broker-2-logs /home/kafka/kraft-broker-3-logs
mkdir -p /home/kafka/kraft-combined-logs
chown kafka:kafka /home/kafka/kraft-combined-logs

echo "== format broker 1 (cluster $CID) =="
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
runuser -u kafka -- "$KB/kafka-storage.sh" format -t "$CID" -c "$f" --ignore-formatted

echo "== start broker 1 =="
systemctl start kafka
sleep 4
echo "broker1 active=$(systemctl is-active kafka)"
echo "rack line: $(grep '^broker.rack=' "$f")"
echo "REBUILD_A_DONE"
