## Minikube GPU Enablement Report

### Overview
This document explains why earlier GPU Minikube attempts failed, the mechanisms required for GPU resource advertisement in Kubernetes, and the final working configuration.

### GPU Enablement Mechanism (Kubernetes Device Plugin Flow)
1. Host prerequisites: NVIDIA driver + nvidia-container-toolkit configure Docker default runtime = `nvidia` (or pass `--gpus=all`).
2. Minikube (docker driver) container is launched with `--gpus=all`, exposing `/dev/nvidia*` inside the node.
3. NVIDIA device plugin DaemonSet starts, loads NVML, enumerates GPUs, and registers the `nvidia.com/gpu` resource with the kubelet over the device plugin gRPC socket.
4. Kubelet updates Node status (Capacity/Allocatable). Scheduler can then place pods requesting `resources.limits.nvidia.com/gpu: 1`.
5. Pod runs in a container runtime that mounts the device nodes (already present because the minikube container inherited them via `--gpus=all`).

### Failure Points Encountered & Root Causes
| Phase | Symptom | Root Cause | Resolution |
|-------|---------|-----------|-----------|
| Early start (v1.33.1) | Apiserver never became healthy; addon apply validation errors | Bleeding-edge / unsupported version; race applying addons before API served | Pin stable version (`v1.31.0`) and gate on apiserver readiness before addon/device logic |
| Fallback attempt | Kubelet health timeout; unknown flag `--cgroupDriver` | Wrong flag form (legacy) + mismatch forcing systemd while Docker used cgroupfs | Detect Docker cgroup driver dynamically; use `--extra-config=kubelet.cgroup-driver=cgroupfs` |
| Device plugin wait | `kubectl wait` found no resources | Script used selector without namespace; addon pod actually in `kube-system` | Add namespace logic; fallback to custom YAML if addon yields no pod |
| NVML init failures (earlier iterations) | `Failed to initialize NVML` in logs | Device nodes missing or runtime not exposing libraries (no `--gpus=all` or runtime misconfig) | Ensure host docker default runtime=nvidia and pass `--gpus=all` during minikube start |
| ImagePullBackOff for app | Node tried to pull `chat-app:latest` from registry | Image built on host daemon (eval not in effect) or build skipped | Use `eval $(minikube docker-env)` or `minikube image build` and verify presence |
| Addon produced no pod | No `nvidia-device-plugin` pod despite addon enabled | Intermittent addon deployment or label/ timing issue | Fallback to custom DaemonSet YAML |

### Key Lessons
1. Always verify apiserver readiness before enabling or waiting on addons.
2. Align kubelet cgroup driver with container runtime (`docker info | grep CgroupDriver`).
3. Treat the addon as opportunistic; include a deterministic fallback manifest.
4. After switching Docker context to Minikube, immediately sanity check with `docker ps` and `docker images`.
5. Prefer `minikube image build -t <image>` as a portable alternative to `eval $(minikube docker-env); docker build ...`.
6. Label & namespace differences matter: addon pods live in `kube-system`; custom YAML defaults to `default` unless specified.

### Final Working Flow (Summarized)
1. `minikube delete`
2. `minikube start --driver=docker --container-runtime=docker --gpus=all --kubernetes-version=v1.31.0 --addons=nvidia-device-plugin --extra-config=kubelet.cgroup-driver=$(docker info --format '{{.CgroupDriver}}')`
3. If addon pod absent after ~30s: `kubectl apply -f k8s/nvidia-device-plugin.yml`
4. Confirm: `/dev/nvidia0` inside node, device plugin logs show NVML loaded, node advertises `nvidia.com/gpu: 1`.
5. Build image inside Minikube: `minikube image build -t chat-app:latest .` (or docker-env + docker build).
6. Deploy in namespace `chat` and verify pod pulls local image (Image ID set, no external pull attempts).

### Verification Checklist
- [x] `nvidia-smi -L` on host
- [x] `minikube ssh -- ls /dev/nvidia0`
- [x] Device plugin pod Running (addon or fallback)
- [x] `kubectl describe node | grep nvidia.com/gpu`
- [x] Smoke pod with `nvidia-smi` succeeds
- [x] Application pod Ready with GPU limit

### Troubleshooting Quick Reference
| Check | Command | Expected |
|-------|---------|----------|
| Host GPU | `nvidia-smi -L` | Lists GPU(s) |
| Node device | `minikube ssh -- ls /dev/nvidia0` | File exists |
| Plugin pod | `kubectl get pods -A -l k8s-app=nvidia-device-plugin` | 1/1 Running |
| Node resource | `kubectl describe node minikube | grep nvidia.com/gpu` | Capacity ≥1 |
| Local image built | `eval $(minikube docker-env); docker images | grep chat-app` | Shows tag `latest` |
| Pod Image ID | `kubectl get pod -n chat -o wide` | IMAGE column not empty |

### Appendix: Why `ImagePullBackOff` Happened
Because the image wasn’t present in the Minikube container runtime (only on host or not built), kubelet attempted a registry pull, failed (no repo `chat-app`), and entered exponential backoff. Fix: build the image inside Minikube’s Docker (or use `minikube image build`). Restart or delete the failing pod after image build.

---
Generated for internal GPU deployment clarity.
# Minikube GPU Enablement Report

## Overview
This document explains the failures encountered in earlier attempts to run a GPU-enabled Minikube cluster (Docker driver + V100) for the chat application, the underlying mechanisms, and the final working configuration.

## Timeline of Attempts
1. Initial starts with `--driver=docker` + manual device plugin YAML: kubelet / apiserver failed; NVML initialization errors.
2. Retried with different Kubernetes versions (v1.30.0, v1.33.1): apiserver never became healthy (kubelet not running) leading to addon apply errors.
3. Added fallback logic (cgroup driver, feature gates) — still unstable; kubelet flag mismatches shown in logs.
4. Successful run achieved by simplifying flags, aligning cgroup driver, enabling addon at start, and falling back to custom `nvidia-device-plugin` DaemonSet when addon produced no pod.

## Root Causes of Failures
| Symptom | Observed Log / Behavior | Root Cause | Mechanism |
|---------|-------------------------|------------|-----------|
| Apiserver never appears | `wait ... apiserver process never appeared` | Kubelet startup failure | Kubelet is responsible for launching static pod manifests for control plane; if kubelet doesn't run, apiserver never launches. |
| Kubelet health timeout | `curl ... localhost:10248/healthz` timeout | Kubelet crashed early due to bad flag | Passing `--cgroupDriver=systemd` flag style not valid for kubelet version; modern kubelet expects config file or `--cgroup-driver`. |
| Unknown kubelet flag errors | `failed to parse kubelet flag: unknown flag: --cgroupDriver` | Incorrect camelCase flag | Kubelet flag names are kebab-case; `--cgroupDriver` invalid. |
| NVML init failed (earlier) | `Failed to initialize NVML` in device plugin | Missing NVIDIA runtime integration in Minikube container | Docker driver Minikube container must be started with GPU devices; without `--gpus=all`, /dev/nvidia* absent so NVML fails. |
| Device plugin pod absent when addon enabled | No pod found with addon label | Addon enabled but addon apply raced with apiserver readiness or image pull; or addon manifest changed | Addon manager could not apply manifest during apiserver bring-up; no later reconciliation produced the pod. |

## Technical Mechanisms
### 1. Minikube Docker Driver + GPU Pass-through
`minikube start --driver=docker --gpus=all` creates a Docker container (the “node”) with GPU devices injected. Without `--gpus=all`, `/dev/nvidia*` devices and associated libraries aren’t inside the node, so NVML (NVIDIA Management Library) cannot initialize.

### 2. cgroup Driver Alignment
Container runtimes (Docker) and kubelet must agree on cgroup driver (e.g., `cgroupfs` vs `systemd`). Mismatches can cause kubelet restarts or suboptimal behavior. We now auto-detect via `docker info --format '{{.CgroupDriver}}'` and pass `--extra-config=kubelet.cgroup-driver=<value>` to Minikube to ensure alignment.

### 3. Device Plugin Registration Flow
The NVIDIA device plugin watches `/var/lib/kubelet/device-plugins/` and registers a gRPC socket for `nvidia.com/gpu`. Kubelet queries that socket to advertise resources. Sequence:
1. GPU devices visible (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`).
2. Device plugin container runs, loads NVML (`libnvidia-ml.so`), enumerates devices.
3. Plugin creates Unix socket; kubelet connects and updates node status with `capacity.allocatable` for `nvidia.com/gpu`.
4. Pods requesting `resources.limits.nvidia.com/gpu: 1` become schedulable.

### 4. Why Addon Sometimes Fails
The addon manager applies manifests early. If apiserver isn’t ready, the apply fails. Unlike some controllers, Minikube's addon enable may not continuously retry aggressively. Net effect: addon shows enabled but no DaemonSet created. Manual YAML apply works because we run it after apiserver readiness.

### 5. Kubernetes Version Sensitivity
Bleeding edge versions (e.g., v1.33.x dev builds) may introduce flag or API changes. Pinning to a stable GA release (v1.31.0) removes variability and ensures kubelet flag compatibility.

## Final Working Start Command (Implicit via Script)
```
minikube start \
  --driver=docker \
  --container-runtime=docker \
  --gpus=all \
  --kubernetes-version=v1.31.0 \
  --addons=nvidia-device-plugin \
  --extra-config=kubelet.cgroup-driver=$(docker info --format '{{.CgroupDriver}}')
```
If addon pod missing, apply custom DaemonSet:
```
kubectl apply -f k8s/nvidia-device-plugin.yml
```

## Validation Steps
1. Host GPU: `nvidia-smi -L`
2. Node devices: `minikube ssh -- ls /dev/nvidia0`
3. Device plugin pod: `kubectl get pods -A -l k8s-app=nvidia-device-plugin || kubectl get pods -l name=nvidia-device-plugin-ds`
4. Node resource: `kubectl describe node minikube | grep nvidia.com/gpu`
5. Smoke test: GPU pod running `nvidia-smi`.

## Common Pitfalls & Fixes
| Pitfall | Detection | Fix |
|---------|-----------|-----|
| Missing /dev/nvidia0 in node | `minikube ssh` ls fails | Recreate with `--gpus=all`; verify host `docker run --rm --gpus all nvidia/cuda:... nvidia-smi` |
| No device plugin pod | `kubectl get pods` empty | Apply custom YAML after apiserver ready |
| NVML fail | Logs contain `Failed to initialize NVML` | Ensure GPU devices and correct NVIDIA driver/toolkit on host |
| Kubelet unknown flag | Logs show `unknown flag` | Remove invalid kubelet flags; rely on `--extra-config=kubelet.cgroup-driver=` |
| Apiserver never up | `minikube logs` repeating kubelet errors | Check cgroup driver, reduce flags, pin supported Kubernetes version |

## Recommendations
- Keep start flags minimal; only add what’s proven needed.
- Always align cgroup drivers automatically.
- Treat addon as best-effort; keep custom YAML as fallback.
- Pin to stable Kubernetes version for reproducibility.
- Implement readiness gating before GPU plugin actions.

## Appendix: File References
- `scripts/deploy.sh` orchestrates start, readiness checks, device plugin handling, and app deployment.
- `k8s/nvidia-device-plugin.yml` provides manual DaemonSet fallback.

---
Generated report to capture rationale and prevent regressions.
