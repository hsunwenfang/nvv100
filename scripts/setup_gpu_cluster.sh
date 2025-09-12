#!/usr/bin/env bash
set -euo pipefail

# Cluster bootstrap helper. Currently adds optional NVIDIA GPU time-slicing enablement.

if [[ "${ENABLE_TIME_SLICING:-}" == "1" ]]; then
	echo "[setup] Enabling NVIDIA GPU time-slicing (replicas=${GPU_TS_REPLICAS:-4})" >&2
	scripts/enable_time_slicing.sh
else
	echo "[setup] Time-slicing not requested (set ENABLE_TIME_SLICING=1 to enable)." >&2
fi

echo "[setup] Done." >&2
