#!/usr/bin/env bash
# Provision the OptionsEdge failover node B (Phase 0: Kafka broker staged + k3s worker joined).
#
# Env:
#   SSH_PASSWORD        SSH password for ansible_user (or use an SSH key instead)
#   K3S_AGENT_TOKEN     k3s join token; required ONLY for a fresh join.
#                       Fetch on the control-plane host:
#                         su -c 'cat /home/options-edge/data/k3s/server/token'
set -euo pipefail
cd "$(dirname "$0")/.."

inventory="${INVENTORY:-ansible/inventory/failover.ini}"
playbook="${PLAYBOOK:-ansible/playbooks/provision-failover.yml}"
extra_args=()

[[ -n "${SSH_PASSWORD:-}" ]] && extra_args+=(--extra-vars "ansible_password=${SSH_PASSWORD}")
[[ -n "${K3S_AGENT_TOKEN:-}" ]] && extra_args+=(--extra-vars "k3s_agent_token=${K3S_AGENT_TOKEN}")

ansible-playbook -i "$inventory" "$playbook" "${extra_args[@]}" "$@"
