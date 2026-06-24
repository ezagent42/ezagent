# 主线进展速览：e2abc02f → b6818123（+59 提交，2026-06-22）

这份是给已经读过 `intro/` 全套的人看的「自上次基线以来发生了什么」增量。
之前 `intro/` 里把 world、agent-schema 写成「在建 / future / 没进 main」的地方，**现在全部过时了**——这两条都已经落地进 main。

> 仍然是 **21 个 umbrella app**，但成分换了：**砍掉 `ezagent_plugin_liveview`，换成 `ezagent_plugin_world`**。不是「多了一个」，是「换了一个」。

---

## 一、world 落地，liveview 退役（最大的一笔）

旧 main 里管理面是 LiveView 实时页（`ezagent_plugin_liveview`，Elixir 服务端渲染）。
现在它**整个被删掉**，由新的 `apps/ezagent_plugin_world/` 取代——这是一个**统一的 React 前端**（Vite + TypeScript，看 `apps/ezagent_plugin_world/package.json` / `vite.config.ts` / `src/`），把原来 LiveView 那套管理界面**逐功能复刻了一遍再退役旧的**。

怎么做到「平价替换」的（commit 串）：
- `c7031d8f test(world): PR-0 LV parity ratchet gate` —— 先建一道闸门，列出 LiveView 有的 **44 项功能**，每补齐一项就少一项，**归零才允许删 liveview**（防止「换了新前端但少了功能」）。
- 中间 PR-1..PR-6 一项项补：会话对话流 + 输入框、@提及、成员面板与在线状态、文件上传（走 `:session :attach` 分发收口，不旁路）、workspace/插件面、PTY 终端面……
- `3b7072a0 Complete world LV parity migration` —— 44 → 0，平价达成。
- 配套修了几个权限/admin 漏洞（如 `d50aa08b` 关掉 admin 平权绕过 + profile admin 默认值泄漏 #154）。

**对回答问题的影响**：再有人问「管理面 / 实时页 / LiveView 在哪」，答案是 `ezagent_plugin_world`（React），**别再去找 `ezagent_plugin_liveview`，它已经不存在**。原 SKILL 模块索引里那条「liveview 46 个稳定失败」的测试基线也随之作废（那个 app 没了）——world 的测试基线需要重新 bootstrap 后才有数。

---

## 二、agent-contract 三阶段落地（原「agent-schema 编排契约」）

旧 main 里这只是设计词汇。现在 **agent manifest 工具契约**真进了代码，分三阶段：

落点文件：
- `apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex` —— 内核侧的 manifest 工具定义。
- `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex` —— CLI 侧的门面。

三阶段（commit 串）：
- **Phase 1**（`a15ca637`）：agent manifest 契约骨架。
- **Phase 2**（`0d5d57f7`）：manifest 工具契约补全。
- **Phase 3**（`9cb4d68b feat(agent-contract): Phase 3 — versioned artifact pin + ledger-tracked migrate_session`）：**带版本的产物钉死（versioned artifact pin）** + **被账本（ledger）跟踪的 `migrate_session`**——即 agent 用的产物有版本、可钉死到某一版，会话迁移留账可追。
- 整合时还修了 URI 构造（`c3f53153 UriQuery-safe URI construction`）。

合并路径：`agent-schema` 分支 → `agent-contract-integrate`（#881）→ main。所以代码里 `agent-schema` / `agent-contract` 两个名字指的是同一条线。

---

## 三、anon-user epic 合并（匿名用户）

`e2eec34d Merge main (anon-user epic #876 + ezagent-socialware skill #877) into world` —— 匿名用户那条 epic（#876）这次也进了 main 并被 world 吸收。配合 socialware 的匿名访问（`public_view: true` 的会话公开给匿名外部用户），这条让「没登录的外部用户」也能被正确接住/接管/合并。

---

## 四、socialware skill 同步

`b6818123 docs(skill): update ezagent-socialware for world + agent-contract landing (#882)` —— 上游那份权威 socialware skill（`.claude/skills/ezagent-socialware/SKILL.md`）也更新到了 world + agent-contract 的新现实。问 socialware / 客户产品 / 匿名访问时，**先加载那份 skill**，它已经是最新的。

---

## 一句话总结

world 把 LiveView 管理面换成了 React 统一前端（liveview 已删），agent-schema 以三阶段 agent-contract 真正落地（manifest 工具 + 产物钉版 + 会话迁移留账），anon-user 也并入 main——**app 数仍 21，但 liveview→world，且两条「在建」产品线都已上线**。
