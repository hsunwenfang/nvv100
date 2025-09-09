#!/usr/bin/env bash
set -euo pipefail

# Lightweight GPU Minikube bootstrap inspired by nv-playground/run-fresh-cluster.sh
# 1) (Optional) delete existing cluster
# 2) Start minikube with GPU flags
# 3) (Optional) fallback to CPU if --fallback-no-gpu given
# 4) (Optional) enable NVIDIA device plugin addon
# 5) Validate GPU visibility (host + in-node + resource advertisement)
#
# Usage:
#   bash scripts/start_minikube_gpu.sh                 # fresh GPU start (deletes old)
#   bash scripts/start_minikube_gpu.sh --keep          # do not delete existing
#   bash scripts/start_minikube_gpu.sh --cpus 6 --memory 16g
#   bash scripts/start_minikube_gpu.sh --fallback-no-gpu
#   bash scripts/start_minikube_gpu.sh --no-addon      # skip enabling device plugin addon
#
# After start (if addon enabled) you should see nvidia.com/gpu via:
#   kubectl describe node minikube | grep nvidia.com/gpu || true
#
# Env overrides:
#   MINIKUBE_PROFILE (default: minikube)

PROFILE=${MINIKUBE_PROFILE:-minikube}
CPUS=""
MEMORY=""
FALLBACK_NO_GPU=0
DELETE_FIRST=1
ENABLE_ADDON=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus) CPUS="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --fallback-no-gpu) FALLBACK_NO_GPU=1; shift ;;
    --keep) DELETE_FIRST=0; shift ;;
    --no-addon) ENABLE_ADDON=0; shift ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

need(){ command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 2; }; }
for c in docker kubectl minikube; do need "$c"; done

# Ensure docker usable without sudo (project policy)
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker not accessible (permission denied)." >&2; exit 1
fi

if (( DELETE_FIRST )); then
  echo "[mk-gpu] Deleting existing profile ($PROFILE)"; minikube delete -p "$PROFILE" || true
else
  echo "[mk-gpu] Keeping existing cluster if present"
fi

START_ARGS=(--driver=docker --container-runtime=docker --gpus=all)
[[ -n "$CPUS" ]] && START_ARGS+=(--cpus="$CPUS")
[[ -n "$MEMORY" ]] && START_ARGS+=(--memory="$MEMORY")

echo "[mk-gpu] Starting: minikube -p $PROFILE start ${START_ARGS[*]}";
if ! minikube -p "$PROFILE" start "${START_ARGS[@]}"; then
  if (( FALLBACK_NO_GPU )); then
    echo "[mk-gpu] WARN: GPU start failed; retrying without --gpus (fallback)" >&2
    CPU_ARGS=(--driver=docker --container-runtime=docker)
    [[ -n "$CPUS" ]] && CPU_ARGS+=(--cpus="$CPUS")
    [[ -n "$MEMORY" ]] && CPU_ARGS+=(--memory="$MEMORY")
    echo "minikube -p $PROFILE start ${CPU_ARGS[*]}"
    minikube -p "$PROFILE" start "${CPU_ARGS[@]}"
  else
    echo "[mk-gpu] ERROR: GPU start failed (use --fallback-no-gpu to retry w/out GPU)" >&2
    exit 1
  fi
fi

echo "[mk-gpu] Enabling NVIDIA addon? $ENABLE_ADDON"
if (( ENABLE_ADDON )); then
  minikube -p "$PROFILE" addons enable nvidia-device-plugin >/dev/null || true
fi

echo "[mk-gpu] Waiting for device plugin pod (if addon enabled)"
for i in {1..30}; do
  if kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running; then
    break
  fi
  sleep 4
done

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "[mk-gpu] Host GPU list:"; nvidia-smi -L || true
fi

echo "[mk-gpu] In-node /dev/nvidia* check"
if ! minikube -p "$PROFILE" ssh -- 'ls /dev/nvidia0 >/dev/null 2>&1'; then
  echo "[mk-gpu] WARNING: /dev/nvidia0 missing inside node" >&2
fi

if (( ENABLE_ADDON )); then
  echo "[mk-gpu] Checking node resource advertisement"
  if kubectl describe node "$PROFILE" | grep -q 'nvidia.com/gpu'; then
    echo "[mk-gpu] SUCCESS: nvidia.com/gpu resource present"
  else
    echo "[mk-gpu] WARNING: nvidia.com/gpu not advertised yet (device plugin may still be initializing)" >&2
  fi
fi

echo "[mk-gpu] Done."
