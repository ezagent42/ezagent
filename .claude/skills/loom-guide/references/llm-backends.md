# Loom LLM 后端 — LOOM_LLM_BACKEND 开关 + 两个例外

## 分发层：`EzagentPluginLoom.LLM`（lib/ezagent/llm.ex）

5 个 Behavior（orchestrator / worker / v0worker / meta / loom）**只认 `LLM.chat/2`**，
不知道底下是谁。两个后端 `chat/2` 签名一致：`{:ok, content} | {:error, reason}`。

| 后端 | 模块 | 说明 |
|---|---|---|
| `:claude_code`（**默认**） | `claude_code.ex` | 本地 `claude` CLI 子进程壳，支持 streaming 进度 + `stop/1` 中断 |
| `:deepseek` | `deepseek.ex` | DeepSeek HTTP（非流式），需要 `DEEPSEEK_KEY` |

## 开关

```bash
# .env（dev/test 由 config/runtime.exs 加载,已有真实环境变量优先）
LOOM_LLM_BACKEND=deepseek   # 或 claude_code（默认）
```

**boot 时生效，不是热切换**：`config/runtime.exs` 读 `LOOM_LLM_BACKEND` 写进
app env `:llm_backend`；改完必须**重启 phx.server**。

后端差异在 LLM 层桥接：
- `stop/1` —— CC 杀在跑的子进程；DeepSeek 单发 HTTP 无持久进程 → no-op
- `max_run_ms/1` —— 单次调用墙钟上界（orchestrator 用它推 dead-worker 兜底超时）；
  DeepSeek 走自己的 HTTP 超时常数

## ⚠️ 两个不走开关的例外（web_plug.ex 内）

**Stitch** 和 **AiSpot**（preview 页辅助聊天 / 划词追问）**独立直连
DeepSeek-v4-flash（非思考）**，不走 LLM 分发器、不进 session 编排——
设计意图是消费侧轻量快答。即使 `LOOM_LLM_BACKEND=claude_code`，
这两处仍然要求 `DEEPSEEK_KEY` 可用，否则 Stitch/AiSpot 不工作。

## Prompt 一览（lib/ezagent/prompts.ex，613 行）

| prompt | 用户 |
|---|---|
| decompose / compose（scene-card 规则 + persona） | orchestrator |
| fragment（主题片段） | worker |
| `page_gen_system_prompt/0`（jsx-only 规则） | v0worker |
| `meta_system_prompt/1`（team op 词表） | meta agent |
| stitch / aispot（含知识库 grounding，`[[term]]` 标注约定） | web_plug 直连 |

迁移注意：`prompts.ex` 的领域知识是迁移清单里 📦 **保留**项（落到 AgentTemplate
content），代码壳丢弃——改 prompt 前看一眼 `migration-map.md` 免得做无用功。
