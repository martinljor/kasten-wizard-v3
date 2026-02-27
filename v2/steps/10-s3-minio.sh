#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=9
STEP_TITLE="INSTALLING MINIO (S3 REPOSITORY ON K3S MASTER)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

MINIO_NS="minio"
MINIO_RELEASE="minio"
MINIO_BUCKET="${MINIO_BUCKET:-kasten-backups}"
MINIO_USER="${MINIO_ROOT_USER:-kasten}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-}"

if [[ -z "$MINIO_PASS" ]]; then
  MINIO_PASS="$(tr -dc 'A-Za-z0-9!@#%^*()_+=' </dev/urandom | head -c 22)"
fi

progress 10
log "Preparing MinIO namespace and secret"

kubectl get ns "$MINIO_NS" >/dev/null 2>&1 || run_bg kubectl create ns "$MINIO_NS"

cat > /tmp/minio-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: ${MINIO_NS}
type: Opaque
stringData:
  rootUser: ${MINIO_USER}
  rootPassword: ${MINIO_PASS}
EOF
run_bg kubectl apply -f /tmp/minio-secret.yaml
run_bg rm -f /tmp/minio-secret.yaml || true

progress 25
log "Deploying MinIO (pinned to k3s-master for demo)"

cat > /tmp/minio-deploy.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      nodeSelector:
        kubernetes.io/hostname: k3s-master
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-creds
                  key: rootUser
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-creds
                  key: rootPassword
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF

run_bg kubectl apply -f /tmp/minio-deploy.yaml
run_bg rm -f /tmp/minio-deploy.yaml || true

progress 45
log "Waiting for MinIO deployment rollout"
run_bg kubectl -n "$MINIO_NS" rollout status deploy/minio --timeout=10m

progress 60
log "Creating S3 bucket for Kasten"

# Create bucket from ephemeral mc pod inside cluster
kubectl -n "$MINIO_NS" run mc-setup --image=minio/mc:latest --restart=Never --rm -i --command -- \
  sh -c "mc alias set local http://minio.${MINIO_NS}.svc.cluster.local:9000 '${MINIO_USER}' '${MINIO_PASS}' && mc mb --ignore-existing local/${MINIO_BUCKET}" \
  >> "$LOG_FILE" 2>&1

progress 75
log "Collecting MinIO access endpoints"
MINIO_CLUSTER_ENDPOINT="http://minio.${MINIO_NS}.svc.cluster.local:9000"
MASTER_IP="$(kubectl get node k3s-master -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
MINIO_MASTER_HINT=""
if [[ -n "${MASTER_IP:-}" ]]; then
  MINIO_MASTER_HINT="http://${MASTER_IP}:9000"
fi

ACCESS_FILE="/var/log/k10-mj/access-summary.log"
run_bg touch "$ACCESS_FILE" || true

echo "MinIO S3 (cluster) | ${MINIO_CLUSTER_ENDPOINT} | AccessKey: ${MINIO_USER} | SecretKey: ${MINIO_PASS}" >> "$ACCESS_FILE"
if [[ -n "${MINIO_MASTER_HINT}" ]]; then
  echo "MinIO S3 (master hint) | ${MINIO_MASTER_HINT} | Bucket: ${MINIO_BUCKET}" >> "$ACCESS_FILE"
fi
echo "MinIO Bucket | ${MINIO_BUCKET}" >> "$ACCESS_FILE"

auto_msg="MinIO ready in namespace '${MINIO_NS}' (bucket: ${MINIO_BUCKET})"
log "$auto_msg"

progress 100
return 0
