
- Pod spec requests GPUs: container.resources.limits (and usually requests) includes nvidia.com/gpu: <N>. (Must be >0; for device plugins limits==requests enforced by kubelet).
- Scheduler picks a node advertising sufficient allocatable nvidia.com/gpu (from device plugin’s ListAndWatch stream to kubelet).
- Kubelet sees a pod with a device plugin resource. For each container it calculates needed count and asks its Device Manager to allocate.
- Device Manager calls the device plugin’s Allocate RPC, passing the list of device IDs it tentatively selected.
NVIDIA device plugin chooses concrete devices (or MIG instances), and returns an AllocateResponse containing:
DeviceSpecs (host device paths like /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm etc.)
Mounts (host library directories or driver bundles) OR (in newer versions) CDI device references instead of raw mounts.
Env vars (e.g. NVIDIA_VISIBLE_DEVICES, NVIDIA_DRIVER_CAPABILITIES) if using legacy injection path.
Kubelet takes that response:
If legacy (no CDI): adds device nodes via container runtime (cgroup device allow + bind-mount), applies mounts, env vars.
If CDI is enabled and response lists CDI device names (gpu.nvidia.com/<id>): kubelet records CDI entries; the container runtime (containerd / CRI-O) invokes CDI resolver at container create time which injects devices, env, mounts declared in the CDI spec files (usually under /var/run/cdi/).
Container starts with /dev/nvidia* present and driver libs accessible (either through mounts or already on the base image).
Key conditions for kubelet to perform the mount / injection:

Resource name matches a registered device plugin resource (e.g. nvidia.com/gpu).
Resource requested in limits (and optionally requests) is non-zero.
Plugin successfully registered (plugin registered over /var/lib/kubelet/device-plugins/kubelet.sock and currently streaming ListAndWatch).
Allocate RPC succeeds and returns specs (or CDI references).
What kubelet does NOT do:

It does not “discover” /dev/nvidia* itself for pods with GPU requests; it relies entirely on the Allocate response (or CDI) from the plugin.
It does not install drivers; if devices/lib paths are missing on host, allocation can fail or container will error at runtime.
MIG nuance:

Plugin advertises MIG-backed resources (e.g. nvidia.com/mig-1g.5gb) or abstracts them into nvidia.com/gpu.
Allocation returns the specific MIG device nodes (e.g. /dev/nvidia-caps, /dev/nvidia0 plus /dev/nvidia-migX).
Same kubelet logic applies.
Pre-CDI vs CDI path:

Pre-CDI: Bind mounts + env from AllocateResponse.
CDI: Allocate just returns device IDs; kubelet records CDI entries; container runtime loads CDI spec (JSON) that defines devices, mounts, env; runtime applies them atomically.
Failure cases (no mounts/injection):

Resource only in requests (not limits) or mismatch limits != requests (kubelet rejects device plugin resource).
Plugin crash / deregistration before Allocate.
Allocate error (kubelet will retry or fail pod start).
CDI spec missing or malformed (runtime start failure).