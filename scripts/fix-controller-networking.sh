#!/usr/bin/env bash
# fix-controller-networking.sh — patch managed controller Deployments with correct
# networking JVM flags when they were provisioned with stale settings.
#
# When this is needed:
#   - After a DR restore where Velero restores controller Deployments from a backup
#     taken before the HTTPS migration (controllers get old ALB URL as MASTER_ENDPOINT).
#   - After re-provisioning a controller from an OC that had wrong networking at the time.
#
# Why not in CasC bundles:
#   The OC injects MASTER_ENDPOINT and com.cloudbees.networking.* JVM flags into
#   each controller Deployment at provisioning time. These are set by the OC, not by
#   the controller's own CasC bundle. The CasC location.url is overridden by the
#   networking JVM flags. The correct fix is to patch the Deployment.
#
# Why not a Groovy script on the OC:
#   The same patch can be done declaratively on the Kubernetes Deployment, which is
#   a Kubernetes API call — no OC UI interaction required. The bootstrap script calls
#   this function after CBCI is installed, making it fully reproducible from code.
#
# Idempotent: only patches if the values are wrong. Safe to re-run.
#
# Usage: AWS_PROFILE=cbci-lab bash scripts/fix-controller-networking.sh
#        (or called from scripts/bootstrap.sh)

set -euo pipefail

NAMESPACE=cloudbees
CORRECT_PROTOCOL="https"
CORRECT_HOSTNAME="cjoc.myhomettbros.com"
CORRECT_PORT="443"

fix_controller() {
  local name="$1"
  local correct_endpoint="https://cjoc.myhomettbros.com/${name}/"

  echo "Checking ${name} controller networking..."

  if ! kubectl get deployment "${name}" -n "${NAMESPACE}" &>/dev/null; then
    echo "  Deployment ${name} not found — skipping (controller not yet provisioned)."
    return
  fi

  local current_endpoint
  current_endpoint=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JAVA_OPTS")].value}' \
    | grep -oP '(?<=-DMASTER_ENDPOINT=")[^"]+' 2>/dev/null || echo "")

  if [[ "$current_endpoint" == "$correct_endpoint" ]]; then
    echo "  ${name}: MASTER_ENDPOINT already correct (${correct_endpoint}). No patch needed."
    return
  fi

  echo "  ${name}: MASTER_ENDPOINT is stale (${current_endpoint}). Patching..."

  # Find JAVA_OPTS env var index
  local idx
  idx=$(kubectl get deployment "${name}" -n "${NAMESPACE}" -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i,e in enumerate(d['spec']['template']['spec']['containers'][0]['env']):
    if e['name']=='JAVA_OPTS': print(i); break
")

  # Get current value and apply all four replacements
  local new_opts
  new_opts=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JAVA_OPTS")].value}' | \
    sed "s|-DMASTER_ENDPOINT=\"[^\"]*\"|-DMASTER_ENDPOINT=\"${correct_endpoint}\"|g" | \
    sed "s|-Dcom\.cloudbees\.networking\.protocol=\"http\"|-Dcom.cloudbees.networking.protocol=\"${CORRECT_PROTOCOL}\"|g" | \
    sed "s|-Dcom\.cloudbees\.networking\.hostname= |-Dcom.cloudbees.networking.hostname=${CORRECT_HOSTNAME} |g" | \
    sed "s|-Dcom\.cloudbees\.networking\.port=80 |-Dcom.cloudbees.networking.port=${CORRECT_PORT} |g")

  local patch
  patch=$(python3 -c "
import json,sys
v=sys.stdin.read().strip()
print(json.dumps([{'op':'replace','path':'/spec/template/spec/containers/0/env/${idx}/value','value':v}]))
" <<< "$new_opts")

  kubectl patch deployment "${name}" -n "${NAMESPACE}" --type=json --patch "${patch}"
  echo "  ${name}: patched. Pods will roll automatically."
}

echo "=== Fixing controller networking JVM flags ==="
fix_controller "devflow"
fix_controller "test1"

echo ""
echo "Waiting for rollouts to complete..."
kubectl rollout status deployment/devflow -n "${NAMESPACE}" --timeout=5m || true
kubectl rollout status deployment/test1  -n "${NAMESPACE}" --timeout=5m || true

# --- OC EFS state files ---
# The OC stores each controller's endpoint in two XML files on its own EFS volume
# (jenkins home of the OC pod, not the controller pod):
#   /var/jenkins_home/jobs/{name}/config.xml  →  <localEndpoint>
#   /var/jenkins_home/jobs/{name}/state.xml   →  <endpointURL>   ← authoritative
#
# On OC startup, state.xml is read and its value is written back into config.xml.
# Patching only config.xml is not sufficient — state.xml will overwrite it on restart.
# Both files must be patched, then the OC pod restarted once so it loads the new values.
#
# This step is only needed when controllers were provisioned with an old URL
# (e.g., after a DR restore from a pre-HTTPS backup or after ALB replacement).
# It is safe to run on a fresh install — sed will make no changes if the URLs are already correct.

echo ""
echo "=== Patching OC EFS controller state files ==="
OC_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=cjoc -o jsonpath='{.items[0].metadata.name}')
echo "OC pod: ${OC_POD}"

for CTRL in devflow test1; do
  CORRECT_URL="https://${CORRECT_HOSTNAME}/${CTRL}/"
  echo "  Patching ${CTRL} (target: ${CORRECT_URL})..."
  kubectl exec -n "${NAMESPACE}" "${OC_POD}" -- sh -c "
    for FILE in /var/jenkins_home/jobs/${CTRL}/config.xml /var/jenkins_home/jobs/${CTRL}/state.xml; do
      if [ -f \"\$FILE\" ]; then
        sed -i 's|http://[^/]*/'"${CTRL}"'/|${CORRECT_URL}|g' \"\$FILE\"
        sed -i 's|https://[^/]*/'"${CTRL}"'/|${CORRECT_URL}|g' \"\$FILE\"
        echo \"    patched: \$FILE\"
      else
        echo \"    not found (controller not yet provisioned): \$FILE\"
      fi
    done
  "
done

echo ""
echo "=== Restarting OC pod so it reads corrected state.xml ==="
kubectl delete pod "${OC_POD}" -n "${NAMESPACE}"
kubectl wait --for=condition=Ready pod -l app=cjoc -n "${NAMESPACE}" --timeout=5m
echo "OC pod restarted and ready."

echo ""
echo "Done. Controller URLs:"
echo "  devflow: https://cjoc.myhomettbros.com/devflow/"
echo "  test1:   https://cjoc.myhomettbros.com/test1/"
