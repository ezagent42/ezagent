# handoff · 2026-06-26 · zhaomaota97 — hello 在 world 内嵌验证

**FP3**：验证 hello 生成内容在 world 内的内嵌渲染是否足够。

## 背景
6-25 完成了 hello AI 页面生成器（#982，纯 shadcn 渲染 + 协作白板 + 增量编辑）。本日验证它在 world 里的**内嵌**是否够用——产品要的是 world 会话里能动态展示生成内容。

## 今日交付（DoD）
- [ ] **关键验证点：world section 能否插入动态卡片**（hello 生成的卡片在 world section 内正确渲染、可交互）—— agent-browser 截图为证。
- [ ] json-render 渲染**稳定性**：style 切换、增量编辑在 world 内嵌场景下不崩。
- [ ] 不足之处列清单（哪些 hello 能力在 world 内嵌时缺失/降级），供后续排期。

## 涉及
`apps/ezagent_plugin_hello/assets/*`（`spec.ex` 只读）· world section 渲染 · json-render catalog/registry。触及 world 遵守 world-coordination。

## 约束
进 main 的 PR 需 precommit+check_invariants 绿 + rebase；前端跑 `pnpm build` 绿。handoff 前读 `docs/together/contributing/`。**用 agent-browser 自验**（截图）再返还。
