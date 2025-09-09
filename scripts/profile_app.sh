#!/usr/bin/env bash
set -euo pipefail

APP_URL=${1:-http://localhost:8080}
MESSAGE=${2:-"Hello"}

OUT_DIR=profiles
TORCH_DIR=${OUT_DIR}/torch
GPU_DIR=${OUT_DIR}/gpu
CPU_DIR=${OUT_DIR}/cpu
mkdir -p "$TORCH_DIR" "$GPU_DIR" "$CPU_DIR"

echo "[Torch Profiler] triggering profiled inference..."
curl -s -X POST "${APP_URL}/chat?profile=true" -H 'Content-Type: application/json' -d "{\"message\": \"${MESSAGE}\"}" > ${TORCH_DIR}/chat_profile_response.json

echo "[GPU dmon] capturing GPU metrics during load..."
(
  set +e
  timeout 20s nvidia-smi dmon -s pucvmet > ${GPU_DIR}/nvidia_smi_dmon.log &
  DMON_PID=$!
  for i in $(seq 1 5); do
    curl -s -X POST "${APP_URL}/chat" -H 'Content-Type: application/json' -d "{\"message\": \"Batch $i ${MESSAGE}\"}" >/dev/null || true
  done
  wait $DMON_PID || true
)

echo "[CPU per-core] sampling mpstat..."
if command -v mpstat >/dev/null 2>&1; then
  mpstat -P ALL 1 10 > ${CPU_DIR}/cpu_mpstat.log || true
else
  echo "mpstat not found" > ${CPU_DIR}/cpu_mpstat.log
fi

echo "Artifacts written under profiles/."