#!/usr/bin/env bash
set -u

# --------------------------------------------------
# Config
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
  echo "[INFO] Waiting for all nodes Ready..." >> "$LOG_FILE"
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
# Host prerequisites (kernel modules)
# --------------------------------------------------
sudo modprobe br_netfilter
sudo modprobe overlay
echo -e "br_netfilter\noverlay" | sudo tee /etc/modules-load.d/k3s.conf >/dev/null

# --------------------------------------------------
# Install LXD (snap)
# --------------------------------------------------
if ! sudo snap list lxd >/dev/null 2>&1; then
  run_bg sudo snap install lxd
fi
sleep 5

# --------------------------------------------------
# Init LXD (non-interactive)
# --------------------------------------------------
run_bg sudo lxd init --auto

# --------------------------------------------------
# Create containers
# --------------------------------------------------
for n in "${NODES[@]}"; do
  if ! sudo lxc list -c n --format csv | grep -qx "$n"; then
    run_bg sudo lxc launch "$LXD_IMAGE" "$n"
    run_bg sudo lxc config set "$n" security.privileged true
    run_bg sudo lxc config set "$n" security.nesting true
  fi
done
sleep 5

# --------------------------------------------------
# Prereqs inside containers
# --------------------------------------------------
for n in "${NODES[@]}"; do
  lxd_exec "$n" "apt-get update"
  lxd_exec "$n" "apt-get install -y curl ca-certificates open-iscsi nfs-common"
  lxd_exec "$n" "systemctl enable --now iscsid || true"
done

# --------------------------------------------------
# Install k3s server
# --------------------------------------------------
lxd_exec "$SERVER_NODE" "
  systemctl is-active --quiet k3s || \
  (curl -sfL https://get.k3s.io | sh -s - server --disable traefik)
"

# --------------------------------------------------
# Get server IP and token
# --------------------------------------------------
SERVER_IP="$(sudo lxc list "$SERVER_NODE" -c 4 --format csv | awk '{print $1}' | cut -d' ' -f1)"
TOKEN="$(sudo lxc exec "$SERVER_NODE" -- bash -lc \
  "cat /var/lib/rancher/k3s/server/node-token" | tr -d '\r')"

# --------------------------------------------------
# Kubeconfig to host
# --------------------------------------------------
run_bg sudo mkdir -p /root/.kube
run_bg sudo lxc file pull "$SERVER_NODE/etc/rancher/k3s/k3s.yaml" /root/.kube/config
run_bg sudo sed -i "s/127.0.0.1/${SERVER_IP}/g" /root/.kube/config
run_bg sudo chmod 600 /root/.kube/config

# --------------------------------------------------
# Install + fix k3s agents
# --------------------------------------------------
for n in "${AGENT_NODES[@]}"; do
  NODE_IP="$(sudo lxc list "$n" -c 4 --format csv | awk '{print $1}' | cut -d' ' -f1)"

  lxd_exec "$n" "
    systemctl stop k3s-agent 2>/dev/null || true
    mkdir -p /etc/systemd/system/k3s-agent.service.d

    cat >/etc/systemd/system/k3s-agent.service <<EOF
[Unit]
Description=Lightweight Kubernetes
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/k3s agent \
  --server https://${SERVER_IP}:6443 \
  --token ${TOKEN} \
  --node-name ${n} \
  --node-ip ${NODE_IP} \
  --flannel-iface eth0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable k3s-agent
    systemctl restart k3s-agent
  "
done

# --------------------------------------------------
# Wait for nodes
# --------------------------------------------------
wait_nodes_ready

return 0
