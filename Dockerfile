# syntax removed (use default frontend)
# Single-stage: use the official ggml-org llama.cpp server-cuda image.
# We previously tried a multi-stage self-compile approach but ran into the
# libcuda.so.1 driver stub link problem on the nvidia/cuda devel image.
# The upstream ggml-org/llama.cpp images already handle that for us.

# Use a pinned tag for reproducibility (bXXXX follows the upstream commit).
# Pin: server-cuda-b4721 (build number)
ARG LLAMA_CPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda

FROM ${LLAMA_CPP_IMAGE}

ARG MODEL_URL=https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q6_K.gguf
ARG MODEL_FILE=gemma-4-12b-it-Q6_K.gguf
ARG MODEL_SHA256=

ARG MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-F16.gguf
ARG MMPROJ_FILE=mmproj-F16.gguf
ARG MMPROJ_SHA256=

# --- 模型准备 ---
# 默认走"host 预下模型 + COPY"路线:把模型放到 build context 的 ./models/
# 目录里(可以是真实文件或 symlink 到外部路径),docker build 阶段直接 COPY。
#
# 如果想走"镜像内 wget 下载"的旧路线,把环境变量 DOWNLOAD_IN_IMAGE=1 传进来。
ARG DOWNLOAD_IN_IMAGE=0

# Download model + mmproj (legacy /opt 路径)
RUN if [ "$DOWNLOAD_IN_IMAGE" = "1" ]; then \
      mkdir -p /models \
      && cd /models \
      && echo "Downloading $MODEL_FILE..." \
      && curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
              -o "$MODEL_FILE" "$MODEL_URL" \
      && if [ -n "$MODEL_SHA256" ]; then \
           echo "$MODEL_SHA256  $MODEL_FILE" | sha256sum -c -; \
         else \
           sha256sum "$MODEL_FILE"; \
         fi \
      && echo "Downloading $MMPROJ_FILE..." \
      && curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
              -o "$MMPROJ_FILE" "$MMPROJ_URL" \
      && if [ -n "$MMPROJ_SHA256" ]; then \
           echo "$MMPROJ_SHA256  $MMPROJ_FILE" | sha256sum -c -; \
         else \
           sha256sum "$MMPROJ_FILE"; \
         fi \
      && ls -lh /models; \
    else \
      mkdir -p /models; \
    fi

# Host 预下模型 + COPY 进镜像(主流路线)
COPY --chown=root:root models/*.gguf /models/
RUN ls -lh /models/ && sha256sum /models/*.gguf

# Entrypoint wraps llama-server with the SCF-required port/env defaults
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SCF Web function defaults (override at function level)
ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    MODEL_PATH=/models/gemma-4-12b-it-Q6_K.gguf \
    MMPROJ_PATH=/models/mmproj-F16.gguf \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=9000 \
    LLAMA_MAX_TOKENS=2048 \
    LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn on --parallel 2 --no-mmap --cache-type-k q8_0 --cache-type-v q8_0"



EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
