# Single-stage: use the official ggml-org llama.cpp server-cuda image.
# We previously tried a multi-stage self-compile approach but ran into the
# libcuda.so.1 driver stub link problem on the nvidia/cuda devel image.
# The upstream ggml-org/llama.cpp images already handle that for us.
#
# Model is NOT bundled in the image — at runtime the SCF function mounts a
# CFS file system onto /mnt and entrypoint reads MODEL_PATH / MMPROJ_PATH
# from there. This keeps the image small (~1.5 GB) and lets multiple model
# versions share a single image without rebuilding.

# Use a pinned tag for reproducibility (bXXXX follows the upstream commit).
ARG LLAMA_CPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda

FROM ${LLAMA_CPP_IMAGE}

# Ensure CFS mount target directory exists in the image.
# SCF will mount CFS here at function deployment time.
RUN mkdir -p /mnt

# Entrypoint wraps llama-server with the SCF-required port/env defaults
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SCF Web function defaults — model lives on CFS mount, not in image.
# Override at function level if mount layout differs.
ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    MODEL_PATH=/mnt/model \
    MMPROJ_PATH=/mnt/mmproj \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=9000 \
    LLAMA_MAX_TOKENS=2048 \
    LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn on --parallel 2 --no-mmap --cache-type-k q8_0 --cache-type-v q8_0"



EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]