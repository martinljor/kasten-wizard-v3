#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=7
STEP_TITLE="K3S CLUSTER HEALTH CHECK"

EXPECTED_NODES=3
MAX_RETRIES=60
SLEEP_SECONDS=5
LOG_EVERY=2   # cada 10s

progress 10
log "Waiting for $EXPECTED_NODES nodes to register"

NODE_COUNT=0

for ((i=1; i<=MAX_RETRIES; i++)); do
  NODE_COUNT=$(sudo kubectl get nodes --no-headers 2>/dev/null | grep -c '^' || true)

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes detected: $NODE_COUNT / $EXPECTED_NODES"
  fi

  if [ "$NODE_COUNT" -ge "$EXPECTED_NODES" ]; then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

if [ "$NODE_COUNT" -lt "$EXPECTED_NODES" ]; then
  log "ERROR: Nodes did not register in time"
  sudo kubectl get nodes || true
  exit 1
fi

progress 50
log "All nodes registered, waiting for Ready state"

NOT_READY=1

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(sudo kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready"' \
    | grep -c '^' || true)

  READY=$((EXPECTED_NODES - NOT_READY))

  if (( i % LOG_EVERY == 0 )); then
    log "Nodes Ready: $READY / $EXPECTED_NODES"
  fi

  if [ "$NOT_READY" -eq 0 ]; then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

if [ "$NOT_READY" -ne 0 ]; then
  log "ERROR: Not all nodes reached Ready state"
  sudo kubectl get nodes
  exit 1
fi

progress 100
log "STEP 07 completed successfully"
