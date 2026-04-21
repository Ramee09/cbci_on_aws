#!/usr/bin/env bash
# provision-controllers.sh — idempotent controller provisioning via CBCI REST API
#
# Why not bundle items.yaml: cloudbees-casc-items-api in CBCI 2.555.x rejects
# 'managedMaster' kind with CasCInvalidKindException when processed at bundle
# load time. The REST API /casc-items/apply uses a different code path that
# accepts managedMaster after plugins are fully initialised.
#
# casc/oc-bundle/items.yaml IS the YAML source of truth — this script is only
# the delivery mechanism. No Groovy, no Script Console, no UI.
#
# Idempotent: checks whether each controller already exists before applying.
# Called automatically by bootstrap.sh after setup-api-token.sh.

set -euo pipefail

NAMESPACE=cloudbees
OC_URL="https://cjoc.myhomettbros.com/cjoc"
ADMIN_USER="admin"
ITEMS_FILE="casc/oc-bundle/items.yaml"

# ── Wait for API token secret ────────────────────────────────────────────────
echo "=== Waiting for jenkins-api-token-secret ==="
for i in $(seq 1 24); do
  TOKEN_LEN=$(kubectl get secret jenkins-api-token-secret \
    -n "${NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | wc -c || echo 0)
  [[ "${TOKEN_LEN}" -gt 4 ]] && { echo "  Secret ready."; break; }
  echo "  ESO sync pending (${i}/24)..."
  sleep 5
done

API_TOKEN=$(kubectl get secret jenkins-api-token-secret \
  -n "${NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "${API_TOKEN}" ]]; then
  echo "ERROR: jenkins-api-token-secret empty. Run terraform apply in 60-platform first."
  exit 1
fi

# ── Wait for OC API ──────────────────────────────────────────────────────────
echo ""
echo "=== Waiting for OC API ==="
HTTP="000"
for i in $(seq 1 36); do
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -u "${ADMIN_USER}:${API_TOKEN}" \
    "${OC_URL}/api/json" 2>/dev/null || echo "000")
  [[ "${HTTP}" == "200" ]] && { echo "  OC API ready."; break; }
  echo "  HTTP ${HTTP} — waiting (${i}/36)..."
  sleep 10
done

if [[ "${HTTP}" != "200" ]]; then
  echo "ERROR: OC API not ready after 6 minutes. Check: kubectl logs -n ${NAMESPACE} cjoc-0"
  exit 1
fi

# ── Check if controllers already exist ──────────────────────────────────────
echo ""
echo "=== Checking controller state ==="
MISSING=0
for CTRL in devflow test1; do
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -u "${ADMIN_USER}:${API_TOKEN}" \
    "${OC_URL}/job/${CTRL}/api/json" 2>/dev/null || echo "000")
  if [[ "${STATUS}" == "200" ]]; then
    echo "  ${CTRL}: exists — will reconcile (removeStrategy: NONE, safe)"
  else
    echo "  ${CTRL}: not found — will create"
    MISSING=$((MISSING + 1))
  fi
done

# ── Apply items.yaml via CBCI REST API ───────────────────────────────────────
echo ""
echo "=== Applying casc/oc-bundle/items.yaml via CBCI CasC items API ==="
CRUMB=$(curl -sf -u "${ADMIN_USER}:${API_TOKEN}" \
  "${OC_URL}/crumbIssuer/api/json" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")

HTTP_STATUS=$(curl -sf -o /tmp/casc-items-response.txt -w "%{http_code}" \
  -u "${ADMIN_USER}:${API_TOKEN}" \
  -H "${CRUMB}" \
  -H "Content-Type: application/yaml" \
  --data-binary @"${ITEMS_FILE}" \
  "${OC_URL}/casc-items/apply" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "204" ]]; then
  echo "  Applied successfully (HTTP ${HTTP_STATUS})."
else
  echo "  ERROR: casc-items/apply returned HTTP ${HTTP_STATUS}"
  cat /tmp/casc-items-response.txt 2>/dev/null || true
  echo "  Possible causes:"
  echo "    - API token not yet injected (setup-api-token.sh must run first)"
  echo "    - OC SAML realm blocking basic auth (token must be in admin config.xml)"
  exit 1
fi

# ── Wait for controllers to have running deployments ─────────────────────────
echo ""
echo "=== Waiting for controller deployments ==="
for CTRL in devflow test1; do
  echo "  Waiting for ${CTRL} Deployment..."
  for i in $(seq 1 60); do
    READY=$(kubectl get deployment "${CTRL}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment "${CTRL}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "${READY}" == "${DESIRED}" && "${DESIRED}" != "0" ]]; then
      echo "  ${CTRL}: ${READY}/${DESIRED} replicas ready"
      break
    fi
    echo "  ${CTRL}: ${READY:-0}/${DESIRED:-?} ready (${i}/60)"
    sleep 10
  done
done

echo ""
echo "=== Controller provisioning complete ==="
echo "  devflow: https://cjoc.myhomettbros.com/devflow/"
echo "  test1:   https://cjoc.myhomettbros.com/test1/"
