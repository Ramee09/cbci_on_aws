#!/usr/bin/env bash
# install-backup.sh — Deploy backup infrastructure for CBCI on AWS
# Idempotent: safe to re-run.
# Prerequisites: terraform/55-backup applied, kubeconfig set for cbci-lab.
set -euo pipefail

ACCOUNT_ID="835090871306"
REGION="us-east-1"
CLUSTER="cbci-lab"
VELERO_NS="velero"
VELERO_VERSION="8.1.0"
CHART_VERSION="8.1.0"

echo "================================================================"
echo " CBCI Backup Installation"
echo " Cluster: ${CLUSTER} | Region: ${REGION}"
echo "================================================================"

# ── 1. Verify kubeconfig ─────────────────────────────────────────────
echo ""
echo "[1/5] Verifying kubeconfig..."
kubectl cluster-info --request-timeout=10s > /dev/null
echo "  OK: connected to cluster"

# ── 2. Apply Terraform for backup infrastructure ─────────────────────
echo ""
echo "[2/5] Applying terraform/55-backup (S3 bucket, IAM role, AWS Backup)..."
echo "  Running terraform plan first..."
(cd "$(dirname "$0")/../terraform/55-backup" && \
  AWS_PROFILE=cbci-lab terraform init -input=false && \
  AWS_PROFILE=cbci-lab terraform plan -out=tfplan -input=false)

echo ""
echo "  Review the plan above. Press Enter to apply, or Ctrl+C to abort."
read -r

(cd "$(dirname "$0")/../terraform/55-backup" && \
  AWS_PROFILE=cbci-lab terraform apply tfplan)

# ── 3. Get Velero IAM role ARN from Terraform output ─────────────────
echo ""
echo "[3/5] Reading Terraform outputs..."
VELERO_ROLE_ARN=$(cd "$(dirname "$0")/../terraform/55-backup" && \
  AWS_PROFILE=cbci-lab terraform output -raw velero_iam_role_arn)
VELERO_BUCKET=$(cd "$(dirname "$0")/../terraform/55-backup" && \
  AWS_PROFILE=cbci-lab terraform output -raw velero_s3_bucket)
echo "  Velero IAM Role: ${VELERO_ROLE_ARN}"
echo "  Velero S3 Bucket: ${VELERO_BUCKET}"

# ── 4. Install Velero via Helm ────────────────────────────────────────
echo ""
echo "[4/5] Installing Velero Helm chart v${CHART_VERSION}..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update vmware-tanzu

# Patch the role ARN into the values (in-memory, not writing to file)
helm upgrade --install velero vmware-tanzu/velero \
  --version "${CHART_VERSION}" \
  --namespace "${VELERO_NS}" \
  --create-namespace \
  --values "$(dirname "$0")/../helm/values-velero.yaml" \
  --set "serviceAccount.server.annotations.eks\\.amazonaws\\.com/role-arn=${VELERO_ROLE_ARN}" \
  --set "configuration.backupStorageLocation[0].bucket=${VELERO_BUCKET}" \
  --wait --timeout 5m

echo "  Velero installed successfully"

# ── 5. Verify Velero is ready ─────────────────────────────────────────
echo ""
echo "[5/5] Verifying Velero..."
kubectl get pods -n "${VELERO_NS}"
echo ""
kubectl get backupstoragelocations -n "${VELERO_NS}"
echo ""

echo "================================================================"
echo " Backup infrastructure deployed successfully"
echo "================================================================"
echo ""
echo "  S3 bucket:    s3://${VELERO_BUCKET}"
echo "  IAM role:     ${VELERO_ROLE_ARN}"
echo "  Schedule:     cbci-daily (02:00 UTC, 30-day retention)"
echo ""
echo "  Useful commands:"
echo "    velero backup get                          # list all backups"
echo "    velero backup describe <name>              # inspect a backup"
echo "    velero restore create --from-backup <name> # restore"
echo "    velero backup create manual-$(date +%Y%m%d) \\
       --include-namespaces ci-controllers          # manual backup"
