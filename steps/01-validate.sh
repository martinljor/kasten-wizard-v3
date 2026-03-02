#!/usr/bin/env bash
set -Eeuo pipefail

type run_bg >/dev/null 2>&1 || { echo "run_bg not defined"; return 1; }

log() {
  echo "[$(date '+%F %T')] [VALIDATION] $*" >> "$LOG_FILE"
}

# --- OS check ---
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
  log "Unsupported OS: $ID"
  return 1
fi
log "OS validation OK ($ID)"

# --- RAM ---
RAM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
if [[ "$RAM_GB" -lt 12 ]]; then
  log "Insufficient RAM: ${RAM_GB}GB"
  return 1
fi
log "RAM validation OK (${RAM_GB}GB)"

# --- CPU ---
CPU_CORES=$(nproc)
if [[ "$CPU_CORES" -lt 4 ]]; then
  log "Insufficient CPU cores: ${CPU_CORES}"
  return 1
fi
log "CPU validation OK (${CPU_CORES} cores)"

# --- IP ---
if ! hostname -I | grep -q .; then
  log "No IP address assigned"
  return 1
fi
log "IP validation OK"

# --- Internet ---
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
  log "No internet connectivity (ping 8.8.8.8 failed)"
  return 1
fi
log "Internet connectivity OK"

return 0

