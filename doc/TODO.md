

# MIG and parallel GPU usage

- play with MIG

# Check nvidia device plugin and how docker interacts with it

# V100 architect and analysis

- V100 GPU architecture
    - 84 Volta SMs
    - Each SM has:
    - 64 FP32 cores
    - 64 INT32 cores
    - 32 FP64 cores
    - 8 Tensor Cores
    - Four texture units
    - Eight 512-bit memory controllers (4096 bits total)

# CUDA cores vs Tensor cores

- CUDA cores FLOPs = 84 SMs * 64 FP32 cores * 2 FLOPs per clock * 1530 MHz = 16 TFLOPs
- Tensor cores FLOPs = 84 SMs * 8 Tensor cores * 128 
FLOPs per clock * 1530 MHz = 131 TFLOPs
- FP16 is also allowed on CUDA cores

- play with PyTorchMemEffAttention::AttentionKernel<cutlass::half_t, cutlass::arch::Sm70, true, 32, 128, 128, true, true>::Params data structure
    - This is a meterialized struct for cutlass kernel
    - cutlass is a template library for CUDA C++ based on C++11
    - cutlass::half_t is float16
    - CUTLASS (CUDA Templates for Linear Algebra Subroutines and Solvers) is a collection of CUDA C++ templates for high-performance matrix-multiplication (GEMM) and related computations.
    - what advantages does cutlass provide over other kernel libraries? -> CUTLASS provides several advantages over other kernel libraries, including:
        - High performance: CUTLASS is optimized for NVIDIA GPUs and can achieve high performance for matrix-multiplication and related operations.
        - Flexibility: CUTLASS provides a wide range of templates and configurations that allow developers to customize their kernels for specific use cases.
        - Ease of use: CUTLASS provides a simple and intuitive API that makes it easy to develop high-performance kernels.
