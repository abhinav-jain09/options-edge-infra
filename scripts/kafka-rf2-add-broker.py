#!/usr/bin/env python3
"""Generate a kafka-reassign-partitions JSON that raises replication factor to 2
by adding a target broker as an extra replica on every partition of the given
topics. Existing replica/leader order is preserved (current leader stays first),
so leadership does not move; broker N just becomes a follower that replicates a
copy onto the second physical machine.

Usage:
  BOOTSTRAP=192.168.100.252:9092 KAFKA_BIN=/opt/kafka/current/bin ADD_BROKER=4 \
    kafka-rf2-add-broker.py [topic ...]

With no topic args, all non-internal topics are included. Pass __consumer_offsets
/ __transaction_state explicitly to include the internal topics.
Prints the reassignment JSON to stdout.
"""
import json
import os
import re
import subprocess
import sys

BOOTSTRAP = os.environ.get("BOOTSTRAP", "192.168.100.252:9092")
KAFKA_BIN = os.environ.get("KAFKA_BIN", "/opt/kafka/current/bin")
ADD = int(os.environ.get("ADD_BROKER", "4"))
TOPICS_TOOL = os.path.join(KAFKA_BIN, "kafka-topics.sh")


def run(args):
    res = subprocess.run(args, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        res.check_returncode()
    return res.stdout


def list_topics():
    out = run([TOPICS_TOOL, "--bootstrap-server", BOOTSTRAP, "--list"])
    return [t for t in out.split() if t and not t.startswith("__")]


def describe(topic):
    return run([TOPICS_TOOL, "--bootstrap-server", BOOTSTRAP, "--describe", "--topic", topic])


def main():
    topics = sys.argv[1:] or list_topics()
    partitions = []
    for topic in topics:
        for line in describe(topic).splitlines():
            if "Partition:" not in line:
                continue
            m_t = re.search(r"Topic:\s*(\S+)", line)
            m_p = re.search(r"Partition:\s*(\d+)", line)
            m_r = re.search(r"Replicas:\s*([\d,]+)", line)
            if not (m_t and m_p and m_r):
                continue
            replicas = [int(x) for x in m_r.group(1).split(",")]
            if ADD not in replicas:
                replicas = replicas + [ADD]
            partitions.append(
                {"topic": m_t.group(1), "partition": int(m_p.group(1)), "replicas": replicas}
            )
    json.dump({"version": 1, "partitions": partitions}, sys.stdout)


if __name__ == "__main__":
    main()
