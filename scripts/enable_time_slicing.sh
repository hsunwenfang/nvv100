#!/usr/bin/env bash
set -euo pipefail

# Enable NVIDIA GPU time-slicing using the GPU Operator (preferred) or provide guidance if operator absent.
# This script assumes you have cluster admin permissions.

NS=${GPU_OPERATOR_NAMESPACE:-gpu-operator}
CONFIG_CM=time-slicing-config-all
REPLICAS=${GPU_TS_REPLICAS:-4}

echo "[time-slicing] Ensuring namespace $NS exists" >&2
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

echo "[time-slicing] Applying config map ($REPLICAS replicas per physical GPU)" >&2
cat > /tmp/ts-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIG_CM}
  namespace: ${NS}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
          - name: nvidia.com/gpu
            replicas: ${REPLICAS}
EOF
kubectl apply -f /tmp/ts-config.yaml

if ! kubectl get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
  cat <<'NOTE'
[time-slicing] GPU Operator not detected (clusterpolicies.nvidia.com CRD missing).
Install operator via Helm (example):
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
  helm install gpu-operator nvidia/gpu-operator -n ${NS} \
    --set devicePlugin.config.name=${CONFIG_CM} \
    --set devicePlugin.config.default=any

After install, re-run this script or patch cluster policy manually.
NOTE
  exit 0
fi

echo "[time-slicing] Patching ClusterPolicy to set default time-slicing config" >&2
kubectl patch clusterpolicies.nvidia.com/cluster-policy -n ${NS} --type merge \
  -p '{"spec": {"devicePlugin": {"config": {"name": "'${CONFIG_CM}'", "default": "any"}}}}'

echo "[time-slicing] Waiting for device plugin + GFD pods to roll out" >&2
kubectl rollout status -n ${NS} daemonset/nvidia-device-plugin-daemonset --timeout=120s || true
kubectl rollout status -n ${NS} daemonset/gpu-feature-discovery || true

echo "[time-slicing] Node labels (gpu.*) after patch:" >&2
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{":\n"}{range $k,$v := .metadata.labels}{if regexMatch("nvidia.com/gpu.*", $k)}{$k}{"="}{$v}{"\n"}{end}{end}{"---\n"}{end}' || true

echo "[time-slicing] Done. Verify capacity via: kubectl describe node <node-name> | grep -E 'gpu.replicas|Allocatable|Capacity'" >&2