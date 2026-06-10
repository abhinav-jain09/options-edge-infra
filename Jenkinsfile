pipeline {
  agent any
  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'production'], description: 'Target environment')
    string(name: 'REMOTE_APP_HOME', defaultValue: '/home/options-edge', description: 'Remote app home. Must stay under /home.')
    string(name: 'BECOME_PASSWORD_CREDENTIAL_ID', defaultValue: 'options-edge-remote-become-password', description: 'Jenkins secret text credential for remote su/become password')
    booleanParam(name: 'CONFIGURE_DOCKER_DATA_ROOT', defaultValue: false, description: 'Allow Docker data-root migration to /home/options-edge/data/docker. Can disrupt existing containers.')
  }
  stages {
    stage('Validate') {
      steps {
        sh 'test "$REMOTE_APP_HOME" = "/home/options-edge"'
      }
    }
    stage('Bootstrap') {
      steps {
        withCredentials([string(credentialsId: params.BECOME_PASSWORD_CREDENTIAL_ID, variable: 'ANSIBLE_BECOME_PASSWORD')]) {
          sh 'REMOTE_APP_HOME="$REMOTE_APP_HOME" CONFIGURE_DOCKER_DATA_ROOT="$CONFIGURE_DOCKER_DATA_ROOT" INVENTORY=ansible/inventory/${ENVIRONMENT}.ini scripts/bootstrap-remote.sh'
        }
      }
    }
    stage('Verify') {
      steps {
        withCredentials([string(credentialsId: params.BECOME_PASSWORD_CREDENTIAL_ID, variable: 'ANSIBLE_BECOME_PASSWORD')]) {
          sh 'INVENTORY=ansible/inventory/${ENVIRONMENT}.ini scripts/verify-remote.sh'
        }
      }
    }
  }
}
