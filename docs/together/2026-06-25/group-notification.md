# 群通知 prompt — 2026-06-25 今日开发计划

> 可直接复制到群里 @ 通知。详细计划 `docs/together/2026-06-25/plan.md`，各人 handoff `docs/together/2026-06-25/handoffs/`。

---

【2026-06-25 今日开发计划】

本周聚焦：**让团队能日常使用 ezagent**。官网本周期搁置。详细见 `docs/together/2026-06-25/plan.md`。

各位今天的任务（handoff 在 `docs/together/2026-06-25/handoffs/`）：

**@张宁(zhaomaota97) — hello / json-render 对齐**
前端 json-render catalog/渲染器对齐后端 shadcn 目录 + 验证 style 切换 + 稳定 hello 结构。
分支 `feat/hello-jsonrender-align`｜handoff: `zhaomaota97-hello-jsonrender-align.md`

**@黄佳佳(gagameow) — 整个 agent console + 后端 handoff**
①先给 `allenwoods` 的后端整合写一份**现状分析 handoff**（其他人等它）②接管**整个 agent console**：UI + config 面板（结构化每字段）+ 对接 `domain.agent`，下探不了的显式标"还没接线"。
分支 `feat/agent-console`｜handoff: `gagameow-agent-console-and-backend-handoff.md`

**@林懿伦(allenwoods) — agent 运行时后端整合**
LocalRuntime + cc-headless sidecar + protocol_api 整合（**从 gagameow 的现状 handoff 开始**）。
分支 `feat/agent-runtime-consolidation`｜handoff: `allenwoods-agent-runtime-consolidation.md`

**@李震宇(zyli-developer) — 产品缺口 F9 / F12**
F9（Feishu chat→session 绑定 UI）+ F12（Feishu `@` 解析成 agent mention）。
分支 `feat/product-gaps-f9-f12`｜handoff: `zyli-developer-product-gaps-f9-f12.md`

**@姚升悦(jjkysy) — dev-together skill 改进（owner）**
分析当前 review/plan，完善 dev-together skill 并提交改进 PR。
分支 `chore/dev-together-skill-improve`｜handoff: `jjkysy-dev-together-skill-improve.md`

**@陈瑞华(ruihuachen-designer) — 协助 jjkysy**
设计 review/plan 的可外发版式，交 `jjkysy` 落进 skill（不直接改 skill 文件）。
handoff: `ruihuachen-designer-review-plan-format.md`

**@戴明(FatNine)** — 今日任务待 @林懿伦 重新分派（agent console 已整体交 gagameow）。

**依赖**：gagameow 先出现状 handoff → 解锁 allenwoods；其余并行。

‼️ **流程（CI 已生效）**：每个进 main 的 PR 必须 ① CI（`precommit + check_invariants`）绿 ② rebase 到当前 main ③ 返还前本地自测绿、按 handoff 的 DoD **逐条**核。**UI 功能要有穿真实界面的自动化测试，不能只截图。** 延期由 lead 裁定，不要自宣"可合并"。
