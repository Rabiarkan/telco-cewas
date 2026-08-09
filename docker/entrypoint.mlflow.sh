#!/usr/bin/env bash
# MLflow tracking server
# Responsibility: Wait until Postgres is ready, then take over the server using 'exec'
set -euo pipefail

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-telco}"
MLFLOW_BACKEND_DB="${MLFLOW_BACKEND_DB:-mlflow}"
ARTIFACT_ROOT="${MLFLOW_ARTIFACTS_DESTINATION:-/mlartifacts}"

echo "[mlflow] Waiting for Postgres: ${PGHOST}:${PGPORT} ..."
for i in $(seq 1 60); do
  if pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -q; then
    echo "[mlflow] Postgres is ready (${i}. test)."
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "[mlflow] ERROR: Postgres wasn't ready within 120s." >&2
    exit 1
  fi
  sleep 2
done

mkdir -p "${ARTIFACT_ROOT}"

BACKEND_URI="postgresql+psycopg2://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${MLFLOW_BACKEND_DB}"
echo "[mlflow] Backend store: postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${MLFLOW_BACKEND_DB}"
echo "[mlflow] Artifact root: ${ARTIFACT_ROOT}"

# exec: When PID 1 becomes mlflow -> SIGTERM is properly sent, and the container shuts down cleanly.
exec mlflow server \
  --host 0.0.0.0 \
  --port 5000 \
  --backend-store-uri "${BACKEND_URI}" \
  --artifacts-destination "${ARTIFACT_ROOT}" \
  --serve-artifacts