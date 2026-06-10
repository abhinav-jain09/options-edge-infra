#!/usr/bin/env bash
set -euo pipefail
: "${REMOTE_APP_HOME:=/home/options-edge}"
if [[ "$REMOTE_APP_HOME" != "/home/options-edge" ]]; then
  echo "REMOTE_APP_HOME must be /home/options-edge" >&2
  exit 1
fi
inventory="${INVENTORY:-ansible/inventory/dev.ini}"
extra_args=(--extra-vars "docker_configure_data_root=${CONFIGURE_DOCKER_DATA_ROOT:-false}")
if [[ -n "${ANSIBLE_BECOME_PASSWORD:-}" ]]; then
  extra_args+=(--extra-vars "ansible_become_password=${ANSIBLE_BECOME_PASSWORD}")
fi
ansible-playbook -i "$inventory" ansible/playbooks/bootstrap.yml "${extra_args[@]}"
