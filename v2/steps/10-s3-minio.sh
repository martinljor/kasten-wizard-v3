#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING MINIO (S3 SERVICE ON K3S MASTER OS)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

MINIO_USER="${MINIO_ROOT_USER:-kasten}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-}"
MINIO_BUCKET="${MINIO_BUCKET:-kasten-backups}"
MASTER_USER="${MASTER_OS_USER:-ubuntu}"

if [[ -z "$MINIO_PASS" ]]; then
  MINIO_PASS="$(tr -dc 'A-Za-z0-9!@#%^*()_+=' </dev/urandom | head -c 22)"
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

if [[ -f "$REAL_HOME/.ssh/id_ed25519" ]]; then
  SSH_KEY="$REAL_HOME/.ssh/id_ed25519"
elif [[ -f "$REAL_HOME/.ssh/id_rsa" ]]; then
  SSH_KEY="$REAL_HOME/.ssh/id_rsa"
else
  log "ERROR: SSH private key not found for $REAL_USER"
  exit 1
fi

MASTER_IP="$(virsh domifaddr k3s-master 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "$MASTER_IP" ]]; then
  log "ERROR: Could not resolve k3s-master IP from virsh"
  exit 1
fi

MASTER_ENDPOINT="http://${MASTER_IP}:9000"

progress 15
log "Installing MinIO and mc on k3s-master OS (${MASTER_IP})"

run_bg ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$MASTER_USER@$MASTER_IP" "
  set -Eeuo pipefail
  sudo mkdir -p /usr/local/bin /etc/default /var/lib/minio
  if ! command -v minio >/dev/null 2>&1; then
    curl -fsSL -o /tmp/minio https://dl.min.io/server/minio/release/linux-amd64/minio
    sudo install -m 0755 /tmp/minio /usr/local/bin/minio
  fi
  if ! command -v mc >/dev/null 2>&1; then
    curl -fsSL -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc
    sudo install -m 0755 /tmp/mc /usr/local/bin/mc
  fi
" 

progress 35
log "Configuring MinIO systemd service on k3s-master"

run_bg ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$MASTER_USER@$MASTER_IP" "
  set -Eeuo pipefail
  sudo id -u minio >/dev/null 2>&1 || sudo useradd --system --home /var/lib/minio --shell /usr/sbin/nologin minio
  sudo chown -R minio:minio /var/lib/minio
  sudo bash -c 'cat > /etc/default/minio <<EOF
MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASS}
MINIO_VOLUMES=/var/lib/minio
MINIO_OPTS=--address :9000 --console-address :9001
EOF'
  sudo bash -c 'cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO
After=network-online.target
Wants=network-online.target

[Service]
User=minio
Group=minio
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server \$MINIO_VOLUMES \$MINIO_OPTS
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF'
  sudo systemctl daemon-reload
  sudo systemctl enable --now minio
" 

progress 55
log "Waiting for MinIO health on k3s-master"

run_bg ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$MASTER_USER@$MASTER_IP" "
  set -Eeuo pipefail
  for i in \\$(seq 1 40); do
    curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 && exit 0
    sleep 2
  done
  exit 1
"

progress 70
log "Creating S3 bucket for Kasten on MinIO"

run_bg ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$MASTER_USER@$MASTER_IP" "
  set -Eeuo pipefail
  mc alias set local http://127.0.0.1:9000 '${MINIO_USER}' '${MINIO_PASS}'
  mc mb --ignore-existing local/${MINIO_BUCKET}
"

progress 85
ACCESS_FILE="/var/log/k10-mj/access-summary.log"
run_bg touch "$ACCESS_FILE" || true

echo "MinIO S3 (master OS) | ${MASTER_ENDPOINT} | AccessKey: ${MINIO_USER} | SecretKey: ${MINIO_PASS}" >> "$ACCESS_FILE"
echo "MinIO Console (master OS) | http://${MASTER_IP}:9001 | AccessKey: ${MINIO_USER} | SecretKey: ${MINIO_PASS}" >> "$ACCESS_FILE"
echo "MinIO Bucket | ${MINIO_BUCKET}" >> "$ACCESS_FILE"

log "MinIO ready on k3s-master OS: ${MASTER_ENDPOINT} (bucket: ${MINIO_BUCKET})"

progress 100
return 0
