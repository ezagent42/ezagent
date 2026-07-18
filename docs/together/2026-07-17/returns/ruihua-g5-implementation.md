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
