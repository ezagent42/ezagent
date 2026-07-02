# 2026-06-26 · 团队 PR 入册 + 分析（lead 侧）

来源：午后转发的三个团队 PR + ruihuachen handoff。逐 PR 核了 diff / 测试 / CI（非只看描述），两处"描述≠实际"已标。

## 概览

| PR | 作者 | 一句话 | 状态 | 待 lead |
|----|------|--------|------|---------|
| #1022 | ruihuachen（设计） | 官网价值链文档 + 3 demo + 一个被误标的 `agent invoke` CLI facade | **CONFLICTING，CI 红（core FsResolver 不变量，疑 stale-base）** | value-confirm 4 张 P0 卡；纠正"无生产代码"措辞；干净 rebase 复验 |
| #1023 | zhaomaota97 | hello session 加 `@salesperson`：聊天回交互式 json-render 数据卡片（不碰页面） | **CI 绿，可合但落后 main** | rebase（非 synced）；lockfile 顺序 vs #1022；卡片 UX 评审 |
| #1024 | gagameow | AutoService 对标审计 + Feishu WSS 修复 + 37 场景 E2E 映射 | **CI 红（自身过期测试，trivial）** | 作者修 SidecarOrphanReapTest；定 KB/Dream-CR/Publish 哪个先排 |

## #1022 — 官网价值链 + demo + CLI facade
- 文档/demo：`docs/rh/homesite/value-chains/V-价值链总表.md`（含新"价值传达"段）+ 暗黑玻璃 v2 全站、指挥官驾照、路线图押注 demo。
- ⚠️ 描述称"无生产 Elixir"，实际加了 `ezagent_cli` 的 `agent invoke`（headless 按 `<behavior>.<action>` 派发到目标 agent，JSON args）~97 行 + dispatch/tree_builder/workspace 的 optional-arg 放宽 → **这是 kanban-loading 的使能件，需被 review，不是 housekeeping**。
- CI 红：`Ezagent.Resource.FsResolverTest`（core 不变量）。但 Elixir 改动 CLI-only、无触 core 解析器的因果路径，且分支 stale/冲突 → 大概率 stale-base 假象，**须干净 rebase 后复验绿再合**。
- **待 value-confirm 的 4 张 P0**：`0-A1` 站点骨架+部署（研发）、`②-C1` 可嵌入跑的 demo（依赖只读 sample 后端）、`0-D1` 锚点定义（产品）、`增-A1` 收益主张（"底座白拿+收敛成配置不写码+可对外公开"作为用户收益）。另：指挥官驾照(⑤-C1)、路线图押注(②-D1，"PR 合并=结算"、仅虚拟积分/合规红线) 为 demo-先验机制。

## #1023 — @salesperson 数据卡片 agent
- 新 `Entity.Salesperson` Kind + `Behavior.Salesperson`，与 builder 并存。`:role_name_taken` 修复真实且只 plugin-local（`App.join/3` 原硬编码 role_name="builder"，现参数化）。
- 卡片：以 salesperson 身份回、从不改页面、malformed JSON 重试一次；按需 per-card scoped CSS（不污染全局）；交互建模成"以用户身份发消息"走现有链路。world 前端补 shadcn `@source`（Tailwind v4 不扫 dist → 之前裸样式）。
- **CI 绿**；hello 插件 **30 测试**（核实）。**最干净的一个**，无触 core。落后 main 需 rebase（描述 synced 不准）；package-lock 与 #1022 撞，先合谁后者 rebase。

## #1024 — AutoService 对标 + Feishu WSS 修复
- 真生产修复：`ws_sidecar/main.js` 的 `process.stdin.resume()` 把 Node 置 flowing → 饿死 Lark SDK WSS 循环（收不到 `im.message.receive_v1`）→ 改 5s 父 PID 轮询。根因 bisect 清楚。
- CI 红 = **自身的 SidecarOrphanReapTest 过期**（删了 stdin-EOF 路径没改断言），非 flake，trivial 修。
- **战略产出 = parity gaps（L3 需开发、非配置）**：① KB 摄取/源管理/向量检索 ② Dream→提案→CR→publish/rollback 治理 ③ sandbox preview/release archive/指针翻转发布 ④ 语音 ASR/TTS ⑤ 附件上传+存储（租户禁用）⑥ 计费看板+SLA 分析。结论：ezagent 作 agent/session/routing/channel 底座可行，**非 AutoService 完整替代**——上述 6 项须按新能力立项。另记 3 issue：Protocol API invalid-token 返 400 非 401（Low）、退役 echo 插件测试残留（Med）、Feishu WSS（Med，已修）。

## 合并协调
- **lockfile 顺序**：#1022 与 #1023 都重写 `apps/ezagent_plugin_world/assets/package-lock.json` → 排序后合，第二个 rebase。
- #1022 须 rebase + 复验绿 + 纠正"无生产代码"框架后再评审。
