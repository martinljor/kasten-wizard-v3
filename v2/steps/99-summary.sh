#!/usr/bin/env bash

END_TS=$(date +%s)
TOTAL_TIME=$((END_TS - START_TS))

echo "================ SUMMARY ================" >> "$LOG_FILE"
echo "Total execution time: ${TOTAL_TIME}s" >> "$LOG_FILE"
echo "Last completed step: $LAST_COMPLETED_STEP / $TOTAL_STEPS" >> "$LOG_FILE"

# Kubernetes status
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get nodes >/dev/null 2>&1; then
    READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)
    TOTAL=$(kubectl get nodes --no-headers | wc -l)
    echo "Kubernetes nodes: $READY / $TOTAL Ready" >> "$LOG_FILE"
  else
    echo "Kubernetes: API not reachable" >> "$LOG_FILE"
  fi
else
  echo "Kubernetes: kubectl not installed" >> "$LOG_FILE"
fi

echo "=========================================" >> "$LOG_FILE"
