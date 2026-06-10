#!/usr/bin/env bash
set -euo pipefail
inventory="${INVENTORY:-ansible/inventory/dev.ini}"
extra_args=()
if [[ -n "${ANSIBLE_BECOME_PASSWORD:-}" ]]; then
  extra_args+=(--extra-vars "ansible_become_password=${ANSIBLE_BECOME_PASSWORD}")
fi
ansible-playbook -i "$inventory" ansible/playbooks/verify.yml "${extra_args[@]}"
