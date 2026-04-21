# dev environment — personal AWS lab
# Sourced by bootstrap.sh: source environments/dev/env.sh

export CLUSTER="cbci-lab"
export REGION="us-east-1"
export ACCOUNT_ID="835090871306"
export DOMAIN="myhomettbros.com"
export OC_HOSTNAME="cjoc.${DOMAIN}"
export CBCI_CHART_VERSION="3.36486.0+0e91c42e72db"
export AWS_PROFILE="cbci-lab"

# Terraform state
export TF_STATE_BUCKET="cbci-lab-tfstate-${ACCOUNT_ID}"
export TF_LOCK_TABLE="cbci-lab-tf-locks"

# Cost profile: single NAT, minimal replicas, spot agents
export CONTROLLER_REPLICAS=2
export CONTROLLER_MAX_REPLICAS=4
export AGENT_SPOT_ENABLED=true
