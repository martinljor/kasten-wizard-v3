#!/usr/bin/env bash
# FINAL SUMMARY – nunca debe fallar

# --------------------------------------------------
# Resolve kubeconfig
# --------------------------------------------------
KUBECONFIG_PATH=""

if [[ -f /root/.kube/config ]]; then
  KUBECONFIG_PATH="/root/.kube/config"
elif [[ -n "${SUDO_USER:-}" && -f "/home/$SUDO_USER/.kube/config" ]]; then
  KUBECONFIG_PATH="/home/$SUDO_USER/.kube/config"
fi

if [[ -n "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

# --------------------------------------------------
# UI
# --------------------------------------------------
STEP_NUM="$TOTAL_STEPS"
STEP_TITLE="INSTALLATION SUMMARY"

draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 100

row=$((PANEL_TOP + 5))

# --------------------------------------------------
# Time summary
# --------------------------------------------------
END_TS=$(date +%s)
TOTAL_TIME=$((END_TS - START_TS))

print_green_line "Summary" "$row"; ((row+=2))
print_green_line "Total execution time : ${TOTAL_TIME}s" "$row"; ((row++))
print_green_line "Last step reached    : $CURRENT_STEP / $TOTAL_STEPS" "$row"; ((row+=2))

# --------------------------------------------------
# Kubernetes status
# --------------------------------------------------
if [[ -n "${KUBECONFIG:-}" ]] && command -v kubectl >/dev/null 2>&1; then
  if kubectl get nodes >/dev/null 2>&1; then
    TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
    READY_NODES=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)
    EXPECTED="${EXPECTED_NODES:-$TOTAL_NODES}"

    if [[ "$READY_NODES" -eq "$EXPECTED" ]]; then
      STATUS="OK"
    else
      STATUS="PARTIAL"
    fi

    print_green_line "Kubernetes nodes     : $READY_NODES / $EXPECTED Ready ($STATUS)" "$row"
  else
    print_green_line "Kubernetes           : kubectl error" "$row"
  fi
else
  print_green_line "Kubernetes           : kubeconfig not found" "$row"
fi

sleep 4
