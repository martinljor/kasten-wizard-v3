#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=10
STEP_TITLE="KASTEN LOCATION PROFILE AUTOCONFIG"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

ask_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer
  local row_prompt row_input left

  row_prompt=$((PANEL_TOP + 10))
  row_input=$((PANEL_TOP + 11))
  left="$(panel_left)"

  print_green_line "$prompt [${default}/no]" "$row_prompt"
  tput cup "$row_input" "$((left + 2))"
  printf "${BG_GREEN}${FG_BLACK}> ${RESET}"
  read -r answer || true

  answer="${answer:-$default}"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

progress 10

if ! ask_yes_no "Configure Kasten Location Profile automatically with MinIO?" "yes"; then
  log "STEP 10 skipped by user"
  progress 100
  return 0
fi

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
MINIO_ENV_FILE="/var/log/k10-mj/minio.env"

if [[ ! -f "$MINIO_ENV_FILE" ]]; then
  log "ERROR: $MINIO_ENV_FILE not found; cannot autoconfigure profile"
  exit 1
fi

# shellcheck disable=SC1090
source "$MINIO_ENV_FILE"

if [[ -z "${MINIO_ENDPOINT:-}" || -z "${MINIO_USER:-}" || -z "${MINIO_PASS:-}" || -z "${MINIO_BUCKET:-}" ]]; then
  log "ERROR: MinIO env file missing required values"
  exit 1
fi

progress 35
log "Creating Kasten S3 credentials secret"

cat > /tmp/k10-s3-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: k10-s3-credentials
  namespace: kasten-io
type: Opaque
stringData:
  aws_access_key_id: ${MINIO_USER}
  aws_secret_access_key: ${MINIO_PASS}
EOF
run_bg kubectl apply -f /tmp/k10-s3-secret.yaml
run_bg rm -f /tmp/k10-s3-secret.yaml || true

progress 65
log "Creating/Updating Kasten Location Profile"

cat > /tmp/k10-location-profile.yaml <<EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: minio-auto-profile
  namespace: kasten-io
spec:
  type: Location
  locationSpec:
    type: ObjectStore
    credential:
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-s3-credentials
        namespace: kasten-io
      secretType: AwsAccessKey
    objectStore:
      name: ${MINIO_BUCKET}
      objectStoreType: S3
      endpoint: ${MINIO_ENDPOINT}
      region: us-east-1
      skipSSLVerify: true
EOF
run_bg kubectl apply -f /tmp/k10-location-profile.yaml
run_bg rm -f /tmp/k10-location-profile.yaml || true

progress 85
log "Validating Kasten Location Profile"
run_bg kubectl -n kasten-io get profiles.config.kio.kasten.io minio-auto-profile -o wide

echo "Kasten LocationProfile | minio-auto-profile | Endpoint: ${MINIO_ENDPOINT} | Bucket: ${MINIO_BUCKET}" >> "$ACCESS_FILE"

progress 100
log "STEP 10 completed successfully"
return 0
