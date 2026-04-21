#!/usr/bin/env bash
# validate-casc.sh — pre-flight CasC bundle validator
#
# Catches known-bad patterns BEFORE applying ConfigMaps or restarting OC.
# Run this before any casc bundle change. Called by bootstrap.sh automatically.
#
# Exit 0 = clean. Exit 1 = found problems (deployment blocked).

set -euo pipefail

CASC_DIR="${1:-casc}"
ERRORS=0

echo "=== CasC pre-flight validation ==="

# ── YAML syntax check ──────────────────────────────────────────────────────
if command -v python3 &>/dev/null; then
  while IFS= read -r -d '' f; do
    python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as fh:
        yaml.safe_load(fh)
except yaml.YAMLError as e:
    print(f'YAML SYNTAX ERROR in {sys.argv[1]}: {e}')
    sys.exit(1)
" "$f" || ERRORS=$((ERRORS + 1))
  done < <(find "${CASC_DIR}" -name '*.yaml' -print0)
  echo "  Syntax: all YAML files parse cleanly."
fi

# ── Known-bad OC patterns ──────────────────────────────────────────────────
OC_BUNDLE="${CASC_DIR}/oc-bundle/jenkins.yaml"
if [[ -f "${OC_BUNDLE}" ]]; then
  # jenkins.users — not supported in CBCI 2.555.x
  if grep -qE '^  users:' "${OC_BUNDLE}"; then
    echo "ERROR [${OC_BUNDLE}]: 'jenkins.users:' is not supported by CBCI 2.555.x JCasC."
    echo "       API tokens must be injected via scripts/setup-api-token.sh."
    ERRORS=$((ERRORS + 1))
  fi

  # globalLibraries — OC has no pipeline execution; plugin absent on OC
  if grep -qE '^  globalLibraries:' "${OC_BUNDLE}"; then
    echo "ERROR [${OC_BUNDLE}]: 'unclassified.globalLibraries' is not available on OC."
    echo "       Pipeline libraries belong in controller bundles (casc/controller-bundles/)."
    ERRORS=$((ERRORS + 1))
  fi

  # Sanity: root URL must be set
  if ! grep -q 'url: https://' "${OC_BUNDLE}"; then
    echo "WARNING [${OC_BUNDLE}]: location.url not set to https://. SSO will likely fail."
  fi

  echo "  OC bundle: no known-bad attributes found."
fi

# ── Known-bad controller bundle patterns ──────────────────────────────────
for ctrl_bundle in "${CASC_DIR}"/controller-bundles/*/jenkins.yaml; do
  [[ -f "${ctrl_bundle}" ]] || continue
  ctrl=$(basename "$(dirname "${ctrl_bundle}")")

  # jenkins.users — same restriction applies to managed controllers
  if grep -qE '^  users:' "${ctrl_bundle}"; then
    echo "ERROR [${ctrl_bundle}]: 'jenkins.users:' is not supported in CBCI 2.555.x."
    ERRORS=$((ERRORS + 1))
  fi
  echo "  Controller bundle [${ctrl}]: OK."
done

# ── Result ─────────────────────────────────────────────────────────────────
echo ""
if [[ "${ERRORS}" -gt 0 ]]; then
  echo "FAILED: ${ERRORS} error(s) found. Fix them before applying to the cluster."
  echo "        Aborting to prevent OC CrashLoopBackOff."
  exit 1
else
  echo "Validation passed — safe to apply."
fi
