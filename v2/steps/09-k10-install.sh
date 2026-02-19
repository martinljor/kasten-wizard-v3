#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING KASTEN K10 (GATEWAY)"

MAX_RETRIES=180
SLEEP_SECONDS=5
LOG_EVERY=3

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

kube_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$REAL_HOME/.kube/config" \
    "$@"
}

helm_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$REAL_HOME/.kube/config" \
    XDG_CONFIG_HOME="$REAL_HOME/.config" \
    XDG_CACHE_HOME="$REAL_HOME/.cache" \
    helm "$@"
}

# --------------------------------------------------
# Detect libvirt subnet and pick MetalLB pool
# (e.g. 192.168.122.200-192.168.122.240)
# --------------------------------------------------
MASTER_IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)
SUBNET_PREFIX=$(echo "$MASTER_IP" | awk -F. '{print $1"."$2"."$3}')
METALLB_START="${SUBNET_PREFIX}.200"
METALLB_END="${SUBNET_PREFIX}.240"

progress 10
log "Installing MetalLB (LB for bare metal/lab)"
kube_u kubectl get ns metallb-system >/dev/null 2>&1 || kube_u kubectl create ns metallb-system

helm_u repo add metallb https://metallb.github.io/metallb || true
helm_u repo update
helm_u upgrade --install metallb metallb/metallb -n metallb-system

progress 20
log "Configuring MetalLB address pool ${METALLB_START}-${METALLB_END}"
cat > /tmp/metallb-pool.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_START}-${METALLB_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
spec: {}
EOF

kube_u kubectl apply -f /tmp/metallb-pool.yaml
run_bg rm -f /tmp/metallb-pool.yaml

progress 30
log "Installing NGINX Ingress Controller (LoadBalancer via MetalLB)"
kube_u kubectl get ns ingress-nginx >/dev/null 2>&1 || kube_u kubectl create ns ingress-nginx

helm_u repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm_u repo update
helm_u upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --set controller.service.type=LoadBalancer

progress 40
log "Waiting for ingress-nginx controller to be ready"
kube_u kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller --timeout=10m

INGRESS_LB_IP=""
for ((i=1; i<=MAX_RETRIES; i++)); do
  INGRESS_LB_IP=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$REAL_HOME/.kube/config" \
    kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$INGRESS_LB_IP" ]] && break
  if (( i % LOG_EVERY == 0 )); then
    log "Waiting for MetalLB to assign IP to ingress-nginx..."
  fi
  sleep "$SLEEP_SECONDS"
done

if [[ -z "$INGRESS_LB_IP" ]]; then
  log "ERROR: Ingress LoadBalancer IP was not assigned (MetalLB issue)"
  exit 1
fi

progress 55
log "Installing Kasten K10 (service type ClusterIP; exposed via Ingress)"
helm_u repo add kasten https://charts.kasten.io || true
helm_u repo update

kube_u kubectl get ns kasten-io >/dev/null 2>&1 || kube_u kubectl create ns kasten-io

helm_u upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.persistence.storageClass=longhorn \
  --set prometheus.server.persistentVolume.storageClass=longhorn \
  --set service.type=ClusterIP

progress 70
log "Waiting for K10 pods to be ready"
for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$REAL_HOME/.kube/config" \
    kubectl get pods -n kasten-io --no-headers 2>/dev/null | awk '$2 != $3' | wc -l | xargs || true)
  [[ "$NOT_READY" == "0" ]] && break
  if (( i % LOG_EVERY == 0 )); then
    log "K10 pods not ready yet (pending: $NOT_READY)"
  fi
  sleep "$SLEEP_SECONDS"
done

progress 85
log "Creating Ingress for K10 gateway"
HOSTNAME="k10.${SUBNET_PREFIX}.nip.io"

cat > /tmp/k10-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k10
  namespace: kasten-io
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: ${HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gateway
            port:
              number: 8000
EOF

kube_u kubectl apply -f /tmp/k10-ingress.yaml
run_bg rm -f /tmp/k10-ingress.yaml

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
touch "$ACCESS_FILE"
echo "Kasten K10 Dashboard | https://${HOSTNAME} (LB ${INGRESS_LB_IP}) | User: N/A | Pass: N/A" >> "$ACCESS_FILE"

progress 100
log "STEP 09 completed successfully"
log "K10 URL: https://${HOSTNAME} (Ingress LB IP: ${INGRESS_LB_IP})"
