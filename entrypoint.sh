#!/usr/bin/env bash
# llama.cpp SCF entrypoint
# - binds 0.0.0.0:9000 (SCF Web function default)
# - mandatory <30s startup (image pull + model load)
# - omit --no-mmap since SCF GPU instances have ≥80G RAM

set -euo pipefail

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
