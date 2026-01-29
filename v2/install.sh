#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# Load UI
# --------------------------------------------------
clear
source ./ui.sh


START_TS=$(date +%s)
LAST_COMPLETED_STEP=0
trap user_abort INT TERM

EXPECTED_NODES=3
export EXPECTED_NODES


user_abort() {
  CURRENT_TITLE="ABORTED BY USER"
  draw_abort "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_TITLE"
  exit 130
}


# --------------------------------------------------
# Log setup
# --------------------------------------------------
LOG_DIR="/var/log/k10-mj"
LOG_FILE="$LOG_DIR/kubernetes-lab-installer.log"
STEP_LOG_FILE="$LOG_DIR/steps-status.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" "$STEP_LOG_FILE"

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
TOTAL_STEPS=7
CURRENT_STEP=0
CURRENT_TITLE=""

START_TIME=$(date +%s)

# --------------------------------------------------
# Step timers & status
# --------------------------------------------------
step_timer_start() {
  STEP_START_TIME=$(date +%s)
}

step_timer_end() {
  local rc="$1"
  local end elapsed status
  end=$(date +%s)
  elapsed=$((end - STEP_START_TIME))

  if [[ "$rc" -eq 0 ]]; then
    status="OK"
  else
    status="FAILED ($rc)"
  fi

  echo "$(date '+%F %T') | STEP $CURRENT_STEP | $CURRENT_TITLE | $status | ${elapsed}s" \
    >> "$STEP_LOG_FILE"

  echo "[INFO] STEP $CURRENT_STEP completed in ${elapsed}s (status: $status)" \
    >> "$LOG_FILE"
}

# --------------------------------------------------
# Cleanup
# --------------------------------------------------
cleanup() {
  enable_terminal_input
  source ./steps/99-final-summary.sh

  echo
  echo "Logs available at:"
  echo "  $LOG_FILE"
  echo "  $STEP_LOG_FILE"
}
trap cleanup EXIT

# --------------------------------------------------
# Error handler (keeps UI behavior)
# --------------------------------------------------
trap 'step_timer_end $?; draw_error "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_TITLE" "$LOG_FILE"' ERR

# --------------------------------------------------
# Confirmation
# --------------------------------------------------
confirm_start

# ==================================================
# STEP 1 – Environment Validation
# ==================================================
CURRENT_STEP=1
CURRENT_TITLE="ENVIRONMENT VALIDATION"

step_timer_start
draw_step 1 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/01-validate.sh
draw_step 1 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 2 – System Preparation
# ==================================================
CURRENT_STEP=2
CURRENT_TITLE="SYSTEM PREPARATION"

step_timer_start
draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/02-system.sh
draw_step 2 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 3 – Required Tools
# ==================================================
CURRENT_STEP=3
CURRENT_TITLE="INSTALLING REQUIRED TOOLS"

step_timer_start
draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/04-tools.sh
draw_step 3 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 4 – VMs for K3s
# ==================================================
CURRENT_STEP=4
CURRENT_TITLE="CREATING VMS"

step_timer_start
draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/05-k3s-vms.sh
draw_step 4 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 5 – K3s Cluster
# ==================================================
CURRENT_STEP=5
CURRENT_TITLE="INSTALLING K3S CLUSTER"

step_timer_start
draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/06-k3s-install.sh
draw_step 5 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 6 – K3s Health Check
# ==================================================
CURRENT_STEP=6
CURRENT_TITLE="K3S CLUSTER HEALTH CHECK"

step_timer_start
draw_step 6 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/07-health.sh
draw_step 6 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 7 – Final
# ==================================================
CURRENT_STEP=7
CURRENT_TITLE="INSTALLATION COMPLETED"

draw_step 7 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
sleep 2

# --------------------------------------------------
# Total execution time
# --------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "[INFO] Wizard execution time: ${ELAPSED}s" >> "$LOG_FILE"

source ./steps/99-summary.sh


exit 0
