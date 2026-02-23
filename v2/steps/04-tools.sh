#!/usr/bin/env bash
set -Eeuo pipefail

STEP_ID=4
STEP_NAME="TOOLS INSTALLATION"

progress() { draw_step "$STEP_ID" "$TOTAL_STEPS" "$STEP_NAME" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

progress 10

# -------------------------------------------------
# Base packages
# -------------------------------------------------
run_bg apt-get update -y
run_bg apt-get install -y \
  curl \
  gpg \
  apt-transport-https \
  ca-certificates \
  qemu-kvm \
  qemu-utils \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils \
  bridge-utils \
  ansible

# Enable libvirt now (needed later)
run_bg systemctl enable --now libvirtd

progress 30

# -------------------------------------------------
# Create bridge br0 automatically (Ubuntu 24.04+ Netplan)
# - Only if br0 does not exist.
# - Detects primary physical NIC.
# -------------------------------------------------
BRIDGE_NAME="br0"
NETPLAN_FILE="/etc/netplan/01-k10-br0.yaml"

if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
  log "Bridge $BRIDGE_NAME not found. Creating it with netplan..."

  # Detect default route interface (best signal for 'uplink')
  UPLINK_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"

  # Fallback: choose first non-loopback, non-bridge, non-virtual
  if [[ -z "${UPLINK_IF:-}" ]]; then
    UPLINK_IF="$(ls /sys/class/net | grep -Ev '^(lo|virbr|vnet|docker|br-|cni|flannel|tun|tap)' | head -n1 || true)"
  fi

  if [[ -z "${UPLINK_IF:-}" ]]; then
    log "ERROR: Unable to detect uplink interface for bridge creation."
    exit 1
  fi

  log "Detected uplink interface: $UPLINK_IF"

  # Backup any existing file we are about to overwrite
  if [[ -f "$NETPLAN_FILE" ]]; then
    run_bg cp -a "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
  fi

  # Create a dedicated netplan file for br0
  # Note: renderer networkd to ensure bridge works consistently.
  cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${UPLINK_IF}:
      dhcp4: no
  bridges:
    ${BRIDGE_NAME}:
      interfaces: [${UPLINK_IF}]
      dhcp4: yes
      parameters:
        stp: false
        forward-delay: 0
EOF

  run_bg chmod 600 "$NETPLAN_FILE"

  # Apply
  run_bg netplan apply

  # Wait for br0 to appear + get an IP
  for i in {1..30}; do
    if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
      if ip -4 addr show "$BRIDGE_NAME" | grep -q "inet "; then
        break
      fi
    fi
    sleep 1
  done

  if ! ip -4 addr show "$BRIDGE_NAME" | grep -q "inet "; then
    log "ERROR: Bridge $BRIDGE_NAME created but did not obtain an IPv4 address (DHCP)."
    log "Tip: if running under ESXi nested, enable Promiscuous/MAC Changes/Forged Transmits on PortGroup."
    exit 1
  fi

  BR0_IP="$(ip -4 addr show "$BRIDGE_NAME" | awk '/inet /{print $2}' | head -n1)"
  log "Bridge $BRIDGE_NAME is up with IP: $BR0_IP"
else
  BR0_IP="$(ip -4 addr show "$BRIDGE_NAME" | awk '/inet /{print $2}' | head -n1 || true)"
  log "Bridge $BRIDGE_NAME already exists (IP: ${BR0_IP:-none})"
fi

progress 45

# -------------------------------------------------
# Helm installation
# -------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  run_bg mkdir -p /usr/share/keyrings

  run_bg bash -c '
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
    | gpg --dearmor \
    | tee /usr/share/keyrings/helm.gpg > /dev/null
  '

  run_bg bash -c '
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] \
    https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
    > /etc/apt/sources.list.d/helm-stable-debian.list
  '

  run_bg apt-get update -y
  run_bg apt-get install -y helm
fi

progress 60

# -------------------------------------------------
# kubectl installation (official Kubernetes repo)
# -------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  run_bg mkdir -p /etc/apt/keyrings

  run_bg bash -c '
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  '

  run_bg bash -c '
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  '

  run_bg apt-get update -y
  run_bg apt-get install -y kubectl
fi

progress 80

# -------------------------------------------------
# k3d installation (optional; keeping as you had it)
# -------------------------------------------------
if ! command -v k3d >/dev/null 2>&1; then
  log "Installing k3d..."
  run_bg bash -c 'curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash'
fi

progress 90

# -------------------------------------------------
# Verification
# -------------------------------------------------
run_bg helm version
run_bg kubectl version --client
run_bg k3d version
run_bg ip -br addr show "$BRIDGE_NAME" || true

progress 100
return 0