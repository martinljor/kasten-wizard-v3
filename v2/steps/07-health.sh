#!/usr/bin/env bash
set -e

STEP_NUM=7
STEP_TITLE="K3S CLUSTER HEALTH CHECK"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log_step() {
  echo "[$(date '+%F %T')] [STEP 07] $*" >> "$LOG_FILE"
}

progress 10
log_step "Starting cluster health checks"

# --------------------------------------------------
# Wait for Kubernetes API
# --------------------------------------------------
log_step "Waiting for Kubernetes API to become reachable"

API_READY=0
for i in {1..60}; do
  if kubectl get nodes >/dev/null 2>&1; then
    log_step "Kubernetes API is reachable"
    API_READY=1
    break
  fi
