# handoff · 2026-06-26 · gagameow — agent 配置验证（对标原 autoservice）

**FP2**：本周期 agent 运行时大改（A+B+C 整合 / RF-1..9 / kanban-as-role / sidecar→erlexec / py-agent P1+P2）后，验证 agent 配置与运行时行为**不回归**，对标原 autoservice 工作。

## 背景
agent 运行时这周期被结构性重写。需要一次集中验证：原本 autoservice 跑通的链路现在是否仍正常。py-agent P1+P2 已在 main（echo 已退役为 py），不阻塞本任务。

## 今日交付（DoD）
- [ ] **原流程重跑**：原 autoservice 的端到端流程在当前 main 上重跑通过（附证据）。
- [ ] **Feishu 同步**：agent↔Feishu 双向同步正常（入站/出站）。
- [ ] **API 同步**：HTTP API 链路正常 —— **用 codex 作 HTTP 客户端**对 OpenAI-兼容端点（`/v1/chat/completions`，默认 agent 现为 `py_default`）发起请求验证。
- [ ] 发现的回归 → 开 issue + 复现步骤；能修的小回归直接修。

## 涉及
`apps/ezagent_plugin_protocol_api`（OpenAI 端点，默认 agent 已 re-point 到 py_default）· autoservice 场景 · Feishu 适配器 · agent 配置（domain.agent，本周期统一）。

## 约束
进 main 的 PR 需 precommit+check_invariants 绿 + rebase。handoff 前读 `docs/together/contributing/`（尤其 P0：动 core 前先与 lead 对齐设计）。
