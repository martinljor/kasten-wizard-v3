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
# run_bg (exported for sourced steps)
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
TOTAL_STEPS=5
CURRENT_STEP=0
CURRENT_TITLE=""

# --------------------------------------------------
# Cleanup
# --------------------------------------------------
cleanup() {
  enable_terminal_input
  clear
  echo "script finished. See more details on $LOG_DIR/kubernetes-lab-installer.log"
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
rc=$?
if [[ $rc -ne 0 ]]; then false; fi
draw_step 1 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 2 – System Preparation
# ==================================================
CURRENT_STEP=2
CURRENT_TITLE="SYSTEM PREPARATION"

draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/02-system.sh
rc=$?
if [[ $rc -ne 0 ]]; then false; fi
draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 3 – Docker
# ==================================================
CURRENT_STEP=3
CURRENT_TITLE="INSTALLING DOCKER ENGINE"

draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/03-docker.sh
rc=$?
if [[ $rc -ne 0 ]]; then false; fi
draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 4 – Tools
# ==================================================
CURRENT_STEP=4
CURRENT_TITLE="INSTALLING REQUIRED TOOLS"

draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/04-tools.sh
rc=$?
if [[ $rc -ne 0 ]]; then false; fi
draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# ==================================================
# STEP 5 – Cluster (pendiente)
# ==================================================

CURRENT_STEP=5
CURRENT_TITLE="CREATING KUBERNETES CLUSTER"

draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 10

set +e
source ./steps/05-k3d-cluster.sh
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  false
fi

draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 1

# --------------------------------------------------
# Final
# --------------------------------------------------
draw_step "$TOTAL_STEPS" "$TOTAL_STEPS" "INSTALLATION COMPLETED" 100
sleep 2

exit 0

