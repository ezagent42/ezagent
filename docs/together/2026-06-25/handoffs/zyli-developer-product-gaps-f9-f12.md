# Handoff — 产品日用缺口 F9 / F12（zyli-developer / 李震宇）

> **任务**: 实现你人肉验证暴露的两个 Feishu 日用入口缺口。
> **分支**: `feat/product-gaps-f9-f12`（off `main`，保持 rebase）
> **本周目标**: 团队日用（目标①）—— 这两个缺口直接挡着"团队能日常用"。

## 背景
你 2026-06-24 的全流程人肉验证跑通了主链路，但 L3/L4 只能靠 DB 手段验证，因为两个产品 UI 缺口：
- **F9**：没有把一个 **Feishu chat 绑定到 session** 的 UI（只能手工塞数据）。
- **F12**：Feishu 里的 **`@` 没有被解析成 agent mention**（消息进来但没路由到 agent）。

## 要做什么
- **F9**：做一个 UI 入口，让用户能把一个 Feishu chat ↔ 一个 session 绑定（建立/查看/解除绑定）。
- **F12**：在 Feishu 入站消息处理里，把 `@<agent>` 解析成 agent mention，路由到对应 agent。

## DoD（四性质）
- [ ] **F9 在用户面验证**：通过 UI 完成一次"Feishu chat → session 绑定"，之后该 chat 的消息进对的 session —— agent-browser 截图 + 一个自动化测试覆盖绑定路径。
- [ ] **F12 在用户面验证**：Feishu 发 `@<agent> 文本` → 被解析成 mention → 对应 agent 收到/回复 —— 真实链路证明（transcript）+ 解析的回归测试。
- [ ] **回归**：两条都有失败即报的自动化测试（不只截图）。
- [ ] **CI 绿** + rebase 到当前 main。

## 关键文件（起点，按实际为准）
- Feishu 适配器：`channel_server/adapters/`（cc-openclaw 侧）/ ezagent 的 feishu 插件 `apps/ezagent_plugin_feishu`
- session 绑定 + 入站路由：`apps/ezagent_domain_session` + world UI（绑定入口）
- @mention 解析参考：world 已有 server-side @mention 解析（#73 / PR-2a），可借鉴

## 必读
- skill `ezagent-developer`（+ `ezagent-socialware` 若触及 session）；`docs/guide/world-coordination.md`（触及 world UI 时）
- 你自己 2026-06-24 的人肉验证 return（F9/F12 的现场）
- dev-together skill（DoD 四性质；返还前 rebase+自测绿）

## 注意
- 触及 world UI 与 `gagameow`(console)/`zhaomaota97`(hello) 协调声明面。
- 先确认 F9/F12 的需求边界（绑定的粒度、@ 的语法）—— 不确定就先 clarify 再做（discuss-first）。
