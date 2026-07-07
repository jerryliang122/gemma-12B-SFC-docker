# syntax=docker/dockerfile:1.7
# Multi-stage build: compile llama.cpp inside Docker
# Target: Tencent Cloud SCF GPU Web Function (X86_64, custom container)

ARG CUDA_VERSION=12.4.1
ARG UBUNTU_VERSION=22.04

# ============================================================
# Stage 1: llama.cpp builder (CUDA + cmake + ninja)
# ============================================================
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS llama-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates cmake build-essential ninja-build \
    && rm -rf /var/lib/apt/lists/* \
    # NVIDIA driver stub library lives in cuda lib64/stubs.
    # Container has no real libcuda.so.1 (only host driver does), so the
    # build must link against the stub for the cuda driver API symbols.
    # See NVIDIA docs: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html
    && STUBS=/usr/local/cuda/lib64/stubs \
    && if [ -f "$STUBS/libcuda.so" ] && [ ! -e "$STUBS/libcuda.so.1" ]; then \
         ln -s libcuda.so "$STUBS/libcuda.so.1"; \
       fi \
    && echo "stubs dir contents:" && ls -l "$STUBS"

# Repo migrated ggerganov/llama.cpp -> ggml-org/llama.cpp (2026-07 confirmed)
# Linker flags point ld to the cuda driver stubs so libcuda.so.1 resolves
# to the stub during link time (host driver provides the real one at run).
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /src \
    && cd /src \
    && cmake -B build -G Ninja \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs" \
        -DCMAKE_MODULE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs" \
    && cmake --build build --config Release -j"$(nproc)" \
        --target llama-server llama-cli \
    && install -m 0755 build/bin/llama-server /usr/local/bin/ \
    && install -m 0755 build/bin/llama-cli    /usr/local/bin/ \
    && /usr/local/bin/llama-server --version

# ============================================================
# Stage 2: Runtime + model + mmproj
# ============================================================
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgomp1 ca-certificates curl wget \
    && rm -rf /var/lib/apt/lists/*

# Build artifacts (small layer, ~few MB)
COPY --from=llama-builder /usr/local/bin/llama-server /usr/local/bin/
COPY --from=llama-builder /usr/local/bin/llama-cli    /usr/local/bin/

# ============================================================
# Model layer (big, isolated for caching)
# Override at build time:
#   --build-arg MODEL_URL=... --build-arg MODEL_SHA256=...
# ============================================================
ARG MODEL_URL=https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q6_K.gguf
ARG MODEL_FILE=gemma-4-12b-it-Q6_K.gguf
ARG MODEL_SHA256=

ARG MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-F16.gguf
ARG MMPROJ_FILE=mmproj-F16.gguf
ARG MMPROJ_SHA256=

RUN mkdir -p /models \
    && cd /models \
    && echo "Downloading $MODEL_FILE..." \
    && curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
            -o "$MODEL_FILE" "$MODEL_URL" \
    && if [ -n "$MODEL_SHA256" ]; then \
         echo "$MODEL_SHA256  $MODEL_FILE" | sha256sum -c -; \
       else \
         sha256sum "$MODEL_FILE"; \
       fi \
    && if [ -n "$MMPROJ_URL" ]; then \
         echo "Downloading $MMPROJ_FILE..." \
         && curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
                -o "$MMPROJ_FILE" "$MMPROJ_URL" \
         && if [ -n "$MMPROJ_SHA256" ]; then \
              echo "$MMPROJ_SHA256  $MMPROJ_FILE" | sha256sum -c -; \
            else \
              sha256sum "$MMPROJ_FILE"; \
            fi; \
       fi \
    && ls -lh /models

# ============================================================
# Entrypoint + SCF env defaults
# ============================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV MODEL_PATH=/models/gemma-4-12b-it-Q6_K.gguf \
    MMPROJ_PATH=/models/mmproj-F16.gguf \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=9000 \
    LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn --parallel 2 --cache-type-k q8_0 --cache-type-v q8_0"

EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
