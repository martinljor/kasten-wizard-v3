#!/usr/bin/env bash
set -Eeuo pipefail

type run_bg >/dev/null 2>&1 || { echo "run_bg not defined"; return 1; }

CLUSTER_NAME="k3s-lab"
SERVERS=1
AGENTS=2

# If cluster already exists, skip
if k3d cluster list | grep -q "^${CLUSTER_NAME}\b"; then
  run_bg echo "k3d cluster '${CLUSTER_NAME}' already exists"
  return 0
fi

# Create cluster
run_bg k3d cluster create "${CLUSTER_NAME}" \
  --servers "${SERVERS}" \
  --agents "${AGENTS}" \
  --k3s-arg "--disable=traefik@server:*" \
  --wait

# Set kubeconfig context
run_bg kubectl config use-context "k3d-${CLUSTER_NAME}"

# Basic validation
run_bg kubectl get nodes

return 0

