#!/usr/bin/env bash
set -Eeuo pipefail

type run_bg >/dev/null 2>&1 || { echo "run_bg not defined"; exit 1; }

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

run_bg apt-get update -y

run_bg apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  bash-completion \
  jq \
  net-tools \
  open-iscsi \
  nfs-common

run_bg systemctl enable --now iscsid || true

run_bg sysctl -w net.ipv4.ip_forward=1
run_bg sysctl -w fs.inotify.max_user_watches=1048576

log "Disabling swap on host"

run_bg sudo swapoff -a || true
run_bg sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

return 0
