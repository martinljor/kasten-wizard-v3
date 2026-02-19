#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING KASTEN K10"

MAX_RETRIES=120
SLEEP_SECONDS=5
LOG_EVERY=3

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

# --------------------------------------------------
# Run kubectl/helm as the real user (not root)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

kube_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$REAL_HOME/.kube/config" \
    "$@"
}

helm_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$REAL_HOME/.kube/config" \
    XDG_CONFIG_HOME="$REAL_HOME/.config" \
    XDG_CACHE_HOME="$REAL_HOME/.cache" \
    helm "$@"
}

progress 10
log "Adding Kasten Helm repo (user: $REAL_USER)"
helm_u repo add kasten https://charts.kasten.io || true
helm_u repo update

progress 20
log "Ensuring kasten-io namespace exists"
kube_u kubectl get ns kasten-io >/dev/null 2>&1 || kube_u kubectl create ns kasten-io

progress 35
log "Installing K10 (storageClass=longhorn)"
helm_u upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.persistence.storageClass=longhorn \
  --set prometheus.server.persistentVolume.storageClass=longhorn \
  --set service.type=NodePort

progress 60
log "Waiting for K10 pods to be ready"
for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$REAL_HOME/.kube/config" \
    kubectl get pods -n kasten-io --no-headers 2>/dev/null | awk '$2 != $3' | wc -l | xargs || true)

  if [[ "$NOT_READY" == "0" ]]; then
    break
  fi

  if (( i % LOG_EVERY == 0 )); then
    log "K10 pods not ready yet (pending: $NOT_READY)"
  fi

  sleep "$SLEEP_SECONDS"
done

progress 85
log "Getting K10 gateway NodePort"
NODE_PORT=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$REAL_HOME/.kube/config" \
  kubectl get svc -n kasten-io gateway -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)

# If service name differs (some charts), try fallback
if [[ -z "${NODE_PORT}" ]]; then
  NODE_PORT=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$REAL_HOME/.kube/config" \
    kubectl get svc -n kasten-io -o name 2>/dev/null | grep -E 'gateway' | head -n1 | cut -d/ -f2 | xargs \
    | xargs -I{} kubectl get svc -n kasten-io {} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
fi

MASTER_IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
touch "$ACCESS_FILE"

if [[ -n "${MASTER_IP:-}" && -n "${NODE_PORT:-}" ]]; then
  echo "Kasten K10 Dashboard | https://$MASTER_IP:$NODE_PORT | User: N/A | Pass: N/A" >> "$ACCESS_FILE"
  log "K10 dashboard: https://$MASTER_IP:$NODE_PORT"
else
  log "WARNING: Could not determine K10 NodePort (check svc in kasten-io)"
fi

progress 100
log "STEP 09 completed successfully"
