#!/usr/bin/env bash
set -e

STEP_NUM=4
STEP_TITLE="CREATING K3S VMS (LIBVIRT)"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# Cleanup existing VMs
# --------------------------------------------------
cleanup_vm() {
  local vm="$1"
  if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
    log "Removing existing VM $vm"
    sudo virsh destroy "$vm" >/dev/null 2>&1 || true
    sudo virsh undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 || true
  fi
}

progress 5
cleanup_vm k3s-master
cleanup_vm k3s-worker1
cleanup_vm k3s-worker2

# --------------------------------------------------
# Packages
# --------------------------------------------------
progress 10
log "Installing libvirt packages"
run_bg sudo apt-get update
run_bg sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Directories
# --------------------------------------------------
IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"
run_bg sudo mkdir -p "$IMG_DIR" "$CI_DIR"

# --------------------------------------------------
# Architecture detection
# --------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
  BASE_IMG="$IMG_DIR/ubuntu-22.04-arm64.img"
else
  UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  BASE_IMG="$IMG_DIR/ubuntu-22.04-amd64.img"
fi

progress 20
if [[ ! -f "$BASE_IMG" ]]; then
  log "Downloading Ubuntu cloud image"
  run_bg sudo wget -O "$BASE_IMG" "$UBUNTU_IMG_URL"
fi

# --------------------------------------------------
# SSH key
# --------------------------------------------------
SUDO_USER_HOME=$(eval echo "~$SUDO_USER")

# --------------------------------------------------
# SSH key handling
# --------------------------------------------------
if [[ ! -f "$SUDO_USER_HOME/.ssh/id_rsa.pub" ]]; then
  echo "[INFO] SSH key not found, generating one" >> "$LOG_FILE"

  run_bg sudo -u "$SUDO_USER" mkdir -p "$SUDO_USER_HOME/.ssh"
  run_bg sudo -u "$SUDO_USER" ssh-keygen -t rsa -b 4096 \
    -f "$SUDO_USER_HOME/.ssh/id_rsa" \
    -N ""
fi

SSH_KEY=$(cat "$SUDO_USER_HOME/.ssh/id_rsa.pub")

run_bg echo $SSH_KEY
# --------------------------------------------------
# Cloud-init generator
# --------------------------------------------------
create_cloudinit() {
  local name="$1"
run_bg echo "Start with cloudinit"
run_bg echo $CI_DIR
run_bg echo $name


  cat > "$CI_DIR/$name-user-data.yaml" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $SSH_KEY
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  echo "instance-id: $name" > "$CI_DIR/$name-meta-data.yaml"

  run_bg sudo cloud-localds \
    "$CI_DIR/$name-seed.iso" \
    "$CI_DIR/$name-user-data.yaml" \
    "$CI_DIR/$name-meta-data.yaml"
}

progress 35
log "Preparing cloud-init"
create_cloudinit k3s-master
create_cloudinit k3s-worker1
create_cloudinit k3s-worker2

# --------------------------------------------------
# VM creator
# --------------------------------------------------
create_vm() {
  local name="$1"
  local mem="$2"
  local vcpus="$3"

  log "Creating VM $name"

run_bg sudo rm -f "$IMG_DIR/$name.qcow2"
run_bg sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" \
  "$IMG_DIR/$name.qcow2"


  run_bg sudo virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$vcpus" \
    --disk path="$IMG_DIR/$name.qcow2",format=qcow2 \
    --disk path="$CI_DIR/$name-seed.iso",device=cdrom \
    --os-variant ubuntu22.04 \
    --network network=default \
    --graphics none \
    --import \
    --noautoconsole
}

progress 50
create_vm k3s-master 2048 2
create_vm k3s-worker1 1536 1
create_vm k3s-worker2 1536 1

# --------------------------------------------------
# Ensure VMs are running
# --------------------------------------------------
progress 70
log "Starting VMs"
for vm in k3s-master k3s-worker1 k3s-worker2; do
  run_bg sudo virsh start "$vm" || true
done

# --------------------------------------------------
# Boot wait (realistic)
# --------------------------------------------------
progress 90
log "Waiting for VMs to boot (this may take a few minutes)"
sleep 60

progress 100
log "STEP 05 completed successfully"
return 0
