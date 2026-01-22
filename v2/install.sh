#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# Load UI
# --------------------------------------------------
clear
source ./ui.sh

# --------------------------------------------------
# Log setup
# --------------------------------------------------
LOG_DIR="/var/log/k10-mj"
LOG_FILE="$LOG_DIR/kubernetes-lab-installer.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# --------------------------------------------------
# run_bg (exported)
# --------------------------------------------------
run_bg() {
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1
}
export -f run_bg
export LOG_FILE

# --------------------------------------------------
# Wizard state
# --------------------------------------------------
TOTAL_STEPS=6
CURRENT_STEP=0
CURRENT_TITLE=""

# --------------------------------------------------
# Cleanup
# --------------------------------------------------
cleanup() {
  enable_terminal_input
  clear
  echo "Script finished. Logs available at:"
  echo "  $LOG_FILE"
}
trap cleanup EXIT

# --------------------------------------------------
# Error handler
# --------------------------------------------------
trap 'draw_error "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_TITLE" "$LOG_FILE"' ERR

# --------------------------------------------------
# Confirmation
# --------------------------------------------------
confirm_start

# ==================================================
# STEP 1 – Environment Validation
# ==================================================
CURRENT_STEP=1
CURRENT_TITLE="ENVIRONMENT VALIDATION"

draw_step 1 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/01-validate.sh
draw_step 1 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 2 – System Preparation
# ==================================================
CURRENT_STEP=2
CURRENT_TITLE="SYSTEM PREPARATION"

draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/02-system.sh
draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 3 – Required Tools
# ==================================================
CURRENT_STEP=3
CURRENT_TITLE="INSTALLING REQUIRED TOOLS"

draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/04-tools.sh
draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 4 – VMs for K3s
# ==================================================
CURRENT_STEP=4
CURRENT_TITLE="CREATING VMS"

draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/05-k3s-vms.sh
draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 5 – K3s Cluster
# ==================================================
CURRENT_STEP=5
CURRENT_TITLE="INSTALLING K3S CLUSTER"

draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/06-k3s-install.sh
draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 6 – Final
# ==================================================
CURRENT_STEP=6
CURRENT_TITLE="INSTALLATION COMPLETED"

draw_step 6 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 2

exit 0
