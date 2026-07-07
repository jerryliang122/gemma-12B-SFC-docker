# syntax=docker/dockerfile:1.7
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

# Download model + mmproj
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

# Entrypoint wraps llama-server with the SCF-required port/env defaults
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SCF Web function defaults (override at function level)
ENV MODEL_PATH=/models/gemma-4-12b-it-Q6_K.gguf \
    MMPROJ_PATH=/models/mmproj-F16.gguf \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=9000 \
    LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn --parallel 2 --cache-type-k q8_0 --cache-type-v q8_0"

EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
