

# Call Stack

fmha_cutlassF_f16_aligned_32x128_rf_sm70(PyTorchMemEffAttention::AttentionKernel<cutlass::half_t, cutlass::arch::Sm70, true, 32, 128, 128, true, true>::Params)

- fmha: fused_multihead_attention
- cutlassF: cutlass forward
- f16: float16 data type
- aligned_32x128: memory alignment of 32x128
- rf: register file usage
- sm70: NVIDIA GPU architecture (Sm70)
- PyTorchMemEffAttention::AttentionKernel<cutlass::half_t, cutlass::arch::Sm70, true, 32, 128, 128, true, true>::Params
-> is this a cuda kernel function for attention mechanism using cutlass library with specific parameters