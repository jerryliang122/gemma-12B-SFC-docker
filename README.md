# gemma-12B-SFC-docker

Docker 镜像,把 [gemma-4-12b-it-Q6_K](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF) GGUF 模型和 `mmproj-F16.gguf` 多模态打包进 `ghcr.io/ggml-org/llama.cpp:server-cuda` 上游镜像,跑 GPU inference。

> 仓库名故意保留 `SFC` 三字母 typo(原目标是 SCF GPU Web Function,后来改成 GPU 应用服务器)。

## 镜像
- 构建产物:**14.3 GB**(单层 9.96 GB:9.78 GB Q6_K + 175 MB mmproj)
- 源镜像:`ghcr.io/ggml-org/llama.cpp:server-cuda`(已含 `libcuda.so.1`,不再 stub 链接)
- Dockerfile 思路:走「host 预下模型 + COPY」主流路线,不二次 wget 到镜像层

## 跑通验证(2026-07-08)
- 平台:腾讯云 GPU 应用服务器 T4 16GB(124.220.191.192 / 内网 10.4.0.5)+ 镜像 `ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b:v1`
- 加载:GPU 11.4/15.4 GB(`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` 借 RAM),模型层 + KV cache Q8 + 128K ctx + parallel 2
- 速度:17-20 tokens/s(prompt eval 128 tokens/s),对齐 192.168.1.9 A4000 表现
- API:`/v1/completions` 直出文本;`/v1/chat/completions` 默认走 thinking mode,客户端加 `"chat_template_kwargs":{"enable_thinking":false}` 关闭

## 关键参数
- 模型:Q6_K + mmproj-F16(已硬编码到 entrypoint.sh)
- 端口:9000(容器内),host 端口可映射
- 环境变量:
  - `LLAMA_MAX_TOKENS=2048`(镜像默认,运行可覆盖)
  - `LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn on --parallel 2 --no-mmap --cache-type-k q8_0 --cache-type-v q8_0"`
  - `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`(关键,允许 GPU 借用 CPU RAM,小于显存时不会 OOM)

## 起容器
```bash
docker run --init --rm --gpus all \
  -p 9090:9000 \
  -e LLAMA_MAX_TOKENS=512 \
  ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b:v1
```

> **`--init` 必须加**,否则 `docker rm -f` 后容器内 `llama-server` 会变 orphan 进程继续占 GPU(已踩)。

## GitHub Actions Workflows
- **`build.yml`** — 传统 build + smoke test(ubuntu-latest runner,无 GPU)
- **`build-and-push-ccr.yml`** — Build 完直接 push 到 `ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b`(v1 + commit SHA 双 tag),需要 secrets `CCR_USERNAME` / `CCR_PASSWORD`

## 踩坑历史
- GH Actions runner 没真实 GPU → daemon `libcuda.so.1` stub 链接踩坑 → 改用上游 server-cuda 镜像
- Dockerfile `# syntax=docker/dockerfile:1.7` 在 buildx 环境需要拉 docker.io → 改删该 syntax 行,走默认 frontend
- buildkitd 多次撞 9.96 GB 单层 exporting 慢 + 磁盘满 no space → 改回 daemon 内置 buildkit,删手动 buildx 副本,用 apt buildx 0.30.1
- `--max-n-tokens` 不是 llama-server 的 flag → 改 `-n` (对应 `--n-predict`)
- `--flash-attn` 不接 value 时被 word-split 吞下一个 token → 改 `--flash-attn on`
- 默认走 thinking mode → 客户端加 `chat_template_kwargs.enable_thinking=false`
- `docker rm -f` 没正确 SIGKILL 容器内 init 进程 → orphan llama-server 占 GPU → 容器用 `--init` flag
