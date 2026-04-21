# stage environment — pre-production validation
# Sourced by bootstrap.sh: source environments/stage/env.sh
# TODO: Update account_id and domain when stage AWS account is provisioned.

export CLUSTER="cbci-stage"
export REGION="us-east-1"
export ACCOUNT_ID="REPLACE_WITH_STAGE_ACCOUNT_ID"
export DOMAIN="stage.myhomettbros.com"
export OC_HOSTNAME="cjoc.${DOMAIN}"
export CBCI_CHART_VERSION="3.36486.0+0e91c42e72db"
export AWS_PROFILE="cbci-stage"

export TF_STATE_BUCKET="cbci-stage-tfstate-${ACCOUNT_ID}"
export TF_LOCK_TABLE="cbci-stage-tf-locks"

# Cost profile: multi-AZ NAT, higher replicas, mixed spot/on-demand
export CONTROLLER_REPLICAS=2
export CONTROLLER_MAX_REPLICAS=6
export AGENT_SPOT_ENABLED=true
