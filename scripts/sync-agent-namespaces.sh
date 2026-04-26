#!/usr/bin/env bash
# Reads casc/oc-bundle/items.yaml, extracts every managedController name,
# and ensures a ci-agents-<name> namespace exists with the standard
# RBAC, ResourceQuota, and LimitRange. No PVC resources are created.
# Safe to re-run; kubectl apply is idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ITEMS_YAML="$REPO_ROOT/casc/oc-bundle/items.yaml"
CONTROLLER_NS="ci-controllers"

controller_names=$(python3 - "$ITEMS_YAML" <<'EOF'
import yaml, sys
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
for item in doc.get("items", []):
    if item.get("kind") == "managedController":
        print(item["name"])
EOF
)

for name in $controller_names; do
  agent_ns="ci-agents-${name}"
  echo "=== Syncing agent namespace: ${agent_ns} ==="

  kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${agent_ns}
  labels:
    cloudbees.com/role: agents
    cloudbees.com/controller: ${name}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agents
  namespace: ${agent_ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agents
  namespace: ${agent_ns}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}-manages-agents
  namespace: ${agent_ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agents
subjects:
- kind: ServiceAccount
  name: ${name}
  namespace: ${CONTROLLER_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agents-self
  namespace: ${agent_ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agents
subjects:
- kind: ServiceAccount
  name: jenkins-agents
  namespace: ${agent_ns}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: agent-quota
  namespace: ${agent_ns}
spec:
  hard:
    requests.cpu: "16"
    requests.memory: 64Gi
    limits.cpu: "16"
    limits.memory: 64Gi
    pods: "40"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: agent-limits
  namespace: ${agent_ns}
spec:
  limits:
  - type: Container
    default:
      cpu: "1"
      memory: 2Gi
    defaultRequest:
      cpu: 500m
      memory: 512Mi
    max:
      cpu: "4"
      memory: 8Gi
    min:
      cpu: 100m
      memory: 128Mi
YAML

  echo "  ${agent_ns} OK"
done

echo "=== Done. Agent namespaces synced for: $(echo $controller_names | tr '\n' ' ') ==="
