#!/usr/bin/env bash
set -euo pipefail
# Helper utilities for profiling GPU & CPU while issuing a chat request
# Creates timestamped files under profiles/
TS=$(date -u +%Y%m%dT%H%M%S)
BASE=profiles
mkdir -p $BASE/nvidia $BASE/cpu
# nvidia-smi dmon (1s interval, 120 samples)
nvidia-smi dmon -s pucvmet -d 1 -o DT -f $BASE/nvidia/dmon_$TS.log &
DMON_PID=$!
# per-process util (optional)
# Run mpstat for per-core CPU
mpstat -P ALL 1 60 > $BASE/cpu/mpstat_$TS.log &
MPSTAT_PID=$!
REQ_PAYLOAD='{"message":"Hello profiler"}'
curl -s -X POST 'http://localhost:8080/chat?profile=true' -H 'Content-Type: application/json' -d "$REQ_PAYLOAD" | jq . > $BASE/response_$TS.json || true
kill $DMON_PID || true
kill $MPSTAT_PID || true
echo "Trace files under profiles/torch (if profiling succeeded)."
