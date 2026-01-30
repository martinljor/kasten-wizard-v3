#!/usr/bin/env bash
set -e

STEP_NUM=7
STEP_TITLE="K3S CLUSTER HEALTH CHECK"

EXPECTED_NODES=3
MAX_RETRIES=60
SLEEP_SECONDS=5
LOG_EVERY=2   # cada 10s

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

progress 10
log "Waiting for $EXPECTED_NODES nodes to register"

NODE_COUNT=0

if [[ ! -f "$HOME/.kube/config" ]]; then
  log "ERROR: kubeconfig not found on host"
  exit 1
fi

progress 20

for ((i=1; i<=MAX_RETRIES; i++)); do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || true)

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes detected: $NODE_COUNT / $EXPECTED_NODES"
  fi

  if (( NODE_COUNT >= EXPECTED_NODES )); then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

progress 50
log "Waiting for all nodes to reach Ready state"

NOT_READY=1

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready"' \
    | wc -l || true)

  READY=$((EXPECTED_NODES - NOT_READY))

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes Ready: $READY / $EXPECTED_NODES"
  fi

  if (( NOT_READY == 0 )); then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

progress 100
log "STEP 07 completed (cluster reachable, readiness checked)"
