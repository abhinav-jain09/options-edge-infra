# Two-Node Kafka Failover Runbook

Operational guide for the two-node OptionsEdge cluster.

## Topology (what lives where)

| | Machine A — `192.168.100.252` | Machine B — `192.168.100.56` |
|---|---|---|
| Kafka | **broker 1** (broker + **KRaft controller**), `rack=A` | **broker 4** (broker only), `rack=B` |
| Kubernetes | k3s **control-plane** (API + etcd) | k3s worker (tainted `oe-role=failover`) |
| Postgres | primary DB (`:5432`) | — |
| App pods | all `options-edge` deployments | — |

- Replication: every partition is `Replicas=[1,4]` → **one copy per machine**. `min.insync.replicas=1`.
- **Machine A is the everything-node**: it holds the only Kafka controller, the only k8s control-plane, Postgres, and all app pods.

## The one fact that drives this runbook

On two nodes there is no controller majority, so **the cluster cannot self-heal the loss of Machine A**. Plan accordingly:

- **Machine B down → non-event.** Data stays available (leaders are on A); you just lose the second copy until B returns.
- **Machine A down → full outage.** Data is safe (copies on B) but nothing serves until A is restored. Recovery is **restore Machine A**, not "fail over to B" — because B has neither a controller nor the k8s control-plane nor Postgres.
- Eliminating this entirely requires a **third node** (RF=3, 3 controllers). Until then, this is best-effort data durability + manual recovery.

---

## 0. Health check (run first, any incident)

From any host with the Kafka CLI (or on A):

```bash
JH=$(dirname $(dirname $(readlink -f $(command -v java)))); export JAVA_HOME=$JH
B=/opt/kafka/current/bin; BS=192.168.100.252:9092

# brokers up + which machine + rack
$B/kafka-broker-api-versions.sh --bootstrap-server $BS 2>/dev/null | grep -E 'id: [0-9]' | sed 's/ -> .*//'
# controller / quorum
$B/kafka-metadata-quorum.sh --bootstrap-server $BS describe --status | grep -E 'LeaderId|CurrentVoters|CurrentObservers'
# any partition missing a copy
$B/kafka-topics.sh --bootstrap-server $BS --describe --under-replicated-partitions
```

Healthy = both brokers listed (1 on .252, 4 on .56), `LeaderId: 1`, zero under-replicated partitions.

App/cluster health (on A): `sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n options-edge get pods`

Service control on A goes through the sanctioned wrapper:
`sudo /usr/local/sbin/options-edge-system-control <status|logs|start|stop|restart> kafka-broker-1`

---

## 1. Machine B (`192.168.100.56`) is down  — severity: LOW

**Symptoms:** broker 4 missing from broker list; under-replicated partitions > 0; `CurrentObservers` no longer lists id 4. Producers/consumers keep working (leaders on broker 1, `minISR=1`). Status = **DEGRADED (no redundancy)**.

**Do:** nothing urgent to the pipeline. Restore B:

```bash
ssh abhinav@192.168.100.56
sudo systemctl start kafka-broker-4          # if only the broker died
# or power the machine back on if the host is down
```

Broker 4 rejoins and re-syncs automatically. Confirm recovery with the health check — under-replicated partitions returns to 0 and ISR returns to `[1,4]`.

If broker 4 won't start, check `sudo journalctl -u kafka-broker-4 -n 50`. If its data dir is corrupt (disposable data), wipe + reformat + start:

```bash
sudo systemctl stop kafka-broker-4
sudo rm -rf /home/kafka/kraft-broker-4-logs && sudo mkdir -p /home/kafka/kraft-broker-4-logs && sudo chown kafka:kafka /home/kafka/kraft-broker-4-logs
sudo -u kafka /opt/kafka/current/bin/kafka-storage.sh format -t of8tXNCLQouXqwkpADBPyg -c /opt/kafka/current/config/server-4.properties --ignore-formatted
sudo systemctl start kafka-broker-4
```

---

## 2. Machine A (`192.168.100.252`) is down — severity: CRITICAL (full outage)

**Symptoms:** Kafka unreachable on `:9092`; `kafka-metadata-quorum` times out (no controller); app pods gone; Postgres unreachable. Data is NOT lost (copies on broker 4) but nothing serves.

**Primary action — RESTORE MACHINE A.** It holds the controller, k8s control-plane, Postgres, and the apps. This is the fastest, safest recovery.

1. Power Machine A back on / bring the host up.
2. Services auto-start (systemd `enabled`): broker 1, k3s, Postgres. Verify:
   ```bash
   ssh abhinav@192.168.100.252
   sudo /usr/local/sbin/options-edge-system-control status kafka-broker-1
   systemctl is-active k3s postgresql
   ```
3. Run the **health check** (section 0). Controller returns as `LeaderId: 1`; broker 4 re-syncs; pods reschedule onto A.
4. If broker 1 is slow, it is recovering its log — give it time (watch `... logs kafka-broker-1`).

**If Machine A is unrecoverable (dead hardware, long outage):** there is no clean automatic promotion of B on two nodes.
- Kafka data on B is a temporary stream; the durable record (signals/audit) is in **Postgres, which was on A** — so promoting B for Kafka alone has limited value without restoring A (Postgres + apps + k8s).
- Emergency Kafka-only promotion of broker 4 to a standalone controller is an **advanced, last-resort** operation (reconfigure `process.roles=broker,controller`, new single-voter quorum on node 4, unclean metadata recovery) and risks **split-brain** if A later returns. Do **not** attempt during market hours without accepting data divergence. The supported answer is: restore A, or stand up a replacement A from the Ansible (`provision-*` playbooks + restore Postgres backup) and let B re-sync.

> This gap is exactly what a **third node** removes. Strongly recommended if A-failure tolerance matters.

---

## 3. Planned maintenance / graceful broker restart

**Restart broker 4 (B):** zero impact — leaders are on A.
```bash
ssh abhinav@192.168.100.56 'sudo systemctl restart kafka-broker-4'
```

**Restart broker 1 (A) — the controller:** brief (~10–30s) metadata stall; `minISR=1` keeps producers from hard-failing, consumers reconnect.
```bash
ssh abhinav@192.168.100.252
sudo /usr/local/sbin/options-edge-system-control restart kafka-broker-1
```
Then health-check. Avoid during market hours if possible.

> Note: brokers 2 and 3 on A are legacy and masked — do not start them.

---

## 4. Failback (after Machine B recovers)

No action needed. When B returns, broker 4 rejoins and re-syncs; ISR returns to `[1,4]`; under-replicated count returns to 0. There is no leadership to move back (leaders stay on broker 1 by design).

---

## 5. Acceptance tests

| Test | Procedure | Pass criteria |
|---|---|---|
| Normal operation | Health check | both brokers up, `LeaderId: 1`, 0 under-replicated |
| Broker-4 restart | `systemctl restart kafka-broker-4` on B | rejoins, 0 under-replicated within minutes; no producer errors |
| Machine B failure | power off B | pipeline keeps running (DEGRADED); under-replicated > 0 |
| Machine B recovery | power on B | auto re-sync to `[1,4]`, 0 under-replicated |
| Broker-1 restart | wrapper `restart kafka-broker-1` | brief stall, recovers; pods reconnect; 0 under-replicated after B catches up |
| Machine A failure | power off A | **full outage as expected**; on restore, cluster + pods recover, no data loss |

## 6. Known limitations

- No automatic failover for Machine A loss (single controller + single k8s control-plane). Needs a 3rd node.
- 5 stream apps recreate internal topics at RF=1 unless `KAFKA_TOPIC_REPLICATION_FACTOR=2` is deployed (options-edge-deploy). Re-check under-replicated/RF after any app redeploy.
- `min.insync.replicas=1` favors availability over zero-loss: a crash can lose the unreplicated tail of in-flight writes. This is the deliberate 2-node trade-off.
