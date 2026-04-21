#!/usr/bin/env bash
# bootstrap.sh — install all Helm charts and apply k8s manifests from scratch
#
# Run AFTER all Terraform modules (00 through 60) have been applied.
# Idempotent: uses `helm upgrade --install` and `kubectl apply`.
#
# Usage: AWS_PROFILE=cbci-lab bash scripts/bootstrap.sh

set -euo pipefail

CLUSTER=cbci-lab
REGION=us-east-1
ACCOUNT_ID=835090871306

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo ""
echo "=== 1. Namespaces ==="
kubectl apply -f k8s/namespaces.yaml

echo ""
echo "=== 2. StorageClass (EFS) ==="
kubectl apply -f k8s/storageclass-efs.yaml

echo ""
echo "=== 3. Karpenter NodePools + EC2NodeClass ==="
# Already managed by terraform/40-addons via null_resource — skip if TF applied.
# Manual re-apply if needed:
# kubectl apply -f k8s/karpenter/ec2nodeclass.yaml
# kubectl apply -f k8s/karpenter/nodepool-controllers.yaml
# kubectl apply -f k8s/karpenter/nodepool-agents.yaml

echo ""
echo "=== 4. External Secrets Operator ==="
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --version 0.13.0 \
  --values helm/values-eso.yaml \
  --wait --timeout 5m

kubectl apply -f k8s/eso-cluster-secret-store.yaml

# Secrets must exist in Secrets Manager before applying ExternalSecrets
# Run: aws secretsmanager put-secret-value --secret-id cbci-lab/jenkins-admin-password \
#        --secret-string '{"password":"<value>"}' --profile cbci-lab
# Run: aws secretsmanager put-secret-value --secret-id cbci-lab/grafana-admin-password \
#        --secret-string '{"username":"admin","password":"<value>"}' --profile cbci-lab
kubectl apply -f k8s/eso-external-secrets.yaml

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

# Apply RBAC for GitHub Actions (needed before OC pod starts)
kubectl apply -f k8s/rbac-github-actions.yaml

# Seed the CasC bundle ConfigMap
# Version is stamped by GitHub Actions on every push; seed it at "0" for a fresh install.
kubectl create configmap oc-casc-bundle \
  --from-file=casc/oc-bundle/bundle.yaml \
  --from-file=casc/oc-bundle/jenkins.yaml \
  --from-file=casc/oc-bundle/plugins.yaml \
  --namespace cloudbees \
  --dry-run=client -o yaml | kubectl apply -f -

# Verify the jenkins-admin-secret is synced before installing OC
kubectl wait --for=condition=Ready externalsecret/jenkins-admin-password \
  -n cloudbees --timeout=120s || true

# Get current chart version: helm search repo cloudbees/cloudbees-core --versions | head -5
# Confirm with: helm list -n cloudbees
CBCI_CHART_VERSION="3.15555.0.0"  # TODO: verify with `helm list -n cloudbees`
helm upgrade --install cbci cloudbees/cloudbees-core \
  --namespace cloudbees \
  --version "$CBCI_CHART_VERSION" \
  --values helm/values-oc.yaml \
  --wait --timeout 10m

echo ""
echo "=== 8. Velero (backup) ==="
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version 12.0.0 \
  --values helm/values-velero.yaml \
  --wait --timeout 5m

echo ""
echo "=== Done ==="
echo "OC URL: https://cjoc.myhomettbros.com/cjoc/"
echo "Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring"
echo ""
echo "NOTE: ExternalDNS is managed by terraform/60-platform (helm_release.external_dns)."
echo "      Run 'terraform apply' in terraform/60-platform/ to install it."
echo ""
echo "NOTE: terraform/60-platform also installs ExternalDNS. After applying, delete the"
echo "      existing manual Route 53 A records for cjoc/devflow/test1 — ExternalDNS"
echo "      will recreate them automatically from Ingress annotations."
