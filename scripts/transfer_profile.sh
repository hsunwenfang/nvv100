#!/usr/bin/env bash
# transfer_profile.sh - Fetch a profiler trace from the running chat pod and copy it to a remote machine.
#
# Usage:
#   ./scripts/transfer_profile.sh <pod|auto> <trace_filename|latest> <remote_spec> [remote_filename]
#
# Arguments:
#   pod             : Explicit pod name (e.g. chat-app-5fb6b68db5-pd7ld) or 'auto' to pick the first Ready pod with label app=chat-app
#   trace_filename  : Exact file name (e.g. trace_20250910T031735444503.json.gz) OR 'latest' to auto-detect newest trace in pod
#   remote_spec     : scp destination in standard form user@host:/absolute/path/or/dir
#   remote_filename : (optional) Override the destination file name (default keeps original)
#
# Environment overrides:
#   NAMESPACE       : Kubernetes namespace (default: chat)
#   LOCAL_DIR       : Local directory to place copied traces (default: profiles/torch)
#   TRACE_DIR_IN_POD: Directory inside pod (default: /app/profiles/torch)
#   DECOMPRESS      : If set to 1, also produce an uncompressed JSON copy locally
#   DRY_RUN         : If set to 1, print commands without executing network actions
#
# Examples:
#   ./scripts/transfer_profile.sh auto latest user@167.220.232.22:/Users/hsunwenfang/Documents/nv-playground
#   ./scripts/transfer_profile.sh chat-app-5fb6b68db5-pd7ld trace_20250910T031735444503.json.gz user@167.220.232.22:/Users/me/traces custom_name.json.gz
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
command -v scp >/dev/null 2>&1 || log "scp not found (will fail if remote transfer attempted)"

if [[ $# -lt 3 || $# -gt 4 ]]; then
  err "Usage: $0 <pod|auto> <trace_filename|latest> <remote_spec> [remote_filename]"
fi

POD_INPUT=$1
TRACE_INPUT=$2
REMOTE_SPEC=$3
REMOTE_FILENAME=${4:-}

# Resolve pod
if [[ ${POD_INPUT} == "auto" ]]; then
  POD=$(kubectl -n "${NAMESPACE}" get pods -l app=chat-app -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | head -n1)
  [[ -z ${POD} ]] && err "No running pod with label app=chat-app found in namespace ${NAMESPACE}"
else
  POD=${POD_INPUT}
fi

# Verify pod exists
kubectl -n "${NAMESPACE}" get pod "${POD}" >/dev/null 2>&1 || err "Pod ${POD} not found in namespace ${NAMESPACE}"

# Determine trace filename
if [[ ${TRACE_INPUT} == "latest" ]]; then
  TRACE_FILE=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -c "ls -1t ${TRACE_DIR_IN_POD}/trace_*.json.gz 2>/dev/null | head -n1") || true
  [[ -z ${TRACE_FILE} ]] && err "No trace_*.json.gz files found in pod ${POD}"
  # Extract just the basename
  TRACE_BASENAME=$(basename "${TRACE_FILE}")
else
  TRACE_BASENAME=${TRACE_INPUT}
  TRACE_FILE="${TRACE_DIR_IN_POD}/${TRACE_BASENAME}"
fi

# Local target
mkdir -p "${LOCAL_DIR}"
LOCAL_PATH="${LOCAL_DIR}/${TRACE_BASENAME}"

log "Pod: ${POD}"
log "Trace file in pod: ${TRACE_FILE}"
log "Local destination: ${LOCAL_PATH}"

KCP_CMD=(kubectl -n "${NAMESPACE}" cp "${POD}:${TRACE_FILE}" "${LOCAL_PATH}")
log "Running: ${KCP_CMD[*]}"
if [[ ${DRY_RUN} != 1 ]]; then
  "${KCP_CMD[@]}"
fi

if [[ ! -s ${LOCAL_PATH} ]]; then
  err "File copy failed or empty: ${LOCAL_PATH}"
fi

if [[ ${DECOMPRESS} == 1 ]]; then
  if command -v gunzip >/dev/null 2>&1; then
    cp "${LOCAL_PATH}" "${LOCAL_PATH}.bak"
    gunzip -k "${LOCAL_PATH}" || log "gunzip failed (continuing)"
  else
    log "gunzip not available; skipping decompression"
  fi
fi

# Remote destination logic
if [[ -n ${REMOTE_FILENAME} ]]; then
  REMOTE_TARGET="${REMOTE_SPEC%/}/${REMOTE_FILENAME}"
else
  # If REMOTE_SPEC ends with '/', treat as directory
  if [[ ${REMOTE_SPEC} == */ ]]; then
    REMOTE_TARGET="${REMOTE_SPEC}${TRACE_BASENAME}"
  else
    # If it looks like user@host:/path
    if [[ ${REMOTE_SPEC} == *:* ]]; then
      # Determine if remote part ends with .gz or .json
      REMOTE_PATH_PART=${REMOTE_SPEC#*:}
      if [[ ${REMOTE_PATH_PART} == */ ]]; then
        REMOTE_TARGET="${REMOTE_SPEC}${TRACE_BASENAME}"
      else
        # Provided a full path including filename
        REMOTE_TARGET="${REMOTE_SPEC}"
      fi
    else
      # Assume directory path without user@host prefix
      REMOTE_TARGET="${REMOTE_SPEC%/}/${TRACE_BASENAME}"
    fi
  fi
fi

log "Remote target: ${REMOTE_TARGET}"

if [[ ${DRY_RUN} == 1 ]]; then
  log "DRY_RUN=1; skipping scp"
  exit 0
fi

# Perform scp
if command -v scp >/dev/null 2>&1; then
  log "Transferring via scp..."
  scp -p "${LOCAL_PATH}" "${REMOTE_TARGET}" || err "scp transfer failed"
  log "Transfer complete: ${REMOTE_TARGET}"
else
  err "scp command not available"
fi

