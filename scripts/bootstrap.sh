#!/usr/bin/env bash
# bootstrap.sh — fully automated end-to-end platform setup
#
# Prerequisites: ALL Terraform modules (00 through 60) must be applied first.
#   make apply ENV=dev   OR   run terraform apply in each module in order.
#
# Zero manual steps: everything is code. No Script Console, no UI clicking,
# no manual kubectl exec required.
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
echo "=== 7. Controller CasC bundle ConfigMaps ==="
# These ConfigMaps are created BEFORE OC starts so they exist when OC provisions
# controllers. The OC items.yaml (via KubernetesMasterProvisioning yaml: patch)
# mounts each controller's ConfigMap via initContainer — no manual kubectl exec.
for CTRL in devflow test1; do
  kubectl create configmap "${CTRL}-casc-bundle" \
    --from-file=casc/controller-bundles/"${CTRL}"/ \
    --namespace cloudbees \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  ${CTRL}-casc-bundle ConfigMap applied."
done

echo ""
echo "=== 8. CloudBees CI — Operations Center ==="
helm repo add cloudbees https://public-charts.artifacts.cloudbees.com/repository/public 2>/dev/null || true

# RBAC for GitHub Actions casc-bundle-updater role
kubectl apply -f k8s/rbac-github-actions.yaml

# OC CasC bundle ConfigMap — includes items.yaml so OC provisions controllers on startup.
# apiVersion: 2 in bundle.yaml ensures items are processed after plugins initialize
# (avoids CasCInvalidKindException that occurs with apiVersion: 1).
kubectl create configmap oc-casc-bundle \
  --from-file=casc/oc-bundle/bundle.yaml \
  --from-file=casc/oc-bundle/jenkins.yaml \
  --from-file=casc/oc-bundle/plugins.yaml \
  --from-file=casc/oc-bundle/items.yaml \
  --namespace cloudbees \
  --dry-run=client -o yaml | kubectl apply -f -

# Repair EFS bundle cache if OC is in CrashLoopBackOff from a previous bad apply.
# CBCI caches the active bundle to EFS at /var/jenkins_home/core-casc-bundle/; a
# bad ConfigMap applied previously can leave a stale file that causes crash-loops.
OC_STATUS=$(kubectl get pod cjoc-0 -n cloudbees --no-headers 2>/dev/null | awk '{print $3}')
if [[ "${OC_STATUS}" == "CrashLoopBackOff" || "${OC_STATUS}" == "Error" ]]; then
  echo "  OC is in ${OC_STATUS} — repairing EFS bundle cache before helm upgrade..."
  bash scripts/repair-oc-efs-bundle.sh
fi

helm upgrade --install cbci cloudbees/cloudbees-core \
  --namespace cloudbees \
  --version "${CBCI_CHART_VERSION}" \
  --values helm/values-oc.yaml \
  --wait --timeout 10m

echo ""
echo "=== 8b. CI automation API token (one-time, idempotent) ==="
# Injects the API token from Secrets Manager into admin's config.xml on EFS.
# Required for any future API-based automation. Survives pod restarts (lives on EFS).
bash scripts/setup-api-token.sh

# Controllers are provisioned by the Groovy init script in ExtraGroovyConfiguration
# (helm/values-oc.yaml). That script runs during OC startup as part of the
# configure-jenkins.groovy.d/ phase — no REST API, no post-startup step required.

echo ""
echo "=== 9. Velero (backup) ==="
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
echo "  Controllers are provisioned by OC from casc/oc-bundle/items.yaml."
echo "  CasC bundles are mounted from ConfigMaps (devflow-casc-bundle, test1-casc-bundle)."
echo ""
echo "  Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring"
echo ""
echo "  Admin credentials: kubectl get secret jenkins-admin-secret -n cloudbees -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "NOTE: ExternalDNS and Secrets Manager secrets are managed by terraform/60-platform."
echo "      Run 'terraform apply' there before bootstrap if this is a fresh environment."
