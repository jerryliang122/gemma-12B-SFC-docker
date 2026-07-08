# gemma-12B-SFC-docker

Docker 镜像,把 [gemma-4-12b-it-Q6_K](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF) GGUF 模型和 `mmproj-F16.gguf` 多模态**通过 CFS 挂载**喂给 `ghcr.io/ggml-org/llama.cpp:server-cuda` 上游镜像,跑 GPU inference。**镜像内不含模型**。

> 仓库名故意保留 `SFC` 三字母 typo(原目标是 SCF GPU Web Function,后来改成 GPU 应用服务器 / SCF GPU 容器)。

## 架构
- **构建产物:~1.5 GB**(不含模型,原 14.3 GB → ~1.5 GB)
- **源镜像**:`ghcr.io/ggml-org/llama.cpp:server-cuda`(已含 `libcuda.so.1`,不再 stub 链接)
- **模型存储**:SCF 函数挂载 CFS 到 `/mnt`,模型文件命名约定:
  - `/mnt/model` ← `gemma-4-12b-it-Q6_K.gguf`(9.2 GB)
  - `/mnt/mmproj` ← `mmproj-F16.gguf`(175 MB)

## 跑通验证(2026-07-08,模型内置镜像版本)
- 平台:腾讯云 GPU 应用服务器 T4 16GB(124.220.191.192 / 内网 10.4.0.5)+ 镜像 `ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b:latest`(原 `:v1` tag 已被覆盖)
- 加载:GPU 11.4/15.4 GB(`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` 借 RAM),模型层 + KV cache Q8 + 128K ctx + parallel 2
- 速度:17-20 tokens/s(prompt eval 128 tokens/s),对齐 192.168.1.9 A4000 表现
- API:`/v1/completions` 直出文本;`/v1/chat/completions` 默认走 thinking mode,客户端加 `"chat_template_kwargs":{"enable_thinking":false}` 关闭

## 关键参数
- 模型:Q6_K + mmproj-F16(**来自 CFS 挂载,不在镜像里**)
- 端口:9000(容器内),host 端口可映射
- 环境变量:
  - `MODEL_PATH=/mnt/model`(CFS 挂载后的模型路径)
  - `MMPROJ_PATH=/mnt/mmproj`(CFS 挂载后的 mmproj 路径)
  - `LLAMA_MAX_TOKENS=2048`(镜像默认,运行可覆盖)
  - `LLAMA_EXTRA_ARGS="--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --threads 12 --flash-attn on --parallel 2 --no-mmap --cache-type-k q8_0 --cache-type-v q8_0"`
  - `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`(关键,允许 GPU 借用 CPU RAM,小于显存时不会 OOM)

## 本地起容器(带 CFS 等效挂载)
```bash
docker run --init --rm --gpus all \
  -p 9090:9000 \
  -v /path/to/your/model.gguf:/mnt/model:ro \
  -v /path/to/your/mmproj.gguf:/mnt/mmproj:ro \
  -e LLAMA_MAX_TOKENS=512 \
  ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b:latest
```

> **`--init` 必须加**,否则 `docker rm -f` 后容器内 `llama-server` 会变 orphan 进程继续占 GPU(已踩)。

## SCF 部署清单(V100 GPU)
1. 创建 CFS 文件系统(同区域、NFS 协议、通用型)
2. 上传模型到 CFS:
   - `gemma-4-12b-it-Q6_K.gguf` → 重命名为 `model`
   - `mmproj-F16.gguf` → 重命名为 `mmproj`
3. 创建 SCF 函数(容器镜像模式):
   - 镜像:`ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b:latest`
   - GPU 类型:V100(GN10.x 系列 32GB)
4. 函数挂载 CFS 到 `/mnt`
5. 验证 `/v1/chat/completions` + `chat_template_kwargs.enable_thinking=false`

## GitHub Actions Workflows
- **`build.yml`** — 本地 build sanity check(ubuntu-latest runner,无 GPU)。**不再下载/打包模型**——只验证 Dockerfile 能 build 出镜像。
- **`build-and-push-ccr.yml`** — Build 完直接 push 到 `ccr.ccs.tencentyun.com/jerryliang/gemma-4-12b`(latest + commit SHA 双 tag),需要 secrets `CCR_USERNAME` / `CCR_PASSWORD`。**不再下载模型**——模型走部署时 CFS 挂载。

## 踩坑历史
- GH Actions runner 没真实 GPU → daemon `libcuda.so.1` stub 链接踩坑 → 改用上游 server-cuda 镜像
- Dockerfile `# syntax=docker/dockerfile:1.7` 在 buildx 环境需要拉 docker.io → 改删该 syntax 行,走默认 frontend
- buildkitd 多次撞 9.96 GB 单层 exporting 慢 + 磁盘满 no space → 改回 daemon 内置 buildkit,删手动 buildx 副本,用 apt buildx 0.30.1
- `--max-n-tokens` 不是 llama-server 的 flag → 改 `-n`(对应 `--n-predict`)
- `--flash-attn` 不接 value 时被 word-split 吞下一个 token → 改 `--flash-attn on`
- 默认走 thinking mode → 客户端加 `chat_template_kwargs.enable_thinking=false`
- `docker rm -f` 没正确 SIGKILL 容器内 init 进程 → orphan llama-server 占 GPU → 容器用 `--init` flag
- 镜像内嵌 9.2GB 模型 → 镜像 push 慢 + 单层 9.96GB 导出困难 → **改用 CFS 外挂(2026-07-08)**