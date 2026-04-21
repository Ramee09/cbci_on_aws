#!/usr/bin/env bash
# setup-api-token.sh — inject the CI automation API token into the OC admin user
#
# Jenkins 2.x with SAML security realm: API tokens are stored separately from
# passwords and work for Basic auth regardless of the security realm configured.
# The token hash (SHA-256 of plaintext) is written to the admin user's config.xml
# on EFS, so it survives pod restarts.
#
# This replaces the unsupported jenkins.users CasC path in CBCI 2.555.x.
#
# Idempotent: skips if the ci-automation-v1 token is already present.
# Called by bootstrap.sh after OC is ready, before provision-controllers.sh.

set -euo pipefail

NAMESPACE=cloudbees

echo "=== Setting up CI automation API token on OC admin user ==="

# Wait for OC pod to be ready
kubectl wait --for=condition=Ready pod/cjoc-0 -n "${NAMESPACE}" --timeout=5m

# Read the API token from the synced k8s secret
API_TOKEN=$(kubectl get secret jenkins-api-token-secret \
  -n "${NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "${API_TOKEN}" ]]; then
  echo "ERROR: jenkins-api-token-secret is empty. Run terraform apply in 60-platform first."
  exit 1
fi

# Check if token is already configured (idempotent)
ALREADY=$(kubectl exec -n "${NAMESPACE}" cjoc-0 -- sh -c \
  "grep -r 'ci-automation-v1' /var/jenkins_home/users/admin_*/config.xml 2>/dev/null | wc -l")
if [[ "${ALREADY}" -gt 0 ]]; then
  echo "  Token ci-automation-v1 already present — skipping."
  exit 0
fi

# Inject the API token directly into admin's config.xml on EFS.
# Jenkins reads config.xml for user properties dynamically; no restart needed.
# The hash format: SHA-256(plaintext) in lowercase hex — Jenkins computes
# the same hash when verifying Basic auth: sha256(provided_token) == stored_value.
kubectl exec -n "${NAMESPACE}" cjoc-0 -- python3 -c "
import hashlib, glob, sys

token_plain = sys.argv[1]
token_hash = hashlib.sha256(token_plain.encode('ascii')).hexdigest()

# Find admin user config.xml
files = glob.glob('/var/jenkins_home/users/admin_*/config.xml')
if not files:
    print('ERROR: admin user config.xml not found', flush=True)
    sys.exit(1)

config_file = files[0]
with open(config_file, 'r') as f:
    content = f.read()

if 'ci-automation-v1' in content:
    print('Token already present — nothing to do.', flush=True)
    sys.exit(0)

token_xml = '''  <jenkins.security.apitoken.ApiTokenStore_-HashedToken>
        <uuid>ci-automation-v1</uuid>
        <name>CI Automation</name>
        <creationDate>1704067200000</creationDate>
        <value>''' + token_hash + '''</value>
      </jenkins.security.apitoken.ApiTokenStore_-HashedToken>'''

# Replace empty tokenList (handle both self-closing and open/close variants)
if '<tokenList/>' in content:
    content = content.replace('<tokenList/>', '<tokenList>' + token_xml + '</tokenList>')
elif '<tokenList />' in content:
    content = content.replace('<tokenList />', '<tokenList>' + token_xml + '</tokenList>')
else:
    print('WARNING: tokenList element not found in ' + config_file, flush=True)
    print('Existing token config may already be present or config format differs.', flush=True)
    sys.exit(0)

with open(config_file, 'w') as f:
    f.write(content)
print('API token ci-automation-v1 written to ' + config_file, flush=True)
print('admin user can now authenticate with: admin:<token-from-jenkins-api-token-secret>', flush=True)
" "${API_TOKEN}"

echo "  API token configured. No OC restart required — Jenkins reads user config dynamically."
