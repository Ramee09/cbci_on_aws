#!/usr/bin/env bash
# lab-start.sh — scale EKS system nodes back up
#
# CBCI and monitoring pods will reschedule automatically.
# Allow ~5-10 minutes for all pods to reach Ready.

set -euo pipefail

CLUSTER=cbci-lab
REGION=us-east-1
NODEGROUP=system

echo "Scaling up node group '$NODEGROUP' to 2..."
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --region "$REGION" \
  --profile cbci-lab

echo "Done. Waiting for nodes to be Ready (this may take 2-3 minutes)..."
aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --region "$REGION" \
  --profile cbci-lab

echo "Nodes ready. CBCI will be available at https://cjoc.myhomettbros.com/cjoc/ in ~5 minutes."
echo "Check pod status: kubectl get pods -A"
