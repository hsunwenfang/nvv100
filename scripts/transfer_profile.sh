#!/usr/bin/env bash
# transfer_profile.sh - List all profiler gz traces in the newest running chat pod and copy the latest one locally.
#
# Simplified per requirements:
#   * Always auto-detect the latest (newest creationTimestamp) Running pod with label app=chat-app
#   * Print all *.json.gz trace files with modification times inside the pod
#   * Always copy the newest (most recently modified) trace_*.json.gz to local directory
#   * Removed all scp / remote transfer logic
#
# Usage:
#   ./scripts/transfer_profile.sh
#
# Environment overrides:
#   NAMESPACE        : Kubernetes namespace (default: chat)
#   LOCAL_DIR        : Local directory to place copied traces (default: profiles/torch)
#   TRACE_DIR_IN_POD : Directory inside pod (default: /app/profiles/torch)
#   DECOMPRESS       : If set to 1, also keep an uncompressed JSON copy
#   DRY_RUN          : If set to 1, show what would happen without copying
#
set -euo pipefail

NAMESPACE=${NAMESPACE:-chat}
LOCAL_DIR=${LOCAL_DIR:-profiles/torch}
TRACE_DIR_IN_POD=${TRACE_DIR_IN_POD:-/app/profiles/torch}
DECOMPRESS=${DECOMPRESS:-0}
DRY_RUN=${DRY_RUN:-0}

err() { echo "[transfer_profile] ERROR: $*" >&2; exit 1; }
log() { echo "[transfer_profile] $*" >&2; }

command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"

if [[ $# -ne 0 ]]; then
  err "No arguments accepted. Use environment variables if needed."
fi

# Find newest running pod (by creationTimestamp) with label app=chat-app
POD=$(kubectl -n "${NAMESPACE}" get pods -l app=chat-app -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.creationTimestamp}{" "}{.metadata.name}{"\n"}{end}' | sort | tail -n1 | awk '{print $2}')
[[ -z ${POD} ]] && err "No Running pods with label app=chat-app in namespace ${NAMESPACE}"

log "Selected newest running pod: ${POD}"

# List all gz trace files with modification time
log "Listing trace *.json.gz files (if any) in ${POD}:${TRACE_DIR_IN_POD}" 
LIST_CMD=(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -ltr ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null || true")
${LIST_CMD[@]} >&2 || true

# Determine newest (most recently modified) trace file path
TRACE_FILE=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -1t ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null | head -n1") || true
[[ -z ${TRACE_FILE} ]] && err "No trace_*.json.gz files found in pod ${POD}"
TRACE_BASENAME=$(basename "${TRACE_FILE}")

mkdir -p "${LOCAL_DIR}"
LOCAL_PATH="${LOCAL_DIR}/${TRACE_BASENAME}"

log "Latest trace file: ${TRACE_FILE}"
log "Copying to: ${LOCAL_PATH}"

if [[ ${DRY_RUN} != 1 ]]; then
  kubectl -n "${NAMESPACE}" cp "${POD}:${TRACE_FILE}" "${LOCAL_PATH}" || err "kubectl cp failed"
else
  log "DRY_RUN=1; skipping copy"
  exit 0
fi

[[ ! -s ${LOCAL_PATH} ]] && err "Local file missing or empty after copy: ${LOCAL_PATH}"

if [[ ${DECOMPRESS} == 1 ]]; then
  if command -v gunzip >/dev/null 2>&1; then
    cp "${LOCAL_PATH}" "${LOCAL_PATH}.bak"
    gunzip -k "${LOCAL_PATH}" || log "gunzip failed (continuing)"
  else
    log "gunzip not available; skipping decompression"
  fi
fi

log "Done."

