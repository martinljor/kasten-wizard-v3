#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=8
STEP_TITLE="INSTALLING LONGHORN"

MAX_RETRIES=90
SLEEP_SECONDS=5
LOG_EVERY=2

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

progress 10
log "Installing Longhorn via Helm"

# --------------------------------------------------
# Helm repo
# --------------------------------------------------
run_bg helm repo add longhorn https://charts.longhorn.io || true
run_bg helm repo update

# --------------------------------------------------
# Namespace (safe + idempotent)
# --------------------------------------------------
if ! kubectl get namespace longhorn-system >/dev/null 2>&1; then
  run_bg kubectl create namespace longhorn-system
fi

# --------------------------------------------------
# Install Longhorn
# --------------------------------------------------
run_bg helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system

progress 40
log "Waiting for Longhorn pods to be Ready"

# --------------------------------------------------
# Wait pods Ready (robust check)
# --------------------------------------------------
for ((i=1; i<=MAX_RETRIES; i++)); do
  TOTAL=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | wc -l | xargs || echo 0)
  NOT_READY=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null \
    | awk '{print $2}' | awk -F/ '$1!=$2 {c++} END{print c+0}' || true)

  READY=$((TOTAL - NOT_READY))

  if (( i % LOG_EVERY == 0 )); then
    log "Longhorn pods Ready: $READY/$TOTAL"
  fi

  if [[ "$TOTAL" -gt 0 && "$NOT_READY" -eq 0 ]]; then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

progress 70
log "Waiting for StorageClass 'longhorn'"

for ((i=1; i<=MAX_RETRIES; i++)); do
  if kubectl get storageclass longhorn >/dev/null 2>&1; then
    break
  fi
  sleep "$SLEEP_SECONDS"
done

if ! kubectl get storageclass longhorn >/dev/null 2>&1; then
  log "ERROR: StorageClass longhorn not found"
  exit 1
fi

progress 80
log "Configuring StorageClass defaults"

run_bg kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true

run_bg kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

progress 95
run_bg kubectl get storageclass

progress 100
log "STEP 08 completed successfully"
return 0