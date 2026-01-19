#!/usr/bin/env bash

NAMESPACE="longhorn-system"
LONGHORN_VERSION="v1.6.2"

# --------------------------------------------------
# Helm repo
# --------------------------------------------------
run_bg helm repo add longhorn https://charts.longhorn.io
run_bg helm repo update

# --------------------------------------------------
# Namespace
# --------------------------------------------------
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || \
  run_bg kubectl create ns "$NAMESPACE"

# --------------------------------------------------
# Install Longhorn (idempotent)
# --------------------------------------------------
if ! helm status longhorn -n "$NAMESPACE" >/dev/null 2>&1; then
  run_bg helm install longhorn longhorn/longhorn \
    -n "$NAMESPACE" \
    --version "$LONGHORN_VERSION" \
    --set defaultSettings.defaultReplicaCount=2
fi

# --------------------------------------------------
# Wait for Longhorn pods (SAME LOGIC AS kasten20.sh)
# --------------------------------------------------
echo "[INFO] Waiting for Longhorn pods..." >> "$LOG_FILE"

while true; do
  NOT_READY=$(kubectl -n "$NAMESPACE" get pods --no-headers \
    | awk '{print $3}' \
    | grep -vE 'Running|Completed' || true)

  if [[ -z "$NOT_READY" ]]; then
    break
  fi

  kubectl -n "$NAMESPACE" get pods >> "$LOG_FILE"
  sleep 10
done

# --------------------------------------------------
# Verify StorageClass
# --------------------------------------------------
kubectl get storageclass longhorn >/dev/null 2>&1 || return 1

return 0
