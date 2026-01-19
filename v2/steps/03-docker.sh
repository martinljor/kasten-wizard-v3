#!/usr/bin/env bash
set -Eeuo pipefail

type run_bg >/dev/null 2>&1 || { echo "run_bg not defined"; return 1; }


# Remove old versions (non-fatal)
run_bg apt-get remove -y docker docker-engine docker.io containerd runc || true

# Prereqs
run_bg apt-get install -y ca-certificates curl gnupg
# Keyrings
run_bg install -m 0755 -d /etc/apt/keyrings

# Docker GPG key (only if not exists)
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  run_bg bash -c '
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  '
  run_bg chmod a+r /etc/apt/keyrings/docker.gpg
fi
# Docker repo
run_bg bash -c '
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
'

run_bg apt-get update -y

# Install Docker
run_bg apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Enable Docker
run_bg systemctl enable --now docker

# Docker group (non-fatal)
run_bg usermod -aG docker "${SUDO_USER:-$USER}" || true

return 0

