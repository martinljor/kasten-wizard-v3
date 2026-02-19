#!/usr/bin/env bash
set -e

STEP_NUM=8
STEP_TITLE="INSTALLING LONGHORN"

EXPECTED_NODES=3
MAX_RETRIES=60
SLEEP_SECONDS=5

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

progress 10
log "Installing Longhorn via Helm"

# --------------------------------------------------
# Add Helm repo
# --------------------------------------------------
run_bg helm repo add longhorn https://charts.longhorn.io
run_bg helm repo update

# --------------------------------------------------
# Create namespace
# --------------------------------------------------
run_bg kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

# --------------------------------------------------
# Install Longhorn
# --------------------------------------------------
run_bg helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultReplicaCount=2

progress 40
log "Waiting for Longhorn pods to be ready"

# --------------------------------------------------
# Wait for pods
# --------------------------------------------------
for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null \
    | awk '$2 != $3' \
    | wc -l || true)

  if [[ "$NOT_READY" -eq 0 ]]; then
    break
  fi

  if (( i % 3 == 0 )); then
    log "Longhorn pods not ready yet..."
  fi

  sleep "$SLEEP_SECONDS"
done

progress 70
log "Configuring StorageClass"

# --------------------------------------------------
# Remove local-path as default
# --------------------------------------------------
run_bg kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true

# --------------------------------------------------
# Set longhorn as default
# --------------------------------------------------
run_bg kubectl patch storageclass longhorn \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

progress 90
log "Validating StorageClasses"

run_bg kubectl get storageclass

progress 100
log "STEP 08 completed successfully"
