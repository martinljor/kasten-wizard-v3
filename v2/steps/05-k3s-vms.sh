#!/usr/bin/env bash
set -e

STEP_TOTAL=100

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

progress() {
  draw_step 5 "$TOTAL_STEPS" "CREATING K3S CLUSTER (VMS)" "$1"
}

progress 10
log "Installing virtualization packages"
run_bg sudo apt-get update
run_bg sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst cloud-image-utils

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Detect architecture
# --------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
  BASE_IMG="ubuntu-22.04-arm64.img"
else
  IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  BASE_IMG="ubuntu-22.04-amd64.img"
fi

IMG_DIR="/var/lib/libvirt/images"
CI_DIR="/var/lib/libvirt/cloudinit"

run_bg sudo mkdir -p "$IMG_DIR" "$CI_DIR"

progress 25
if [[ ! -f "$IMG_DIR/$BASE_IMG" ]]; then
  log "Downloading Ubuntu base image"
  run_bg sudo wget -O "$IMG_DIR/$BASE_IMG" "$IMG_URL"
fi

# --------------------------------------------------
# Create cloud-init files
# --------------------------------------------------
create_cloudinit() {
  NAME=$1

  cat > "$CI_DIR/$NAME-user-data.yaml" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
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

progress 40
for VM in k3s-master k3s-worker1 k3s-worker2; do
  log "Preparing cloud-init for $VM"
  create_cloudinit "$VM"

  DISK="$IMG_DIR/$VM.qcow2"
  if [[ ! -f "$DISK" ]]; then
    run_bg sudo qemu-img create -f qcow2 -F qcow2 \
      -b "$IMG_DIR/$BASE_IMG" "$DISK"
  fi

  if ! sudo virsh dominfo "$VM" &>/dev/null; then
    log "Creating VM $VM"
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
      --noautoconsole
  fi
done

progress 65
log "Waiting for VMs to boot (cloud-init + DHCP)"
sleep 60

progress 75
ATTEMPTS=0
MAX_ATTEMPTS=30

while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
  IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}')
  if [[ -n "$IP" ]]; then
    log "Master IP detected: $IP"
    break
  fi
  ATTEMPTS=$((ATTEMPTS+1))
  log "Master IP not ready yet (attempt $ATTEMPTS)"
  sleep 10
done

if [[ -z "$IP" ]]; then
  log "ERROR: Master IP not obtained"
  exit 1
fi

progress 90
log "All VMs running and reachable via DHCP"

progress 100
log "STEP 5 completed successfully"
return 0
