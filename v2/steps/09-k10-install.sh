#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING KASTEN K10 (GATEWAY VIA INGRESS)"

MAX_RETRIES=180
SLEEP_SECONDS=5
LOG_EVERY=3

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

# --------------------------------------------------
# Run kubectl/helm as the real user (NOT root)
# --------------------------------------------------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

KUBECONFIG_PATH="$REAL_HOME/.kube/config"
if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  log "ERROR: kubeconfig not found at $KUBECONFIG_PATH"
  exit 1
fi

kube_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$KUBECONFIG_PATH" \
    "$@"
}

helm_u() {
  run_bg sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" \
    KUBECONFIG="$KUBECONFIG_PATH" \
    XDG_CONFIG_HOME="$REAL_HOME/.config" \
    XDG_CACHE_HOME="$REAL_HOME/.cache" \
    helm "$@"
}

# --------------------------------------------------
# Helpers
# --------------------------------------------------
wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-5m}"
  kube_u kubectl rollout status -n "$ns" "$kind/$name" --timeout="$timeout"
}

wait_lb_ip() {
  local ns="$1" svc="$2"
  local ip=""
  for ((i=1; i<=MAX_RETRIES; i++)); do
    ip=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$KUBECONFIG_PATH" \
      kubectl get svc -n "$ns" "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    if (( i % LOG_EVERY == 0 )); then
      log "Waiting for LoadBalancer IP on $ns/$svc..."
    fi
    sleep "$SLEEP_SECONDS"
  done
  return 1
}

# --------------------------------------------------
# MetalLB install + wait (avoid webhook/no endpoints race)
# --------------------------------------------------
progress 10
log "Installing MetalLB"
kube_u kubectl get ns metallb-system >/dev/null 2>&1 || kube_u kubectl create ns metallb-system

helm_u repo add metallb https://metallb.github.io/metallb || true
helm_u repo update
helm_u upgrade --install metallb metallb/metallb -n metallb-system

progress 20
log "Waiting for MetalLB components (controller/speaker/webhook)"
# controller
wait_rollout metallb-system deploy metallb-controller 5m

# speaker is a daemonset
kube_u kubectl rollout status -n metallb-system ds/metallb-speaker --timeout=5m || true

# wait webhook service endpoints (key fix)
for i in {1..60}; do
  EP_COUNT=$(sudo -u "$REAL_USER" -E env HOME="$REAL_HOME" KUBECONFIG="$KUBECONFIG_PATH" \
    kubectl get endpoints -n metallb-system metallb-webhook-service \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | xargs || true)

  if [[ "${EP_COUNT}" != "0" ]]; then
    log "MetalLB webhook endpoints ready ($EP_COUNT)"
    break
  fi

  if (( i % 6 == 0 )); then
    log "Waiting for MetalLB webhook endpoints..."
  fi
  sleep 5
done

# Configure pool based on master IP subnet
MASTER_IP=$(sudo virsh domifaddr k3s-master | awk '/ipv4/ {print $4}' | cut -d/ -f1)
if [[ -z "${MASTER_IP}" ]]; then
  log "ERROR: Unable to resolve k3s-master IP"
  exit 1
fi
SUBNET_PREFIX=$(echo "$MASTER_IP" | awk -F. '{print $1"."$2"."$3}')
METALLB_START="${SUBNET_PREFIX}.200"
METALLB_END="${SUBNET_PREFIX}.240"

progress 30
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

# retry apply (webhook can still race on slow boots)
for i in {1..10}; do
  if kube_u kubectl apply -f /tmp/metallb-pool.yaml; then
    break
  fi
  log "Retrying MetalLB pool apply..."
  sleep 5
done
run_bg rm -f /tmp/metallb-pool.yaml || true

# --------------------------------------------------
# Ingress NGINX (LoadBalancer -> MetalLB)
# --------------------------------------------------
progress 40
log "Installing ingress-nginx (LoadBalancer)"
kube_u kubectl get ns ingress-nginx >/dev/null 2>&1 || kube_u kubectl create ns ingress-nginx

helm_u repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm_u repo update
helm_u upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --set controller.service.type=LoadBalancer

wait_rollout ingress-nginx deploy ingress-nginx-controller 10m

INGRESS_LB_IP="$(wait_lb_ip ingress-nginx ingress-nginx-controller)" || {
  log "ERROR: ingress-nginx LoadBalancer IP not assigned"
  exit 1
}

log "Ingress LB IP: $INGRESS_LB_IP"

# --------------------------------------------------
# K10 install
# --------------------------------------------------
progress 55
log "Installing Kasten K10 (gateway via Ingress, service=ClusterIP)"
helm_u repo add kasten https://charts.kasten.io || true
helm_u repo update

kube_u kubectl get ns kasten-io >/dev/null 2>&1 || kube_u kubectl create ns kasten-io

helm_u upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
#  --set global.persistence.storageClass=longhorn \
#  --set prometheus.server.persistentVolume.storageClass=longhorn \
  --set service.type=ClusterIP

progress 70
log "Waiting for K10 pods to be Ready"

for ((i=1; i<=MAX_RETRIES; i++)); do
  NOT_READY=$(kubectl get pods -n kasten-io --no-headers 2>/dev/null \
    | awk '
      {
        split($2,a,"/"); ready=a[1]; total=a[2];
        status=$3;
        if ((ready<total) || (status!="Running" && status!="Completed")) c++
      }
      END{print c+0}
    ')

  [[ "$NOT_READY" == "0" ]] && break

  if (( i % LOG_EVERY == 0 )); then
    log "K10 pods not ready yet (pending: $NOT_READY)"
  fi
  sleep "$SLEEP_SECONDS"
done

# --------------------------------------------------
# Ingress for K10 gateway (NO host -> IP access)
# Your current svc shows gateway port 80, so we route to 80.
# --------------------------------------------------
progress 85
log "Creating Ingress for K10 gateway (no host, IP access)"
cat > /tmp/k10-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k10
  namespace: kasten-io
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gateway
            port:
              number: 80
EOF

kube_u kubectl apply -f /tmp/k10-ingress.yaml
run_bg rm -f /tmp/k10-ingress.yaml || true

# --------------------------------------------------
# Expose Ingress LB (192.168.122.x) to LAN via host DNAT
# --------------------------------------------------
progress 92
log "Exposing K10 (Ingress LB $INGRESS_LB_IP) to LAN via host firewall"

LAN_IF="$(get_lan_if)"
VIR_IF="virbr0"
HOST_LAN_IP=""
if [[ -n "${LAN_IF}" ]]; then
  HOST_LAN_IP="$(get_if_ipv4 "$LAN_IF" || true)"
fi

if [[ -z "${LAN_IF}" || -z "${HOST_LAN_IP}" ]]; then
  log "WARN: Could not detect LAN interface/IP, skipping DNAT exposure"
elif ! ip link show "$VIR_IF" >/dev/null 2>&1; then
  log "WARN: $VIR_IF not found, skipping DNAT exposure"
else
  enable_ip_forward

  # DNAT: LAN -> LB IP on virbr0
  run_bg sudo bash -c "
    iptables -t nat -C PREROUTING -i '$LAN_IF' -p tcp --dport 80  -j DNAT --to-destination '${INGRESS_LB_IP}:80'  2>/dev/null || \
    iptables -t nat -A PREROUTING -i '$LAN_IF' -p tcp --dport 80  -j DNAT --to-destination '${INGRESS_LB_IP}:80'
    iptables -t nat -C PREROUTING -i '$LAN_IF' -p tcp --dport 443 -j DNAT --to-destination '${INGRESS_LB_IP}:443' 2>/dev/null || \
    iptables -t nat -A PREROUTING -i '$LAN_IF' -p tcp --dport 443 -j DNAT --to-destination '${INGRESS_LB_IP}:443'

    iptables -t nat -C POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80  -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80  -j MASQUERADE
    iptables -t nat -C POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 443 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 443 -j MASQUERADE
  " || true

  # FORWARD rules (clave si UFW está activo)
  run_bg sudo bash -c "
    iptables -C FORWARD -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80  -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80  -j ACCEPT
    iptables -C FORWARD -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 443 -j ACCEPT
    iptables -C FORWARD -i '$VIR_IF' -o '$LAN_IF' -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i '$VIR_IF' -o '$LAN_IF' -m state --state ESTABLISHED,RELATED -j ACCEPT
  " || true

  # Open ports if UFW active
  if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    run_bg sudo ufw allow 80/tcp || true
    run_bg sudo ufw allow 443/tcp || true
  fi

  # Persist rules if netfilter-persistent exists
  if command -v netfilter-persistent >/dev/null 2>&1; then
    run_bg sudo netfilter-persistent save >/dev/null || true
  fi

  log "K10 exposed on LAN: http://${HOST_LAN_IP}/ (DNAT -> ${INGRESS_LB_IP})"
fi


# --------------------------------------------------
# Save access info for summary
# --------------------------------------------------
ACCESS_FILE="/var/log/k10-mj/access-summary.log"
run_bg touch "$ACCESS_FILE" || true

echo "Kasten K10 Dashboard (internal) | http://${INGRESS_LB_IP}/ | User: N/A | Pass: N/A" >> "$ACCESS_FILE"
if [[ -n "${HOST_LAN_IP:-}" ]]; then
  echo "Kasten K10 Dashboard (LAN via host) | http://${HOST_LAN_IP}/ | User: N/A | Pass: N/A" >> "$ACCESS_FILE"
fi
progress 100
log "STEP 09 completed successfully"
log "K10 URL (IP): http://${INGRESS_LB_IP}/k10/#"
log "K10 URL http://${HOST_LAN_IP}/k10/# "
return 0