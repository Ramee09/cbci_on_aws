package com.cbcilab

class PipelineUtils implements Serializable {

    static String gitSha(script) {
        return script.sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
    }

    static String imageTag(script, String prefix = '') {
        def sha   = gitSha(script)
        def stamp = new Date().format('yyyyMMdd-HHmm')
        return prefix ? "${prefix}-${stamp}-${sha}" : "${stamp}-${sha}"
    }

    static void ecrPush(script, String repo, String tag) {
        script.sh "docker tag ${repo}:${tag} ${repo}:latest"
        script.sh "docker push ${repo}:${tag}"
        script.sh "docker push ${repo}:latest"
    }
}
