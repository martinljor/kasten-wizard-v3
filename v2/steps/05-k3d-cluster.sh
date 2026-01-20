#!/usr/bin/env bash

K3S_SERVER_SERVICE="k3s"
K3S_AGENT_SERVICE="k3s-agent"
K3S_TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

# --------------------------------------------------
# Host prerequisites (required for Longhorn)
# --------------------------------------------------
sudo apt-get update >> "$LOG_FILE" 2>&1
sudo apt-get install -y open-iscsi >> "$LOG_FILE" 2>&1
sudo systemctl enable --now iscsid >> "$LOG_FILE" 2>&1

# --------------------------------------------------
# Install k3s server (idempotent, latest stable)
# --------------------------------------------------
if ! sudo systemctl is-active --quiet "$K3S_SERVER_SERVICE"; then
  {
    echo "[INFO] Installing k3s server (latest stable)..."
    curl -sfL https://get.k3s.io | \
      sudo sh -s - server \
        --disable traefik
  } >> "$LOG_FILE" 2>&1
fi

# --------------------------------------------------
# Wait for server
# --------------------------------------------------
echo "[INFO] Waiting for k3s server to be ready..." >> "$LOG_FILE"
until sudo systemctl is-active --quiet "$K3S_SERVER_SERVICE"; do
  sleep 5
done

# --------------------------------------------------
# Configure kubectl access for root
# --------------------------------------------------
sudo mkdir -p /root/.kube
sudo cp -f "$KUBECONFIG_PATH" /root/.kube/config
sudo chown root:root /root/.kube/config
sudo chmod 600 /root/.kube/config

# --------------------------------------------------
# Read join token
# --------------------------------------------------
K3S_TOKEN="$(sudo cat "$K3S_TOKEN_FILE")"

# --------------------------------------------------
# Install 2 k3s agents on the same VM (idempotent)
# --------------------------------------------------
for i in 1 2; do
  NODE_NAME="k3s-agent-${i}"

  if ! sudo kubectl get nodes "$NODE_NAME" >/dev/null 2>&1; then
    {
      echo "[INFO] Installing k3s agent ${i}..."
      curl -sfL https://get.k3s.io | \
        sudo K3S_URL="https://127.0.0.1:6443" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - agent \
          --node-name "$NODE_NAME"
    } >> "$LOG_FILE" 2>&1
  fi
done

# --------------------------------------------------
# Wait for all nodes to be Ready
# --------------------------------------------------
echo "[INFO] Waiting for all k3s nodes to be Ready..." >> "$LOG_FILE"

while true; do
  NOT_READY=$(sudo kubectl get nodes --no-headers \
    | awk '{print $2}' \
    | grep -v "Ready" || true)

  if [[ -z "$NOT_READY" ]]; then
    break
  fi

  sudo kubectl get nodes >> "$LOG_FILE"
  sleep 10
done

return 0
