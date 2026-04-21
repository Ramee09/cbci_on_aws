#!/usr/bin/env bash
# lab-stop.sh — scale down EKS nodes to stop compute costs
#
# Costs that continue: EKS control plane (~$2.40/day), EFS (~$0.30/GB/mo),
# NAT gateway (~$1/day), ALB (~$0.20/day).
# Compute cost (EC2 nodes) stops completely.
#
# Workloads are evicted when nodes scale to 0.
# Karpenter-provisioned nodes drain automatically once Karpenter itself is evicted.

set -euo pipefail

CLUSTER=cbci-lab
REGION=us-east-1
NODEGROUP=system

echo "Scaling down node group '$NODEGROUP' to 0..."
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=0,maxSize=4,desiredSize=0 \
  --region "$REGION" \
  --profile cbci-lab

echo "Done. Nodes will drain over the next few minutes."
echo "Remaining costs: EKS control plane + EFS + NAT gateway + ALB (~\$3-4/day)."
echo "To resume: bash scripts/lab-start.sh"
