#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=8
STEP_TITLE="INSTALLING LONGHORN"

MAX_RETRIES=90
SLEEP_SECONDS=5
LOG_EVERY=2   # cada 10s

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
# Namespace (idempotent)
# --------------------------------------------------
run_bg kubectl create namespace longhorn-system --dry-run=client -o yaml | run_bg kubectl apply -f -

# --------------------------------------------------
# Install/Upgrade Longhorn
# --------------------------------------------------
run_bg helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --wait --timeout 15m

progress 40
log "Waiting for Longhorn pods to be Ready"

# --------------------------------------------------
# Wait: pods Ready (kubectl wait) + fallback loop
# --------------------------------------------------
# Primero: intenta con kubectl wait (lo más confiable)
if ! kubectl -n longhorn-system wait --for=condition=Ready pod --all --timeout=10m >/dev/null 2>&1; then
  log "kubectl wait did not complete, switching to fallback loop"

  for ((i=1; i<=MAX_RETRIES; i++)); do
    # Cuenta pods que NO están Ready (READY column like 1/1, 0/1, 2/2 etc)
    NOT_READY=$(
      kubectl get pods -n longhorn-system --no-headers 2>/dev/null \
      | awk '{print $2}' \
      | awk -F/ '$1!=$2 {c++} END{print c+0}' || true
    )

    if (( i % LOG_EVERY == 0 )); then
      TOTAL_PODS=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | wc -l | xargs || echo 0)
      READY_PODS=$(( TOTAL_PODS - NOT_READY ))
      log "Longhorn pods Ready: ${READY_PODS}/${TOTAL_PODS}"
    fi

    if [[ "$NOT_READY" -eq 0 ]]; then
      break
    fi
    sleep "$SLEEP_SECONDS"
  done
fi

progress 65
log "Waiting for StorageClass 'longhorn' to exist"

# --------------------------------------------------
# Wait for StorageClass to appear
# --------------------------------------------------
SC_FOUND=0
for ((i=1; i<=MAX_RETRIES; i++)); do
  if kubectl get storageclass longhorn >/dev/null 2>&1; then
    SC_FOUND=1
    break
  fi
  if (( i % LOG_EVERY == 0 )); then
    log "StorageClass 'longhorn' not found yet..."
  fi
  sleep "$SLEEP_SECONDS"
done

if [[ "$SC_FOUND" -ne 1 ]]; then
  log "ERROR: StorageClass 'longhorn' still not found after waiting"
  run_bg kubectl get storageclass || true
  exit 1
fi

progress 75
log "Configuring StorageClass defaults (local-path -> false, longhorn -> true)"

# --------------------------------------------------
# Remove local-path as default (ignore if missing)
# --------------------------------------------------
run_bg kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  >/dev/null 2>&1 || true

# --------------------------------------------------
# Set longhorn as default
# --------------------------------------------------
run_bg kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

progress 90
log "Validating StorageClasses"
run_bg kubectl get storageclass

progress 100
log "STEP 08 completed successfully"
return 0