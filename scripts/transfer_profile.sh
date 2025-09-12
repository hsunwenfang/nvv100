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

# List trace files (.json.gz preferred, fall back to raw .json)
log "Listing trace artifacts in ${POD}:${TRACE_DIR_IN_POD}" 
kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -ltr ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null || true" >&2 || true
kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -ltr ${TRACE_DIR_IN_POD}/trace_*.json 2>/dev/null | grep -v '.json.gz' || true" >&2 || true

# Determine list of latest traces to copy (default 3). If none gzipped, gzip raws then re-list.
TRACE_COPY_COUNT=${TRACE_COPY_COUNT:-3}
TRACE_FILES=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -1t ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null | head -n ${TRACE_COPY_COUNT}") || true
if [[ -z ${TRACE_FILES} ]]; then
  RAW_LIST=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -1t ${TRACE_DIR_IN_POD}/trace_*.json 2>/dev/null | head -n ${TRACE_COPY_COUNT}") || true
  if [[ -n ${RAW_LIST} ]]; then
    log "No compressed traces; gzipping raw traces inside pod"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "set -e; for f in ${TRACE_DIR_IN_POD}/trace_*.json; do [ -f \"$f\" ] || continue; gzip -c \"$f\" > \"$f.gz\" && rm -f \"$f\"; done" || true
    TRACE_FILES=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -1t ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null | head -n ${TRACE_COPY_COUNT}") || true
  fi
fi
[[ -z ${TRACE_FILES} ]] && err "No trace_*.json(.gz) files found in pod ${POD}"

mkdir -p "${LOCAL_DIR}"
log "Copying up to ${TRACE_COPY_COUNT} traces to ${LOCAL_DIR}" 
if [[ ${DRY_RUN} == 1 ]]; then
  echo "${TRACE_FILES}" | sed 's/^/[transfer_profile] DRY_RUN would copy: /' >&2
  exit 0
fi

copied=0
while IFS= read -r TRACE_FILE; do
  [[ -z ${TRACE_FILE} ]] && continue
  BASENAME=$(basename "${TRACE_FILE}")
  DEST="${LOCAL_DIR}/${BASENAME}"
  log "Copying ${TRACE_FILE} -> ${DEST}"
  kubectl -n "${NAMESPACE}" cp "${POD}:${TRACE_FILE}" "${DEST}" || err "kubectl cp failed for ${TRACE_FILE}"
  [[ ! -s ${DEST} ]] && err "Copied file empty: ${DEST}"
  if [[ ${DECOMPRESS} == 1 ]]; then
    if command -v gunzip >/dev/null 2>&1; then
      cp "${DEST}" "${DEST}.bak"
      gunzip -k "${DEST}" || log "gunzip failed (continuing)"
    else
      log "gunzip not available; skipping decompression for ${BASENAME}"
    fi
  fi
  copied=$((copied+1))
done < <(echo "${TRACE_FILES}")

log "Done. Copied ${copied} trace file(s)."

