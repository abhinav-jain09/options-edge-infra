#!/usr/bin/env bash
set -euo pipefail
ansible-playbook -i "${INVENTORY:-ansible/inventory/dev.ini}" ansible/playbooks/verify.yml
