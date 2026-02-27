#!/usr/bin/env bash
set -e

STEP_NUM=4
STEP_TITLE="CREATING K3S VMs"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

# --------------------------------------------------
# VM sizing
# --------------------------------------------------
DISK_SIZE="60G"
MASTER_VCPUS=4
MASTER_MEM=6144     # MB (lab profile for 24GB host)
WORKER_VCPUS=2
WORKER_MEM=4096     # MB (lab profile for 24GB host)

IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"

# --------------------------------------------------
# Detect real user + SSH key (IMPORTANT when running with sudo)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_DIR="$REAL_HOME/.ssh"

# Pick an existing key, or create one (rsa) for the REAL user
if [[ -f "$SSH_DIR/id_ed25519.pub" ]]; then
  SSH_PUB="$SSH_DIR/id_ed25519.pub"
elif [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
  SSH_PUB="$SSH_DIR/id_rsa.pub"
else
  log "SSH key not found for $REAL_USER, generating RSA key"
  run_bg sudo -u "$REAL_USER" mkdir -p "$SSH_DIR"
  run_bg sudo -u "$REAL_USER" ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N ""
  SSH_PUB="$SSH_DIR/id_rsa.pub"
fi

SSH_KEY="$(cat "$SSH_PUB")"

progress 10
run_bg sudo mkdir -p "$IMG_DIR" "$CI_DIR"

# --------------------------------------------------
# Base cloud image (Ubuntu 22.04)
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

progress 30
cleanup_vm k3s-master
cleanup_vm k3s-worker1
cleanup_vm k3s-worker2

# --------------------------------------------------
# Cloud-init generator
# --------------------------------------------------
create_cloudinit() {
  local name="$1"

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

  echo "instance-id: $name" > "$CI_DIR/$name-meta-data.yaml"
  echo "local-hostname: $name" >> "$CI_DIR/$name-meta-data.yaml"

  run_bg sudo cloud-localds \
    "$CI_DIR/$name-seed.iso" \
    "$CI_DIR/$name-user-data.yaml" \
    "$CI_DIR/$name-meta-data.yaml"
}

progress 45
log "Preparing cloud-init"
create_cloudinit k3s-master
create_cloudinit k3s-worker1
create_cloudinit k3s-worker2

# --------------------------------------------------
# VM creator (NAT: network=default)
# --------------------------------------------------
create_vm() {
  local name="$1"
  local mem="$2"
  local vcpus="$3"

  log "Creating VM $name"

  run_bg sudo rm -f "$IMG_DIR/$name.qcow2"
  run_bg sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" \
    "$IMG_DIR/$name.qcow2"
  run_bg sudo qemu-img resize "$IMG_DIR/$name.qcow2" "$DISK_SIZE"

  run_bg sudo virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$vcpus" \
    --cpu host-model \
    --disk path="$IMG_DIR/$name.qcow2",format=qcow2 \
    --disk path="$CI_DIR/$name-seed.iso",device=cdrom \
    --os-variant ubuntu22.04 \
    --network network=default,model=virtio \
    --graphics none \
    --import \
    --noautoconsole
}

progress 60
create_vm k3s-master  "$MASTER_MEM" "$MASTER_VCPUS"
create_vm k3s-worker1 "$WORKER_MEM" "$WORKER_VCPUS"
create_vm k3s-worker2 "$WORKER_MEM" "$WORKER_VCPUS"

progress 85
log "Waiting for VMs to boot"
sleep 30

progress 100
log "STEP 05 completed successfully"
return 0