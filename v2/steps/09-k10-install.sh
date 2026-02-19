#!/usr/bin/env bash
set -e

STEP_NUM=9
STEP_TITLE="INSTALLING KASTEN K10"

MAX_RETRIES=60
SLEEP_SECONDS=5

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

progress 10
log "Adding Kasten Helm repository"

run_bg helm repo add kasten https://charts.kasten.io
run_bg helm repo update

progress 20
log "Creating kasten-io namespace"

run_bg kubectl create namespace kasten-io --dry-run=client -o yaml | kubectl apply -f -

progress 30
log "Installing K10"

run_bg helm upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.persistence.storageClass=longhorn \
  --set prometheus.server.persistentVolume.storageClass=longhorn \
  --set service.type=NodePort

progress 50
log "Waiting for K10 pods to be ready"

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(kubectl get pods -n kasten-io --no-headers 2>/dev/null \
    | awk '$2 != $3' \
    | wc -l || true)

  if [[ "$NOT_READY" -eq 0 ]]; then
    break
  fi

  if (( i % 3 == 0 )); then
    log "K10 pods not ready yet..."
  fi

  sleep "$SLEEP_SECONDS"
done

progress 80
log "Getting K10 service details"

run_bg kubectl get svc -n kasten-io

NODE_PORT=$(kubectl get svc gateway -n kasten-io \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)

progress 100
log "STEP 09 completed successfully"
log "K10 dashboard available on NodePort: $NODE_PORT"

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
touch "$ACCESS_FILE"

MASTER_IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)
NODE_PORT=$(kubectl get svc gateway -n kasten-io -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)

if [[ -n "$MASTER_IP" && -n "$NODE_PORT" ]]; then
  echo "Kasten K10 Dashboard | https://$MASTER_IP:$NODE_PORT | User: N/A | Pass: N/A" >> "$ACCESS_FILE"
fi
