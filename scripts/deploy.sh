#!/usr/bin/env bash
set -euo pipefail

# Require docker usable without sudo
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker not accessible (permission denied). Fix by adding user to docker group or adjusting /var/run/docker.sock perms." >&2
  exit 1
fi

IMAGE_NAME="chat-app:latest"
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
    --image-name) IMAGE_NAME="$2"; shift 2 ;;
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
START_FLAGS=${START_FLAGS:-"--driver=docker --container-runtime=docker --gpus=all --kubernetes-version=${K8S_VERSION}"}
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
  local tries=30
  local sleep_s=6
  local i
  for i in $(seq 1 $tries); do
    if kubectl version >/dev/null 2>&1; then
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

echo "Waiting for any NVIDIA device plugin pod to be Running..."
for i in {1..45}; do
  if kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running || \
     kubectl get pods -A -l name=nvidia-device-plugin-ds 2>/dev/null | grep -q Running; then
    echo "Device plugin detected running."; break
  fi
  sleep 4
done
if ! (kubectl get pods -A -l k8s-app=nvidia-device-plugin 2>/dev/null | grep -q Running || \
      kubectl get pods -A -l name=nvidia-device-plugin-ds 2>/dev/null | grep -q Running); then
  echo "ERROR: No running NVIDIA device plugin pod after wait." >&2
  kubectl get pods -A | grep -i nvidia || true
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
  echo "WARNING: Node does not advertise nvidia.com/gpu yet." >&2
  echo "Attempting fallback Kubernetes versions..." >&2
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
    for i in {1..20}; do
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

echo "[5/6] Building image inside Minikube docker daemon (docker-env enforced)..."
eval "$(minikube -p ${MINIKUBE_PROFILE} docker-env)"
docker build -t ${IMAGE_NAME} .

echo "Verifying image presence in Minikube daemon..."
eval "$(minikube -p ${MINIKUBE_PROFILE} docker-env)"
if ! docker images | awk '{print $1":"$2}' | grep -q "^${IMAGE_NAME}$"; then
  echo "ERROR: Image ${IMAGE_NAME} not found in Minikube docker daemon after build." >&2
  exit 1
fi

NAMESPACE=${NAMESPACE:-chat}
echo "[6/6] Deploying and waiting for application pod in namespace '${NAMESPACE}'..."
kubectl get namespace ${NAMESPACE} >/dev/null 2>&1 || kubectl create namespace ${NAMESPACE}

HF_TOKEN=$HF_TOKEN
# Optional Hugging Face token secret creation (idempotent)
if [ -n "${HF_TOKEN:-}" ]; then
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