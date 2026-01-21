#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=4
STEP_TITLE="CREATING VMS FOR K3S"

IMG_DIR="/var/lib/libvirt/images"
BASE_IMG=""
ARCH="$(uname -m)"

MASTER_NAME="k3s-master"
WORKERS=("k3s-worker1" "k3s-worker2")

VM_MEM=3072
VM_CPU=2

# --------------------------------------------------
# Detect architecture & image
# --------------------------------------------------
case "$ARCH" in
  x86_64)
    BASE_IMG="${IMG_DIR}/ubuntu-22.04-amd64.img"
    BASE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ;;
  aarch64)
    BASE_IMG="${IMG_DIR}/ubuntu-22.04-arm64.img"
    BASE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
    ;;
  *)
    echo "[ERROR] Unsupported architecture: $ARCH" >> "$LOG_FILE"
    return 1
    ;;
esac

draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 10

# --------------------------------------------------
# Ensure base image
# --------------------------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
  run_bg sudo wget -O "$BASE_IMG" "$BASE_URL"
fi

draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 30

# --------------------------------------------------
# Create qcow2 disks
# --------------------------------------------------
create_disk() {
  local name="$1"
  local disk="${IMG_DIR}/${name}.qcow2"

  if [[ ! -f "$disk" ]]; then
    run_bg sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$disk"
  fi
}

create_disk "$MASTER_NAME"
for w in "${WORKERS[@]}"; do
  create_disk "$w"
done

draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 50

# --------------------------------------------------
# Create VMs
# --------------------------------------------------
create_vm() {
  local name="$1"
  local disk="${IMG_DIR}/${name}.qcow2"

  if sudo virsh list --all | awk '{print $2}' | grep -qx "$name"; then
    return
  fi

  run_bg sudo virt-install \
    --name "$name" \
    --memory "$VM_MEM" \
    --vcpus "$VM_CPU" \
    --disk path="$disk",format=qcow2 \
    --os-variant ubuntu22.04 \
    --network network=default \
    --graphics none \
    --noautoconsole \
    --import \
    --boot uefi,hd,menu=off
}

create_vm "$MASTER_NAME"
for w in "${WORKERS[@]}"; do
  create_vm "$w"
done

draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 100

return 0
