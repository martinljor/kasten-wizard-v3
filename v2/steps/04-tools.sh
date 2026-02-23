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
# Create bridge br0 (NO rollback)
# - Moves current uplink IPv4 config (IP/prefix + gw + DNS) to br0
# -------------------------------------------------
BRIDGE_NAME="br0"
NETPLAN_FILE="/etc/netplan/01-k10-br0.yaml"

if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
  log "Bridge $BRIDGE_NAME not found. Creating it with netplan (NO rollback) and preserving current NIC IP..."

  # Detect uplink interface (default route first)
  UPLINK_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  if [[ -z "${UPLINK_IF:-}" ]]; then
    UPLINK_IF="$(ls /sys/class/net | grep -Ev '^(lo|virbr|vnet|docker|br-|cni|flannel|tun|tap)' | head -n1 || true)"
  fi
  if [[ -z "${UPLINK_IF:-}" ]]; then
    log "ERROR: Unable to detect uplink interface for bridge creation."
    exit 1
  fi
  log "Detected uplink interface: $UPLINK_IF"

  # Current IPv4 (CIDR) and gateway for that interface
  CUR_ADDR="$(ip -4 -o addr show dev "$UPLINK_IF" scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
  CUR_GW="$(ip route show default dev "$UPLINK_IF" 2>/dev/null | awk '{print $3; exit}' || true)"

  # DNS: prefer systemd-resolved per-interface; fallback to /etc/resolv.conf
  DNS_LIST=""
  if command -v resolvectl >/dev/null 2>&1; then
    # Example output:
    # Link 2 (ens34): 172.17.2.7
    DNS_LIST="$(resolvectl dns "$UPLINK_IF" 2>/dev/null \
      | sed -n 's/.*):[[:space:]]*//p' \
      | tr ' ' '\n' \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | xargs || true)"
  fi
  if [[ -z "${DNS_LIST:-}" ]]; then
    DNS_LIST="$(awk '/^nameserver[[:space:]]+/{print $2}' /etc/resolv.conf 2>/dev/null \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | xargs || true)"
  fi

  if [[ -n "${CUR_ADDR:-}" ]]; then
    log "Preserving IPv4: $CUR_ADDR (gw: ${CUR_GW:-none}, dns: ${DNS_LIST:-none})"

    # Build YAML safely with correct indentation
    {
      cat <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${UPLINK_IF}:
      dhcp4: no
      dhcp6: no
  bridges:
    ${BRIDGE_NAME}:
      interfaces: [${UPLINK_IF}]
      addresses: [${CUR_ADDR}]
EOF

      if [[ -n "${CUR_GW:-}" ]]; then
        echo "      gateway4: ${CUR_GW}"
      fi

      if [[ -n "${DNS_LIST:-}" ]]; then
        DNS_YAML="$(echo "$DNS_LIST" | sed 's/[[:space:]]\+/, /g')"
        cat <<EOF
      nameservers:
        addresses: [${DNS_YAML}]
EOF
      fi

      cat <<EOF
      parameters:
        stp: false
        forward-delay: 0
EOF
    } > "$NETPLAN_FILE"

  else
    log "No static IPv4 detected on $UPLINK_IF. Falling back to DHCP on bridge (IP may change)."

    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${UPLINK_IF}:
      dhcp4: no
      dhcp6: no
  bridges:
    ${BRIDGE_NAME}:
      interfaces: [${UPLINK_IF}]
      dhcp4: yes
      parameters:
        stp: false
        forward-delay: 0
EOF
  fi

  chmod 600 "$NETPLAN_FILE"

  log "Applying netplan now (may temporarily drop SSH)"
  netplan apply >> "$LOG_FILE" 2>&1 || { log "ERROR: netplan apply failed"; exit 1; }

  log "Done. Current br0 IPv4:"
  ip -4 addr show "$BRIDGE_NAME" | awk '/inet /{print " - " $2}'
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