#!/usr/bin/env bash
set -e

STEP_NUM=7
STEP_TITLE="K3S CLUSTER HEALTH CHECK"

EXPECTED_NODES=3
MAX_RETRIES=30
SLEEP_SECONDS=10
LOG_EVERY=2   # cada 10s

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

# --------------------------------------------------
# Detect real user kubeconfig
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
KUBECONFIG_PATH="$REAL_HOME/.kube/config"

progress 10

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  run_bg "WARN: kubeconfig not found at $KUBECONFIG_PATH"
  run_bg "STEP 07 skipped (cluster not reachable from host)"
  progress 100
  exit 0
fi

export KUBECONFIG="$KUBECONFIG_PATH"

# --------------------------------------------------
# Wait for nodes to register
# --------------------------------------------------
progress 20
run_bg "Waiting for $EXPECTED_NODES nodes to register"

NODE_COUNT=0

for ((i=1; i<=MAX_RETRIES; i++)); do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || true)

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes detected: $NODE_COUNT / $EXPECTED_NODES"
  fi

  (( NODE_COUNT >= EXPECTED_NODES )) && break
  sleep "$SLEEP_SECONDS"
done

# --------------------------------------------------
# Wait for Ready state
# --------------------------------------------------
progress 50
log "Waiting for all nodes to reach Ready state"

NOT_READY=1

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready"' \
    | wc -l || true)

  READY=$((NODE_COUNT - NOT_READY))

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes Ready: $READY / $NODE_COUNT"
  fi

  (( NOT_READY == 0 )) && break
  sleep "$SLEEP_SECONDS"
done

progress 100
log "STEP 07 completed (cluster reachable, readiness checked)"
