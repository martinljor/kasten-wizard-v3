#!/usr/bin/env bash
set -e

STEP_NUM=6
STEP_TITLE="INSTALLING K3S CLUSTER"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# IPs (desde libvirt)
# --------------------------------------------------
MASTER_IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)
W1_IP=$(sudo virsh domifaddr k3s-worker1 | awk '/ipv4/ {print $4}' | cut -d/ -f1)
W2_IP=$(sudo virsh domifaddr k3s-worker2 | awk '/ipv4/ {print $4}' | cut -d/ -f1)

if [[ -z "$MASTER_IP" || -z "$W1_IP" || -z "$W2_IP" ]]; then
  log "ERROR: Unable to resolve VM IPs"
  return 1
fi

progress 10
log "Installing k3s server on master ($MASTER_IP)"

# --------------------------------------------------
# Install k3s server
# --------------------------------------------------
run_bg sudo ssh -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" \
  "curl -sfL https://get.k3s.io | sh -s - server --disable traefik"

progress 35
log "Waiting for k3s server to be ready"

sleep 20

# --------------------------------------------------
# Get token
# --------------------------------------------------
TOKEN=$(sudo ssh -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" \
  "sudo cat /var/lib/rancher/k3s/server/node-token")

if [[ -z "$TOKEN" ]]; then
  log "ERROR: k3s token not found"
  return 1
fi

progress 55
log "Joining worker1 ($W1_IP)"

# --------------------------------------------------
# Join worker1
# --------------------------------------------------
run_bg sudo ssh -o StrictHostKeyChecking=no ubuntu@"$W1_IP" \
  "curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -"

progress 70
log "Joining worker2 ($W2_IP)"

# --------------------------------------------------
# Join worker2
# --------------------------------------------------
run_bg sudo ssh -o StrictHostKeyChecking=no ubuntu@"$W2_IP" \
  "curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -"

progress 85
log "Fetching kubeconfig"

# --------------------------------------------------
# Kubeconfig
# --------------------------------------------------
run_bg sudo mkdir -p /root/.kube
run_bg sudo ssh -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/$MASTER_IP/g" \
  | sudo tee /root/.kube/config >/dev/null

run_bg sudo chmod 600 /root/.kube/config

progress 95
log "Waiting for nodes to register"
sleep 20

progress 100
log "STEP 06 completed successfully"

return 0
