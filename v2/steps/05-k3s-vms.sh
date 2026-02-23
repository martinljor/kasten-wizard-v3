#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=5
STEP_TITLE="CREATING K3S VMS (BRIDGE MODE)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

# --------------------------------------------------
# VM sizing (IMPORTANT)
# --------------------------------------------------
DISK_SIZE="50G"

MASTER_MEM=4096     # 4 GB
WORKER_MEM=8192     # 8 GB

MASTER_VCPUS=4
WORKER_VCPUS=8

# --------------------------------------------------
# Bridge (must exist)
# --------------------------------------------------
BRIDGE_NAME="br0"

# --------------------------------------------------
# Cleanup existing VMs
# --------------------------------------------------
cleanup_vm() {
  local vm="$1"
  if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
    log "Removing existing VM $vm"
    run_bg sudo virsh destroy "$vm" >/dev/null 2>&1 || true
    run_bg sudo virsh undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 || true
  fi
}

progress 5
run_bg cleanup_vm k3s-master
run_bg cleanup_vm k3s-worker1
run_bg cleanup_vm k3s-worker2

# --------------------------------------------------
# Packages
# --------------------------------------------------
progress 10
run_bg sudo apt-get update
run_bg sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Validate bridge exists
# --------------------------------------------------
progress 15
if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
  log "ERROR: Bridge $BRIDGE_NAME not found. Create it first (netplan br0)."
  exit 1
fi

# --------------------------------------------------
# Directories
# --------------------------------------------------
IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"
run_bg sudo mkdir -p "$IMG_DIR" "$CI_DIR"

# --------------------------------------------------
# Architecture detection
# --------------------------------------------------
ARCH="$(uname -m)"
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
# SSH key handling (real sudo user)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_DIR="$REAL_HOME/.ssh"

if [[ ! -f "$SSH_DIR/id_rsa.pub" && ! -f "$SSH_DIR/id_ed25519.pub" ]]; then
  log "SSH key not found, generating RSA key for $REAL_USER"
  run_bg sudo -u "$REAL_USER" mkdir -p "$SSH_DIR"
  run_bg sudo -u "$REAL_USER" ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N ""
fi

if [[ -f "$SSH_DIR/id_ed25519.pub" ]]; then
  SSH_KEY="$(cat "$SSH_DIR/id_ed25519.pub")"
else
  SSH_KEY="$(cat "$SSH_DIR/id_rsa.pub")"
fi

# --------------------------------------------------
# Cloud-init generator
# --------------------------------------------------
create_cloudinit() {
  local name="$1"

  # user-data
  cat > "$CI_DIR/$name-user-data.yaml" <<EOF
#cloud-config
hostname: $name
preserve_hostname: false
manage_etc_hosts: true

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

  # meta-data
  echo "instance-id: $name" > "$CI_DIR/$name-meta-data.yaml"
  echo "local-hostname: $name" >> "$CI_DIR/$name-meta-data.yaml"

  # seed ISO
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

  log "Creating VM $name (RAM=${mem}MB, vCPU=${vcpus}, Disk=${DISK_SIZE}, Net=bridge:${BRIDGE_NAME})"

  run_bg sudo rm -f "$IMG_DIR/$name.qcow2"

  # Create disk from base + resize
  run_bg sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$IMG_DIR/$name.qcow2"
  run_bg sudo qemu-img resize "$IMG_DIR/$name.qcow2" "$DISK_SIZE"

  # Create VM
  run_bg sudo virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$vcpus" \
    --disk path="$IMG_DIR/$name.qcow2",format=qcow2 \
    --disk path="$CI_DIR/$name-seed.iso",device=cdrom \
    --os-variant ubuntu22.04 \
    --network bridge="$BRIDGE_NAME",model=virtio \
    --graphics none \
    --import \
    --noautoconsole
}

progress 55
run_bg create_vm k3s-master  "$MASTER_MEM" "$MASTER_VCPUS"
run_bg create_vm k3s-worker1 "$WORKER_MEM" "$WORKER_VCPUS"
run_bg create_vm k3s-worker2 "$WORKER_MEM" "$WORKER_VCPUS"

# --------------------------------------------------
# Ensure VMs are running
# --------------------------------------------------
progress 75
log "Starting VMs"
for vm in k3s-master k3s-worker1 k3s-worker2; do
  run_bg sudo virsh start "$vm" || true
done

# --------------------------------------------------
# Boot wait
# --------------------------------------------------
progress 90
log "Waiting for VMs to boot"
sleep 45

progress 100
log "STEP 05 completed successfully"