import os
import glob
import shutil
from pathlib import Path

os.environ.setdefault("MODEL_SOURCE", "hf")
os.environ.setdefault("MODEL_NAME", "tiny")  # uses sshleifer/tiny-gpt2
os.environ.setdefault("MAX_NEW_TOKENS", "16")

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402

client = TestClient(app)


def setup_module(module):  # noqa: D401
    prof_dir = Path("profiles")
    if prof_dir.exists():
        shutil.rmtree(prof_dir)


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["status"] == "ok"
    assert "model_name" in data


def test_chat():
    r = client.post("/chat", json={"message": "Hello"})
    assert r.status_code == 200, r.text
    data = r.json()
    assert "response" in data
    assert data["model"]["model_name"].endswith("tiny-gpt2")


def test_chat_profile_creates_trace():
    r = client.post("/chat?profile=true", json={"message": "Profile run"})
    assert r.status_code == 200, r.text
    data = r.json()
    trace_path = data.get("profile_trace")
    assert trace_path and trace_path.endswith(".json")
    assert Path(trace_path).is_file()
    # At least one trace file present
    files = glob.glob("profiles/torch/trace_*.json")
    assert files, "No trace files found"