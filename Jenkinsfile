pipeline {
  agent any
  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'production'], description: 'Target environment')
    string(name: 'REMOTE_APP_HOME', defaultValue: '/home/options-edge', description: 'Remote app home. Must stay under /home.')
    string(name: 'BECOME_PASSWORD_CREDENTIAL_ID', defaultValue: 'options-edge-remote-become-password', description: 'Jenkins secret text credential for remote su/become password')
    booleanParam(name: 'CONFIGURE_DOCKER_DATA_ROOT', defaultValue: false, description: 'Allow Docker data-root migration to /home/options-edge/data/docker. Can disrupt existing containers.')
  }
  stages {
    stage('Prepare Ansible') {
      steps {
        sh '''
          set -euo pipefail
          python3 -m venv "$WORKSPACE/.venv"
          "$WORKSPACE/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
          "$WORKSPACE/.venv/bin/python" -m pip install -r requirements.txt
          "$WORKSPACE/.venv/bin/ansible-playbook" --version
        '''
      }
    }
    stage('Validate') {
      steps {
        sh '''
          set -euo pipefail
          REMOTE_APP_HOME="${REMOTE_APP_HOME:-/home/options-edge}"
          test "$REMOTE_APP_HOME" = "/home/options-edge"
        '''
      }
    }
    stage('Bootstrap') {
      steps {
        withCredentials([string(credentialsId: params.BECOME_PASSWORD_CREDENTIAL_ID, variable: 'ANSIBLE_BECOME_PASSWORD')]) {
          sh '''
            set -euo pipefail
            export PATH="$WORKSPACE/.venv/bin:$PATH"
            ENVIRONMENT="${ENVIRONMENT:-dev}"
            REMOTE_APP_HOME="${REMOTE_APP_HOME:-/home/options-edge}" CONFIGURE_DOCKER_DATA_ROOT="${CONFIGURE_DOCKER_DATA_ROOT:-false}" INVENTORY="ansible/inventory/${ENVIRONMENT}.ini" scripts/bootstrap-remote.sh
          '''
        }
      }
    }
    stage('Verify') {
      steps {
        withCredentials([string(credentialsId: params.BECOME_PASSWORD_CREDENTIAL_ID, variable: 'ANSIBLE_BECOME_PASSWORD')]) {
          sh '''
            set -euo pipefail
            export PATH="$WORKSPACE/.venv/bin:$PATH"
            ENVIRONMENT="${ENVIRONMENT:-dev}"
            INVENTORY="ansible/inventory/${ENVIRONMENT}.ini" scripts/verify-remote.sh
          '''
        }
      }
    }
  }
}
