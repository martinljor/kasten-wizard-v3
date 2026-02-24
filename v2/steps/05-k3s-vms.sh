#!/usr/bin/env bash
set -e

STEP_NUM=5
STEP_TITLE="CREATING K3S VMs"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

VM_DIR="/var/lib/libvirt/images"
BASE_IMAGE="$VM_DIR/ubuntu-22.04-server-cloudimg-amd64.img"

progress 10
log "Ensuring base cloud image exists"

if [[ ! -f "$BASE_IMAGE" ]]; then
  run_bg wget -O "$BASE_IMAGE" \
    https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img
fi

create_vm() {
  local NAME="$1"
  local VCPU="$2"
  local RAM_MB="$3"

  local DISK_IMG="$VM_DIR/${NAME}.qcow2"
  local SEED_IMG="$VM_DIR/${NAME}-seed.img"

  log "Creating disk for $NAME"
  run_bg qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMG" 40G

  log "Creating cloud-init seed for $NAME"
  cat > /tmp/user-data <<EOF
#cloud-config
hostname: $NAME
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$HOME/.ssh/id_rsa.pub")
package_update: true
package_upgrade: true
EOF

  cloud-localds "$SEED_IMG" /tmp/user-data

  log "Creating VM $NAME"
  run_bg virt-install \
    --name "$NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPU" \
    --disk path="$DISK_IMG",format=qcow2 \
    --disk path="$SEED_IMG",device=cdrom \
    --os-variant ubuntu22.04 \
    --import \
    --network network=default,model=virtio \
    --graphics none \
    --noautoconsole
}

progress 30

# Destroy if already exists
for VM in k3s-master k3s-worker1 k3s-worker2; do
  if sudo virsh dominfo "$VM" >/dev/null 2>&1; then
    log "Removing existing VM $VM"
    run_bg virsh destroy "$VM" || true
    run_bg virsh undefine "$VM" --remove-all-storage || true
  fi
done

progress 40

# Create VMs
create_vm "k3s-master" 2 4096
create_vm "k3s-worker1" 4 8192
create_vm "k3s-worker2" 4 8192

progress 80

log "Waiting for VMs to boot..."
sleep 20

progress 100
log "STEP 05 completed successfully"

return 0