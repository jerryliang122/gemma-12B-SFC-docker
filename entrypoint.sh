#!/usr/bin/env bash
# llama.cpp SCF entrypoint — wraps the upstream server-cuda image's
# prebuilt llama-server binary with model + flags from env vars.

set -euo pipefail

# llama-server is on PATH in the upstream server-cuda image
ARGS=("-m" "$MODEL_PATH")
if [ -n "${MMPROJ_PATH:-}" ] && [ -f "$MMPROJ_PATH" ]; then
    ARGS+=("--mmproj" "$MMPROJ_PATH")
fi

# shellcheck disable=SC2086
exec llama-server \
    "${ARGS[@]}" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT" \
    $LLAMA_EXTRA_ARGS
