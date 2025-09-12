import os
import time
import math
import multiprocessing as mp

import pytest

try:
    import torch
except Exception:  # pragma: no cover
    torch = None


def _worker(device_index: int, iters: int, size: int, dtype: str, q: mp.Queue):
    try:
        torch.cuda.set_device(device_index)
        dt = getattr(torch, dtype)
        a = torch.randn(size, size, device=f"cuda:{device_index}", dtype=dt)
        b = torch.randn(size, size, device=f"cuda:{device_index}", dtype=dt)
        torch.cuda.synchronize(device_index)
        t0 = time.time()
        c = None
        for _ in range(iters):
            c = a @ b  # matmul
        torch.cuda.synchronize(device_index)
        elapsed = time.time() - t0
        # return checksum to ensure computation happened
        checksum = float(c[0, 0].item()) if c is not None else math.nan
        q.put((device_index, elapsed, checksum))
    except Exception as e:  # pragma: no cover
        q.put((device_index, -1.0, repr(e)))


@pytest.mark.timeout(120)
def test_parallel_gpu_usage():
    """Validate that multiple CUDA devices (e.g., MIG instances) can run workloads in parallel.

    Strategy:
    1. Skip if torch or CUDA unavailable, or fewer than 2 visible devices.
    2. Perform a sequential run across N devices collecting total time.
    3. Spawn N processes doing identical matmul loops concurrently.
    4. Assert all succeeded and parallel wall time < sequential time * 0.9 (10% speedup threshold).

    Notes:
    - Time threshold is loose to reduce flakiness.
    - For time-slicing (single device) this test skips; separate logic would be needed.
    """
    if torch is None:
        pytest.skip("torch not available")
    if not torch.cuda.is_available():
        pytest.skip("CUDA not available")

    device_count = torch.cuda.device_count()
    if device_count < 2:
        pytest.skip(f"Need >=2 CUDA devices (MIG instances or GPUs); have {device_count}")

    # Parameters
    iters = int(os.environ.get("MIG_TEST_ITERS", "5"))
    size = int(os.environ.get("MIG_TEST_SIZE", "512"))
    dtype = os.environ.get("MIG_TEST_DTYPE", "float16")

    # Sequential baseline
    seq_start = time.time()
    seq_checksums = []
    for d in range(device_count):
        torch.cuda.set_device(d)
        dt = getattr(torch, dtype)
        a = torch.randn(size, size, device=f"cuda:{d}", dtype=dt)
        b = torch.randn(size, size, device=f"cuda:{d}", dtype=dt)
        torch.cuda.synchronize(d)
        for _ in range(iters):
            c = a @ b
        torch.cuda.synchronize(d)
        seq_checksums.append(float(c[0, 0].item()))
    seq_time = time.time() - seq_start

    # Parallel run (process per device)
    mgr_q = mp.Queue()
    procs = [mp.Process(target=_worker, args=(d, iters, size, dtype, mgr_q)) for d in range(device_count)]
    par_start = time.time()
    for p in procs:
        p.start()
    results = []
    for _ in procs:
        results.append(mgr_q.get(timeout=60))
    for p in procs:
        p.join(timeout=60)
    par_time = time.time() - par_start

    # Validate results
    assert len(results) == device_count
    for (dev, elapsed, checksum) in results:
        assert elapsed > 0, f"Device {dev} failed: {checksum}"
        assert isinstance(checksum, float)

    # Parallel should be materially faster than sequential total (allow generous margin)
    assert par_time < seq_time * 0.9, f"Parallel time {par_time:.2f}s not < 90% of sequential {seq_time:.2f}s"

    # Basic diversity check: checksums should differ across devices (random inputs)
    parallel_checksums = [r[2] for r in results]
    assert len(set(parallel_checksums)) == device_count

    # Provide debug output for logs
    print(f"Sequential time: {seq_time:.3f}s for {device_count} devices; Parallel time: {par_time:.3f}s; Speedup: {seq_time/par_time:.2f}x")
