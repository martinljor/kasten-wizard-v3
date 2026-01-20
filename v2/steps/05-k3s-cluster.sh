#!/usr/bin/env bash
set -u

# --------------------------------------------------
# Configuration
# --------------------------------------------------
LXD_IMAGE="ubuntu:22.04"
NODES=("k3s-1" "k3s-2" "k3s-3")
SERVER_NODE="k3s-1"
AGENT_NODES=("k3s-2" "k3s-3")

# --------------------------------------------------
# Helpers
# --------------------------------------------------
lxd_exec() {
  local node="$1"; shift
  sudo lxc exec "$node" -- bash -lc "$*" >> "$LOG_FILE" 2>&1
}

wait_nodes_ready() {
  echo "[INFO] Waiting for 3 nodes Ready..." >> "$LOG_FILE"
  while true; do
    COUNT=$(sudo kubectl get nodes --no-headers 2>>"$LOG_FILE" | wc -l | tr -d ' ')
    NOT_READY=$(sudo kubectl get nodes --no-headers 2>>"$LOG_FILE" \
      | awk '{print $2}' | grep -v "Ready" || true)

    if [[ "$COUNT" -ge 3 && -z "$NOT_READY" ]]; then
      break
    fi

    sudo kubectl get nodes >> "$LOG_FILE" 2>&1 || true
    sleep 10
  done
}

# --------------------------------------------------
# Install LXD (snap-based)
# --------------------------------------------------
if ! sudo snap list lxd >/dev/null 2>&1; then
  run_bg sudo snap install lxd
fi

# Allow snap services to settle
sleep 5

# --------------------------------------------------
# Initialize LXD (non-interactive, idempotent)
# --------------------------------------------------
if ! sudo lxc storage list >/dev/null 2>&1; then
  run_bg sudo lxd init --auto
fi

# Ensure default storage pool exists
if ! sudo lxc storage list | awk '{print $1}' | grep -qx default; then
  run_bg sudo lxc storage create default dir
fi

# Ensure default network exists
if ! sudo lxc network list | awk '{print $1}' | grep -qx lxdbr0; then
  run_bg sudo lxc network create lxdbr0
fi

# --------------------------------------------------
# Create containers (privileged + nesting)
# --------------------------------------------------
for n in "${NODES[@]}"; do
  if ! sudo lxc list -c n --format csv | grep -qx "$n"; then
    run_bg sudo lxc launch "$LXD_IMAGE" "$n"
    run_bg sudo lxc config set "$n" security.privileged true
    run_bg sudo lxc config set "$n" security.nesting true
  fi
done

# Give containers time to boot
sleep 5

# --------------------------------------------------
# Prerequisites inside each node
# --------------------------------------------------
for n in "${NODES[@]}"; do
  lxd_exec "$n" "apt-get update"
  lxd_exec "$n" "apt-get install -y curl ca-certificates open-iscsi nfs-common"
  lxd_exec "$n" "systemctl enable --now iscsid || true"
done

# --------------------------------------------------
# Install k3s server
# --------------------------------------------------
lxd_exec "$SERVER_NODE" \
  "systemctl is-active --quiet k3s || (curl -sfL https://get.k3s.io | sh -s - server --disable traefik)"

# --------------------------------------------------
# Retrieve server IP and join token
# --------------------------------------------------
SERVER_IP="$(sudo lxc list "$SERVER_NODE" -c 4 --format csv | awk '{print $1}' | cut -d' ' -f1)"
TOKEN="$(sudo lxc exec "$SERVER_NODE" -- bash -lc "cat /var/lib/rancher/k3s/server/node-token" \
  2>>"$LOG_FILE" | tr -d '\r')"

# --------------------------------------------------
# Configure kubeconfig on host (root)
# --------------------------------------------------
run_bg sudo mkdir -p /root/.kube
run_bg sudo lxc file pull "$SERVER_NODE/etc/rancher/k3s/k3s.yaml" /root/.kube/config
run_bg sudo sed -i "s/127.0.0.1/${SERVER_IP}/g" /root/.kube/config
run_bg sudo chmod 600 /root/.kube/config

# --------------------------------------------------
# Install k3s agents
# --------------------------------------------------
for n in "${AGENT_NODES[@]}"; do
  lxd_exec "$n" \
    "systemctl is-active --quiet k3s-agent || \
     (K3S_URL=https://${SERVER_IP}:6443 K3S_TOKEN=${TOKEN} \
      curl -sfL https://get.k3s.io | sh -s - agent --node-name ${n})"
done

# --------------------------------------------------
# Wait for all nodes to be Ready
# --------------------------------------------------
wait_nodes_ready

return 0
