#!/usr/bin/env bash

STEP_NAME="INSTALLING LONGHORN STORAGE"
NAMESPACE="longhorn-system"
LONGHORN_VERSION="v1.6.2"

# --------------------------------------------------
# Add Longhorn repo
# --------------------------------------------------
run_bg helm repo add longhorn https://charts.longhorn.io
run_bg helm repo update

# --------------------------------------------------
# Create namespace if not exists
# --------------------------------------------------
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || \
  run_bg kubectl create ns "$NAMESPACE"

# --------------------------------------------------
# Install Longhorn (idempotent)
# --------------------------------------------------
if ! helm status longhorn -n "$NAMESPACE" >/dev/null 2>&1; then
  run_bg helm install longhorn longhorn/longhorn \
    --namespace "$NAMESPACE" \
    --version "$LONGHORN_VERSION" \
    --set defaultSettings.defaultReplicaCount=2
fi

# --------------------------------------------------
# Wait for Longhorn pods
# --------------------------------------------------
run_bg kubectl rollout status deployment/longhorn-ui \
  -n "$NAMESPACE" --timeout=300s

run_bg kubectl rollout status deployment/longhorn-manager \
  -n "$NAMESPACE" --timeout=300s

# --------------------------------------------------
# Verify StorageClass
# --------------------------------------------------
kubectl get storageclass longhorn >/dev/null 2>&1 || return 1

return 0
