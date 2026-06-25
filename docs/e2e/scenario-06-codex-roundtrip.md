# 场景 06(执行记录):codex-agent 往返

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS(✅ 纠正了"预判 blocked" —— 实测可用) |
| **对应设计场景** | [scenarios/06-codex-agent-roundtrip](../scenarios/06-codex-agent-roundtrip/scenario.zh_cn.md) |
| **验证面** | world LV + server 日志 |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~17:45 |
| **环境** | 分支 `feat/product-gaps-f9-f12`(= main `8b673310`)· server 带 `HTTPS_PROXY=7890` |
| **前置 scenario** | scenario-03 ✅(session `zyli-test-1`) |

## 前置条件(当次实际)

- zyli **本机 `codex login`** 成功 → `~/.codex/auth.json`(+ `config.toml`)存在
- 新建 codex agent `entity://system/agent/zyli-codex-1`(flavor=codex,**cwd 必填**=`/tmp/codex-agent-zyli`)
- 创建时 CODEX_HOME 未自动 seed 凭据 → 主线手工 `cp ~/.codex/{auth.json,config.toml}` 进 agent 的 CODEX_HOME `/home/lenovo/.ezagent/default/codex-agents/system/zyli-codex-1/`(codex 经 `CODEX_HOME` env 隔离凭据)
- server 带代理 → codex 可达 OpenAI

## 角色

- **调用方**:admin · **目标**:`entity://system/agent/zyli-codex-1`(codex flavor,bridge)

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | New Agent flavor=codex, cwd=/tmp/codex-agent-zyli, Create | **创建成功无报错**;日志:`create_agent granted`(**1.8s,无 `:activate_timeout`**)、`JOINED agent_bridge:codex:...zyli-codex-1`、`bridge sidecar join ok` | server log 行 84503/84519/84531 | ✅ |
| 2 | 主线 seed `auth.json`+`config.toml` 进 CODEX_HOME | 凭据落地(创建时未自动 seed) | — | ✅ |
| 3 | Invite 进 session + 发 `@zyli-codex-1 你好,你是谁`(17:45:03) | zyli-codex-1 **回真实 Codex 回复**(17:45:10,~7s):"你好,我是 **Codex**,一个在你这个工作区里帮助写代码、读代码、改代码、跑命令和排查问题的 AI 编程助手……"(**未重启 app-server,turn 直接读了新凭据**) | [s06-step1-codex-reply-zyli](./evidence/scenario-06/s06-step1-codex-reply-zyli.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| codex bridge 经 UDS WS 派发并回包 | ✅ `agent_bridge:codex` join ok,@mention → 真实 Codex 回复 ~7s | ✅ |
| LV 渲染对话 | ✅ 去/回上屏 | ✅ |

## 发现 / 意义(重要)

- **纠正预判**:本场曾被预判 BLOCKED(pypi 无外网 + 疑似 cc 同类)。实测:① server 带代理后网络通;② zyli `codex login` + 手工 seed CODEX_HOME 凭据后,codex **完整往返成功**。
- **codex 工作 ⇒ cc bug 是 cc-flavor 专属的强证据**:codex 也是复杂 agent(bridge/app-server),但 **创建仅 1.8s 无 `:activate_timeout`**、bridge join、能回 —— 而 cc(PTY)创建 10s 超时、PTY 不转发。**说明 scenario-05 的 cc 三个 bug 不是"所有复杂 agent 都坏",而是 cc/PTY/SDK 路径专属。**
- **DX 缺口(轻)**:创建 codex agent 时 CODEX_HOME **未自动从 `~/.codex` seed 凭据**(cc 有 `seed_cc_sandbox` task,codex 无对应 task)→ 需手工拷 auth.json/config.toml。可作为体验改进点。

## 遗留 / bug
- 非阻塞。轻量 DX 缺口:codex 无自动 seed 凭据 task(见上)。codex `invocations` 留 scenario-12 类审计(本轮 12 已跑但在 codex 之前,未含 codex 行)。

## 证据清单
- `evidence/scenario-06/s06-step1-codex-reply-zyli.png` — zyli 视角:@zyli-codex-1 + 真实 Codex 回复 + 5 成员
- `evidence/scenario-06/s06-step2-codex-confirmed.png` — observer 服务端对照:zyli-codex-1 `data-online=true`,transcript 持久化,确认真实 Codex provider(自报身份+仓库语境,非 stub)

## 交叉引用
- 设计场景:`docs/scenarios/06-codex-agent-roundtrip`、`26-codex-bridge-uds-ws`

## 交叉引用
- 设计场景:`docs/scenarios/06-codex-agent-roundtrip`、`26-codex-bridge-uds-ws`
