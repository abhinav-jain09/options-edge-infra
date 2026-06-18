# OptionsEdge Infra

Infrastructure bootstrap for the OptionsEdge remote server.

Owns:
- `/home/options-edge` directory layout
- Docker installation with data-root under `/home/options-edge/data/docker`
- k3s/Kubernetes installation with data dir under `/home/options-edge/data/k3s`
- kubectl and Helm installation
- base observability installation

Application deployment belongs in `options-edge-deploy`, not this repo.

## Remote Target

Default dev inventory:

```text
abhinav@192.168.100.252
```

The remote host currently escalates with `su`, not `sudo`. The become password must be stored in Jenkins as a Secret Text credential. Do not commit passwords to this repo.

Default Jenkins credential id:

```text
options-edge-remote-become-password
```

## Safety Rule

The bootstrap job refuses to change Docker data-root on an existing Docker host unless `CONFIGURE_DOCKER_DATA_ROOT=true` is explicitly selected.

Changing Docker data-root can make existing containers/images appear missing because Docker starts using a new storage directory.

## Two-node Kafka/k3s failover — node B (Phase 0)

Provisions the failover node B (`192.168.100.56`) for the two-node HA build-out:

- Installs Apache Kafka (KRaft) **broker 4**, joined to the existing cluster
  `of8tXNCLQouXqwkpADBPyg` but **staged, not started** (the controller on node 1
  is still bound to `localhost` and unreachable until Phase 1).
- Joins node B to the existing k3s cluster as a **tainted failover worker**
  (`oe-role=failover:NoSchedule`), with insecure-registry access to
  `192.168.100.252:5000`.

This is additive and safe: nothing schedules onto the tainted worker and the
staged broker does not start, so the running primary cluster is untouched.

```bash
# Fresh join needs the k3s token from the control-plane host:
#   su -c 'cat /home/options-edge/data/k3s/server/token'   (run on 192.168.100.252)
SSH_PASSWORD=... K3S_AGENT_TOKEN=... ./scripts/provision-failover.sh

# Re-run / converge (token not needed once the node has joined):
SSH_PASSWORD=... ./scripts/provision-failover.sh

# Verify Phase 0 expectations:
INVENTORY=ansible/inventory/failover.ini \
  PLAYBOOK=ansible/playbooks/verify-failover.yml \
  SSH_PASSWORD=... ./scripts/provision-failover.sh
```

Node B uses `become_method=sudo` (the `abhinav` user has NOPASSWD sudo there),
overriding the `su` default used for the primary host. Lifecycle flags
(`kafka_broker_started`, `kafka_format_storage`) stay `false` for Phase 0 and are
flipped in Phase 2 once the controller is reachable on the network.
