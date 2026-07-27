> **Task:** G5 SOP — 通用可配置错误机制实施文档
> **Branch:** `docs/workspace-self-service-product-plan`
> **PR:** https://github.com/ezagent42/ezagent/pull/1436
> **Dev:** ruihua（designer）
> **returned_at:** 2026-07-17 17:00 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time

## 做了什么

基于仓库现有错误处理机制的实地调研（见 §1），撰写了 **通用可配置错误机制 SOP**：

**文档：** `docs/plans/2026-07-17-error-mechanism-sop.md`

**内容结构：**

| § | 内容 | 受众 |
|---|------|------|
| §1 | 现有基础——仓库已有的 `{:error, reason}` 约定、`dispatch_error` 类型、`Ezagent.Notifications`、`CredentialStatus` 等可复用的机制 | 研发 |
| §2 | 错误码 Schema——一条注册记录长什么样（code / trigger / category / message） | 研发 |
| §3 | 注册流程 4 步：收集 case → 注册错误码 → 写文案 → 测试链路 | 研发 |
| §4 | 渲染链路——`ErrorMatcher` → `ErrorRenderer` → 前端消息卡片 | 研发 |
| §5 | 消息文案撰写规范——不道歉、不猜测、可行动的语气原则 + 按 category 的示例 | 产品/设计 |
| §6 | beta 第一批错误码——从现有代码提取的 7 条待注册 case（含来源文件和行号） | 研发 |
| §7 | 验证方式——单条错误码自测 6 步 + CI E2E 全链路验证 | 研发 |
| §8 | **待 lead 裁定（3 项）** | lead |

## 待 lead 裁定（§8）

| # | 决策项 | 选项 | 影响 |
|---|--------|------|------|
| **D1** | 错误码注册表放在哪个 app？ | A: `ezagent_domain_agent`（靠近 agent）<br>B: `ezagent_core`（通用 infrastructure） | 决定 3 个新模块的 namespace |
| **D2** | beta 第一批注册几条？ | A: 2 条最小路径先跑通<br>B: 全部 7 条 | 决定 beta 实施范围 |
| **D3** | 渲染链路改造范围？ | A: 只改后端 + 扩展现有前端组件<br>B: 新建前端消息卡片组件 | 决定前端工作量 |

## Method friction

调研过程中发现：仓库的错误处理目前是「一个领域一个 `error_message/1` 函数」的散落模式——`identity_data.ex`、`agent_actions.ex`、`conversation_actions.ex` 各有一套。SOP 的价值在于把这些散落点收敛为一个注册表，新增错误 case 不需要找「该在哪个文件加映射」。但这也意味着**实施时有迁移成本**——需要把现有的 `error_message/1` 调用逐步替换为走注册表。这个成本在 SOP 中没有展开（取决于 D1/D2/D3 裁定后的实施 plan）。

## Merge request

SOP 文档已 push 到 PR #1436 分支。3 项待裁定需要 lead 决策后才能锁版。
