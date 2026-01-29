#!/usr/bin/env bash
set -Eeuo pipefail

SUMMARY_STEP=7
SUMMARY_TITLE="Summary"

draw_step "$SUMMARY_STEP" "$TOTAL_STEPS" "$SUMMARY_TITLE" 100

ROW=5

# --------------------------------------------------
# Time summary
# --------------------------------------------------
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

print_green_line "Total execution time : ${TOTAL_TIME}s" "$ROW"; ((ROW++))
print_green_line "Last step reached    : $CURRENT_STEP / $TOTAL_STEPS" "$ROW"; ((ROW+=2))

# --------------------------------------------------
# Kubeconfig detection
# --------------------------------------------------
KUBECONFIG_CANDIDATES=(
  "$HOME/.kube/config"
  "/root/.kube/config"
  "/etc/rancher/k3s/k3s.yaml"
)

FOUND_KUBECONFIG=""

for cfg in "${KUBECONFIG_CANDIDATES[@]}"; do
  if [[ -f "$cfg" ]]; then
    FOUND_KUBECONFIG="$cfg"
    break
  fi
done

# --------------------------------------------------
# Kubernetes status
# --------------------------------------------------
if [[ -n "$FOUND_KUBECONFIG" ]]; then
  export KUBECONFIG="$FOUND_KUBECONFIG"

  if kubectl cluster-info >/dev/null 2>&1; then
    NODE_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs)
    NODE_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | xargs)

    print_green_line "Kubernetes nodes     : ${NODE_READY} / ${NODE_TOTAL} Ready" "$ROW"
  else
    print_green_line "Kubernetes           : API not reachable" "$ROW"
  fi
else
  print_green_line "Kubernetes           : kubeconfig not found" "$ROW"
fi

((ROW+=2))

# --------------------------------------------------
# Logs
# --------------------------------------------------
print_green_line "Logs available at:" "$ROW"; ((ROW++))
print_green_line "$LOG_FILE" "$ROW"; ((ROW++))
print_green_line "$STEP_LOG_FILE" "$ROW"

sleep 3
