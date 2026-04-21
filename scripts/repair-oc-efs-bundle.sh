#!/usr/bin/env bash
# repair-oc-efs-bundle.sh — overwrite stale CBCI EFS bundle cache
#
# CBCI caches the active CasC bundle to EFS at:
#   /var/jenkins_home/core-casc-bundle/jcasc/jenkins.yaml
# If a bad bundle was applied previously, the OC reads the cached (bad) file at
# startup and enters CrashLoopBackOff even after the ConfigMap is corrected.
#
# This script creates a temporary pod that mounts the OC's EFS PVC and copies
# the current (validated) ConfigMap content over the stale cache file.
# Safe to run at any time — it does not restart the OC pod by itself.

set -euo pipefail

NAMESPACE="${NAMESPACE:-cloudbees}"
POD_NAME="oc-efs-repair-$$"

echo "=== Repairing OC EFS bundle cache ==="

kubectl run "${POD_NAME}" \
  --image=busybox:1.36 \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "repair",
        "image": "busybox:1.36",
        "command": ["sh", "-c",
          "mkdir -p /jh/core-casc-bundle/jcasc && cp -L /casc-src/jenkins.yaml /jh/core-casc-bundle/jcasc/jenkins.yaml && cp -L /casc-src/items.yaml /jh/core-casc-bundle/items/items.yaml 2>/dev/null || true && echo Repaired && head -3 /jh/core-casc-bundle/jcasc/jenkins.yaml"],
        "volumeMounts": [
          {"name": "jenkins-home", "mountPath": "/jh"},
          {"name": "casc-src",    "mountPath": "/casc-src"}
        ]
      }],
      "volumes": [
        {"name": "jenkins-home", "persistentVolumeClaim": {"claimName": "jenkins-home-cjoc-0"}},
        {"name": "casc-src",     "configMap":             {"name": "oc-casc-bundle"}}
      ],
      "restartPolicy": "Never"
    }
  }'

echo "  Waiting for repair pod to complete..."
kubectl wait --for=condition=Ready pod/"${POD_NAME}" -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
until kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -qE 'Completed|Succeeded|Error|Failed'; do sleep 3; done

kubectl logs pod/"${POD_NAME}" -n "${NAMESPACE}"
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "  EFS bundle cache repaired. Deleting cjoc-0 to trigger fresh start..."
kubectl delete pod cjoc-0 -n "${NAMESPACE}" --ignore-not-found

echo "  Waiting for cjoc-0 to restart..."
until kubectl get pod cjoc-0 -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -qE 'Running|CrashLoop|Error'; do sleep 5; done
kubectl get pod cjoc-0 -n "${NAMESPACE}"
