#!/usr/bin/env bash
set -u

# --------------------------------------------------
# Step metadata (wizard)
# --------------------------------------------------
STEP_NUM=5
STEP_TITLE="CREATING K3S CLUSTER (VMS)"

# --------------------------------------------------
# Configuration
# --------------------------------------------------
VM_DIR="/var/lib/libvirt/images"
CLOUDINIT_DIR="/var/lib/libvirt/cloudinit"
BASE_IMG="${VM_DIR}/ubuntu-22.04.qcow2"

MASTER_NAME="k3s-master"
WORKERS=("k3s-worker1" "k3s-worker2")

MASTER_RAM=3072
WORKER_RAM=3072
VCPU=2

# --------------------------------------------------
# Progress: 10% – Dependencies
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 10

run_bg sudo apt-get update
run_bg sudo apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst cloud-image-utils bridge-utils

run_bg sudo systemctl enable --now libvirtd

# --------------------------------------------------
# Progress: 25% – Base image
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 25

if [[ ! -f "$BASE_IMG" ]]; then
  run_bg sudo wget -O "$BASE_IMG" \
    https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi

run_bg sudo mkdir -p "$CLOUDINIT_DIR"

# --------------------------------------------------
# Cloud-init templates
# --------------------------------------------------
create_cloudinit() {
  local name="$1"
  local role="$2"

  cat <<EOF | sudo tee "${CLOUDINIT_DIR}/${name}.yaml" >/dev/null
#cloud-config
hostname: ${name}
manage_etc_hosts: true

package_update: true
packages:
  - curl
  - open-iscsi
  - nfs-common

runcmd:
  - systemctl enable --now iscsid
  - |
    if [ "${role}" = "master" ]; then
      curl -sfL https://get.k3s.io | sh -s - server --disable traefik
    fi
EOF
}

create_cloudinit "$MASTER_NAME" "master"
for w in "${WORKERS[@]}"; do
  create_cloudinit "$w" "worker"
done

# --------------------------------------------------
# Progress: 45% – Create VMs
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 45

create_vm() {
  local name="$1"
  local ram="$2"

  local disk="${VM_DIR}/${name}.qcow2"
  local seed="${CLOUDINIT_DIR}/${name}-seed.iso"

  [[ -f "$disk" ]] || run_bg sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$disk"
  run_bg sudo cloud-localds "$seed" "${CLOUDINIT_DIR}/${name}.yaml"

  if ! sudo virsh list --all | awk '{print $2}' | grep -qx "$name"; then
    run_bg sudo virt-install \
      --name "$name" \
      --memory "$ram" \
      --vcpus "$VCPU" \
      --disk path="$disk",format=qcow2 \
      --disk path="$seed",device=cdrom \
      --os-variant ubuntu22.04 \
      --network network=default \
      --graphics none \
      --noautoconsole \
      --import
  fi
}

create_vm "$MASTER_NAME" "$MASTER_RAM"
for w in "${WORKERS[@]}"; do
  create_vm "$w" "$WORKER_RAM"
done

# --------------------------------------------------
# Progress: 65% – k3s server ready
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 75
echo "[INFO] Waiting for master IP..." >> "$LOG_FILE"

MASTER_IP=""
for i in {1..30}; do
  MASTER_IP=$(sudo virsh domifaddr "$MASTER_NAME" \
    | awk '/ipv4/ {print $4}' | cut -d/ -f1)

  if [[ -n "$MASTER_IP" ]]; then
    echo "[INFO] Master IP detected: $MASTER_IP" >> "$LOG_FILE"
    break
  fi

  echo "[INFO] Master IP not ready yet (attempt $i)..." >> "$LOG_FILE"
  sleep 10
done

if [[ -z "$MASTER_IP" ]]; then
  echo "[ERROR] Timed out waiting for master IP" >> "$LOG_FILE"
  return 1
fi


# --------------------------------------------------
# Progress: 85% – Join workers
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 85

TOKEN=$(ssh -o StrictHostKeyChecking=no \
  ubuntu@"$MASTER_IP" \
  sudo cat /var/lib/rancher/k3s/server/node-token)

for w in "${WORKERS[@]}"; do
  IP=$(sudo virsh domifaddr "$w" | awk '/ipv4/ {print $4}' | cut -d/ -f1)

  ssh -o StrictHostKeyChecking=no ubuntu@"$IP" "
    curl -sfL https://get.k3s.io | \
    K3S_URL=https://${MASTER_IP}:6443 \
    K3S_TOKEN=${TOKEN} \
    sh -
  "
done

# --------------------------------------------------
# Kubeconfig
# --------------------------------------------------
run_bg sudo mkdir -p /root/.kube
ssh -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" \
  sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/${MASTER_IP}/g" \
  | sudo tee /root/.kube/config >/dev/null

run_bg sudo chmod 600 /root/.kube/config

# --------------------------------------------------
# Progress: 100% – Nodes Ready
# --------------------------------------------------
draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" 100

return 0
