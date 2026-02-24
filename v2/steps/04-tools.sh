#!/usr/bin/env bash
set -e

STEP_ID=4
STEP_NAME="TOOLS INSTALLATION"

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 10

# -------------------------------------------------
# Base packages
# -------------------------------------------------

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
  bridge-utils \
  ansible

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 30

# -------------------------------------------------
# Enable & start libvirt
# -------------------------------------------------
run_bg systemctl enable --now libvirtd

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 40

# -------------------------------------------------
# Ensure default NAT network exists
# -------------------------------------------------
if ! sudo virsh net-info default >/dev/null 2>&1; then
  run_bg virsh net-define /usr/share/libvirt/networks/default.xml
fi

run_bg virsh net-autostart default
run_bg virsh net-start default || true

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 50

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

  #run_bg apt-get update -y
  run_bg apt-get install -y helm
fi

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 70

# -------------------------------------------------
# kubectl installation
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

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 85

# -------------------------------------------------
# Verification
# -------------------------------------------------
run_bg helm version
run_bg kubectl version --client

draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" 100

return 0