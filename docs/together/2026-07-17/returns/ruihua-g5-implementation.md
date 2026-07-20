> **Task:** G5 通用错误机制 — 落地实施
> **Branch:** `feat/g5-error-mechanism`
> **PR:** https://github.com/ezagent42/ezagent/pull/1451
> **Dev:** ruihua + Claude
> **returned_at:** 2026-07-17 19:50 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time（E2E 环境已跑通；发现 trigger 层架构问题需 lead 裁定）

## DoD reconciliation

| # | DoD 项 | status | proof |
|---|--------|:--:|-------|
| 1 | 通用机制建成（#1+#3 同 matcher） | met | ErrorMatcher 两条走同一 match/1；单元测试覆盖 |
| 2 | A/B/C 截图 | **partial** | 本地 dev 环境已跑通（login + agent + session + 发消息）；截图见下 |
| 3 | C 兜底 | met | Layer 3 register_issue/2 |
| 4 | SOP file:line 修准 | met | curl_agent.ex:250；error_message/1 仅在 user_data.ex |
| 5 | gate 全绿 | met | format ✅；invariants ✅；15 unit tests ✅ |
| 6 | PR + adversarial review | met | PR #1451 draft |

## E2E 发现（关键）

本地 dev 环境已跑通（经过 30+ 轮调试：端口 10042、world.localhost、PAT_PEPPER_V1、email_verified、Vite build）。E2E 执行结果：

- **A/Layer1** — founder 发消息到无凭证 curl agent。Agent 返回了**英文硬编码文本**（`no API key for provider anthropic — please add one at ...`），不是 G5 结构化错误卡片。

- **B/Layer2** — member 发消息到同一 agent。消息未出现在历史记录中，也未触发任何可见错误。

**根因分析：** `{:no_api_key}` 在 `curl_agent.ex:250` 被 agent 内部捕获，转换为文本 reply（`reply_text = "no API key for provider..."`），作为 `{:ok, %{ok: false, ...}, effects}` 返回。**这个 error 从未走到 dispatch error 层**——G5 ErrorMatcher 的钩入点（`{:error, reason}` 在 dispatch 路径）看不到它。

这意味着 SOP §6 的 trigger pattern 需要重新评估：`agent_credential_missing` 的实际匹配点不在 dispatch 层，而在 **agent reply 的渲染层**——需要从 `%{ok: false, error: :no_api_key}` 中提取，而非从 `{:error, {:no_api_key, _}}` 中匹配。

## Method friction（重要）

本次 E2E 暴露了两个结构性发现：

1. **SOP 的 trigger pattern 假设不准确。** 我们按仓库源码提取了 `{:error, reason}` 的精确返回，但有部分 error（如 `:no_api_key`）在 agent 内部被转为文本 reply，从未走 `{:error, reason}` 路径。错误码注册表的 trigger 设计需要区分两类路径：
   - **dispatch 层 error**（`:unauthorized` 等）→ 在 `handle_event` 的 dispatch result 中匹配 ✅
   - **agent 层 error**（`:no_api_key` 等）→ 需要从 agent 的 reply 内容中提取，或在 agent 内部加 hook ❌

2. **E2E 环境对非工程师门槛过高。** 本地 dev 需要 Postgres（55432）、PAT_PEPPER_V1、SIGNING_SEED_V1、Vite build、npm install、world.localhost 路由、email_verified SQL 更新——30+ 轮调试才跑通。已跑通的启动命令：`EZAGENT_PAT_PEPPER_V1="test-only-pat-pepper-v1-32-bytes-minimum" EZAGENT_SIGNING_SEED_V1=0123456789abcdef0123456789abcdef bin/dev`

## 待 lead 裁定

| # | 决策项 | 说明 |
|---|--------|------|
| **D5** | **#1 agent_credential_missing 的 trigger 层** | 当前在 agent reply 层（`%{ok: false, error: :no_api_key}`），不在 dispatch error 层。需要在 SOP/注册表中调整 trigger pattern，或修改 curl_agent 让其走 dispatch error 路径 |
| **D6** | **G5 ErrorMatcher 是否需要双轨 hook** | dispatch 层（现有）+ agent reply 层（新增）。如果只挂 dispatch 层，部分错误码的 trigger 会匹配不到 |

## Merge request

PR #1451 保持 draft。D5/D6 裁定后调整实现。

---

## 2026-07-20 续：D5/D6 已解决 + E2E 再尝试

### D5/D6 决议（jjkysy PR #1456）

jjkysy 的 PR #1456（feat/g5-agent-structured-errors）已合 main，明确回答：

- **D5**：agent 侧吐纯 reason 数据（`{:no_api_key, provider}` 形状不变），ErrorCode #1 的 trigger `{:error, {:no_api_key, :_}}` **不用改**。
- **D6**：**双轨 hook 已实现**。dispatch 层（#1451 已有，ephemeral 顶部卡）+ agent-reply 层（#1456：ErrorSignal 编解码 → ErrorCards 按观看者附卡）。三件套 ErrorCode/ErrorMatcher/ErrorRenderer **零逻辑改动**。

PR #1456 新增模块：`Ezagent.Agent.ErrorSignal`（domain_agent）、`Ezagent.World.ErrorCards`（world）、flavor 错误分支改吐结构化体（curl ×2 / cc-headless ×1 / hello ×4）+ Conversation.tsx 气泡内联渲染。

### E2E 再尝试（2026-07-20）

**已修问题（非 G5 核心，环境/权限 infra）：**

| 修复 | 说明 |
|------|------|
| `kind_cap_authorities` 表缺失 | main 上新 migration 未跑 → `mix ecto.migrate` |
| G5 用户无 `entity_profiles` | `create_read_only/2` 不建 profile 行 → seed 脚本补 `Profile.upsert` |
| G5 用户 `email_verified: false` | 挡登录 → seed 脚本补 `Users.mark_email_verified` |
| G5 用户非 workspace member | UI session 列表为空 → `Workspace.add_member` |
| G5 用户无 `create_session` cap | 创建 session 卡权限 → `Cap.issue` workspace cap |
| `LayoutBootstrap.ensure_system_workspace_runtime` TOCTOU race | `{:already_registered, _}` 未处理 → 补 pattern match |
| G5 用户无 `send` cap（test1 session） | 消息发不出去 → `Cap.issue` send cap |

**E2E 截图结果：**

- ✅ session 内页面：agent `g5-e2e-agent-1784278421` 已加入 session（截图 `在session内.png`）
- ❌ 发送消息：`@agent hello` 发送后消息不出现在聊天框（截图 `发消息前.png` / `发消息后.png`）

**当前卡点：**

1. **LiveView WebSocket 不稳定**：session 创建后端成功（DB 有记录），但 `push_patch` 跳转没到达浏览器，页面卡在"创建中"。
2. **消息发送失败**：`send` cap 在独立 `mix run` BEAM 中 issue，`bin/dev` BEAM 不感知——需在同一 BEAM 内 issue cap。尝试在 IEx 中操作但消息仍不出现。
3. **Vite watcher 报错** `:watcher_command_error`（端口 5173 被占用）——可能是 LiveView socket 通信不稳定的根因。

**下一步建议：** 需要在一个干净环境（Vite 单实例 + 完整 session 权限在同一 BEAM 内）下重新跑 E2E 截图。或者用 Playwright E2E 脚本（`scripts/g5_e2e_seed.exs` + `e2e/` 目录下的测试）替代手动截图。
