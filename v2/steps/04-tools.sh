#!/usr/bin/env bash
set -e

STEP_ID=4
STEP_NAME="TOOLS INSTALLATION"

# Asume:
# - run_bg definido en install.sh
# - TOTAL_STEPS definido
# - draw_step disponible (ui.sh sourceado)

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 10

# -------------------------------------------------
# Base packages
# -------------------------------------------------
run_bg apt-get update -y
draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 20

run_bg apt-get install -y \
  curl \
  gpg \
  apt-transport-https \
  ca-certificates \
  qemu-kvm \
  qemu-utils \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils \
  bridge-utils
draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 30

# -------------------------------------------------
# Ansible installation 
# -------------------------------------------------

log "Installing Ansible"
sudo apt-get update
sudo apt-get install -y ansible

# -------------------------------------------------
# Helm installation 
# -------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  run_bg mkdir -p /usr/share/keyrings

  run_bg bash -c '
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
    | gpg --dearmor \
    | tee /usr/share/keyrings/helm.gpg > /dev/null
  '

  run_bg bash -c '
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] \
    https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
    > /etc/apt/sources.list.d/helm-stable-debian.list
  '

  run_bg apt-get update -y
  run_bg apt-get install -y helm
fi
draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 55

# -------------------------------------------------
# kubectl installation (official Kubernetes repo)
# -------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  run_bg mkdir -p /etc/apt/keyrings

  run_bg bash -c '
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  '

  run_bg bash -c '
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  '

  run_bg apt-get update -y
  run_bg apt-get install -y kubectl
fi
draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 75

# -------------------------------------------------
# k3d installation (official installer)
# -------------------------------------------------
if ! command -v k3d >/dev/null 2>&1; then
  {
    echo "[INFO] Installing k3d..."
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  } >> "$LOG_FILE" 2>&1
fi

# -------------------------------------------------
# Verification
# -------------------------------------------------
run_bg helm version
run_bg kubectl version --client
run_bg k3d version
draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 100

return 0

