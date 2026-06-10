#!/usr/bin/env bash
set -euo pipefail
: "${REMOTE_APP_HOME:=/home/options-edge}"
if [[ "$REMOTE_APP_HOME" != "/home/options-edge" ]]; then
  echo "REMOTE_APP_HOME must be /home/options-edge" >&2
  exit 1
fi
ansible-playbook -i "${INVENTORY:-ansible/inventory/dev.ini}" ansible/playbooks/bootstrap.yml
