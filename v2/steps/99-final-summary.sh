#!/usr/bin/env bash
set -Eeuo pipefail

SUMMARY_STEP="$TOTAL_STEPS"
SUMMARY_TITLE="INSTALLATION COMPLETED"

hide_cursor
clear
draw_green_panel
ROW=$((PANEL_TOP + 2))

print_green_line "KASTEN LAB INSTALLATION COMPLETED" "$ROW"; ((ROW+=1))
print_green_line "------------------------------------------------------------" "$ROW"; ((ROW+=2))

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_MIN=$((TOTAL_TIME / 60))
TOTAL_SEC=$((TOTAL_TIME % 60))
print_green_line "Time: ${TOTAL_MIN} min ${TOTAL_SEC} sec" "$ROW"; ((ROW+=2))

K10_URL="N/A"
if [[ -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
  LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${LB_IP:-}" ]] && K10_URL="http://${LB_IP}/"
fi

get_lan_if() {
  local ifc
  ifc="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$ifc" ]] && { echo "$ifc"; return 0; }
}

get_if_ipv4() {
  local ifname="$1"
  ip -o -4 addr show dev "$ifname" scope global 2>/dev/null     | awk '{print $4}' | head -n1 | cut -d/ -f1
}

LAN_IF="$(get_lan_if)"
HOST_LAN_IP=""
if [[ -n "${LAN_IF:-}" ]]; then
  HOST_LAN_IP="$(get_if_ipv4 "$LAN_IF" || true)"
fi

if [[ "$K10_URL" == "N/A" && -f "$LOG_FILE" ]]; then
  LAST_URL="$(grep -Eo 'K10 URL[^:]*: (https?://[^ ]+)' "$LOG_FILE" 2>/dev/null | tail -n 1 | sed -E 's/.*: (https?:\/\/[^ ]+).*/\1/' || true)"
  [[ -n "${LAST_URL:-}" ]] && K10_URL="$LAST_URL"
fi

print_green_line "K10 URLS:" "$ROW"; ((ROW+=1))
print_green_line "- Internal: ${K10_URL}" "$ROW"; ((ROW+=1))
if [[ -n "${HOST_LAN_IP:-}" ]]; then
  print_green_line "- LAN:      http://${HOST_LAN_IP}/k10/#" "$ROW"; ((ROW+=1))
fi
((ROW+=1))

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
if [[ -f "$ACCESS_FILE" ]]; then
  MINIO_EP="$(grep -m1 '^MinIO S3 (master OS)' "$ACCESS_FILE" | sed -E 's#.*\| (http://[^ ]+) \|.*#\1#' || true)"
  MINIO_BUCKET="$(grep -m1 '^MinIO Bucket' "$ACCESS_FILE" | awk -F'\| ' '{print $2}' | xargs || true)"
  if [[ -n "${MINIO_EP:-}" ]]; then
    print_green_line "MINIO S3:" "$ROW"; ((ROW+=1))
    print_green_line "- Endpoint: ${MINIO_EP}" "$ROW"; ((ROW+=1))
    if [[ -n "${MINIO_BUCKET:-}" ]]; then
      print_green_line "- Bucket:   ${MINIO_BUCKET}" "$ROW"; ((ROW+=1))
    fi
    print_green_line "- AccessKey: kasten (secret hidden)" "$ROW"; ((ROW+=1))
  fi
fi

((ROW+=1))
print_green_line "LOGS:" "$ROW"; ((ROW+=1))
print_green_line "- $LOG_FILE" "$ROW"; ((ROW+=1))
print_green_line "- $STEP_LOG_FILE" "$ROW"

show_cursor
sleep 4
