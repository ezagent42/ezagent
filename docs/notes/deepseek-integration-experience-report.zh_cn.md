# DeepSeek 模型集成经验总结报告

> **范围**: ezagent 项目中通过 `curl.agent` plugin (即 `ezagent_plugin_curl_agent`) 将 DeepSeek HTTP Chat Completion API 接入 Ezagent 多 agent 编排体系的完整测试数据、性能表现和经验教训。
> **数据来源**: 代码库中的测试文件、scenario 文档、stress-test 报告、runbook、PR walkthrough 等，截至 2026-06-11。
> **生成方式**: 基于全项目代码 + 文档搜索（`grep -rni deepseek`），由 Claude Code 整理。
> **英文对照**: `deepseek-integration-experience-report.md`

---

## 1. DeepSeek 在 Ezagent 中的角色定位

### 1.1 架构位置

Ezagent 中 DeepSeek 通过 **`curl.agent`** flavor 接入——这是一个普适的"把消息 POST 到远程 HTTP Completion API"的 Agent flavor，不是 DeepSeek 专有：

```
用户消息 → Chat.send → Routing → curl.agent :receive
  → reads_siblings([:api_keys]) 取 API key
  → Ezagent.PluginCurlAgent.ApiClient.chat_completion/1
  → POST https://api.deepseek.com/chat/completions
  → 解析 assistant content → dispatch chat.send 回 session
```

### 1.2 两种使用场景

| 场景 | 模型 | 用途 | 配置 |
|---|---|---|---|
| **Fast agent** (即时安抚 ACK) | `deepseek-v4-flash`, no thinking | 客服场景 t=0 即时响应，12-30 字，<2s | `max_tokens: 256`, `thinking: {type: "disabled"}` |
| **Slow agent 补充** (cc 翻译/转换) | `deepseek-chat` | LaTeX → numpy 表达式翻译等辅助任务 | 默认 `max_history: 20` |
| **Progress filler** (体验填充) | `deepseek-v4-flash` | cc 慢时每 5-10s 生成安抚填充语 | PV2 red/fast_phase 驱动 |

---

## 2. 测试方法与覆盖面

### 2.1 测试金字塔

```
         ┌──────────────────────┐
         │  真栈 smoke (manual)  │  ~30s wall-time
         │  Allen 手动验证        │  real claude + real DeepSeek
         ├──────────────────────┤
         │  CI e2e (mock)        │  ~3s
         │  Bandit Plug mock     │  FakeCcAgent + MockDeepSeek
         │  DeepSeek HTTP        │
         ├──────────────────────┤
         │  集成测试              │
         │  curl_cascade_        │  API key 级联、cold-load
         │  activation_test      │
         ├──────────────────────┤
         │  单元测试              │
         │  curl_agent_test      │  14/14 pass
         │  curl_agent_roundtrip │  contract + effect grammar
         └──────────────────────┘
```

### 2.2 单元测试 — `curl_agent_test.exs`

**文件**: `apps/ezagent_plugin_curl_agent/test/ezagent/behavior/curl_agent_test.exs`

**覆盖**:
- `create/1` 默认值：正确默认到 deepseek/chat（provider=`"deepseek"`, model=`"deepseek-chat"`, api_url=`"https://api.deepseek.com/chat/completions"`）
- 每个 action 有 description
- `required_caps/0` 使用 `:curl_agent` kind axis（非 auto-derived `:any`）
- `reads_siblings/0` 声明 `[:api_keys]`
- `new_style?/1` 检测新合约
- per-instance override 可覆盖默认 provider/model/api_url
- **状态**: 全量通过 (`14/14 pass`)

### 2.3 E2E 合约测试 — `scenario_07_curl_agent_roundtrip_test.exs`

**文件**: `apps/ezagent_plugin_curl_agent/test/e2e/scenario_07_curl_agent_roundtrip_test.exs`

**覆盖 7 个 describe block**:

| 测试类别 | 验证项 | 状态 |
|---|---|---|
| macro-derived metadata | 3 actions declared、modes 正确、kind axis 非 `:any`、reads_siblings | ✅ |
| handle_configure/2 | `:set` effects 覆盖 5 个配置字段、framework apply 后 slice 正确 | ✅ |
| handle_reset_conversation/2 | conversation + last_error 清除 | ✅ |
| handle_receive/2 loop guard | self-message → `{:ok, %{ignored: :self_message}, []}`，零 effect | ✅ |
| handle_receive/2 missing key | `:set :last_error` + dispatch operator-help 到 session，不泄漏 key | ✅ |
| data_owner/1 | `:any` / non-agent URI / no-creator URI 三种场景 | ✅ |
| ApiClient 结构确认 | 模块存在 + `chat_completion/1` public entry | ✅ |

**真实 DeepSeek roundtrip** 标记为 `@tag :requires_allen, @tag :skip` — 真 key 手动 smoke，不入 CI。

### 2.4 CI 级 4-agent 编排 e2e — MockDeepSeek

**文件**: `apps/ezagent_plugin_np/test/support/mock_deepseek.ex`
**测试**: `apps/ezagent_plugin_np/test/integration/comprehensive_4agent_e2e_test.exs`

**Mock 策略**: 用 Bandit 启动 HTTP server（随机端口），暴露 `POST /chat/completions`，按确定性规则返回：

```elixir
# 转换规则 (deterministic, no LLM):
# \int_0^1 x dx → "0.5"          (实际积分值)
# \latex{...}   → 内层表达式      (原样输出)
# 其他          → "2 + 2"         (安全默认)
```

返回完整的 OpenAI-shape JSON (`choices[0].message.content` + `usage`)，让 curl-agent 的 HTTP 响应解析器得到真实 exercise。

**全链路验证**: `admin → cc(fake) → curl(real code, mock HTTP) → np(real Python) → admin`

**特点**:
- ~3s 完成，不需要外部 API key
- 证明 orchestration 路径正确，隔离外部依赖
- 真栈验证走 `docs/runbook/4-agent-comprehensive-e2e.md` 手动 smoke

### 2.5 API key 级联测试 — `curl_cascade_activation_test.exs`

**文件**: `apps/ezagent_plugin_curl_agent/test/integration/curl_cascade_activation_test.exs`

**覆盖场景**:
- source agent 有 key → 级联成功
- source agent 无 key → `{:error, {:cascade_api_key_missing, "deepseek", source_uri}}`
- workspace 优先级 source → workspace key cascade
- user 优先级 source → user key cascade（多个 source 时 highest-priority wins）
- validate 拒绝空 api_url

### 2.6 Cold-load 测试 — `curl_agent_cold_load_test.exs`

**文件**: `apps/ezagent_plugin_curl_agent/test/ezagent/behavior/curl_agent_cold_load_test.exs`

验证**重启后 `create/1` 不被错误重跑**（不会把用户配置的 provider/model 重置回 deepseek 默认值）。

### 2.7 真实 DeepSeek roundtrip — 手动 smoke (Allen)

**文件**: `docs/notes/curl-agent-walkthrough.md`（PR #126, 2026-05-19）
**证据**:
- `docs/notes/evidence/pr126-curl-agent-deepseek-e2e.webm` — agent-browser 录制完整流程
- `docs/notes/evidence/pr126-04-deepseek-reply.png` — chat 界面显示真实 DeepSeek 回复："Hello from the depths of attentive stillness."

**5 步验证流程**:
1. 添加 API key → masked 显示 `sk-06a5...0a7c`
2. 创建 workspace
3. 添加 curl.agent template（7 字段：agent_uri/provider/api_url/model/system_prompt/max_history/owner_uri）
4. 添加 routing rule `{:always} → curl-agent://my-deepseek`
5. Chat: 发 "DeepSeek say hello" → 真实回复出现在 session

---

## 3. 性能基准

### 3.1 Stress test 中与 DeepSeek 相关的发现

**文件**: `docs/notes/v1-stress-test-results-2026-05-22.md` 及中文版

> 注意：stress test 直接测试的是 Ezagent 的 dispatch/routing/session 能力，不是 DeepSeek API 本身的性能。DeepSeek 作为**外部 HTTP 依赖**引入的延迟未在 stress test 中测量——stress test 用 `turn_cap=0` (sink mode) 消除了 agent 回复路径。

#### 对 DeepSeek 作为 external dependency 的相关结论：

| 指标 | 数据 | 含义 |
|---|---|---|
| **dispatch 延迟** | p99 < 1ms（任意 N agent） | Ezagent 内部编排路径不是瓶颈 |
| **Session GenServer 串行化** | N=100 时 持续 msg/s 降至 329（从 N=5 的 1460） | 扇出成本线性增长，但非 DeepSeek 导致 |
| **DB 写延迟** | p99 1.5–17ms（WAL 模式） | SQLite 单写者远未达瓶颈 |
| **内存** | N=100 agent burst → 1.77 GB 瞬时 RSS | 主要约束是内存，不是外部 API 延迟 |

#### DeepSeek API 相关的延迟估算（来自 autoservice v2 spec）：

| 组件 | 目标 | 模型 |
|---|---|---|
| **Fast agent ACK** | **< 2s** response time | `deepseek-v4-flash`, no thinking, `max_tokens: 256` |
| **Progress filler** | 每 5-10s 生成一次 | `deepseek-v4-flash` |
| **Curl translate** | 未硬性规定（辅助角色） | `deepseek-chat` |

### 3.2 API 调用模式

- **协议**: HTTP `POST /chat/completions`（OpenAI 兼容）
- **客户端**: Erlang stdlib `:httpc`（零新依赖，匹配 Feishu plugin 的 stdlib-only 选择）
- **流式传输**: **不支持**——当前 unary request/response
- **重试**: 依赖用户重发；无自动 retry on 429/5xx（out of scope）

---

## 4. 可靠性模式与失败处理

### 4.1 已覆盖的失败场景

| 失败模式 | 系统行为 | 用户可见性 |
|---|---|---|
| **无效 API key (401)** | curl agent 发 `chat.send` "Error: 401 unauthorized" | ✅ admin 在 session 看到，key 不泄漏 |
| **DeepSeek 不可达（网络）** | `:httpc` 重试 N 次 → 超时错误 surface 到 session | ✅ 超时错误可见 |
| **用户无 API key** | `get_api_key` dispatch 失败 → surface "missing api-key for provider deepseek" + `/admin/.../api-keys` hint | ✅ 操作员在 chat 看到指引 |
| **Loop prevention** | `msg.sender == ctx.self_uri` → ignore + 返回 `{:ignored, :self_message}` | ✅ 防止无限循环（实测 PR #126 首次 demo 33 次迭代后才 kill） |
| **重启后配置保留** | `create/1` 仅在 `ever_created` 列 gated，cold-load 不重置 provider/model | ✅ cold-load test 验证 |

### 4.2 Loop prevention 事故记录

> **PR #126 首次 demo**：使用 `{:always}` routing rule 指向 curl-agent。admin → curl-agent → DeepSeek → session 单向成功，但 curl-agent 的回复命中同一 `{:always}` 规则 → 无限循环，33 次迭代后才手动 kill phx。（来源：`curl-agent-walkthrough.md` §"Loop prevention"）

**两层修复**:
1. **Behavior 层**: `CurlAgent.handle_receive` 检测 `msg.sender == ctx.self_uri` → ignore
2. **运营建议**: 用 `{:from, user://x}` matcher 替代 `{:always}`

CI 回归 gate 已加入。

### 4.3 API Key 模型

- **per-user key**：系统本身不提供 key；每个 user 在 `/admin/users/<uri>/api-keys` 管理自己的 key
- **cascade 优先级**: 自身 slice → workspace template source → user template source（见 `curl_cascade_activation_test.exs`）
- **不可过期**: curl 的 DeepSeek key 是静态 secret，不需要 OAuth credential adapter（跟 cc/codex 不同，见 `dockerized-e2e-harness-design.md` §76）
- **mask 显示**: `sk-06a5...0a7c` 格式

---

## 5. Autoservice V2 中的 DeepSeek 使用

### 5.1 模型选择

| Agent | 模型 | Reasoning | 关键参数 |
|---|---|---|---|
| **fast** (即时安抚) | `deepseek-v4-flash` | 低延迟，no thinking | `max_tokens: 256`, `thinking: {type: "disabled"}` |
| **slow** (cc) | `deepseek-v4-flash`, effort=medium | 主回复 + kb_search + skill Read | cc agent, CLAUDE.md(soul) + MCP |

### 5.2 Fast agent 的 prompt 工程

**来源**: `cinnox-data/fast-deepseek-prompt/prompts.py`

两套 system prompt，共用同一 JSON schema `{"ack","intent","confidence","role_hint"}`：

- **`_ACK_SYSTEM_PROMPT`** — t=0 开场确认："我听到了，马上查"
- **`_PROGRESS_SYSTEM_PROMPT`** — cc 慢时 progress filler："还在查，快好了"

关键 prompt 设计约束：
- 12-30 中文字 / 30-70 英文字
- 引用客户话题自然词汇（"退款" 而非 "您的咨询"）
- 不承诺操作（"我帮您退款" forbidden）
- 连续两轮不回相同措辞
- **Voice fallback**: 4s 级 voice filler，用静态词库替代 deepseek 调用（避免 API 延迟叠加）

### 5.3 FillerLoop（安抚填充语调度）

来自 autoservice v2 设计（`docs/superpowers/specs/2026-06-10-autoservice-v2-design.md` §10）:

- Text: 每 10s → deepseek 生成安抚填充语
- Voice: 每 4s → deepseek 生成安抚填充语
- **熔断**: deepseek 连续失败 3 次 → session 永久 pin 回静态 fallback

---

## 6. 已知问题与经验教训

### 6.1 已解决的问题

| # | 问题 | 根因 | 修复 | PR |
|---|---|---|---|---|
| 1 | **Loop 无限循环** | `{:always}` routing rule 让 agent 回复也路由回自己 | Behavior 层 self-sender guard + `{:from}` matcher 推荐 | #126 |
| 2 | **Routing rule 不生效** | `RoutingRegistry.put/3` 要求 owner pid；LV process 非 table owner | restart phx 后生效；未来应通过 owner GenServer call | (pre-existing, 发现于 #126) |
| 3 | **API key 泄漏风险** | 旧代码在 audit/log 中可能输出 key | mask 显示 + grep gate | #126, #389 |
| 4 | **Cold restart 重置配置** | `create/1` 在每次 start 都跑 | Lifecycle API: `create` 仅 `ever_created=false` 时跑，`activate` 每次跑但不重置 state | #153 |

### 6.2 Deferred 项（有意识不做）

| 项 | 原因 |
|---|---|
| **Streaming** (`stream: true`) | chunked response 解码增加复杂度，unary 够用 |
| **Provider-specific schema branching** (Anthropic) | DeepSeek 是 OpenAI-compatible；多个后端时在 `ApiClient` 加 switch |
| **Per-instance retry on 429/5xx** | 依赖用户重发 |
| **`owner_uri` rotation** | 固定 owner 防止 orphan-conversation-with-new-key 混淆 |

### 6.3 关键教训

1. **Routing rule 的正确姿势**: 对于任何会自己发消息的 agent，永远用 `{:from, specific_uri}` 而非 `{:always}`，否则 agent 的回复会 re-enter 同一规则形成无限循环。

2. **双测试策略有效**: CI mock (Bandit Plug) 保证编排路径正确 + ~3s 反馈；手动 real-key smoke 保证真实 HTTP 集成。两者互补，不互相替代。

3. **Static key vs OAuth**: DeepSeek 的 API key 是静态 secret，这简化了 Docker dev harness 的 layerability——key 直接存在 DB `:api_keys` slice 里，不需要 credential adapter 和 provisioner（跟 cc/codex 的 OAuth 完全不同）。

4. **`:httpc` 够用**: Erlang stdlib 的 `:httpc` 做 unary completion 调用完全胜任，零新依赖。但 streaming 场景需要升级。

---

## 7. 测试数据汇总

### 7.1 测试统计

| 测试层 | 文件数 | 测试数 | 状态 | 运行时间 |
|---|---|---|---|---|
| 单元测试 (curl_agent) | 2 | ~30 | ✅ 全通过 | <1s |
| 单元测试 (api_keys) | 1 | 12 | ✅ 12/12 pass | <1s |
| 集成测试 (cascade) | 1 | ~8 | ✅ 全通过 | ~2s |
| E2E 合约测试 (scenario 07) | 1 | ~12 | ✅ 全通过 | <1s |
| E2E 编排 (4-agent CI) | 1 | 1 | ✅ 全通过 | ~3s |
| 真栈 smoke | 2 runbooks | 手动 | ✅ 已执行 | ~30s |
| Stress test | 1 工具 | 6 场景 | ✅ 0 error | 分钟级 |

### 7.2 证据清单

```
docs/notes/evidence/
├── pr126-curl-agent-deepseek-e2e.webm     (210 KB, 完整 e2e 录制)
├── pr126-01-api-keys-page.png             (API key masked 显示)
├── pr126-02-workspace-template.png         (curl.agent template 注册)
├── pr126-03-routing-rule.png              (routing rule active)
└── pr126-04-deepseek-reply.png            (真实 DeepSeek 回复)
```

---

## 8. 建议

1. **生产部署前**: 建议在目标网络环境（非本地）测量 DeepSeek API 的 p50/p95/p99 延迟，特别是 `deepseek-v4-flash` no-thinking 模式的响应时间。当前 Ezagent 内部 dispatch p99 < 1ms，外部 API 延迟是主导因素。

2. **FillerLoop 熔断**: autoservice v2 设计的 "3 次连续失败 → 熔断到静态 fallback" 应在实现时加入可观测性（telemetry event），便于运维感知 DeepSeek API 降级。

3. **Key rotation**: 当前 API key 是静态存储，无过期机制。如果 DeepSeek 后续支持临时 token，可考虑实现 credential adapter 对接。

4. **Streaming 评估**: 如果 fast agent ACK 延迟超出 `<2s` 目标，应评估 `stream: true` 的 chunked response 是否能改善首字延迟。

5. **Model version pin**: `deepseek-v4-flash` 是 floating tag——建议在 AgentTemplate 中记录实际 resolved model version，方便问题回溯。
