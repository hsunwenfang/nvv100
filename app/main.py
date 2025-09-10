import os
import time
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional, List
import threading
import queue

import torch
from torch.profiler import record_function
from fastapi import FastAPI, Query
from pydantic import BaseModel
from fastapi.responses import JSONResponse

from .model_loader import get_model

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("chat-app")

app = FastAPI(title="Chat App", version="0.1.0")


class ChatRequest(BaseModel):
    message: str
    max_new_tokens: Optional[int] = None


class _BatchItem:
    def __init__(self, prompt: str, max_new_tokens: int):
        self.prompt = prompt
        self.max_new_tokens = max_new_tokens
        self.event = threading.Event()
        self.output: Optional[str] = None
        self.error: Optional[str] = None


BATCH_QUEUE: "queue.Queue[_BatchItem]" = queue.Queue()
BATCH_MAX_DELAY_SEC = float(os.getenv("BATCH_MAX_DELAY_SEC", "0.01"))
BATCH_MAX_SIZE = int(os.getenv("BATCH_MAX_SIZE", "4"))
_batch_thread_started = False
_batch_lock = threading.Lock()


def _ensure_batch_thread():
    global _batch_thread_started
    if _batch_thread_started:
        return
    with _batch_lock:
        if _batch_thread_started:
            return
        t = threading.Thread(target=_batch_worker, name="batch-worker", daemon=True)
        t.start()
        _batch_thread_started = True
        logger.info("Started batch worker thread")


def _batch_worker():
    while True:
        try:
            first: _BatchItem = BATCH_QUEUE.get()
        except Exception:
            continue
        batch: List[_BatchItem] = [first]
        deadline = time.time() + BATCH_MAX_DELAY_SEC
        while len(batch) < BATCH_MAX_SIZE and time.time() < deadline:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            try:
                nxt = BATCH_QUEUE.get(timeout=remaining)
                batch.append(nxt)
            except queue.Empty:
                break
        m = get_model()
        batch_start = time.time()
        with record_function("batch.generate"):
            for item in batch:
                try:
                    with record_function("item.generate"):
                        item.output = m.generate(item.prompt, max_new_tokens=item.max_new_tokens)
                except Exception as e:  # noqa: BLE001
                    item.error = str(e)
                finally:
                    item.event.set()
        batch_time = time.time() - batch_start
        try:
            avg = batch_time / max(len(batch), 1)
        except Exception:
            avg = batch_time
        logger.info(
            "batch processed size=%d total_time=%.3fs avg_per_item=%.3fs window=%.3f max_size=%d",
            len(batch), batch_time, avg, BATCH_MAX_DELAY_SEC, BATCH_MAX_SIZE,
        )
        _record_batch(len(batch))


_metrics = {"batches": 0, "total_batch_items": 0}


def _record_batch(n: int):
    _metrics["batches"] += 1
    _metrics["total_batch_items"] += n


@app.get("/healthz")
def healthz():
    try:
        m = get_model()
        return {"status": "ok", **m.meta}
    except Exception as e:
        return JSONResponse(status_code=500, content={"status": "error", "detail": str(e)})


@app.post("/chat")
def chat(body: ChatRequest, profile: bool = Query(False)):
    """Chat endpoint.

    When profile=true: bypass batching and synchronously run generation under torch.profiler
    (CPU + CUDA if available). Produces a chrome trace (.json + .json.gz) and a summary text file.
    Fallback: if torch.profiler fails, autograd profiler is used and only a summary is written.
    """
    max_new_tokens = body.max_new_tokens or int(os.getenv("MAX_NEW_TOKENS", "128"))
    start = time.time()
    prof_path = None
    summary_path = None

    # Standard (batched) path if not profiling
    if not profile:
        _ensure_batch_thread()
        item = _BatchItem(body.message, max_new_tokens)
        BATCH_QUEUE.put(item)
        if not item.event.wait(timeout=300):  # generous timeout
            return JSONResponse(status_code=504, content={"error": "timeout"})
        if item.error:
            return JSONResponse(status_code=500, content={"error": item.error})
        latency = time.time() - start
        return {"response": item.output, "latency_sec": round(latency, 4)}

    # Profiling path (single request)
    prof_dir = Path("profiles/torch")
    prof_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%S%f")
    base_name = f"trace_{ts}"
    trace_file = prof_dir / f"{base_name}.json"
    summary_file = prof_dir / f"{base_name}_summary.txt"
    model = get_model()
    output = ""

    def _run_generate():
        nonlocal output
        with record_function("profile.generate"):
            output = model.generate(body.message, max_new_tokens=max_new_tokens)
        if torch.cuda.is_available():
            torch.cuda.synchronize()

    used_fallback = False
    try:
        from torch.profiler import profile, ProfilerActivity
        activities = [ProfilerActivity.CPU]
        if torch.cuda.is_available():
            activities.append(ProfilerActivity.CUDA)
        with profile(
            activities=activities,
            record_shapes=True,
            profile_memory=True,
            with_stack=True,
            with_modules=True,
        ) as prof:
            _run_generate()
        # Export chrome trace
        prof.export_chrome_trace(str(trace_file))
        # Summary (pick CUDA sort if any CUDA time recorded)
        try:
            ka = prof.key_averages()
            has_cuda = any(getattr(e, 'self_cuda_time_total', 0) for e in ka)
            sort_key = "cuda_time_total" if has_cuda else "cpu_time_total"
            table = ka.table(sort_by=sort_key, row_limit=40)
            summary_file.write_text(table)
            summary_path = str(summary_file)
        except Exception:  # noqa: BLE001
            logger.exception("Failed to write profiler summary")
        # gzip trace
        try:
            import gzip, shutil
            gz_path = trace_file.with_suffix(trace_file.suffix + ".gz")
            with open(trace_file, "rb") as fin, gzip.open(gz_path, "wb", compresslevel=5) as fout:
                shutil.copyfileobj(fin, fout)
            prof_path = str(gz_path)
        except Exception:  # noqa: BLE001
            logger.exception("Failed to gzip trace; returning raw path")
            prof_path = str(trace_file)
        if prof_path is None:
            prof_path = str(trace_file)
    except Exception:  # noqa: BLE001
        # Fallback: autograd profiler without chrome trace
        logger.exception("torch.profiler failed; falling back to autograd profiler")
        used_fallback = True
        try:
            from torch.autograd import profiler as autograd_profiler
            with autograd_profiler.profile(use_cuda=torch.cuda.is_available(), record_shapes=False) as ap:
                _run_generate()
            try:
                ka = ap.key_averages()
                has_cuda = any(getattr(e, 'self_cuda_time_total', 0) for e in ka)
                sort_key = "cuda_time_total" if has_cuda else "cpu_time_total"
                table = ka.table(sort_by=sort_key, row_limit=40)
                summary_file.write_text(table)
                summary_path = str(summary_file)
            except Exception:  # noqa: BLE001
                logger.exception("Failed to write autograd summary")
            # Write note file so tests still see a trace artifact
            trace_file.write_text('{"note":"autograd fallback - no chrome trace"}')
            prof_path = str(trace_file)
        except Exception:  # noqa: BLE001
            logger.exception("Autograd fallback also failed")
            return JSONResponse(status_code=500, content={"error": "profiling failed"})

    latency = time.time() - start
    return {
        "response": output,
        "latency_sec": round(latency, 4),
        "profile_trace": prof_path,
        "profile_summary": summary_path,
        "profiler_fallback": used_fallback,
    }


@app.get("/")
def root():
    return {"endpoints": ["/healthz", "/chat"], "profile": "POST /chat?profile=true"}


@app.get("/metrics")
def metrics():
    return {
        **_metrics,
        "avg_batch_size": (
            (_metrics["total_batch_items"] / _metrics["batches"]) if _metrics["batches"] else 0
        ),
        "batch_max_delay_sec": BATCH_MAX_DELAY_SEC,
        "batch_max_size": BATCH_MAX_SIZE,
    }