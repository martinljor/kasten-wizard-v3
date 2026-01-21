#!/usr/bin/env bash
set -Eeuo pipefail

STEP_TITLE="CREATING K3S CLUSTER (VMS)"
TOTAL_PROGRESS_START=10
TOTAL_PROGRESS_READY=90

draw_step 5 5 "$STEP_TITLE" $TOTAL_PROGRESS_START

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# Variables
# --------------------------------------------------
VM_MEM=3072
VM_CPU=2
BASE_IMG="/var/lib/libvirt/images/ubuntu-22.04.qcow2"
IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"

MASTER_NAME="k3s-master"
WORKERS=("k3s-worker1" "k3s-worker2")

# --------------------------------------------------
# Packages
# --------------------------------------------------
log "Installing virtualization packages"
run_bg sudo apt-get update
run_bg sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils \
  bridge-utils \
  qemu-guest-agent

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Network
# --------------------------------------------------
if ! sudo virsh net-info default >/dev/null 2>&1; then
  log "Starting libvirt default network"
  run_bg sudo virsh net-start default
  run_bg sudo virsh net-autostart default
fi

# --------------------------------------------------
# Base image
# --------------------------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
  log "Downloading Ubuntu cloud image"
  run_bg sudo wget -O "$BASE_IMG" \
    https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img
fi

run_bg sudo mkdir -p "$CI_DIR"

# --------------------------------------------------
# Cloud-init templates
# --------------------------------------------------
create_cloud_init() {
  local name=$1 role=$2 master_ip=$3 token=$4

  cat <<EOF | sudo tee "$CI_DIR/$name.yaml" >/dev/null
#cloud-config
hostname: $name
manage_etc_hosts: true
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$role" sh -
EOF

  if [[ "$role" == "agent" ]]; then
    sed -i "/INSTALL_K3S_EXEC/ s|agent|agent --server https://$master_ip:6443 --token $token|" \
      "$CI_DIR/$name.yaml"
  else
    sed -i "/INSTALL_K3S_EXEC/ s|server|server --disable traefik|" \
      "$CI_DIR/$name.yaml"
  fi

  run_bg sudo cloud-localds "$CI_DIR/$name-seed.iso" "$CI_DIR/$name.yaml"
}

# --------------------------------------------------
# Create Master VM
# --------------------------------------------------
log "Creating master VM disk"
run_bg sudo qemu-img create -f qcow2 -F qcow2 \
  -b "$BASE_IMG" "$IMG_DIR/$MASTER_NAME.qcow2"

log "Generating cloud-init for master"
create_cloud_init "$MASTER_NAME" "server" "" ""

log "Launching master VM"
run_bg sudo virt-install \
  --name "$MASTER_NAME" \
  --memory "$VM_MEM" \
  --vcpus "$VM_CPU" \
  --disk path="$IMG_DIR/$MASTER_NAME.qcow2",format=qcow2 \
  --disk path="$CI_DIR/$MASTER_NAME-seed.iso",device=cdrom \
  --os-variant ubuntu22.04 \
  --network network=default \
  --graphics none \
  --noautoconsole \
  --import \
  --boot uefi,hd,menu=off

# --------------------------------------------------
# Wait for Master IP
# --------------------------------------------------
draw_step 5 5 "$STEP_TITLE" 50
log "Waiting for master IP"

MASTER_IP=""
for i in {1..40}; do
  MASTER_IP=$(sudo virsh domifaddr "$MASTER_NAME" \
    | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true)
  [[ -n "$MASTER_IP" ]] && break
  log "Master IP not ready yet (attempt $i)"
  sleep 10
done

if [[ -z "$MASTER_IP" ]]; then
  log "ERROR: Master IP not obtained"
  exit 1
fi

log "Master IP detected: $MASTER_IP"

# --------------------------------------------------
# Wait for K3s token
# --------------------------------------------------
log "Waiting for K3s token"
for i in {1..40}; do
  TOKEN=$(sudo virsh qemu-agent-command "$MASTER_NAME" \
    '{"execute":"guest-exec","arguments":{"path":"cat","arg":["/var/lib/rancher/k3s/server/node-token"],"capture-output":true}}' \
    | grep out-data | cut -d'"' -f4 | base64 -d || true)
  [[ -n "$TOKEN" ]] && break
  sleep 10
done

if [[ -z "$TOKEN" ]]; then
  log "ERROR: K3s token not found"
  exit 1
fi

# --------------------------------------------------
# Create Worker VMs
# --------------------------------------------------
draw_step 5 5 "$STEP_TITLE" 75

for w in "${WORKERS[@]}"; do
  log "Creating worker $w"

  run_bg sudo qemu-img create -f qcow2 -F qcow2 \
    -b "$BASE_IMG" "$IMG_DIR/$w.qcow2"

  create_cloud_init "$w" "agent" "$MASTER_IP" "$TOKEN"

  run_bg sudo virt-install \
    --name "$w" \
    --memory "$VM_MEM" \
    --vcpus "$VM_CPU" \
    --disk path="$IMG_DIR/$w.qcow2",format=qcow2 \
    --disk path="$CI_DIR/$w-seed.iso",device=cdrom \
    --os-variant ubuntu22.04 \
    --network network=default \
    --graphics none \
    --noautoconsole \
    --import \
    --boot uefi,hd,menu=off
done

# --------------------------------------------------
# Final wait
# --------------------------------------------------
draw_step 5 5 "$STEP_TITLE" $TOTAL_PROGRESS_READY
log "Waiting for nodes to join cluster"
sleep 60

draw_step 5 5 "$STEP_TITLE" 100
log "K3s cluster creation completed"

return 0
