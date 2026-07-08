#!/usr/bin/env bash
# llama.cpp SCF entrypoint — wraps the upstream server-cuda image's
# prebuilt llama-server binary with model + flags from env vars.

set -euo pipefail

# llama-server is at /app/llama-server in the upstream server-cuda image
ARGS=("-m" "$MODEL_PATH")
if [ -n "${MMPROJ_PATH:-}" ] && [ -f "$MMPROJ_PATH" ]; then
    ARGS+=("--mmproj" "$MMPROJ_PATH")
fi

# LLAMA_MAX_TOKENS: per-request max output tokens (-n / --max-n-tokens)
if [ -n "${LLAMA_MAX_TOKENS:-}" ]; then
    ARGS+=("-n" "${LLAMA_MAX_TOKENS}")
fi

# LLAMA_EXTRA_ARGS: any other flags (string-split on whitespace)
if [ -n "${LLAMA_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    EXTRA=( ${LLAMA_EXTRA_ARGS} )
    ARGS+=("${EXTRA[@]}")
fi

# shellcheck disable=SC2086
exec /app/llama-server \
    "${ARGS[@]}" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT"
