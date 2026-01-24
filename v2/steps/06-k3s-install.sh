#!/usr/bin/env bash
set -e

STEP_NUM=5
STEP_TITLE="INSTALLING K3S CLUSTER"

SSH_OPTS="-o StrictHostKeyChecking=no"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# Helpers
# --------------------------------------------------
wait_ssh() {
  local ip="$1"
  for i in {1..30}; do
    run_bg echo "Trying SSH with IP $ip"
    if ssh $SSH_OPTS ubuntu@"$ip" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# --------------------------------------------------
# Resolve IPs
# --------------------------------------------------
get_vm_ip() {
  local vm="$1"
  for i in {1..30}; do
    ip=$(sudo virsh domifaddr "$vm" | awk '/ipv4/ {print $4}' | cut -d/ -f1)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 5
  done
  return 1
}

MASTER_IP=$(get_vm_ip k3s-master) || return 1
W1_IP=$(get_vm_ip k3s-worker1)   || return 1
W2_IP=$(get_vm_ip k3s-worker2)   || return 1

if [[ -z "$MASTER_IP" || -z "$W1_IP" || -z "$W2_IP" ]]; then
  log "ERROR: Unable to resolve VM IPs"
  return 1
fi

progress 10
log "Waiting for SSH availability"
#wait_ssh "$MASTER_IP" || { log "ERROR: SSH not ready on master"; return 1; }
#wait_ssh "$W1_IP"     || { log "ERROR: SSH not ready on worker1"; return 1; }
#wait_ssh "$W2_IP"     || { log "ERROR: SSH not ready on worker2"; return 1; }
sleep 15

# --------------------------------------------------
# Install k3s server
# --------------------------------------------------
progress 25
log "Installing k3s server on master ($MASTER_IP)"
ssh $SSH_OPTS ubuntu@"$MASTER_IP" \
  "curl -sfL https://get.k3s.io | sudo sh -s - server --disable traefik"

progress 45
log "Waiting for k3s server to initialize"
sleep 20
log (ssh $SSH_OPTS ubuntu@$MASTER_IP kubectl get nodes -A)

# --------------------------------------------------
# Get token
# --------------------------------------------------
TOKEN=$(ssh $SSH_OPTS ubuntu@"$MASTER_IP" \
  "sudo cat /var/lib/rancher/k3s/server/node-token")

if [[ -z "$TOKEN" ]]; then
  log "ERROR: k3s token not found"
  return 1
fi

# --------------------------------------------------
# Join workers
# --------------------------------------------------
progress 60
log "Joining worker1 ($W1_IP)"
run_bg ssh $SSH_OPTS ubuntu@"$W1_IP" \
  "curl -sfL https://get.k3s.io | sudo K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -"

progress 75
log "Joining worker2 ($W2_IP)"
run_bg ssh $SSH_OPTS ubuntu@"$W2_IP" \
  "curl -sfL https://get.k3s.io | sudo K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -"

# --------------------------------------------------
# Kubeconfig
# --------------------------------------------------
progress 90
log "Fetching kubeconfig"
run_bg sudo mkdir -p /root/.kube
run_bg ssh $SSH_OPTS ubuntu@"$MASTER_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/$MASTER_IP/g" \
  | sudo tee /root/.kube/config >/dev/null
run_bg sudo chmod 600 /root/.kube/config

progress 100
log "STEP 06 completed successfully"
return 0
