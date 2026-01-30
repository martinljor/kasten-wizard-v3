#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=8
STEP_TITLE="INSTALLING LONGHORN STORAGE"

EXPECTED_PODS=6
MAX_RETRIES=60
SLEEP_SECONDS=5

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

progress 10
log "Validating Kubernetes access"

# --------------------------------------------------
# Pre-check
# --------------------------------------------------
if ! kubectl get nodes >/dev/null 2>&1; then
  log "ERROR: Kubernetes cluster not reachable"
  exit 1
fi

progress 20
log "Applying Longhorn manifests"

# --------------------------------------------------
# Install Longhorn
# --------------------------------------------------
run_bg kubectl apply -f \
  https://raw.githubusercontent.com/longhorn/longhorn/v1.6.2/deploy/longhorn.yaml

progress 40
log "Waiting for Longhorn namespace to be created"

for i in {1..30}; do
  kubectl get ns longhorn-system >/dev/null 2>&1 && break
  sleep 2
done

progress 60
log "Waiting for Longhorn pods to be Running"

READY=0
TOTAL=0

for ((i=1; i<=MAX_RETRIES; i++)); do
  READY=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null \
    | awk '$3=="Running"' | wc -l)

  TOTAL=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | wc -l)

  log "Longhorn pods Running: $READY / $TOTAL"

  if [[ "$READY" -ge "$EXPECTED_PODS" ]]; then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

if [[ "$READY" -lt "$EXPECTED_PODS" ]]; then
  log "ERROR: Longhorn pods did not reach Running state"
  run_bg kubectl get pods -n longhorn-system
  exit 1
fi

progress 80
log "Setting Longhorn as default StorageClass"

run_bg kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

progress 100
log "STEP 08 completed successfully (Longhorn ready)"
