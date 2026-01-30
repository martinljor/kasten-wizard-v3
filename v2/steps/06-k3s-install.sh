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
# Detect real user + SSH key
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_DIR="$REAL_HOME/.ssh"

if [[ -f "$SSH_DIR/id_ed25519" ]]; then
  SSH_KEY="$SSH_DIR/id_ed25519"
elif [[ -f "$SSH_DIR/id_rsa" ]]; then
  SSH_KEY="$SSH_DIR/id_rsa"
else
  log "ERROR: No SSH key found"
  exit 1
fi

# --------------------------------------------------
# Resolve VM IPs
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

MASTER_IP=$(get_vm_ip k3s-master) || exit 1
W1_IP=$(get_vm_ip k3s-worker1)   || exit 1
W2_IP=$(get_vm_ip k3s-worker2)   || exit 1


# --------------------------------------------------
# Generate Ansible inventory (dynamic)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_KEY_PATH="$REAL_HOME/.ssh/id_rsa"


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
ansible_ssh_private_key_file=$SSH_KEY_PATH
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

progress 20
log "Running Ansible playbook"

run_bg ansible-playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/k3s.yml"
progress 70

log "Fetching kubeconfig from k3s-master"

MASTER_IP=$(virsh domifaddr k3s-master \
  | awk '/ipv4/ {print $4}' | cut -d/ -f1)

mkdir -p "$HOME/.kube"

scp -o StrictHostKeyChecking=no \
  ubuntu@"$MASTER_IP":/etc/rancher/k3s/k3s.yaml \
  "$HOME/.kube/config"

sed -i "s/127.0.0.1/$MASTER_IP/" "$HOME/.kube/config"

chmod 600 "$HOME/.kube/config"

log "kubeconfig installed at $HOME/.kube/config"

progress 100
log "STEP 06 completed successfully"
