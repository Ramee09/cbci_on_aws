// standardPipeline — opinionated wrapper used by all controllers.
// Usage:
//   @Library('cbci-shared') _
//   standardPipeline(
//     agentLabel: 'default-agent',
//     stages: { ... }   // closure containing your stage blocks
//   )
def call(Map config = [:], Closure stages) {
    def agentLabel = config.get('agentLabel', 'default-agent')

    pipeline {
        agent { label agentLabel }

        options {
            timestamps()
            timeout(time: 60, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '20'))
            disableConcurrentBuilds()
        }

        post {
            always  { notify(status: currentBuild.currentResult) }
            failure { notify(status: 'FAILURE') }
        }

        stages {
            stage('Pipeline') {
                steps {
                    script { stages() }
                }
            }
        }
    }
}
