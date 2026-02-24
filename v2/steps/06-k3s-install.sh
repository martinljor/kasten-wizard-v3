#!/usr/bin/env bash
set -e

STEP_NUM=6
STEP_TITLE="INSTALLING K3S CLUSTER (ANSIBLE)"

progress() {
  draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"
}

log() {
  echo "[INFO] $*" >> "$LOG_FILE"
}

# --------------------------------------------------
# Detect real user (even if script is sudo)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_DIR="$REAL_HOME/.ssh"

log "Detected REAL_USER=$REAL_USER"
log "Detected REAL_HOME=$REAL_HOME"

# --------------------------------------------------
# Detect PRIVATE SSH key (NOT .pub!)
# --------------------------------------------------
if [[ -f "$SSH_DIR/id_ed25519" ]]; then
  SSH_KEY="$SSH_DIR/id_ed25519"
elif [[ -f "$SSH_DIR/id_rsa" ]]; then
  SSH_KEY="$SSH_DIR/id_rsa"
else
  log "ERROR: No SSH private key found in $SSH_DIR"
  exit 1
fi

log "Using SSH private key: $SSH_KEY"

# Safety check: avoid using public key by mistake
if head -n1 "$SSH_KEY" | grep -qE '^ssh-(rsa|ed25519) '; then
  log "ERROR: $SSH_KEY appears to be a public key. Aborting."
  exit 1
fi

# --------------------------------------------------
# Resolve VM IPs (libvirt NAT mode)
# --------------------------------------------------
get_vm_ip() {
  local vm="$1"
  for i in {1..30}; do
    ip=$(sudo virsh domifaddr "$vm" | awk '/ipv4/ {print $4}' | cut -d/ -f1)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 5
  done
  return 1
}

MASTER_IP=$(get_vm_ip k3s-master) || { log "ERROR: master IP not found"; exit 1; }
W1_IP=$(get_vm_ip k3s-worker1)   || { log "ERROR: worker1 IP not found"; exit 1; }
W2_IP=$(get_vm_ip k3s-worker2)   || { log "ERROR: worker2 IP not found"; exit 1; }

log "Master IP: $MASTER_IP"
log "Worker1 IP: $W1_IP"
log "Worker2 IP: $W2_IP"

progress 20

# --------------------------------------------------
# Generate Ansible inventory
# --------------------------------------------------
ANSIBLE_DIR="$(pwd)/ansible"
mkdir -p "$ANSIBLE_DIR"

cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[master]
k3s-master ansible_host=$MASTER_IP

[workers]
k3s-worker1 ansible_host=$W1_IP
k3s-worker2 ansible_host=$W2_IP

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=$SSH_KEY
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

log "Running Ansible playbook"
run_bg ansible-playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/k3s.yml"

progress 70

# --------------------------------------------------
# Fetch kubeconfig properly
# --------------------------------------------------
log "Fetching kubeconfig from k3s-master to host user ($REAL_USER)"

KUBE_DIR="$REAL_HOME/.kube"
run_bg sudo -u "$REAL_USER" mkdir -p "$KUBE_DIR"
run_bg sudo -u "$REAL_USER" chmod 700 "$KUBE_DIR"

# 1) Copy kubeconfig inside master VM to ubuntu home (needs sudo there)
run_bg ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@"$MASTER_IP" \
  "sudo cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/k3s.yaml && \
   sudo chown ubuntu:ubuntu /home/ubuntu/k3s.yaml && \
   sudo chmod 600 /home/ubuntu/k3s.yaml"

# 2) Copy from VM to host
run_bg sudo -u "$REAL_USER" scp -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@"$MASTER_IP":/home/ubuntu/k3s.yaml \
  "$KUBE_DIR/config"

# 3) Replace localhost with real master IP
run_bg sudo -u "$REAL_USER" sed -i "s/127.0.0.1/$MASTER_IP/g" "$KUBE_DIR/config"
run_bg sudo -u "$REAL_USER" chmod 600 "$KUBE_DIR/config"

log "kubeconfig installed at $KUBE_DIR/config"

progress 100
log "STEP 06 completed successfully"

return 0