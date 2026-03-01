#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=11
STEP_TITLE="DEPLOY STATELESS DEMO APP (PORT 8080)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

DEMO_NS="demo-app"
ING_NS="ingress-nginx"
DEMO_PORT=8080

progress 10
log "Creating demo namespace"
kubectl get ns "$DEMO_NS" >/dev/null 2>&1 || run_bg kubectl create ns "$DEMO_NS"

progress 25
log "Deploying whoami app"
cat > /tmp/demo-whoami.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:latest
          ports:
            - containerPort: 80
              name: http
          resources:
            requests:
              cpu: "25m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: demo-app
spec:
  selector:
    app: whoami
  ports:
    - name: http
      port: 80
      targetPort: 80
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: demo-app
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /demo
            pathType: Prefix
            backend:
              service:
                name: whoami
                port:
                  number: 80
EOF
run_bg kubectl apply -f /tmp/demo-whoami.yaml
run_bg rm -f /tmp/demo-whoami.yaml || true

progress 45
log "Waiting for whoami rollout"
run_bg kubectl -n "$DEMO_NS" rollout status deploy/whoami --timeout=5m

progress 60
log "Configuring host exposure on port 8080"
INGRESS_LB_IP="$(kubectl -n "$ING_NS" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$INGRESS_LB_IP" ]]; then
  log "ERROR: ingress-nginx LoadBalancer IP not found"
  exit 1
fi

get_lan_if() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

get_if_ipv4() {
  local ifname="$1"
  ip -o -4 addr show dev "$ifname" scope global 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1
}

LAN_IF="$(get_lan_if || true)"
HOST_LAN_IP=""
VIR_IF="virbr0"
if [[ -n "${LAN_IF}" ]]; then
  HOST_LAN_IP="$(get_if_ipv4 "$LAN_IF" || true)"
fi

if [[ -z "$LAN_IF" || -z "$HOST_LAN_IP" ]]; then
  log "ERROR: Unable to detect LAN interface/IP for port 8080 exposure"
  exit 1
fi

run_bg sysctl -w net.ipv4.ip_forward=1
run_bg bash -c "grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf || echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf"

run_bg bash -c "
iptables -t nat -C PREROUTING -i '$LAN_IF' -p tcp --dport ${DEMO_PORT} -j DNAT --to-destination '${INGRESS_LB_IP}:80' 2>/dev/null || \
iptables -t nat -A PREROUTING -i '$LAN_IF' -p tcp --dport ${DEMO_PORT} -j DNAT --to-destination '${INGRESS_LB_IP}:80'
iptables -t nat -C POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80 -j MASQUERADE
iptables -C FORWARD -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80 -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -i '$LAN_IF' -o '$VIR_IF' -p tcp -d '${INGRESS_LB_IP}' --dport 80 -j ACCEPT
iptables -C FORWARD -i '$VIR_IF' -o '$LAN_IF' -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -i '$VIR_IF' -o '$LAN_IF' -m state --state ESTABLISHED,RELATED -j ACCEPT
"

if ! iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport ${DEMO_PORT} -j DNAT --to-destination "${INGRESS_LB_IP}:80" >/dev/null 2>&1; then
  log "ERROR: Failed to install DNAT rule for demo port ${DEMO_PORT}"
  exit 1
fi

progress 80
log "Validating demo endpoint"
run_bg curl -fsS "http://${INGRESS_LB_IP}/demo" >/dev/null

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
run_bg touch "$ACCESS_FILE" || true
echo "Demo App (whoami) | http://${HOST_LAN_IP}:${DEMO_PORT}/demo | Stateless" >> "$ACCESS_FILE"

progress 100
log "STEP 11 completed successfully"
return 0
