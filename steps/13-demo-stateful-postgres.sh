#!/usr/bin/env bash
set -Eeuo pipefail

STEP_NUM=12
STEP_TITLE="OPTIONAL STATEFUL DEMO (POSTGRESQL)"

progress() { draw_step "$STEP_NUM" "$TOTAL_STEPS" "$STEP_TITLE" "$1"; }
log() { echo "[INFO] $*" >> "$LOG_FILE"; }

ask_yes_no_strict() {
  local prompt="$1"
  local answer
  local row_prompt row_input row_msg left

  row_prompt=$((PANEL_TOP + 10))
  row_input=$((PANEL_TOP + 11))
  row_msg=$((PANEL_TOP + 12))
  left="$(panel_left)"

  while true; do
    print_green_line "$prompt [yes/no]" "$row_prompt"
    print_green_line "" "$row_msg"
    tput cup "$row_input" "$((left + 2))"
    printf "${BG_GREEN}${FG_BLACK}> ${RESET}"
    read -r answer || true

    case "${answer,,}" in
      yes) return 0 ;;
      no)  return 1 ;;
      *) print_green_line "Invalid option. Please answer: yes or no" "$row_msg" ;;
    esac
  done
}

progress 10
if ! ask_yes_no_strict "Deploy optional PostgreSQL stateful demo?"; then
  log "STEP 12 skipped by user"
  progress 100
  return 0
fi

DB_NS="demo-db"
DB_USER="demo"
DB_PASS="demo123"
DB_NAME="demodb"

progress 20
log "Creating namespace and postgres resources"
kubectl get ns "$DB_NS" >/dev/null 2>&1 || run_bg kubectl create ns "$DB_NS"

cat > /tmp/demo-postgres.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: demo-db
type: Opaque
stringData:
  POSTGRES_USER: demo
  POSTGRES_PASSWORD: demo123
  POSTGRES_DB: demodb
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: demo-db
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          envFrom:
            - secretRef:
                name: postgres-secret
          ports:
            - containerPort: 5432
              name: postgres
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: demo-db
spec:
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
  type: ClusterIP
EOF
run_bg kubectl apply -f /tmp/demo-postgres.yaml
run_bg rm -f /tmp/demo-postgres.yaml || true

progress 45
log "Waiting for postgres PVC to bind"
run_bg kubectl -n "$DB_NS" wait --for=jsonpath='{.status.phase}'=Bound pvc/postgres-pvc --timeout=8m

PV_NAME="$(kubectl -n "$DB_NS" get pvc postgres-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -z "${PV_NAME:-}" ]]; then
  log "ERROR: postgres-pvc has no bound volume name"
  exit 1
fi

if kubectl -n longhorn-system get volumes.longhorn.io "$PV_NAME" >/dev/null 2>&1; then
  log "Waiting for Longhorn volume $PV_NAME to become healthy"
  ready=0
  for _ in {1..80}; do
    ROBUSTNESS="$(kubectl -n longhorn-system get volumes.longhorn.io "$PV_NAME" -o jsonpath='{.status.robustness}' 2>/dev/null || true)"
    STATE="$(kubectl -n longhorn-system get volumes.longhorn.io "$PV_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    if [[ "$ROBUSTNESS" == "healthy" && "$STATE" == "attached" ]]; then
      ready=1
      break
    fi
    sleep 5
  done
  if [[ "$ready" -ne 1 ]]; then
    log "ERROR: Longhorn volume $PV_NAME not ready for workloads"
    run_bg kubectl -n longhorn-system get volumes.longhorn.io "$PV_NAME" -o wide || true
    run_bg kubectl -n longhorn-system describe volumes.longhorn.io "$PV_NAME" || true
    exit 1
  fi
fi

log "Waiting for postgres rollout"
run_bg kubectl -n "$DB_NS" rollout status deploy/postgres --timeout=10m

PG_POD="$(kubectl -n "$DB_NS" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"

progress 65
log "Waiting for postgres readiness query"
ok=0
for _ in {1..30}; do
  if kubectl -n "$DB_NS" exec "$PG_POD" -- env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done
if [[ "$ok" -ne 1 ]]; then
  log "ERROR: postgres is not responding to queries"
  run_bg kubectl -n "$DB_NS" get pod "$PG_POD" -o wide || true
  run_bg kubectl -n "$DB_NS" describe pod "$PG_POD" || true
  exit 1
fi

log "Seeding sample people table"
run_bg kubectl -n "$DB_NS" exec "$PG_POD" -- env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS people (id SERIAL PRIMARY KEY, first_name TEXT, last_name TEXT, address TEXT, phone TEXT, country TEXT, created_at TIMESTAMP DEFAULT NOW());"
run_bg kubectl -n "$DB_NS" exec "$PG_POD" -- env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "TRUNCATE TABLE people;"
run_bg kubectl -n "$DB_NS" exec "$PG_POD" -- env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "INSERT INTO people (first_name,last_name,address,phone,country) VALUES ('Liam','Walker','14 Oak St','+1-202-555-0111','USA'),('Sofia','Costa','221 Avenida Norte','+55-11-9988-1001','Brazil'),('Noah','Meyer','7 Bahnhofstrasse','+49-30-555-8877','Germany'),('Emma','Rossi','Via Roma 18','+39-06-555-2211','Italy'),('Mateo','Garcia','Calle 45 #12','+54-11-555-3456','Argentina'),('Olivia','Dubois','9 Rue Victor','+33-1-555-7788','France'),('Lucas','Silva','Rua das Flores 90','+55-21-555-1919','Brazil'),('Mia','Ivanova','Lenina 25','+7-495-555-3030','Russia'),('Ethan','Khan','88 Green Ave','+44-20-555-4545','UK'),('Ava','Nakamura','3 Sakura Way','+81-3-555-6262','Japan');"

progress 80
log "Creating host-side postgres check script"
SCRIPT_DIR="/home/${SUDO_USER:-martin}/projects/kasten-wizard-v3/scripts"
run_bg mkdir -p "$SCRIPT_DIR"
cat > "$SCRIPT_DIR/check-postgres.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NS="${DB_NS}"
POD=\$(kubectl -n "\$NS" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
echo "[postgres] pod=\$POD"
kubectl -n "\$NS" exec "\$POD" -- env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c "SELECT COUNT(*) AS people_count FROM people;"
kubectl -n "\$NS" exec "\$POD" -- env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c "SELECT id, first_name, last_name, country FROM people ORDER BY id LIMIT 5;"
EOF
run_bg chmod +x "$SCRIPT_DIR/check-postgres.sh"

run_bg touch "$ACCESS_FILE" || true
echo "Stateful App (postgres) | namespace=${DB_NS} svc=postgres:5432 db=${DB_NAME}" >> "$ACCESS_FILE"
echo "Postgres Check Script | ${SCRIPT_DIR}/check-postgres.sh" >> "$ACCESS_FILE"

progress 100
log "STEP 12 completed successfully"
return 0
