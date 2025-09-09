Chat App with Profiling on V100

Endpoints:
- GET /healthz returns status and model info
- POST /chat with JSON {"message":"..."}

Supports HuggingFace or Ollama models (aliases: llama2, llama3.1, mistral, gemma2-9b, gemma2-27b).

Profiling: torch.profiler (per request), nvidia-smi dmon, mpstat per-core.

See scripts/deploy.sh and scripts/profile_app.sh.