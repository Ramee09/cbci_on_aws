#!/usr/bin/env bash
# bootstrap.sh — fully automated end-to-end platform setup
#
# Prerequisites: ALL Terraform modules (00 through 60) must be applied first.
#   make apply ENV=dev   OR   run terraform apply in each module in order.
#
# What this script does NOT do (OC handles it via CasC):
#   - Controller provisioning  → casc/oc-bundle/items.yaml loaded by SCM Retriever
#   - Controller CasC config   → casc/controller-bundles/ mounted via initContainer
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
echo "=== 3. StorageClass (EFS) ==="
kubectl apply -f k8s/storageclass-efs.yaml

echo ""
echo "=== 4. External Secrets Operator ==="
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --version 0.13.0 \
  --values helm/values-eso.yaml \
  --wait --timeout 5m

kubectl apply -f k8s/eso-cluster-secret-store.yaml

# All secrets created by Terraform (terraform/60-platform) — no manual seeding.
# Secrets Manager: jenkins-admin-password, grafana-admin-password, jenkins-api-token
# ESO syncs them to Kubernetes secrets automatically.
kubectl apply -f k8s/eso-external-secrets.yaml

echo "  Waiting for jenkins-admin-secret to sync..."
kubectl wait --for=condition=Ready externalsecret/jenkins-admin-password \
  -n cloudbees --timeout=120s

echo "  Waiting for casc-retriever-secrets (GitHub PAT) to sync..."
kubectl wait --for=condition=Ready externalsecret/github-casc-retriever \
  -n cloudbees --timeout=120s

echo ""
echo "=== 5. kube-prometheus-stack (monitoring) ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 83.6.0 \
  --values helm/values-monitoring.yaml \
  --wait --timeout 10m

echo ""
echo "=== 6. Fluent Bit (CloudWatch log shipping) ==="
helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  --version 0.57.3 \
  --values helm/values-fluent-bit.yaml \
  --wait --timeout 5m

echo ""
echo "=== 7. CloudBees CI — Operations Center ==="
helm repo add cloudbees https://public-charts.artifacts.cloudbees.com/repository/public 2>/dev/null || true

# RBAC for GitHub Actions
kubectl apply -f k8s/rbac-github-actions.yaml

# OC startup sequence:
#   1. SCM Retriever init container — fetches casc/oc-bundle/ from GitHub
#   2. seed-controller-bundles init container — sparse-clones repo, copies
#      casc/controller-bundles/ into $JENKINS_HOME/casc-server-bundles/ (OC EFS)
#   3. clear-casc-cache init container — removes stale OC bundle cache
#   4. OC starts, loads bundle (plugins, jenkins.yaml, items.yaml)
#   5. items.yaml provisions devflow + test1 controllers with bundle assignments
#   6. casc-client on each controller pulls its bundle from OC via HTTPS

helm upgrade --install cbci cloudbees/cloudbees-core \
  --namespace cloudbees \
  --version "${CBCI_CHART_VERSION}" \
  --values helm/values-oc.yaml \
  --wait --timeout 10m

# OC will now: fetch the bundle from GitHub (SCM Retriever init container),
# load plugins.yaml + jenkins.yaml + items.yaml, and provision controllers.
# Monitor: kubectl logs -n cloudbees cjoc-0 -f

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
echo "  devflow: https://${OC_HOSTNAME}/devflow/"
echo "  test1:   https://${OC_HOSTNAME}/test1/"
echo ""
echo "  Controllers are provisioned automatically by OC from casc/oc-bundle/items.yaml"
echo "  (SCM Retriever fetches from GitHub on startup, polls every 3 minutes)."
echo ""
echo "  Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring"
echo ""
echo "  Admin credentials: kubectl get secret jenkins-admin-secret -n cloudbees -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "NOTE: Secrets Manager secrets are managed by terraform/60-platform."
echo "      Run 'terraform apply' there before bootstrap if this is a fresh environment."
