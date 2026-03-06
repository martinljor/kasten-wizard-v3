#!/usr/bin/env bash
set -Eeuo pipefail

type run_bg >/dev/null 2>&1 || { echo "run_bg not defined"; exit 1; }

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

export DEBIAN_FRONTEND=noninteractive

is_apt_busy() {
  pgrep -x apt >/dev/null 2>&1 || \
  pgrep -x apt-get >/dev/null 2>&1 || \
  pgrep -x dpkg >/dev/null 2>&1 || \
  pgrep -f unattended-upgrade >/dev/null 2>&1
}

recover_apt_if_busy() {
  local waited=0
  local max_wait=30

  while is_apt_busy && (( waited < max_wait )); do
    sleep 2
    waited=$((waited + 2))
  done

  if is_apt_busy; then
    log "APT still busy after ${max_wait}s; forcing recovery"
    run_bg killall apt apt-get dpkg unattended-upgrade || true
    sleep 2
  fi

  run_bg dpkg --configure -a || true
  run_bg apt-get -f install -y -o Dpkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || true
}

recover_apt_if_busy

run_bg apt-get update -y -o Dpkg::Use-Pty=0

run_bg apt-get install -y -o Dpkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
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
