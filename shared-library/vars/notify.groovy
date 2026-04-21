// notify(status: 'SUCCESS'|'FAILURE'|'UNSTABLE', message: '...')
// Sends a build notification. Extend with Slack/SNS as needed.
def call(Map config = [:]) {
    def status  = config.get('status',  currentBuild.currentResult)
    def message = config.get('message', "${env.JOB_NAME} #${env.BUILD_NUMBER}: ${status}")
    def color   = status == 'SUCCESS' ? 'good' : (status == 'FAILURE' ? 'danger' : 'warning')

    echo "[notify] ${color.toUpperCase()} — ${message}"

    // Extend here: slackSend, mail, SNS publish, etc.
}
