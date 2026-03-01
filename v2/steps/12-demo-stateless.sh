#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=11
STEP_TITLE="DEPLOY STATELESS LAB STATUS (PORT 8080)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

DEMO_NS="demo-app"
APP_NAME="lab-status"
ING_NS="ingress-nginx"
DEMO_PORT=8080

progress 10
log "Creating demo namespace"
kubectl get ns "$DEMO_NS" >/dev/null 2>&1 || run_bg kubectl create ns "$DEMO_NS"

progress 20
log "Deploying stateless lab-status service"
cat > /tmp/demo-lab-status.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lab-status-sa
  namespace: demo-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-status-read
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "namespaces"]
    verbs: ["get", "list"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["nodes", "pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-status-read-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lab-status-read
subjects:
  - kind: ServiceAccount
    name: lab-status-sa
    namespace: demo-app
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-status-app
  namespace: demo-app
data:
  app.py: |
    import datetime
    import html
    import json
    import os
    import ssl
    import urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    API = "https://kubernetes.default.svc"
    TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

    def k8s_get(path):
      token = open(TOKEN_PATH, "r", encoding="utf-8").read().strip()
      req = urllib.request.Request(API + path)
      req.add_header("Authorization", f"Bearer {token}")
      ctx = ssl.create_default_context(cafile=CA_PATH)
      with urllib.request.urlopen(req, context=ctx, timeout=6) as r:
        return json.loads(r.read().decode("utf-8"))

    def fmt_resources(nodes, metrics):
      by_name = {i.get("metadata", {}).get("name"): i for i in metrics.get("items", [])}
      rows = []
      for n in nodes.get("items", []):
        name = n.get("metadata", {}).get("name", "-")
        cap_cpu = n.get("status", {}).get("capacity", {}).get("cpu", "-")
        cap_mem = n.get("status", {}).get("capacity", {}).get("memory", "-")
        m = by_name.get(name, {})
        used_cpu = m.get("usage", {}).get("cpu", "n/a")
        used_mem = m.get("usage", {}).get("memory", "n/a")
        rows.append((name, cap_cpu, cap_mem, used_cpu, used_mem))
      return rows

    def pod_health(pods):
      total = len(pods.get("items", []))
      not_ready = 0
      by_ns = {}
      for p in pods.get("items", []):
        ns = p.get("metadata", {}).get("namespace", "default")
        phase = p.get("status", {}).get("phase", "Unknown")
        cs = p.get("status", {}).get("containerStatuses", [])
        ready = bool(cs) and all(c.get("ready", False) for c in cs)
        if phase != "Running" or not ready:
          not_ready += 1
          by_ns[ns] = by_ns.get(ns, 0) + 1
      return total, not_ready, by_ns

    class H(BaseHTTPRequestHandler):
      def do_GET(self):
        try:
          nodes = k8s_get("/api/v1/nodes")
          pods = k8s_get("/api/v1/pods")
          try:
            metrics = k8s_get("/apis/metrics.k8s.io/v1beta1/nodes")
          except Exception:
            metrics = {"items": []}

          rows = fmt_resources(nodes, metrics)
          total, not_ready, by_ns = pod_health(pods)

          now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
          lines = []
          lines.append("<h1>Lab Status</h1>")
          lines.append(f"<p><b>Updated:</b> {html.escape(now)}</p>")
          lines.append(f"<p><b>Pods:</b> total={total}, not-ready={not_ready}</p>")

          if by_ns:
            lines.append("<p><b>Not-ready by namespace:</b></p><ul>")
            for ns, c in sorted(by_ns.items()):
              lines.append(f"<li>{html.escape(ns)}: {c}</li>")
            lines.append("</ul>")

          lines.append("<h2>Node Resource Snapshot</h2>")
          lines.append("<table border='1' cellpadding='6' cellspacing='0'>")
          lines.append("<tr><th>Node</th><th>CPU Cap</th><th>Mem Cap</th><th>CPU Used</th><th>Mem Used</th></tr>")
          for r in rows:
            lines.append("<tr>" + "".join(f"<td>{html.escape(str(x))}</td>" for x in r) + "</tr>")
          lines.append("</table>")

          body = "\n".join(lines).encode("utf-8")
          self.send_response(200)
          self.send_header("Content-Type", "text/html; charset=utf-8")
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)
        except Exception as e:
          msg = f"lab-status error: {e}".encode("utf-8")
          self.send_response(500)
          self.send_header("Content-Type", "text/plain; charset=utf-8")
          self.send_header("Content-Length", str(len(msg)))
          self.end_headers()
          self.wfile.write(msg)

      def log_message(self, format, *args):
        return

    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-status
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lab-status
  template:
    metadata:
      labels:
        app: lab-status
    spec:
      serviceAccountName: lab-status-sa
      containers:
        - name: lab-status
          image: python:3.11-alpine
          command: ["python", "/app/app.py"]
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: "25m"
              memory: "64Mi"
            limits:
              cpu: "300m"
              memory: "256Mi"
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: lab-status-app
---
apiVersion: v1
kind: Service
metadata:
  name: lab-status
  namespace: demo-app
spec:
  selector:
    app: lab-status
  ports:
    - name: http
      port: 8080
      targetPort: 8080
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lab-status
  namespace: demo-app
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /status
            pathType: Prefix
            backend:
              service:
                name: lab-status
                port:
                  number: 8080
EOF
run_bg kubectl apply -f /tmp/demo-lab-status.yaml
run_bg rm -f /tmp/demo-lab-status.yaml || true

progress 45
log "Waiting for lab-status rollout"
run_bg kubectl -n "$DEMO_NS" rollout status deploy/$APP_NAME --timeout=5m

progress 60
log "Configuring host exposure on port 8080"
INGRESS_LB_IP="$(kubectl -n "$ING_NS" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$INGRESS_LB_IP" ]]; then
  log "ERROR: ingress-nginx LoadBalancer IP not found"
  exit 1
fi

get_lan_if() { ip route show default 2>/dev/null | awk '{print $5; exit}'; }
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
log "Validating lab-status endpoint"
run_bg curl -fsS "http://${INGRESS_LB_IP}/status" >/dev/null

run_bg touch "$ACCESS_FILE" || true
echo "Demo App (lab-status) | http://${HOST_LAN_IP}:${DEMO_PORT}/status | Stateless" >> "$ACCESS_FILE"

echo "LAB_STATUS_URL=http://${HOST_LAN_IP}:${DEMO_PORT}/status" >> /var/log/k10-mj/minio.env

progress 100
log "STEP 11 completed successfully"
return 0
