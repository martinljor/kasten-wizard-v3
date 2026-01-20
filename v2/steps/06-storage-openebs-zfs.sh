#!/usr/bin/env bash
set -u

NAMESPACE="openebs"
POOL_NAME="openebspool"
POOL_IMG_DIR="/var/lib/openebs-zfs"
POOL_IMG="${POOL_IMG_DIR}/zfs-pool.img"
POOL_SIZE_GB="${POOL_SIZE_GB:-40}"   # podés cambiar con env var

echo "[INFO] Preparing ZFS on host..." >> "$LOG_FILE"

# --------------------------------------------------
# ZFS on host (required)
# --------------------------------------------------
run_bg sudo apt-get update
run_bg sudo apt-get install -y zfsutils-linux

# Load module (safe)
run_bg sudo modprobe zfs

# Create a loopback pool (LAB-friendly)
run_bg sudo mkdir -p "$POOL_IMG_DIR"

if ! sudo zpool list "$POOL_NAME" >/dev/null 2>&1; then
  if [[ ! -f "$POOL_IMG" ]]; then
    run_bg sudo truncate -s "${POOL_SIZE_GB}G" "$POOL_IMG"
  fi

  # Create pool using loop file (idempotent-ish for lab)
  # NOTE: This pool is on the host; in a single-VM lab that's OK.
  run_bg sudo zpool create -f "$POOL_NAME" "$POOL_IMG"
fi

# Make sure pool is healthy
run_bg sudo zpool status "$POOL_NAME"

# --------------------------------------------------
# Install OpenEBS ZFS LocalPV (CSI)
# --------------------------------------------------
run_bg sudo helm repo add openebs https://openebs.github.io/charts
run_bg sudo helm repo update

if ! sudo kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  run_bg sudo kubectl create ns "$NAMESPACE"
fi

# Install chart (idempotent)
if ! sudo helm status zfs-localpv -n "$NAMESPACE" >/dev/null 2>&1; then
  run_bg sudo helm install zfs-localpv openebs/zfs-localpv -n "$NAMESPACE" \
    --set zfsNode.kubeletDir="/var/lib/kubelet" \
    --set zfsPlugin.enable=true \
    --set zfsNode.driverRegistrar.enable=true \
    --set zfsNode.zfs.utilPath="/sbin"
fi

# --------------------------------------------------
# Wait pods Running/Completed (simple loop)
# --------------------------------------------------
echo "[INFO] Waiting for OpenEBS ZFS pods..." >> "$LOG_FILE"

while true; do
  NOT_READY=$(sudo kubectl -n "$NAMESPACE" get pods --no-headers 2>>"$LOG_FILE" \
    | awk '{print $3}' | grep -vE 'Running|Completed' || true)

  if [[ -z "$NOT_READY" ]]; then
    break
  fi

  sudo kubectl -n "$NAMESPACE" get pods >> "$LOG_FILE" 2>&1 || true
  sleep 10
done

# --------------------------------------------------
# Verify StorageClass exists (ZFS LocalPV)
# Common names: openebs-zfspv
# --------------------------------------------------
if ! sudo kubectl get storageclass openebs-zfspv >/dev/null 2>&1; then
  # fallback: any SC containing "zfs"
  if ! sudo kubectl get storageclass -o name | grep -qi zfs; then
    echo "[ERROR] No ZFS StorageClass detected." >> "$LOG_FILE"
    return 1
  fi
fi

return 0
