

# 500 response

HTTP/1.1 500 Internal Server Error
date: Wed, 10 Sep 2025 12:47:24 GMT
server: uvicorn
content-length: 71
content-type: application/json
connection: close

{
  "error": "Tensor on device cuda:0 is not on the expected device meta!"
}


# Hugging Face doc

https://deepwiki.com/huggingface/accelerate/5.1-model-loading-and-device-mapping

# AI analysis

# Device map error analysis

## Root cause
Model was loaded with `device_map="auto"` (Accelerate sharding). Inputs were then moved via `.to(self.model.device)`, assuming a single uniform device. Some submodules stayed as unresolved `meta` tensors (lazy / quantized / offloaded) so a forward pass hit a mismatch: runtime tensor on `cuda:0` vs parameter still on `meta`.

## Typical triggers
- Mixing manual `.to(model.device)` with `device_map="auto"`.
- Partial 4-bit load (missing `bitsandbytes`) leaves meta tensors.
- Large model fallback attempts (dtype retries) leaving an incomplete module.
- Forcing batching quickly after startup before full materialization.

## Quick fix matrix

| Situation | Action |
|-----------|--------|
| Single GPU (<=7B) | Force single device: `export DEVICE_MAP=single` |
| 4-bit set but no bitsandbytes | Remove `QUANTIZE` or install bitsandbytes |
| Just want it working | Unset device map: `export DEVICE_MAP=none` |
| Multi-GPU real sharding desired | Remove manual input `.to(...)` logic |

## Recommended minimal fix
Force full placement on one GPU (if available) or CPU fallback; reject meta leftovers.

## Code patch (proposed)

````python
# In [model_loader.py](http://_vscodecontentref_/2) inside load(), replace the current load_kwargs init block.

device_map_env = os.getenv("DEVICE_MAP", "auto").lower()
load_kwargs = {}
if device_map_env == "auto":
    load_kwargs["device_map"] = "auto"
elif device_map_env in ("single", "cuda", "gpu"):
    if torch.cuda.is_available():
        load_kwargs["device_map"] = {"": 0}  # whole model -> cuda:0
elif device_map_env in ("none", "off"):
    pass  # no device_map arg
else:
    load_kwargs["device_map"] = "auto"

# After successful self.model creation, add:
if any(p.device.type == "meta" for p in self.model.parameters()):
    raise RuntimeError(
        "Model still has meta tensors after load. Try DEVICE_MAP=single or remove QUANTIZE."
    )