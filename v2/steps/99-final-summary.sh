\#!/usr/bin/env bash
set -Eeuo pipefail

SUMMARY_STEP="$TOTAL_STEPS"
SUMMARY_TITLE="INSTALLATION COMPLETED"

# Dibuja el panel final (100%)
draw_step "$SUMMARY_STEP" "$TOTAL_STEPS" "$SUMMARY_TITLE" 100

ROW=4

# --------------------------------------------------
# Header "final"
# --------------------------------------------------
print_green_line "KASTEN LAB INSTALLATION COMPLETED" "$ROW"; ((ROW+=2))

# --------------------------------------------------
# Time summary
# --------------------------------------------------
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

TOTAL_MIN=$((TOTAL_TIME / 60))
TOTAL_SEC=$((TOTAL_TIME % 60))

print_green_line "Total execution time: ${TOTAL_MIN} min ${TOTAL_SEC} sec" "$ROW"; ((ROW+=2))

# --------------------------------------------------
# Try to detect K10 URL (best-effort)
# - Prefer Ingress LB IP: ingress-nginx-controller EXTERNAL-IP
# - Fallback: read from log (last "K10 URL")
# --------------------------------------------------
K10_URL="N/A"

# Detect kubeconfig to query cluster
KUBECONFIG_CANDIDATES=(
  "$HOME/.kube/config"
  "/root/.kube/config"
)

FOUND_KUBECONFIG=""
for cfg in "${KUBECONFIG_CANDIDATES[@]}"; do
  if [[ -f "$cfg" ]]; then
    FOUND_KUBECONFIG="$cfg"
    break
  fi
done

if [[ -n "$FOUND_KUBECONFIG" ]]; then
  export KUBECONFIG="$FOUND_KUBECONFIG"

  # Try LB External IP from ingress-nginx
  LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${LB_IP:-}" ]]; then
    K10_URL="http://${LB_IP}/"
  fi
fi

get_lan_if() {
 
  local ifc
  ifc="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$ifc" ]] && { echo "$ifc"; return 0; }

}

get_if_ipv4() {
  local ifname="$1"
  ip -o -4 addr show dev "$ifname" scope global 2>/dev/null \
    | awk '{print $4}' | head -n1 | cut -d/ -f1
}

LAN_IF="$(get_lan_if)"

# Fallback: last URL in log if present
if [[ "$K10_URL" == "N/A" && -f "$LOG_FILE" ]]; then
  # Examples you've logged:
  # [INFO] K10 URL (IP): http://192.168.122.200/
  # [INFO] K10 URL: https://k10.192.168.122.nip.io ...
  LAST_URL="$(grep -Eo 'K10 URL[^:]*: (https?://[^ ]+)' "$LOG_FILE" 2>/dev/null | tail -n 1 | sed -E 's/.*: (https?:\/\/[^ ]+).*/\1/' || true)"
  if [[ -n "${LAST_URL:-}" ]]; then
    K10_URL="$LAST_URL"
  fi
fi

print_green_line "Kasten K10 Dashboard: ${K10_URL}" "$ROW" "/k10/#"; ((ROW+=2))
print_green_line "Kasten K10 Dashboard: http://${HOST_LAN_IP}/k10/# "
print_green_line "____________________________________________________"
# --------------------------------------------------
# Logs
# --------------------------------------------------
print_green_line "If you want to check logs available at:" "$ROW"; ((ROW++))
print_green_line "$LOG_FILE" "$ROW"; ((ROW++))
print_green_line "$STEP_LOG_FILE" "$ROW"

# Pausa para que se vea
sleep 4