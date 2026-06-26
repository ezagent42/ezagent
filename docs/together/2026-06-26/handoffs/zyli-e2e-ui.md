# handoff · 2026-06-26 · zyli-developer — E2E 文档补全 + UI 修复

**FP4 + FP5**：① E2E 文档体系补全（支持未来开发测试）；② UI 界面修复（先列清单，再逐条修复）。

## 背景
6-25 你建了人肉 E2E 执行记录体系（#990，docs/e2e/ 场景）。F9（#975）+ F12（@→agent mention）已完成。本日把 E2E 文档补全到"agent 拿 agent-browser 能照着自动跑通"，并系统修 UI。

## 今日交付（DoD）
- [ ] **E2E 文档补全**：`docs/e2e/` 场景沉淀完整（每场景：步骤 + 期望 + evidence 示例），**agent 拿 agent-browser 能照着自动跑通**——这是支撑未来开发测试的资产。
- [ ] **UI 修复（先清单后逐条）**：先通盘巡检列出 UI 问题清单（截图标注），再逐条修；每条修复 PR 附**前后对比证据**。
- [ ] （注意 #990 记录的 gap：新 session 无默认 `always→members` 路由规则、无 @ 消息不送达——若属 UI/产品缺口可纳入清单。）

## 涉及
`docs/e2e/` · world UI（触及 world 遵守 world-coordination）· Feishu 适配器（如 UI 涉及）。

## 约束
进 main 的 PR 需 precommit+check_invariants 绿 + rebase；前端 `pnpm build` 绿。**用 agent-browser 自验**再返还。handoff 前读 `docs/together/contributing/`。
