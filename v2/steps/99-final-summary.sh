#!/usr/bin/env bash
set -Eeuo pipefail

SUMMARY_STEP="$TOTAL_STEPS"
SUMMARY_TITLE="INSTALLATION COMPLETED"

draw_step "$SUMMARY_STEP" "$TOTAL_STEPS" "$SUMMARY_TITLE" 100
ROW=4

print_green_line "KASTEN LAB INSTALLATION COMPLETED" "$ROW"; ((ROW+=2))

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_MIN=$((TOTAL_TIME / 60))
TOTAL_SEC=$((TOTAL_TIME % 60))
print_green_line "Total execution time: ${TOTAL_MIN} min ${TOTAL_SEC} sec" "$ROW"; ((ROW+=2))

K10_URL="N/A"
if [[ -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
  LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${LB_IP:-}" ]] && K10_URL="http://${LB_IP}/"
fi

if [[ "$K10_URL" == "N/A" && -f "$LOG_FILE" ]]; then
  LAST_URL="$(grep -Eo 'K10 URL[^:]*: (https?://[^ ]+)' "$LOG_FILE" 2>/dev/null | tail -n 1 | sed -E 's/.*: (https?:\/\/[^ ]+).*/\1/' || true)"
  [[ -n "${LAST_URL:-}" ]] && K10_URL="$LAST_URL"
fi

print_green_line "Kasten K10 Dashboard: ${K10_URL}" "$ROW"; ((ROW+=2))
print_green_line "____________________________________________________" "$ROW"; ((ROW+=2))
print_green_line "If you want to check logs available at:" "$ROW"; ((ROW++))
print_green_line "$LOG_FILE" "$ROW"; ((ROW++))
print_green_line "$STEP_LOG_FILE" "$ROW"

sleep 4
