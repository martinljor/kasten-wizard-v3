#!/usr/bin/env bash
set -e

STEP_NUM=4
STEP_TITLE="CREATING VMS FOR K3S"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# SSH key (host)
# --------------------------------------------------
SSH_PUB_KEY="$HOME/.ssh/id_rsa.pub"
if [[ ! -f "$SSH_PUB_KEY" ]]; then
  log "ERROR: SSH public key not found at $SSH_PUB_KEY"
  return 1
fi
SSH_KEY_CONTENT=$(cat "$SSH_PUB_KEY")

# --------------------------------------------------
# Architecture detection
# --------------------------------------------------
ARCH=$(uname -m)
IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"

if [[ "$ARCH" == "aarch64" ]]; then
  BASE_IMG="$IMG_DIR/ubuntu-22.04-arm64.img"
  BASE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
else
  BASE_IMG="$IMG_DIR/ubuntu-22.04-amd64.img"
  BASE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
fi

# --------------------------------------------------
# Packages
# --------------------------------------------------
progress 10
run_bg sudo apt-get update
run_bg sudo apt-get install -y \
  qemu-kvm qemu-utils libvirt-daemon-system \
  libvirt-clients virtinst cloud-image-utils

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Images dirs
# --------------------------------------------------
run_bg sudo mkdir -p "$IMG_DIR" "$CI_DIR"

progress 25
if [[ ! -f "$BASE_IMG" ]]; then
  log "Downloading Ubuntu base image"
  run_bg sudo wget -O "$BASE_IMG" "$BASE_URL"
fi

# --------------------------------------------------
# Cloud-init generator
# --------------------------------------------------
create_cloudinit() {
  local NAME="$1"

  cat > "$CI_DIR/$NAME-user-data.yaml" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $SSH_KEY_CONTENT
ssh_pwauth: false
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  cat > "$CI_DIR/$NAME-meta-data.yaml" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF

  run_bg sudo cloud-localds "$CI_DIR/$NAME-seed.iso" \
    "$CI_DIR/$NAME-user-data.yaml" \
    "$CI_DIR/$NAME-meta-data.yaml"
}

# --------------------------------------------------
# Create VMs
# --------------------------------------------------
progress 40
for VM in k3s-master k3s-worker1 k3s-worker2; do
  log "Preparing VM $VM"
  create_cloudinit "$VM"

  DISK="$IMG_DIR/$VM.qcow2"
  if [[ ! -f "$DISK" ]]; then
    run_bg sudo qemu-img create -f qcow2 -F qcow2 \
      -b "$BASE_IMG" "$DISK"
  fi

  if ! sudo virsh dominfo "$VM" &>/dev/null; then
    run_bg sudo virt-install \
      --name "$VM" \
      --memory 3072 \
      --vcpus 2 \
      --disk path="$DISK",format=qcow2 \
      --disk path="$CI_DIR/$VM-seed.iso",device=cdrom \
      --os-variant ubuntu22.04 \
      --network network=default \
      --graphics none \
      --import \
      --noautoconsole \
      --boot uefi,hd,menu=off
  fi
done

# --------------------------------------------------
# Wait for OS + DHCP
# --------------------------------------------------
progress 70
log "Waiting for VMs to finish OS setup"
sleep 60

progress 90
ATTEMPTS=0
while [[ $ATTEMPTS -lt 20 ]]; do
  IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}')
  [[ -n "$IP" ]] && break
  ATTEMPTS=$((ATTEMPTS+1))
  log "Master IP not ready yet (attempt $ATTEMPTS)"
  sleep 10
done

if [[ -z "$IP" ]]; then
  log "ERROR: Master IP not obtained"
  return 1
fi

progress 100
log "STEP 05 completed successfully"
return 0
