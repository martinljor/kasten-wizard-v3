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
export STEP_LOG_FILE
export START_TIME

# --------------------------------------------------
# Wizard state
# --------------------------------------------------
TOTAL_STEPS=10
CURRENT_STEP=0
CURRENT_TITLE=""

START_TIME=$(date +%s)

# --------------------------------------------------
# Step state (prevents OK+FAILED duplication)
# --------------------------------------------------
STEP_CLOSED=0
STEP_RC=0

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
  local rc=$?
  enable_terminal_input

  # Show final summary only on successful run.
  # On error, keep the error screen/log context instead of overriding with green summary.
  if [[ "$rc" -eq 0 ]]; then
    source ./steps/99-final-summary.sh || true
  else
    show_cursor || true
  fi

  echo
  echo " "
   echo " "
    echo " "
     echo " "
}
trap cleanup EXIT

# --------------------------------------------------
# Error handler helpers
# --------------------------------------------------
write_fail_summary() {
  local rc="$1"
  local failed_cmd="$2"
  local fail_file="$LOG_DIR/fail-summary.log"

  {
    echo "=== INSTALL FAILED ==="
    echo "timestamp: $(date '+%F %T')"
    echo "step: $CURRENT_STEP"
    echo "title: $CURRENT_TITLE"
    echo "exit_code: $rc"
    echo "command: $failed_cmd"
    echo "log_file: $LOG_FILE"
    echo "step_log_file: $STEP_LOG_FILE"
    echo ""
    echo "--- last 50 lines: $LOG_FILE ---"
    tail -n 50 "$LOG_FILE" 2>/dev/null || true
    echo ""
    echo "--- last 20 lines: $STEP_LOG_FILE ---"
    tail -n 20 "$STEP_LOG_FILE" 2>/dev/null || true
  } > "$fail_file"

  echo "[ERROR] fail summary written to $fail_file" >> "$LOG_FILE"
}

# --------------------------------------------------
# Error handler (keeps UI behavior)
# --------------------------------------------------
trap 'rc=$?;
  failed_cmd=${BASH_COMMAND:-unknown};
  write_fail_summary "$rc" "$failed_cmd";
  # If the current step was already closed/logged, do NOT re-log it as FAILED.
  if [[ "${STEP_CLOSED:-0}" -eq 1 ]]; then
    draw_error "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_TITLE" "$LOG_DIR/fail-summary.log"
    exit "$rc"
  fi
  step_timer_end "$rc"
  draw_error "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_TITLE" "$LOG_DIR/fail-summary.log"
' ERR

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
# STEP 7 – Longhorn Storage
# ==================================================
CURRENT_STEP=7
CURRENT_TITLE="INSTALLING LONGHORN STORAGE"

step_timer_start
draw_step 7 "$TOTAL_STEPS" "$CURRENT_TITLE" 10
source ./steps/08-longhorn.sh
draw_step 7 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end 0
sleep 1

# ==================================================
# STEP 8 – Kasten K10
# ==================================================
CURRENT_STEP=8
CURRENT_TITLE="INSTALLING KASTEN K10"

STEP_CLOSED=0
STEP_RC=0
step_timer_start
draw_step 8 "$TOTAL_STEPS" "$CURRENT_TITLE" 10

source ./steps/09-k10-install.sh || STEP_RC=$?

draw_step 8 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end "$STEP_RC"
STEP_CLOSED=1
sleep 1

# If step 8 failed, stop here (avoid summary masking / double-logging)
if (( STEP_RC != 0 )); then
  exit "$STEP_RC"
fi

# ==================================================
# STEP 9 – MinIO S3 Repository
# ==================================================
CURRENT_STEP=9
CURRENT_TITLE="INSTALLING MINIO S3 REPOSITORY"

STEP_CLOSED=0
STEP_RC=0
step_timer_start
draw_step 9 "$TOTAL_STEPS" "$CURRENT_TITLE" 10

source ./steps/10-s3-minio.sh || STEP_RC=$?

draw_step 9 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end "$STEP_RC"
STEP_CLOSED=1
sleep 1

if (( STEP_RC != 0 )); then
  exit "$STEP_RC"
fi

# ==================================================
# STEP 10 – Kasten Auto Configuration (optional)
# ==================================================
CURRENT_STEP=10
CURRENT_TITLE="KASTEN LOCATION PROFILE AUTOCONFIG"

STEP_CLOSED=0
STEP_RC=0
step_timer_start
draw_step 10 "$TOTAL_STEPS" "$CURRENT_TITLE" 10

source ./steps/11-kasten-autoconfig.sh || STEP_RC=$?

draw_step 10 "$TOTAL_STEPS" "$CURRENT_TITLE" 100
step_timer_end "$STEP_RC"
STEP_CLOSED=1
sleep 1

if (( STEP_RC != 0 )); then
  exit "$STEP_RC"
fi

# --------------------------------------------------
# Total execution time
# --------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "[INFO] Wizard execution time: ${ELAPSED}s" >> "$LOG_FILE"

# Summary should never fail the wizard
source ./steps/99-final-summary.sh || true

exit 0