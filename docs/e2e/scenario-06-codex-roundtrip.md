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

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**2026-06-26 agent-browser 实地推进:已建成 + bridge 连上,但回复被 OpenAI SSE 流经代理反复重连卡住(环境)**。 -->

**前置(自动化)**:scenario-03 已跑(session `e2e-test-1`)。codex 凭据:`~/.codex/auth.json`+`config.toml`(zyli 本机 `codex login`,**已在**);codex 默认走 `~/.codex`(`CODEX_HOME` 不设即可)。**server 必须带正确 proxy**:OpenAI 在本网需经代理。
> **2026-06-26 实地诊断(关键)**:
> ① **建 codex 需 `project_cwd`**(已存在目录),否则 `error:cwd_required_for_codex`(同 cc,见 GAP-4);补 cwd 后建成(`data-last-dispatch=idle` 但建成,需去 `/identities/agents` 确认)。
> ② **proxy 是真卡点**:运行中 server 原本**无 `HTTP(S)_PROXY`**(只有 `no_proxy`)→ codex 连不上 OpenAI 静默不回。**重启 server 加 `HTTP_PROXY=HTTPS_PROXY=http://127.0.0.1:7890`(注意 http:// scheme,曾见 https:// typo)后** codex bridge **能连上并跑 turn**。
> ③ **残留环境阻塞**:proxy 修好后,codex app-server 仍报 `Reconnecting 1/5…5/5`(OpenAI **SSE responseStream 经本地代理反复重连**)→ `turn/completed` 但 `{'text': ''}` 空 → `not sending empty codex reply`。**= OpenAI 流式 over 代理不稳(环境/网络),非代码/runbook bug**。curl(DeepSeek 直连免代理)能回正印证是 OpenAI-over-代理专属问题。
> **结论**:runbook 步骤本身正确;06 的 PASS 取决于**稳定的 OpenAI 代理通道**。当前环境下断言预期 ⏳(连得上、跑了 turn、但流式拿不到内容)。

**入口 URL**:`http://world.localhost:10042/sessions?session=<encodeURIComponent("session://system/default/e2e-test-1")>`

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | 建 codex(native-setter,**必填 cwd**) | `/identities/agents/new` form:flavor=`codex` / name=`e2e-codex` / cwd=已存在目录 | — | 去 `/identities/agents` 确认含 `entity://system/agent/e2e-codex`(**实地✅建成**) | — |
| 2 | navigate session + Invite(完整URI) | `#world-invite-input` | `entity://system/agent/e2e-codex` | `attr li[data-kind=agent] data-online=true`(**实地✅ online**) | — |
| 3 | 真键盘 @ + 提问 + 发送 | `keyboard type '@e2e-co'`→`click 'ul[role=listbox] button'`→`keyboard type ' 用一个词回答:1+1等于几'`→`press Enter` | — | `visible [data-mine=true]`(**实地✅**) | — |
| 4 | wait ≤30s 等 codex 回复 | `[data-sender-kind=agent][data-mine=false]` | — | agent 气泡含确定性答案 —— **当前环境 ⏳ 无回复**(bridge 连上但 SSE 流 Reconnecting 5/5 → 空 turn);**proxy 通道稳定后应转 PASS** | `s06-step4-codex-reply-auto.png` |

**断言映射**:
- 「codex bridge 经 UDS WS 派发并回包」→ step4;**2026-06-26 实地:派发✅ + bridge 连上✅ + turn 跑了✅,但 OpenAI SSE 流不稳 → 空回复**。环境阻塞,非 runbook/代码问题。
- 「LV 渲染对话」→ step3 `data-mine=true` 上屏✅。

**清理**:删除自建 `e2e-codex`(受 GAP-5 死锁,需先解 session 绑定);临时 cwd 目录可删。

> **运维建议(非 UI 缺口)**:dev server 启动应固定带 `HTTP_PROXY=HTTPS_PROXY=http://127.0.0.1:7890`(本轮重启已加);并排查 OpenAI SSE 经 clash/7890 代理的流式稳定性(`responseStream` Reconnecting)。
