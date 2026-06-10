pipeline {
  agent any
  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'production'], description: 'Target environment')
    string(name: 'REMOTE_APP_HOME', defaultValue: '/home/options-edge', description: 'Remote app home. Must stay under /home.')
  }
  stages {
    stage('Validate') {
      steps {
        sh 'test "$REMOTE_APP_HOME" = "/home/options-edge"'
      }
    }
    stage('Bootstrap') {
      steps { sh 'REMOTE_APP_HOME="$REMOTE_APP_HOME" INVENTORY=ansible/inventory/${ENVIRONMENT}.ini scripts/bootstrap-remote.sh' }
    }
    stage('Verify') {
      steps { sh 'INVENTORY=ansible/inventory/${ENVIRONMENT}.ini scripts/verify-remote.sh' }
    }
  }
}
