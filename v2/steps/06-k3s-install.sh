#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=6
STEP_TITLE="INSTALLING K3S CLUSTER (ANSIBLE)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

# --------------------------------------------------
# Detect real user + SSH key
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SSH_DIR="$REAL_HOME/.ssh"

if [[ -f "$SSH_DIR/id_ed25519" ]]; then
  SSH_KEY_PATH="$SSH_DIR/id_ed25519"
elif [[ -f "$SSH_DIR/id_rsa" ]]; then
  SSH_KEY_PATH="$SSH_DIR/id_rsa"
else
  log "ERROR: No SSH private key found in $SSH_DIR (id_ed25519 or id_rsa)"
  exit 1
fi

# --------------------------------------------------
# Helpers: resolve IP by MAC via ARP (bridge-friendly)
# --------------------------------------------------
normalize_mac() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

get_vm_mac() {
  local vm="$1"
  # virsh domiflist output example: vnetX  bridge  br0  virtio  52:54:00:...
  sudo virsh domiflist "$vm" 2>/dev/null | awk '/virtio|e1000|rtl8139/ {print $5; exit}'
}

refresh_neighbor_cache() {
  # Try to populate ARP/neighbor cache by probing likely addresses.
  # We don't know the subnet here, so we just ping broadcast-ish via arping is not guaranteed.
  # Instead: rely on the VM itself emitting ARP when booting; plus try a few harmless commands.
  run_bg ip neigh show >/dev/null 2>&1 || true
}

ip_from_mac() {
  local mac="$1"
  local mac_lc
  mac_lc="$(normalize_mac "$mac")"

  # Prefer 'ip neigh' (works on modern systems)
  ip neigh show 2>/dev/null \
    | awk -v m="$mac_lc" 'BEGIN{IGNORECASE=1} $0 ~ m {print $1; exit}'
}

wait_for_ip_by_mac() {
  local vm="$1"
  local mac="$2"
  local retries="${3:-60}"
  local sleep_s="${4:-5}"

  local ip=""
  for ((i=1; i<=retries; i++)); do
    refresh_neighbor_cache
    ip="$(ip_from_mac "$mac" || true)"

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    if (( i % 3 == 0 )); then
      log "Waiting IP for $vm (MAC=$mac) attempt $i/$retries"
    fi
    sleep "$sleep_s"
  done

  return 1
}

wait_ssh() {
  local ip="$1"
  local retries="${2:-60}"
  local sleep_s="${3:-5}"

  for ((i=1; i<=retries; i++)); do
    if ssh -i "$SSH_KEY_PATH" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      ubuntu@"$ip" "echo OK" >/dev/null 2>&1; then
      return 0
    fi
    if (( i % 3 == 0 )); then
      log "Waiting SSH on $ip attempt $i/$retries"
    fi
    sleep "$sleep_s"
  done
  return 1
}

# --------------------------------------------------
# Resolve MACs
# --------------------------------------------------
progress 10
MASTER_MAC="$(get_vm_mac k3s-master || true)"
W1_MAC="$(get_vm_mac k3s-worker1 || true)"
W2_MAC="$(get_vm_mac k3s-worker2 || true)"

if [[ -z "$MASTER_MAC" || -z "$W1_MAC" || -z "$W2_MAC" ]]; then
  log "ERROR: Unable to resolve one or more VM MAC addresses via virsh domiflist"
  run_bg sudo virsh domiflist k3s-master || true
  run_bg sudo virsh domiflist k3s-worker1 || true
  run_bg sudo virsh domiflist k3s-worker2 || true
  exit 1
fi

log "MACs: master=$MASTER_MAC worker1=$W1_MAC worker2=$W2_MAC"

# --------------------------------------------------
# Wait IPs (bridge-friendly)
# --------------------------------------------------
progress 20
log "Waiting for DHCP IPs (bridge mode) via ARP/MAC discovery"

MASTER_IP="$(wait_for_ip_by_mac k3s-master "$MASTER_MAC" 60 5 || true)"
W1_IP="$(wait_for_ip_by_mac k3s-worker1 "$W1_MAC" 60 5 || true)"
W2_IP="$(wait_for_ip_by_mac k3s-worker2 "$W2_MAC" 60 5 || true)"

if [[ -z "$MASTER_IP" || -z "$W1_IP" || -z "$W2_IP" ]]; then
  log "ERROR: Failed to discover one or more IPs (bridge mode)."
  log "MASTER_IP=$MASTER_IP W1_IP=$W1_IP W2_IP=$W2_IP"
  log "Tip: ensure DHCP is available on your LAN + ESXi portgroup allows promiscuous/MAC changes."
  run_bg ip neigh show || true
  exit 1
fi

log "IPs: master=$MASTER_IP worker1=$W1_IP worker2=$W2_IP"

# --------------------------------------------------
# Wait SSH on nodes
# --------------------------------------------------
progress 30
log "Waiting for SSH availability on all nodes"
wait_ssh "$MASTER_IP" 60 5 || { log "ERROR: SSH not ready on master $MASTER_IP"; exit 1; }
wait_ssh "$W1_IP" 60 5 || { log "ERROR: SSH not ready on worker1 $W1_IP"; exit 1; }
wait_ssh "$W2_IP" 60 5 || { log "ERROR: SSH not ready on worker2 $W2_IP"; exit 1; }

# --------------------------------------------------
# Generate Ansible inventory (dynamic)
# --------------------------------------------------
progress 40
ANSIBLE_DIR="$(pwd)/ansible"
run_bg mkdir -p "$ANSIBLE_DIR"

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
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'
EOF

log "Inventory generated at $ANSIBLE_DIR/inventory.ini"

# --------------------------------------------------
# Run playbook
# --------------------------------------------------
progress 55
log "Running Ansible playbook (k3s.yml)"
run_bg ansible-playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/k3s.yml"

log "Fetching kubeconfig from k3s-master to host user ($REAL_USER)"

# Master IP (ya la tenés calculada antes, pero por seguridad)
MASTER_IP="$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)"
[[ -n "$MASTER_IP" ]] || { log "ERROR: master IP not found"; exit 1; }

# Directorio kube del usuario real (NO root)
KUBE_DIR="$REAL_HOME/.kube"
run_bg sudo -u "$REAL_USER" mkdir -p "$KUBE_DIR"
run_bg sudo -u "$REAL_USER" chmod 700 "$KUBE_DIR"

# 1) En el master: copiar el kubeconfig a /home/ubuntu/k3s.yaml y hacerlo legible
run_bg ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@"$MASTER_IP" \
  "sudo cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/k3s.yaml && sudo chown ubuntu:ubuntu /home/ubuntu/k3s.yaml && sudo chmod 600 /home/ubuntu/k3s.yaml"

# 2) SCP desde ubuntu (ya con permisos)
run_bg sudo -u "$REAL_USER" scp -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@"$MASTER_IP":/home/ubuntu/k3s.yaml \
  "$KUBE_DIR/config"

# 3) Ajustar server IP dentro del kubeconfig (sale con 127.0.0.1)
run_bg sudo -u "$REAL_USER" sed -i "s/127.0.0.1/$MASTER_IP/g" "$KUBE_DIR/config"
run_bg sudo -u "$REAL_USER" chmod 600 "$KUBE_DIR/config"

log "kubeconfig installed at $KUBE_DIR/config"

progress 100
log "STEP 06 completed successfully"