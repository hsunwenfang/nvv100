#!/usr/bin/env bash
set -euo pipefail

# User-space installer for NVIDIA GPU Operator with time-slicing enabled.
# Does NOT modify existing app deploy scripts.

OPERATOR_NS=${GPU_OPERATOR_NAMESPACE:-gpu-operator}
CONFIG_MAP=k8s/time-slicing-config-all.yaml
HELM_BIN=./bin/helm
VERSION_FLAG=${GPU_OPERATOR_VERSION_FLAG:---version v25.3.3}

mkdir -p bin

if [[ ! -x ${HELM_BIN} ]]; then
  echo "[gpu-operator] Downloading Helm locally" >&2
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH=amd64;;
    aarch64) ARCH=arm64;;
  esac
  curl -sSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v3.14.4-linux-${ARCH}.tar.gz
  tar -C /tmp -xzf /tmp/helm.tar.gz
  mv /tmp/linux-${ARCH}/helm ${HELM_BIN}
  chmod +x ${HELM_BIN}
fi

if ! kubectl get ns ${OPERATOR_NS} >/dev/null 2>&1; then
  echo "[gpu-operator] Creating namespace ${OPERATOR_NS}" >&2
  kubectl create namespace ${OPERATOR_NS}
fi

echo "[gpu-operator] Applying time-slicing ConfigMap (${CONFIG_MAP})" >&2
kubectl apply -f ${CONFIG_MAP}

echo "[gpu-operator] Adding NVIDIA Helm repo" >&2
${HELM_BIN} repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
${HELM_BIN} repo update >/dev/null 2>&1 || true

if kubectl get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
  echo "[gpu-operator] ClusterPolicy CRD already exists. Skipping install, patching for time-slicing." >&2
  kubectl patch clusterpolicies.nvidia.com/cluster-policy -n ${OPERATOR_NS} --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config-all", "default": "any"}}}}' || true
else
  echo "[gpu-operator] Installing GPU Operator (this may take a few minutes)" >&2
  set +e
  ${HELM_BIN} install gpu-operator nvidia/gpu-operator -n ${OPERATOR_NS} \
    --set devicePlugin.config.name=time-slicing-config-all \
    --set devicePlugin.config.default=any ${VERSION_FLAG}
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[gpu-operator] Helm install failed (rc=$rc)." >&2
    exit $rc
  fi
fi

echo "[gpu-operator] Waiting for device plugin & GFD DaemonSets" >&2
kubectl rollout status -n ${OPERATOR_NS} daemonset/nvidia-device-plugin-daemonset --timeout=300s || true
kubectl rollout status -n ${OPERATOR_NS} daemonset/gpu-feature-discovery --timeout=300s || true

echo "[gpu-operator] Polling node labels for time-slicing (up to 120s)" >&2
deadline=$((SECONDS+120))
found=0
while (( SECONDS < deadline )); do
  out=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels."nvidia.com/gpu.count"}{"|"}{.metadata.labels."nvidia.com/gpu.replicas"}{"\n"}{end}' 2>/dev/null || true)
  while IFS='|' read -r name count replicas; do
    [[ -z "$name" ]] && continue
    if [[ -n "$count" && -n "$replicas" && "$replicas" != "$count" ]]; then
      echo "[gpu-operator] Detected time-slicing on node $name (count=$count replicas=$replicas)" >&2
      found=1; break
    fi
  done <<<"$out"
  (( found )) && break
  sleep 5
done

if (( ! found )); then
  echo "[gpu-operator] Time-slicing labels not observed (gpu.replicas != gpu.count)." >&2
  echo "[gpu-operator] Describe a node manually: kubectl describe node <node> | grep -E 'gpu.replicas|gpu.count'" >&2
else
  echo "[gpu-operator] Time-slicing configuration appears active." >&2
fi

echo "[gpu-operator] Done." >&2