#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING MINIO (S3 REPOSITORY)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

MINIO_USER="${MINIO_ROOT_USER:-kasten}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-}"
MINIO_BUCKET="${MINIO_BUCKET:-kasten-backups}"
MINIO_DATA_DIR="/var/lib/minio"
MINIO_ENV_FILE="/etc/default/minio"
MINIO_ENDPOINT="http://127.0.0.1:9000"

get_lan_if() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

get_if_ipv4() {
  local ifname="$1"
  ip -o -4 addr show dev "$ifname" scope global 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1
}

if [[ -z "$MINIO_PASS" ]]; then
  MINIO_PASS="$(tr -dc 'A-Za-z0-9!@#%^*()_+=' </dev/urandom | head -c 22)"
fi

progress 10
log "Installing MinIO binaries"

if ! command -v minio >/dev/null 2>&1; then
  run_bg curl -fsSL -o /usr/local/bin/minio https://dl.min.io/server/minio/release/linux-amd64/minio
  run_bg chmod +x /usr/local/bin/minio
fi

if ! command -v mc >/dev/null 2>&1; then
  run_bg curl -fsSL -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc
  run_bg chmod +x /usr/local/bin/mc
fi

progress 25
log "Configuring MinIO service"

run_bg id -u minio >/dev/null 2>&1 || run_bg useradd --system --home /var/lib/minio --shell /usr/sbin/nologin minio
run_bg mkdir -p "$MINIO_DATA_DIR"
run_bg chown -R minio:minio "$MINIO_DATA_DIR"

cat > "$MINIO_ENV_FILE" <<EOF
MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASS}
MINIO_VOLUMES=${MINIO_DATA_DIR}
MINIO_OPTS=--address :9000 --console-address :9001
EOF

cat > /etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO
After=network-online.target
Wants=network-online.target

[Service]
User=minio
Group=minio
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_VOLUMES $MINIO_OPTS
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

run_bg systemctl daemon-reload
run_bg systemctl enable --now minio

progress 45
log "Waiting for MinIO health endpoint"

for _ in {1..30}; do
  if curl -fsS "${MINIO_ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! curl -fsS "${MINIO_ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
  log "ERROR: MinIO is not healthy"
  exit 1
fi

progress 65
log "Creating S3 bucket for Kasten"
run_bg mc alias set local "$MINIO_ENDPOINT" "$MINIO_USER" "$MINIO_PASS"
run_bg mc mb --ignore-existing "local/${MINIO_BUCKET}"

LAN_IF="$(get_lan_if || true)"
HOST_LAN_IP=""
if [[ -n "${LAN_IF}" ]]; then
  HOST_LAN_IP="$(get_if_ipv4 "$LAN_IF" || true)"
fi

# Open firewall ports for LAN access when UFW is active
if ufw status 2>/dev/null | grep -q "Status: active"; then
  run_bg ufw allow 9000/tcp || true
  run_bg ufw allow 9001/tcp || true
fi

progress 85
ACCESS_FILE="/var/log/k10-mj/access-summary.log"
run_bg touch "$ACCESS_FILE" || true

echo "MinIO API | http://${HOST_LAN_IP:-127.0.0.1}:9000 | AccessKey: ${MINIO_USER} | SecretKey: ${MINIO_PASS}" >> "$ACCESS_FILE"
echo "MinIO Console | http://${HOST_LAN_IP:-127.0.0.1}:9001 | AccessKey: ${MINIO_USER} | SecretKey: ${MINIO_PASS}" >> "$ACCESS_FILE"
echo "MinIO Bucket | ${MINIO_BUCKET}" >> "$ACCESS_FILE"

log "MinIO S3 ready at http://${HOST_LAN_IP:-127.0.0.1}:9000 (bucket: ${MINIO_BUCKET})"

progress 100
return 0
