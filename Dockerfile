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

# Ensure CFS/COS mount target directory exists in the image.
# SCF will mount a user-configured filesystem (CFS 文件存储 or COS 对象存储)
# onto this path at function deployment time. Default below: /mnt.
#
# IMPORTANT: this path MUST match the 本地目录 you set in:
#   函数配置 → 文件系统 → 添加 → 本地目录
# The recommended default is /mnt (also recommended by SCF docs).
# SCF will refuse to mount onto a non-empty path, so /mnt is fine because
# it is created empty here.
#
# Sub-paths (e.g. /home/llama, /data) also work — just keep
# MODEL_PATH / MMPROJ_PATH consistent.
RUN mkdir -p /mnt

# Entrypoint wraps llama-server with the SCF-required port/env defaults
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SCF Web function defaults — model lives on CFS/COS mount, not in image.
#
# Mount config (set once in console, persisted with the function version):
#   函数配置 → 文件系统 → 添加
#     - 类型: CFS 文件存储  (or COS 对象存储)
#     - 存储桶/文件系统: 同地域(否则挂载失败)
#     - 本地目录: /mnt
#     - 子目录: 模型所在子目录(留空 = 根)
#   角色授权: 需在 CAM 给 SCF_QcsRole 授权 COS/CFS 读权限(控制台首次挂载时会引导)
#
# Override MODEL_PATH / MMPROJ_PATH at function level if your mount layout
# differs (e.g. COS path is /mnt/cosfs/<storage>/<subdir>/model).
ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    MODEL_PATH=/mnt/model \
    MMPROJ_PATH=/mnt/mmproj \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=9000 \
    LLAMA_MAX_TOKENS=2048 \
    LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn on --parallel 2 --no-mmap --cache-type-k q8_0 --cache-type-v q8_0"



EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]