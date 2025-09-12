#!/usr/bin/env bash
set -euo pipefail

# Allow defining a shell kubectl shim if kubectl binary absent (use minikube's embedded kubectl)
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH; using 'minikube kubectl --' shim" >&2
  kubectl() { minikube kubectl -- "$@"; }
fi

# Require docker usable without sudo
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker not accessible (permission denied). Fix by adding user to docker group or adjusting /var/run/docker.sock perms." >&2
  exit 1
fi

IMAGE_NAME="chat-app:latest"
AUTO_TAG=1
FRESH=0
CPU_COUNT=""
MEMORY_SIZE=""
NO_ADDON=0

usage() {
  cat <<EOF
Usage: $0 [--fresh] [--cpus N] [--memory SIZE] [--no-addon] [--k8s-version VER] [--image-name NAME:TAG]
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --fresh) FRESH=1; shift ;;
    --cpus) CPU_COUNT="$2"; shift 2 ;;
    --memory) MEMORY_SIZE="$2"; shift 2 ;;
    --no-addon) NO_ADDON=1; shift ;;
    --k8s-version) K8S_VERSION="$2"; shift 2 ;;
  --image-name) IMAGE_NAME="$2"; AUTO_TAG=0; shift 2 ;;
  --no-auto-tag) AUTO_TAG=0; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done
MINIKUBE_PROFILE="minikube"
# Use the built-in minikube addon for the NVIDIA device plugin (preferred) unless overridden
USE_MINIKUBE_ADDON_NVIDIA=${USE_MINIKUBE_ADDON_NVIDIA:-1}
# Pin a known stable Kubernetes version unless user overrides (avoid bleeding edge causing apiserver issues)
K8S_VERSION=${K8S_VERSION:-"v1.31.0"}
# Detect host docker cgroup driver to match kubelet (prevents mismatch causing kubelet fail)
HOST_CGROUP_DRIVER=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo cgroupfs)

# Explicit GPU start: minimal stable flags (feature-gate no longer needed on modern k8s)
START_FLAGS=${START_FLAGS:-"--driver=docker --container-runtime=docker --gpus=all --kubernetes-version=${K8S_VERSION} --extra-config=kubelet.v=6"}
[[ -n "$CPU_COUNT" ]] && START_FLAGS+=" --cpus=${CPU_COUNT}"
[[ -n "$MEMORY_SIZE" ]] && START_FLAGS+=" --memory=${MEMORY_SIZE}"

# Allow starting with addon directly (avoids post-start enable timing race)
if (( NO_ADDON )); then
  echo "Skipping nvidia-device-plugin addon (--no-addon)" >&2
elif [ "${USE_MINIKUBE_ADDON_NVIDIA}" = "1" ]; then
  START_FLAGS+=" --addons=nvidia-device-plugin"
fi

# Ensure kubelet uses same cgroup driver as docker (only add if not already present)
if [[ "$START_FLAGS" != *"kubelet.cgroup-driver"* ]]; then
  START_FLAGS+=" --extra-config=kubelet.cgroup-driver=${HOST_CGROUP_DRIVER}"
fi

wait_for_apiserver() {
  echo "Waiting for Kubernetes apiserver to answer..."
  local tries=40
  local sleep_s=5
  local i
  for i in $(seq 1 $tries); do
    if kubectl version --short >/dev/null 2>&1 || kubectl get nodes >/dev/null 2>&1; then
      echo "Apiserver is reachable."; return 0
    fi
    sleep $sleep_s
  done
  echo "ERROR: Apiserver not reachable after $((tries*sleep_s))s." >&2
  return 1
}

echo "[1/6] Checking host GPU availability..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found on host. Install NVIDIA drivers + nvidia-container-toolkit first." >&2
  exit 1
fi
nvidia-smi -L || { echo "ERROR: No NVIDIA GPU detected." >&2; exit 1; }

echo "[2/6] Starting (or validating) Minikube GPU cluster... (host cgroup driver: ${HOST_CGROUP_DRIVER})"
if (( FRESH )); then
  echo "--fresh: deleting existing profile ${MINIKUBE_PROFILE}" >&2
  minikube delete -p "${MINIKUBE_PROFILE}" || true
fi
if ! minikube status -p "${MINIKUBE_PROFILE}" >/dev/null 2>&1; then
  echo "Starting Minikube with GPU flags: ${START_FLAGS}" 
  if ! minikube start -p "${MINIKUBE_PROFILE}" ${START_FLAGS}; then
    echo "ERROR: minikube start failed with --gpus=all (no CPU fallback logic present)." >&2
    exit 1
  fi
else
  echo "Minikube already running. Skipping start.";
  if (( ! FRESH )); then
    echo "Checking existing cluster GPU readiness (device, plugin pod, resource)..."
    # New logic: be less destructive. Only restart if the GPU device itself is missing.
    # Env toggles:
    #   GPU_READINESS_STRICT=1   -> revert to old behaviour (restart if not fully ready)
    #   GPU_VERSION_FALLBACK=1   -> later section may delete & retry different K8s versions
    GPU_READINESS_STRICT=${GPU_READINESS_STRICT:-0}
    attempts=0
    max_attempts=45   # ~180s (45 * 4s) total gentle wait
    while :; do
      GPU_DEVICE_OK=0; PLUGIN_OK=0; RESOURCE_OK=0
      if minikube ssh -p "${MINIKUBE_PROFILE}" -- 'ls /dev/nvidia0 >/dev/null 2>&1'; then GPU_DEVICE_OK=1; fi
      if kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running; then PLUGIN_OK=1; fi
      # Extra heuristic: some installations use 'nvidia-device-plugin-daemonset'
      if (( PLUGIN_OK == 0 )); then
        if kubectl get pods -n kube-system 2>/dev/null | grep -E 'nvidia-device-plugin' | grep -q Running; then PLUGIN_OK=1; fi
      fi
      if kubectl describe node ${MINIKUBE_PROFILE} 2>/dev/null | grep -q 'nvidia.com/gpu'; then RESOURCE_OK=1; fi
      if (( GPU_DEVICE_OK && PLUGIN_OK && RESOURCE_OK )); then
        echo "Cluster already GPU ready; no restart needed."; break
      fi
      if (( attempts >= max_attempts )); then
        if (( GPU_DEVICE_OK == 0 )); then
          echo "GPU device /dev/nvidia0 still missing after ${max_attempts} attempts; restarting cluster (hard failure)." >&2
          minikube delete -p "${MINIKUBE_PROFILE}" || true
          echo "Starting Minikube with GPU flags: ${START_FLAGS}"
          if ! minikube start -p "${MINIKUBE_PROFILE}" ${START_FLAGS}; then
            echo "ERROR: minikube start failed after restart attempt." >&2
            exit 1
          fi
        else
          if (( GPU_READINESS_STRICT )); then
            echo "Not fully ready (plugin:${PLUGIN_OK} resource:${RESOURCE_OK}) and GPU_READINESS_STRICT=1 -> restarting." >&2
            minikube delete -p "${MINIKUBE_PROFILE}" || true
            if ! minikube start -p "${MINIKUBE_PROFILE}" ${START_FLAGS}; then
              echo "ERROR: minikube start failed after strict restart." >&2
              exit 1
            fi
          else
            echo "Proceeding even though not fully ready yet (plugin:${PLUGIN_OK} resource:${RESOURCE_OK}); later steps will wait. Set GPU_READINESS_STRICT=1 to enforce restart." >&2
            if (( PLUGIN_OK == 0 )); then
              echo "DEBUG: Device plugin not yet detected; current kube-system NVIDIA pods:" >&2
              kubectl get pods -n kube-system 2>/dev/null | grep -i nvidia || true
            fi
          fi
        fi
        break
      fi
      if (( attempts % 5 == 0 )); then
        echo "Still waiting (attempt ${attempts}/${max_attempts}) device:${GPU_DEVICE_OK} plugin:${PLUGIN_OK} resource:${RESOURCE_OK}" >&2
      fi
      attempts=$((attempts+1))
      sleep 4
    done
  fi
fi

echo "Verifying apiserver health before GPU checks..."
if ! wait_for_apiserver; then
  echo "Collecting minikube logs snippet for diagnostics..." >&2
  minikube logs --length=80 2>/dev/null | tail -n 120 >&2 || true
  echo "Suggested next steps:" >&2
  echo "  1. minikube delete" >&2
  echo "  2. Retry with: K8S_VERSION=v1.30.0 bash scripts/deploy.sh (alternate stable)" >&2
  echo "  3. If still failing: try CPU only first: minikube start --driver=docker --kubernetes-version=v1.31.0" >&2
  exit 1
fi

echo "Verifying /dev/nvidia* inside Minikube VM..."
if ! minikube ssh -p "${MINIKUBE_PROFILE}" -- 'ls /dev/nvidia0 >/dev/null 2>&1'; then
  echo "ERROR: /dev/nvidia0 missing inside node. --gpus=all did not propagate devices." >&2
  echo "Validate host GPU passthrough works: docker run --rm --gpus all nvidia/cuda:12.2.0-base nvidia-smi" >&2
  exit 1
fi

echo "[3/6] Ensuring NVIDIA device plugin present..."
if [ "${USE_MINIKUBE_ADDON_NVIDIA}" = "1" ]; then
  # If started with addon the pod may already be coming up; ensure addon actually enabled (idempotent)
  minikube addons enable nvidia-device-plugin -p "${MINIKUBE_PROFILE}" >/dev/null || true
else
  echo "Applying custom k8s/nvidia-device-plugin.yml (addon disabled)."
  kubectl apply -f k8s/nvidia-device-plugin.yml
fi

# Determine selector + namespace
if [ "${USE_MINIKUBE_ADDON_NVIDIA}" = "1" ]; then
  PLUGIN_SELECTOR="-l k8s-app=nvidia-device-plugin"
  PLUGIN_NAMESPACE="-n kube-system"
else
  # custom YAML labels
  if kubectl get pods -l name=nvidia-device-plugin-ds >/dev/null 2>&1; then
    PLUGIN_SELECTOR="-l name=nvidia-device-plugin-ds"
  else
    PLUGIN_SELECTOR="-l k8s-app=nvidia-device-plugin"
  fi
  PLUGIN_NAMESPACE=""  # default namespace
fi

echo "Waiting for NVIDIA device plugin pod to be Running (robust matching)..."
device_plugin_ready() {
  # Match any of several common label patterns OR fallback to name substring scan.
  if kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running; then return 0; fi
  if kubectl get pods -A -l name=nvidia-device-plugin-ds 2>/dev/null | grep -q Running; then return 0; fi
  if kubectl get pods -n kube-system 2>/dev/null | grep -E 'nvidia-device-plugin' | grep -q Running; then return 0; fi
  return 1
}
for i in {1..45}; do
  if device_plugin_ready; then
    echo "Device plugin detected running."; break
  fi
  if (( i % 5 == 0 )); then
    echo "(attempt $i) still waiting for device plugin; current matching pods:" >&2
    kubectl get pods -n kube-system 2>/dev/null | grep -i nvidia || true
  fi
  sleep 4
done
if ! device_plugin_ready; then
  echo "ERROR: No running NVIDIA device plugin pod after wait (tried multiple matching strategies)." >&2
  kubectl get pods -n kube-system 2>/dev/null | grep -i nvidia || kubectl get pods -A | grep -i nvidia || true
  exit 1
fi

echo "Checking NVML init in device plugin logs..."
if kubectl logs -n kube-system $(kubectl get pods -n kube-system -l k8s-app=nvidia-device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) 2>/dev/null | grep -qi 'Failed to initialize NVML'; then
  echo "ERROR: NVML failed to initialize (no GPU libraries)." >&2
  echo "Check: docker run --rm --gpus all nvidia/cuda:12.2.0-base nvidia-smi (should succeed)." >&2
  echo "If that works: minikube delete; retry script. If not: fix host NVIDIA toolkit." >&2
  exit 1
fi

echo "[4/6] Validating node advertises nvidia.com/gpu..."
if ! kubectl describe node ${MINIKUBE_PROFILE} | grep -q 'nvidia.com/gpu'; then
  echo "WARNING: Node does not advertise nvidia.com/gpu yet (may take time after plugin starts)." >&2
  echo "Waiting up to 300s for resource advertisement..." >&2
  for i in {1..60}; do
    if kubectl describe node ${MINIKUBE_PROFILE} 2>/dev/null | grep -q 'nvidia.com/gpu'; then
      echo "GPU resource appeared after wait (${i} *5s)." >&2
      break
    fi
    sleep 5
  done
  if ! kubectl describe node ${MINIKUBE_PROFILE} | grep -q 'nvidia.com/gpu'; then
    GPU_VERSION_FALLBACK=${GPU_VERSION_FALLBACK:-0}
    if (( GPU_VERSION_FALLBACK )); then
      echo "Resource still absent; GPU_VERSION_FALLBACK=1 -> attempting alternate Kubernetes versions." >&2
      FALLBACK_VERSIONS=${GPU_RETRY_VERSIONS:-"v1.30.2 v1.29.6"}
      for ver in $FALLBACK_VERSIONS; do
        echo "--- Fallback attempt with Kubernetes ${ver} ---" >&2
        echo "Deleting cluster..." >&2
        minikube delete -p "${MINIKUBE_PROFILE}" >/dev/null 2>&1 || true
        echo "Starting Minikube (Kubernetes ${ver}) with GPU flags..." >&2
        if ! minikube start -p "${MINIKUBE_PROFILE}" --driver=docker --container-runtime=docker --gpus=all --kubernetes-version=${ver} --addons=nvidia-device-plugin --extra-config=kubelet.cgroup-driver=${HOST_CGROUP_DRIVER}; then
          echo "Start failed for ${ver}; trying next if available." >&2
          continue
        fi
        echo "Waiting briefly for device plugin pods..." >&2
        for j in {1..20}; do
          if kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running; then break; fi
          sleep 4
        done
        if kubectl describe node ${MINIKUBE_PROFILE} | grep -q 'nvidia.com/gpu'; then
          echo "SUCCESS: GPU resource visible on ${ver}." >&2
          break
        else
          echo "GPU still not visible on ${ver}." >&2
        fi
      done
    else
      echo "Proceeding without GPU resource yet (deploy may Pending). Set GPU_VERSION_FALLBACK=1 to enable destructive fallback attempts." >&2
    fi
  fi
  if ! kubectl describe node ${MINIKUBE_PROFILE} | grep -q 'nvidia.com/gpu'; then
    echo "ERROR: GPU resource not advertised after fallback attempts." >&2
    echo "Troubleshoot steps:" >&2
    echo "  * Ensure host Docker can run: docker run --rm --gpus all nvidia/cuda:12.2.0-base nvidia-smi" >&2
    echo "  * Confirm nvidia-container-toolkit installed and configured." >&2
    echo "  * If using rootless Docker, GPU passthrough may fail." >&2
    exit 1
  fi
fi
echo "Node GPU resource present." 

echo "[5/6] Building images (base + app) with auto-tag logic inside Minikube docker daemon..."
eval "$(minikube -p ${MINIKUBE_PROFILE} docker-env)"

# Determine hashes
if (( AUTO_TAG )); then
  BASE_HASH=$( (sha256sum Dockerfile.base requirements.txt 2>/dev/null; ) | sha256sum | cut -c1-12 || echo baseunknown)
  APP_HASH=$( (find app -type f -name '*.py' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null; sha256sum Dockerfile.app requirements_app.txt k8s/deployment.yaml 2>/dev/null ) | sha256sum | cut -c1-12 || echo appunknown)
  BASE_IMAGE="chat-app-base:${BASE_HASH}"
  IMAGE_NAME="chat-app:${APP_HASH}"
  echo "Computed BASE_HASH=${BASE_HASH} APP_HASH=${APP_HASH}" >&2
else
  BASE_IMAGE="chat-app-base:latest"
fi

# Build base if needed
if ! docker images | awk '{print $1":"$2}' | grep -q "^${BASE_IMAGE}$"; then
  echo "Building base image ${BASE_IMAGE}..." >&2
  docker build -f Dockerfile.base -t ${BASE_IMAGE} .
  # No 'latest' tagging when AUTO_TAG enabled (keep hash-only tagging)
else
  echo "Base image ${BASE_IMAGE} already present (cache hit)." >&2
fi

# Build app image if needed
if ! docker images | awk '{print $1":"$2}' | grep -q "^${IMAGE_NAME}$"; then
  echo "Building app image ${IMAGE_NAME} (FROM ${BASE_IMAGE})..." >&2
  docker build -f Dockerfile.app --build-arg BASE_IMAGE=${BASE_IMAGE} -t ${IMAGE_NAME} .
  # No 'latest' tagging when AUTO_TAG enabled (keep hash-only tagging)
else
  echo "App image ${IMAGE_NAME} already present (cache hit)." >&2
fi

# Remove any stale 'latest' tags to keep only hash tags (non-fatal if absent)
if (( AUTO_TAG )); then
  docker rmi chat-app:latest chat-app-base:latest 2>/dev/null || true
fi

mkdir -p .deploy 2>/dev/null || true
echo "${IMAGE_NAME}" > .deploy/last_image_tag
echo "Last app image tag stored in .deploy/last_image_tag" >&2

NAMESPACE=${NAMESPACE:-chat}
echo "[6/6] Deploying and waiting for application pod in namespace '${NAMESPACE}'..."
kubectl get namespace ${NAMESPACE} >/dev/null 2>&1 || kubectl create namespace ${NAMESPACE}

HF_TOKEN="${HF_TOKEN:-}"
# Optional Hugging Face token secret creation (idempotent)
if [ -n "${HF_TOKEN}" ]; then
  echo "Creating/Updating hf-token secret for Hugging Face auth..."
  kubectl create secret generic hf-token -n ${NAMESPACE} \
    --from-literal=HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Force deployment to use the exact built image tag (even if manifest has a different default)
echo "Setting deployment image to ${IMAGE_NAME} explicitly..."
kubectl set image deployment/chat-app chat-app=${IMAGE_NAME} -n ${NAMESPACE} --record >/dev/null || {
  echo "WARNING: Failed to set image on deployment/chat-app" >&2
}

# Rollout logic for single GPU (Recreate strategy expected)
echo "Ensuring single-pod rollout (GPU constraint)..."
kubectl rollout status deployment/chat-app -n ${NAMESPACE} --timeout=600s || {
  echo "Rollout status timeout; forcing scale cycle." >&2
  kubectl scale deployment/chat-app -n ${NAMESPACE} --replicas=0
  kubectl wait --for=delete pod -l app=chat-app -n ${NAMESPACE} --timeout=180s || true
  kubectl scale deployment/chat-app -n ${NAMESPACE} --replicas=1
  kubectl rollout status deployment/chat-app -n ${NAMESPACE} --timeout=600s
}

# If a pending pod remains due to GPU scheduling, recycle deployment
PENDING=$(kubectl get pods -n ${NAMESPACE} -l app=chat-app --no-headers | awk '$3=="Pending" {c++} END{print c+0}')
if [ "$PENDING" -gt 0 ]; then
  echo "Detected $PENDING pending pod(s); performing recreate cycle." >&2
  kubectl scale deployment/chat-app -n ${NAMESPACE} --replicas=0
  kubectl wait --for=delete pod -l app=chat-app -n ${NAMESPACE} --timeout=180s || true
  kubectl scale deployment/chat-app -n ${NAMESPACE} --replicas=1
  kubectl rollout status deployment/chat-app -n ${NAMESPACE} --timeout=600s || true
fi

echo "Final pod set:" 
kubectl get pods -n ${NAMESPACE} -l app=chat-app -o wide

echo "Deployment complete. Quick test commands:"
echo "kubectl port-forward -n chat svc/chat-app 8080:8080 &" 
echo "curl -s localhost:8080/healthz | jq || curl -s localhost:8080/healthz"

# --- Post-deploy profiler sanity check ---
SKIP_PROFILE_SANITY=${SKIP_PROFILE_SANITY:-0}
if [ "${SKIP_PROFILE_SANITY}" != "1" ]; then
  echo "Running profiler sanity check (set SKIP_PROFILE_SANITY=1 to skip)..." >&2
  # Select newest running pod
  POD=$(kubectl -n ${NAMESPACE} get pods -l app=chat-app -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.creationTimestamp}{" "}{.metadata.name}{"\n"}{end}' | sort | tail -n1 | awk '{print $2}')
  if [ -z "${POD}" ]; then
    echo "Profiler sanity: no running pod found; skipping." >&2
  else
    echo "Profiler sanity: targeting pod ${POD}" >&2
    # Wait for /healthz readiness (HTTP 200) up to 30s via exec curl inside container
    for i in {1..15}; do
      if kubectl -n ${NAMESPACE} exec "${POD}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/healthz" 2>/dev/null | grep -q '^200$'; then
        break
      fi
      sleep 2
    done
    # Issue profiling request
    PROF_TRACE=$(kubectl -n ${NAMESPACE} exec "${POD}" -- bash -c "curl -s -X POST 'http://localhost:8080/chat?profile=true' -H 'Content-Type: application/json' -d '{\"message\":\"profiler sanity\"}' | jq -r .profile_trace 2>/dev/null || true")
    if [ -z "${PROF_TRACE}" ] || echo "${PROF_TRACE}" | grep -qi 'error:'; then
      echo "Profiler sanity: profiling failed or returned error: ${PROF_TRACE}" >&2
    else
      echo "Profiler sanity: profile_trace reported: ${PROF_TRACE}" >&2
      # Check file existence (inside container)
      if kubectl -n ${NAMESPACE} exec "${POD}" -- bash -c "test -f ${PROF_TRACE} || test -f ${PROF_TRACE}.gz"; then
        echo "Profiler sanity: trace file exists." >&2
        kubectl -n ${NAMESPACE} exec "${POD}" -- bash -c "ls -lt $(dirname ${PROF_TRACE}) | head" >&2 || true
          # Retention / cleanup: keep only latest N compressed trace_*.json.gz (default 3)
          RETAIN=${PROFILE_TRACE_RETAIN:-3}
          TRACE_DIR=$(dirname "${PROF_TRACE}")
          echo "Profiler cleanup: retaining latest ${RETAIN} trace_*.json.gz and removing older + non-matching artifacts" >&2
          kubectl -n ${NAMESPACE} exec "${POD}" -- bash -c '
            set -euo pipefail
            cd '"${TRACE_DIR}"' 2>/dev/null || exit 0
            # Compress any raw trace_*.json not yet gzipped
            COMP_METHOD=${TRACE_RECOMPRESS:-gzip9}
            for f in trace_*.json; do
              [ -f "$f" ] || continue
              [ -f "$f.gz" ] && continue
              if [ "$COMP_METHOD" = "xz" ] && command -v xz >/dev/null 2>&1; then
                xz -T1 -9 -c "$f" > "$f.xz" && rm -f "$f" || true
              else
                gzip -9 -c "$f" > "$f.gz" && rm -f "$f" || true
              fi
            done
            # Remove non trace_*.json.gz profiler artifacts (e.g., pt.trace.json, summaries, tar archives)
            for f in *; do
              [ -f "$f" ] || continue
              case "$f" in
                trace_*.json.gz|trace_*.json.xz) ;; # keep candidates
                *) rm -f -- "$f" || true ;;
              esac
            done
            # Prune older gz beyond retention count
            count=0
            for f in $(ls -1t trace_*.json.gz trace_*.json.xz 2>/dev/null); do
              count=$((count+1))
              if [ $count -gt '"${RETAIN}"' ]; then
                rm -f -- "$f" || true
              fi
            done
            echo "Remaining traces:" >&2
            ls -1lt trace_*.json.gz trace_*.json.xz 2>/dev/null | head -n 10 >&2 || true
          ' || true
      else
        echo "Profiler sanity: trace file not found inside container." >&2
      fi
    fi
  fi
else
  echo "Skipping profiler sanity check (SKIP_PROFILE_SANITY=1)." >&2
fi