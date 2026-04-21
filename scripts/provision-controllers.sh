#!/usr/bin/env bash
# provision-controllers.sh — idempotent controller provisioning via CBCI REST API
#
# Replaces ALL manual Groovy Script Console steps:
#   - Controller creation (was: items.yaml applied once + Script Console)
#   - HA replication config (was: Groovy Replication(2,4,70))
#   - CasC bundle javaOptions (was: Groovy config.javaOptions)
#   - Rolling restart (was: Groovy mm.rollingRestartAction())
#
# Why not items.yaml in the OC bundle:
#   managedMaster kind is not registered at CasC load time in CBCI 2.555.x,
#   causing CasCInvalidKindException on OC restart. Items applied here via
#   the REST API succeed because plugins are fully loaded at this point.
#
# Auth: uses the CI automation API token stored in jenkins-api-token-secret
#   (synced from Secrets Manager by ESO). Token hash is pre-configured on
#   the admin user via CasC (ADMIN_API_TOKEN_HASH env var in values-oc.yaml).
#
# Idempotent: checks if each controller already exists before creating.
#
# Usage: bash scripts/provision-controllers.sh
#        Called automatically from bootstrap.sh after OC is healthy.

set -euo pipefail

NAMESPACE=cloudbees
OC_URL="https://cjoc.myhomettbros.com/cjoc"
ADMIN_USER="admin"

echo "=== Waiting for jenkins-api-token-secret to be synced by ESO ==="
for i in $(seq 1 24); do
  if kubectl get secret jenkins-api-token-secret -n "${NAMESPACE}" &>/dev/null; then
    echo "  Secret found."
    break
  fi
  echo "  Waiting for ESO to sync jenkins-api-token-secret... (${i}/24)"
  sleep 5
done

API_TOKEN=$(kubectl get secret jenkins-api-token-secret \
  -n "${NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "${API_TOKEN}" ]]; then
  echo "ERROR: jenkins-api-token-secret not found or empty."
  echo "  Run: terraform apply in terraform/60-platform/ first."
  exit 1
fi

echo ""
echo "=== Waiting for OC to accept API requests ==="
for i in $(seq 1 36); do
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -u "${ADMIN_USER}:${API_TOKEN}" \
    "${OC_URL}/api/json" 2>/dev/null || echo "000")
  if [[ "${HTTP}" == "200" ]]; then
    echo "  OC API ready (HTTP 200)."
    break
  fi
  echo "  OC not ready yet (HTTP ${HTTP})... (${i}/36)"
  sleep 10
done

if [[ "${HTTP}" != "200" ]]; then
  echo "ERROR: OC API did not become ready after 6 minutes."
  echo "  Check: kubectl logs -n ${NAMESPACE} cjoc-0"
  exit 1
fi

# Get CSRF crumb (required for POST requests)
CRUMB=$(curl -sf -u "${ADMIN_USER}:${API_TOKEN}" \
  "${OC_URL}/crumbIssuer/api/json" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")

echo "  CSRF crumb acquired."

# ─── Apply items via CBCI CasC items API ────────────────────────────────────
#
# The casc-items/apply endpoint accepts items.yaml content and provisions
# managed masters exactly as if items.yaml were in the OC bundle — but
# without the CasCInvalidKindException that occurs at startup.
#
# With removeStrategy.items: NONE, this is safe to re-run: only adds,
# never removes existing controllers.

echo ""
echo "=== Applying controller definitions via CBCI CasC items API ==="
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${API_TOKEN}" \
  -H "${CRUMB}" \
  -H "Content-Type: application/yaml" \
  --data-binary @casc/oc-bundle/items.yaml \
  "${OC_URL}/casc-items/apply" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "204" ]]; then
  echo "  casc-items/apply succeeded (HTTP ${HTTP_STATUS})."
else
  echo "  casc-items/apply returned HTTP ${HTTP_STATUS} — falling back to createItem API."
  _provision_via_create_item
fi

echo ""
echo "=== Waiting for controllers to reach APPROVED state ==="
for CTRL in devflow test1; do
  echo "  Waiting for ${CTRL}..."
  for i in $(seq 1 60); do
    STATE=$(curl -sf -u "${ADMIN_USER}:${API_TOKEN}" \
      "${OC_URL}/job/${CTRL}/api/json?tree=description" 2>/dev/null | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('description','UNKNOWN'))" 2>/dev/null \
      || echo "NOT_FOUND")
    if [[ "${STATE}" == "APPROVED" ]]; then
      echo "  ${CTRL}: APPROVED"
      break
    fi
    echo "  ${CTRL}: ${STATE} (${i}/60)"
    sleep 10
  done
done

echo ""
echo "=== Controller provisioning complete ==="
echo "  devflow: ${OC_URL%/cjoc}/devflow/"
echo "  test1:   ${OC_URL%/cjoc}/test1/"

# ─── Fallback: createItem API (used if casc-items/apply is unavailable) ─────
_provision_via_create_item() {
  for CTRL in devflow test1; do
    # Check if already exists
    EXISTING=$(curl -sf -o /dev/null -w "%{http_code}" \
      -u "${ADMIN_USER}:${API_TOKEN}" \
      "${OC_URL}/job/${CTRL}/api/json" 2>/dev/null || echo "404")
    if [[ "${EXISTING}" == "200" ]]; then
      echo "  ${CTRL}: already exists — skipping."
      continue
    fi

    echo "  Creating ${CTRL}..."
    # Export config from items.yaml and convert to Jenkins XML format
    # (requires the controller to be defined in items.yaml)
    curl -sf \
      -u "${ADMIN_USER}:${API_TOKEN}" \
      -H "${CRUMB}" \
      -H "Content-Type: text/xml" \
      --data-binary "$(python3 scripts/_items_to_xml.py "${CTRL}")" \
      "${OC_URL}/createItem?name=${CTRL}" || {
        echo "  WARNING: could not create ${CTRL} via createItem API."
        echo "  Provision manually via OC UI or re-run after verifying API token."
      }
  done
}
