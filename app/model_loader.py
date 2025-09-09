import os
import json
import logging
from typing import Optional, Dict, Any, List

import torch
from transformers import AutoTokenizer, AutoModelForCausalLM

logger = logging.getLogger(__name__)

ALIAS_CANDIDATES = {
    # NOTE: Some upstream models (Llama / Gemma large) are gated or may exceed single V100 16GB.
    # We provide ordered fallbacks of increasingly general open models that usually do not require auth.
    "llama2": [
        # Primary (gated) – skipped unless ACCEPT_GATED=1
        "meta-llama/Llama-2-7b-chat-hf",
        # Community or lighter open chat alternatives
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "openlm-research/open_llama_3b",
        "HuggingFaceH4/zephyr-7b-beta"
    ],
    "llama3.1": [
        "meta-llama/Meta-Llama-3.1-8B-Instruct",  # gated
        "meta-llama/Meta-Llama-3-8B-Instruct",     # gated (older tag)
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "HuggingFaceH4/zephyr-7b-beta"
    ],
    "mistral": [
        "mistralai/Mistral-7B-Instruct-v0.2",
        "mistralai/Mistral-7B-Instruct-v0.1",
        "HuggingFaceH4/zephyr-7b-beta",
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
    ],
    "gemma2-9b": [
        "google/gemma-2-9b-it",  # may require acceptance
        "google/gemma-2-2b-it",
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
    ],
    "gemma2-27b": [
        "google/gemma-2-27b-it",  # >16GB, likely OOM on single V100 16GB
        "google/gemma-2-9b-it",
        "google/gemma-2-2b-it",
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
    ],
    # Tiny explicit
    "tiny": ["sshleifer/tiny-gpt2"],
}


class ChatModel:
    def __init__(self):
        self.model = None
        self.tokenizer = None
        self.meta: Dict[str, Any] = {}

    def load(self):
        source = os.getenv("MODEL_SOURCE", "hf").lower()
        requested = os.getenv("MODEL_NAME") or os.getenv("HF_MODEL_FAMILY", "llama2")

        # Candidate resolution
        if "/" in requested and requested not in ALIAS_CANDIDATES:
            candidates = [requested]
        else:
            candidates = ALIAS_CANDIDATES.get(requested, [requested])

        accept_gated = (os.getenv("ACCEPT_GATED", "0") == "1") or bool(
            os.getenv("HUGGING_FACE_HUB_TOKEN") or os.getenv("HF_TOKEN")
        )
        quantize = os.getenv("QUANTIZE")
        last_error = None
        chosen_name = None

        if source == "ollama":
            remote_name = os.getenv("MODEL_NAME", requested)
            self.meta = {
                "source": source,
                "model_name": remote_name,
                "device": "remote",
                "dtype": None,
                "quantization": None,
                "requested": requested,
            }
            return

        def is_potentially_gated(name: str) -> bool:
            lower = name.lower()
            gated_markers = ["meta-llama/", "mistralai/", "gemma-", "google/gemma", "google/gemma-2"]
            return any(m in lower for m in gated_markers)

        for candidate in candidates:
            try:
                if is_potentially_gated(candidate) and not accept_gated:
                    logger.info(f"Skipping gated candidate (no token / ACCEPT_GATED): {candidate}")
                    continue
                logger.info(f"Attempting to load model candidate: {candidate}")
                load_kwargs = {"device_map": "auto"}
                if quantize == "4":
                    load_kwargs["load_in_4bit"] = True
                if torch.cuda.is_available() and ("27b" in candidate.lower() or "70b" in candidate.lower()):
                    total_mem = torch.cuda.get_device_properties(0).total_memory
                    if total_mem < 30 * 1024**3:
                        logger.warning(
                            f"Skipping {candidate} (likely OOM on <30GB GPU; detected {(total_mem/1024**3):.1f}GB)"
                        )
                        continue
                self.tokenizer = AutoTokenizer.from_pretrained(candidate, use_fast=True)
                if self.tokenizer.pad_token is None:
                    self.tokenizer.pad_token = self.tokenizer.eos_token
                self.model = AutoModelForCausalLM.from_pretrained(
                    candidate, torch_dtype="auto", **load_kwargs
                )
                chosen_name = candidate
                break
            except Exception as e:  # noqa: BLE001
                msg = str(e)
                last_error = msg
                if "gated repo" in msg.lower() and not accept_gated:
                    logger.warning(f"Gated model skipped (no ACCEPT_GATED): {candidate}")
                else:
                    logger.warning(f"Failed loading candidate {candidate}: {e}")
                continue

        if not chosen_name:
            raise RuntimeError(
                f"Unable to load any candidate for '{requested}'. Last error: {last_error}"
            )

        dtype = getattr(self.model, "dtype", None)
        self.meta = {
            "source": source,
            "model_name": chosen_name,
            "device": str(next(self.model.parameters()).device),
            "dtype": str(dtype),
            "quantization": "4bit" if quantize == "4" else None,
            "requested": requested,
        }

    def generate(self, message: str, max_new_tokens: int = 128) -> str:
        source = self.meta.get("source")
        if source == "ollama":
            return self._generate_ollama(message, max_new_tokens)
        if self.model is None:
            self.load()
        inputs = self.tokenizer(message, return_tensors="pt").to(self.model.device)
        with torch.no_grad():
            output_ids = self.model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                do_sample=True,
                top_p=0.9,
                temperature=0.7,
                pad_token_id=self.tokenizer.eos_token_id,
            )
        return self.tokenizer.decode(output_ids[0], skip_special_tokens=True)

    def _generate_ollama(self, message: str, max_new_tokens: int) -> str:
        import requests
        host = os.getenv("OLLAMA_HOST", "http://localhost:11434")
        model_name = os.getenv("MODEL_NAME", "llama2")
        payload = {"model": model_name, "prompt": message, "options": {"num_predict": max_new_tokens}}
        r = requests.post(f"{host}/api/generate", json=payload, timeout=600)
        r.raise_for_status()
        try:
            data = r.json()
            if isinstance(data, dict) and "response" in data:
                return data["response"]
        except ValueError:
            pass
        lines = []
        for line in r.text.splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
                if "response" in obj:
                    lines.append(obj["response"])
            except Exception:
                lines.append(line)
        return "".join(lines)


global_chat_model: Optional[ChatModel] = None


def get_model() -> ChatModel:
    global global_chat_model
    if global_chat_model is None:
        global_chat_model = ChatModel()
        global_chat_model.load()
    return global_chat_model