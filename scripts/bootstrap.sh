#!/usr/bin/env bash
# bootstrap.sh — fully automated end-to-end platform setup
#
# Prerequisites: ALL Terraform modules (00 through 60) must be applied first.
#   make apply ENV=dev   OR   run terraform apply in each module in order.
#
# What this script does NOT do (OC handles it via CasC):
#   - Controller provisioning  → casc/oc-bundle/items.yaml loaded by SCM Retriever
#   - Controller CasC config   → casc/controller-bundles/ mounted via git-sync sidecar
#   - Plugin installation      → casc/oc-bundle/plugins.yaml
#   - OC JCasC config          → casc/oc-bundle/jenkins.yaml
#
# Idempotent: safe to re-run at any point (helm upgrade --install, kubectl apply).
#
# Usage: AWS_PROFILE=cbci-lab bash scripts/bootstrap.sh [ENV]
#   ENV defaults to "dev"

set -euo pipefail

ENV="${1:-dev}"

# ── Load environment config ─────────────────────────────────────────────────
ENV_FILE="environments/${ENV}/env.sh"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

CLUSTER="${CLUSTER:-cbci-lab}"
REGION="${REGION:-us-east-1}"
OC_HOSTNAME="${OC_HOSTNAME:-cjoc.myhomettbros.com}"
CBCI_CHART_VERSION="${CBCI_CHART_VERSION:-3.36486.0+0e91c42e72db}"
CBCI_NAMESPACE="${CBCI_NAMESPACE:-ci-controllers}"

echo "=========================================="
echo " CBCI on AWS — Bootstrap (ENV=${ENV})"
echo "=========================================="
echo ""

echo "=== 1. Kubeconfig ==="
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}"

echo ""
echo "=== 2. Namespaces ==="
kubectl apply -f k8s/namespaces.yaml

echo ""
echo "=== 3. Agent namespaces + RBAC + ResourceQuota ==="
# Creates/updates ci-agents-<controller> namespaces with RBAC, ResourceQuota (16 CPU /
# 64Gi / 40 pods) and LimitRange. Derives controller names from items.yaml — adding a
# new controller to items.yaml and re-running bootstrap is all that's needed.
bash "$(dirname "$0")/sync-agent-namespaces.sh"

echo ""
echo "=== 4. StorageClass (EFS) ==="
kubectl apply -f k8s/storageclass-efs.yaml

echo ""
echo "=== 5. Secrets from AWS Secrets Manager ==="
# Pull credentials from Secrets Manager — nothing is hardcoded in git or this script.
JENKINS_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id cbci-lab/jenkins-admin-password \
  --query SecretString --output text \
  --region "${REGION}" | jq -r .password)

# Jenkins admin secret — used by the OC container to set the initial admin account.
kubectl create secret generic jenkins-admin-secret \
  --from-literal=password="${JENKINS_PASSWORD}" \
  --namespace "${CBCI_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  jenkins-admin-secret created."

# casc-retriever credentials — allows the retriever sidecar to authenticate to
# the OC's internal /casc-internal/check-bundle-update endpoint so it can
# trigger hot-reloads after detecting a new commit (without an OC restart).
# Same password as the Jenkins admin account.
kubectl create secret generic casc-retriever-cbci-creds \
  --from-literal=username=admin \
  --from-literal=password="${JENKINS_PASSWORD}" \
  --namespace "${CBCI_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  casc-retriever-cbci-creds created."

# GitHub webhook HMAC secret — validates X-Hub-Signature-256 on every push event
# so only authentic GitHub requests trigger a CasC reload (prevents spoofed webhooks).
WEBHOOK_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id cbci-lab/github-webhook-secret \
  --query SecretString --output text \
  --region "${REGION}" | jq -r .secret)
kubectl create secret generic github-webhook-secret \
  --from-literal=secret="${WEBHOOK_SECRET}" \
  --namespace "${CBCI_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  github-webhook-secret created."

echo ""
echo "=== 6. CloudBees CI — Operations Center ==="
helm repo add cloudbees https://public-charts.artifacts.cloudbees.com/repository/public 2>/dev/null || true

helm upgrade --install cbci cloudbees/cloudbees-core \
  --namespace "${CBCI_NAMESPACE}" \
  --version "${CBCI_CHART_VERSION}" \
  --values helm/values-oc.yaml \
  --wait --timeout 10m

echo ""
echo "=== 7. Patch casc-retriever with Jenkins credentials ==="
# The Helm chart has no native values for retriever → Jenkins authentication.
# We inject the credentials via a strategic merge patch so the retriever can
# call /casc-internal/check-bundle-update and trigger hot-reloads on every push.
# NOTE: This patch must be re-applied after every helm upgrade (helm resets the
# StatefulSet template to what the chart generates, removing custom env vars).
kubectl patch statefulset cjoc \
  --namespace "${CBCI_NAMESPACE}" \
  --type strategic \
  --patch "$(cat <<'PATCH'
spec:
  template:
    spec:
      containers:
      - name: casc-retriever
        env:
        - name: casc_retriever_cbci_username
          valueFrom:
            secretKeyRef:
              name: casc-retriever-cbci-creds
              key: username
        - name: casc_retriever_cbci_password
          valueFrom:
            secretKeyRef:
              name: casc-retriever-cbci-creds
              key: password
PATCH
)"
echo "  casc-retriever patched with Jenkins credentials."
echo "  OC pod will restart to pick up the new env vars."

echo ""
echo "=== 8. Velero (backup) ==="
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version 12.0.0 \
  --values helm/values-velero.yaml \
  --wait --timeout 5m

echo ""
echo "=========================================="
echo " Bootstrap complete"
echo "=========================================="
echo ""
echo "  OC:      https://${OC_HOSTNAME}/cjoc/"
echo "  CITEST-1: https://${OC_HOSTNAME}/citest-1/"
echo "  CITEST2:  https://${OC_HOSTNAME}/citest2/"
echo ""
echo "  Controllers are provisioned automatically by OC from casc/oc-bundle/items.yaml"
echo "  (ocBundleAutomaticVersion: commit hash replaces version — no manual bumping needed)."
echo ""
echo "  Admin password: aws secretsmanager get-secret-value --secret-id cbci-lab/jenkins-admin-password --query SecretString --output text | jq -r .password"
echo ""
echo "NOTE: License must be activated via OC UI on a fresh PVC before controllers provision."
