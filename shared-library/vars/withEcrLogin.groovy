// withEcrLogin(region: 'us-east-1', accountId: '...') { ... }
// Authenticates Docker to ECR then executes the body block.
def call(Map config = [:], Closure body) {
    def region    = config.get('region',    env.AWS_REGION ?: 'us-east-1')
    def accountId = config.get('accountId', env.AWS_ACCOUNT_ID)

    sh """
        aws ecr get-login-password --region ${region} | \
        docker login --username AWS --password-stdin \
          ${accountId}.dkr.ecr.${region}.amazonaws.com
    """
    try {
        body()
    } finally {
        sh "docker logout ${accountId}.dkr.ecr.${region}.amazonaws.com || true"
    }
}
