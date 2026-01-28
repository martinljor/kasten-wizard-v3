#!/usr/bin/env bash
set -e

# ==================================================
# Global config
# ==================================================
TOTAL_STEPS=7
LOG_DIR="/var/log/k10-mj"
LOG_FILE="$LOG_DIR/k10-lab-installer.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# --------------------------------------------------
# Helpers
# --------------------------------------------------
log() {
  echo "[INFO] $*" | tee -a "$LOG_FILE"
}

draw_step() {
  local step="$1"
  local total="$2"
  local title="$3"
  local percent="$4"

  clear
  echo "KASTEN LAB INSTALLATION"
  echo
  echo "STEP $step / $total"
  echo "$title"
  echo
  printf "[%-40s] %s%%\n" "$(printf '#%.0s' $(seq 1 $((percent / 2))))" "$percent"
  echo
}

# ==================================================
# STEP 01 – Environment validation
# ==================================================
CURRENT_STEP=1
CURRENT_TITLE="ENVIRONMENT VALIDATION"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/01-validate.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 02 – System preparation
# ==================================================
CURRENT_STEP=2
CURRENT_TITLE="SYSTEM PREPARATION"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/02-system.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 03 – Virtualization stack
# ==================================================
CURRENT_STEP=3
CURRENT_TITLE="VIRTUALIZATION STACK"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/03-virtualization.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 04 – Tools
# ==================================================
CURRENT_STEP=4
CURRENT_TITLE="INSTALLING TOOLS"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/04-tools.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 05 – VM provisioning
# ==================================================
CURRENT_STEP=5
CURRENT_TITLE="CREATING K3S VMS"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/05-vms.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 06 – K3s cluster installation
# ==================================================
CURRENT_STEP=6
CURRENT_TITLE="INSTALLING K3S CLUSTER"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/06-k3s-install.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 07 – Cluster health
# ==================================================
CURRENT_STEP=7
CURRENT_TITLE="K3S CLUSTER HEALTH CHECK"

draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/07-health.sh
draw_step $CURRENT_STEP "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 2

log "INSTALLATION COMPLETED SUCCESSFULLY"
exit 0
