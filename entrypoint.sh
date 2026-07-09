#!/usr/bin/env bash
# llama.cpp SCF entrypoint — verbose diagnostic build.
#
# Designed so EVERY step the entrypoint takes shows up in the SCF
# function log console. Look for the "[ep HH:MM:SS]" prefix.
#
# SCF mount expectations (set in 函数配置 → 文件系统):
#   - Type:    CFS 文件存储  (or COS 对象存储)
#   - 本地目录: /mnt
#   - Files:   /mnt/model   (gguf)        — required
#              /mnt/mmproj  (mmproj gguf) — optional
# Override MODEL_PATH / MMPROJ_PATH at function-level env if you mount
# somewhere else.
#
# COS 挂载 (if you chose COS instead of CFS):
#   Real path on disk:  /mnt/cosfs/<bucket-name>/<subdir>/model
#   Set MODEL_PATH accordingly.

# -e: exit on error        -u: error on unset var
# -x: print every command   (so SCF log shows what bash is doing)
# -o pipefail: catch errors in pipelines
set -euxo pipefail

log() { echo "[ep $(date +%H:%M:%S.%3N)] $*" >&2; }

# 0) Boot banner
log "============================================================"
log "boot pid=$$ ppid=$PPID user=$(id 2>&1 | tr '\n' ' ')"
log "image:  $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | head -1 || echo '?')"
log "kernel: $(uname -r 2>&1) arch=$(uname -m 2>&1)"
log "MODEL_PATH=${MODEL_PATH:-<unset>}"
log "MMPROJ_PATH=${MMPROJ_PATH:-<unset>}"
log "LLAMA_PORT=${LLAMA_PORT:-9000}"
log "LLAMA_HOST=${LLAMA_HOST:-0.0.0.0}"
log "============================================================"

# 1) SCF auto-injected env (so you can see what the platform handed us)
log "--- SCF-injected env (SCF_*, TENCENTCLOUD_*, USER_*) ---"
env | grep -E '^(SCF_|TENCENTCLOUD_|USER_|GGML_)' | sort | sed 's/^/  /' || true

# 2) Filesystem state — the whole point of this entrypoint rev
log "--- /proc/self/mountinfo (everything mounted into this container) ---"
if [ -r /proc/self/mountinfo ]; then
  cat /proc/self/mountinfo | sed 's/^/  /'
else
  log "  (cannot read /proc/self/mountinfo)"
fi

log "--- mount (classic output) ---"
mount 2>&1 | sed 's/^/  /' || log "  (mount cmd failed)"

log "--- df -h ---"
df -h 2>&1 | sed 's/^/  /'

log "--- ls -la / (top level) ---"
ls -la / 2>&1 | sed 's/^/  /'

# 3) /mnt — the path the Dockerfile / MODEL_PATH expects
log "--- /mnt exists? ---"
if [ -d /mnt ]; then
  log "  yes, /mnt is a directory"
  log "--- stat /mnt ---"
  stat /mnt 2>&1 | sed 's/^/  /'
  log "--- ls -la /mnt ---"
  ls -la /mnt 2>&1 | sed 's/^/  /' || log "  (ls failed)"
  log "--- find /mnt (maxdepth 4) ---"
  find /mnt -maxdepth 4 2>&1 | sed 's/^/  /' | head -100
else
  log "  no, /mnt does not exist in this container"
fi

# 4) Probe other SCF-common mount roots, just in case user picked a
#    different 本地目录 in the console (e.g. /home, /data, /var/user)
log "--- probe SCF-common mount roots ---"
for p in /home /data /var/user /cosfs /opt /workspace; do
  if [ -d "/$p" ] && [ "$(ls -A "/$p" 2>/dev/null)" ]; then
    log "  /$p exists and is non-empty:"
    ls -la "/$p" 2>&1 | head -20 | sed 's/^/    /'
  fi
done

# 5) COS 挂载 specific probe (real path = /mnt/cosfs/<bucket>/<subdir>/)
log "--- COS 挂载 path probe (/mnt/cosfs) ---"
if [ -d /mnt/cosfs ]; then
  log "  /mnt/cosfs exists"
  find /mnt/cosfs -maxdepth 4 2>&1 | head -100 | sed 's/^/    /'
else
  log "  /mnt/cosfs does not exist → not using COS 挂载 (or挂载失败)"
fi

# 6) Model file wait + diagnostic loop. SCF usually has the mount ready
#    before entrypoint, but allow up to ~30s for slow mount hooks.
log "--- waiting for MODEL_PATH=$MODEL_PATH ---"
if [ -z "${MODEL_PATH:-}" ]; then
  log "ERROR: MODEL_PATH env is empty."
  log "  → Set it in 函数配置 → 环境变量, or update the Dockerfile ENV."
  exit 1
fi

for i in 1 2 3 4 5 6; do
  if [ -f "$MODEL_PATH" ]; then
    SIZE=$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo '?')
    log "  ✓ model OK at $MODEL_PATH (size=$SIZE bytes)"
    break
  fi
  log "  wait $i/5: $MODEL_PATH not found"
  # re-dump a tiny slice on each miss so timing is visible
  log "    ls -la /mnt | tail -5:"
  ls -la /mnt 2>/dev/null | tail -5 | sed 's/^/      /' || log "      (ls failed)"
  if [ "$i" -eq 5 ]; then
    log "ERROR: $MODEL_PATH not found after ~30s. Giving up."
    log "  → Check SCF console: 函数配置 → 文件系统, confirm 本地目录=/mnt"
    log "  → 角色授权: SCF_QcsRole 需在 CAM 中已配置"
    log "  → 存储桶/文件系统 必须在 函数同地域"
    log "  → 模型文件 model 必须真的在那个 存储桶/文件系统 里"
    exit 1
  fi
  sleep 5
done

# 7) Optional mmproj
if [ -n "${MMPROJ_PATH:-}" ] && [ ! -f "$MMPROJ_PATH" ]; then
  log "WARN: MMPROJ_PATH=$MMPROJ_PATH not found, starting without mmproj"
  MMPROJ_PATH=""
fi

# 8) Build llama-server args
log "--- building llama-server args ---"
ARGS=("-m" "$MODEL_PATH")
if [ -n "${MMPROJ_PATH:-}" ] && [ -f "$MMPROJ_PATH" ]; then
    ARGS+=("--mmproj" "$MMPROJ_PATH")
fi

if [ -n "${LLAMA_MAX_TOKENS:-}" ]; then
    ARGS+=("-n" "${LLAMA_MAX_TOKENS}")
fi

if [ -n "${LLAMA_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    EXTRA=( ${LLAMA_EXTRA_ARGS} )
    ARGS+=("${EXTRA[@]}")
fi

log "  ARGS: ${ARGS[*]}"

# 9) Hand off. From here on, stdout/stderr belong to llama-server.
#    The "exec" replaces bash with llama-server, so it inherits PID 1
#    (which is what SCF expects for signal handling).
log "--- exec /app/llama-server (replacing this bash process) ---"

# shellcheck disable=SC2086
exec /app/llama-server \
    "${ARGS[@]}" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT"
