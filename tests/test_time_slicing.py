import json
import os
import shutil
import subprocess
import time
import uuid

import pytest


def _kubectl_json(args):
    cmd = ["kubectl"] + args
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)} failed: {res.stderr}\n")
    return json.loads(res.stdout)


@pytest.mark.skipif(shutil.which("kubectl") is None, reason="kubectl not installed")
def test_time_sliced_concurrent_scheduling():
    """Validate that multiple GPU-requiring pods can run concurrently on a single physical GPU node via time-slicing.

    Conditions for running:
    - kubectl installed
    - At least one node labeled with nvidia.com/gpu.replicas >=2 (indicates time-slicing configured)
    - gpu-operator/device plugin providing capacity so that Capacity nvidia.com/gpu > nvidia.com/gpu.count

    Steps:
    1. Discover a GPU node with replicas > count.
    2. Launch a short-lived busy Deployment (vectorAdd loop) with R replicas (default 3) each requesting 1 GPU.
    3. Wait until all pods are Running on the SAME node.
    4. Assert they scheduled concurrently (no pending) and replicas label >= pod count.
    5. Cleanup.

    Skips gracefully if prerequisites not met to avoid CI flakiness.
    """

    # Fetch nodes as JSON
    try:
        nodes = _kubectl_json(["get", "nodes", "-o", "json"])
    except Exception as e:  # pragma: no cover - infrastructure dependent
        pytest.skip(f"Cannot get nodes: {e}")

    target = None
    for item in nodes.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        replicas = labels.get("nvidia.com/gpu.replicas")
        count = labels.get("nvidia.com/gpu.count")
        if replicas and count:
            try:
                rep_i = int(replicas)
                cnt_i = int(count)
            except ValueError:
                continue
            if rep_i > cnt_i:  # oversubscription in effect
                target = {
                    "name": item["metadata"]["name"],
                    "replicas": rep_i,
                    "count": cnt_i,
                }
                break

    if target is None:
        pytest.skip("No node with time-slicing (gpu.replicas > gpu.count) found")

    desired_pods = int(os.environ.get("TS_TEST_PODS", "3"))
    desired_pods = max(2, min(desired_pods, target["replicas"]))

    deploy_name = f"ts-verify-{uuid.uuid4().hex[:6]}"
    manifest = f"""
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {deploy_name}
  labels:
    app: {deploy_name}
spec:
  replicas: {desired_pods}
  selector:
    matchLabels:
      app: {deploy_name}
  template:
    metadata:
      labels:
        app: {deploy_name}
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        kubernetes.io/hostname: {target['name']}
      containers:
        - name: vadd
          image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c", "--"]
          args: ["for i in $(seq 1 120); do /cuda-samples/vectorAdd >/dev/null 2>&1 || true; sleep 1; done"]
          resources:
            limits:
              nvidia.com/gpu: 1
    """

    # Apply manifest
    apply = subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if apply.returncode != 0:  # pragma: no cover
        pytest.skip(f"Failed to apply test deployment: {apply.stderr}")

    try:
        # Wait for pods running
        deadline = time.time() + 180
        running = set()
        scheduled_nodes = set()
        while time.time() < deadline:
            pods_json = _kubectl_json(["get", "pods", "-l", f"app={deploy_name}", "-o", "json"])
            items = pods_json.get("items", [])
            for p in items:
                phase = p.get("status", {}).get("phase")
                if phase == "Running":
                    running.add(p["metadata"]["name"])
                    node_name = p.get("spec", {}).get("nodeName")
                    if node_name:
                        scheduled_nodes.add(node_name)
            if len(running) == desired_pods:
                break
            time.sleep(3)

        if len(running) != desired_pods:  # pragma: no cover
            pytest.fail(f"Only {len(running)}/{desired_pods} pods Running after timeout")

        # Assert all on same node (time-slicing single physical GPU oversubscription)
        assert len(scheduled_nodes) == 1, f"Pods spread across nodes: {scheduled_nodes}"
        assert target["replicas"] >= desired_pods

    finally:
        subprocess.run(["kubectl", "delete", "deployment", deploy_name], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
