# Return: T4 官网 — 栏目 / 内容优先级 / 交互方向（ruihua → zhaomato）

> **Task:** T4 官网（ruihua 设计部分）— 给栏目/内容/交互方向，unblock zhaomato 框架上线
> **Branch:** `docs/website-0630`
> **PR:** https://github.com/ezagent42/ezagent/pull/1103 (draft)
> **Dev:** ruihua (designer)
> **returned_at:** 2026-06-30 (Tue)
> **deadline:** 2026-06-30 19:00 +0800
> **deadline_status:** on_time
> **对接人:** zhaomato（建 hello 页面 + 连通 backend/world + 生产尝试）

本文是给 zhaomato 的**可执行方向**，不是终稿文案。原则：**先上线一个风格/栏目一致的框架**，内容与交互细节后续迭代（见末尾 follow-up）。素材底座 = 本 PR 的 `docs/website-demo/`（多页 demo 已成型）。

---

## 0. 定位与风格基线（不可漂移）

- **一句话定位：** 组织的 IDE · Organization IDE —— 一个底座，两个产品。
- **风格权威：** 走 `ezagent-design-system`（global skill）拉取的品牌系统，**与 #1083 FP4 app 内 token 完全一致**：
  - 色：De Stijl 三原色 `#D81830 红 / #0048A8 蓝 / #FFD400 黄` + **行动色钴蓝 `#0B5CFF`（唯一 CTA 色）** + 页底 `#E8E8EB`；**禁渐变**。
  - 字：Inter / Noto Serif SC（中文标题）/ Noto Sans SC（中文正文）/ Space Mono（数据）。
  - 形：白卡 + radius 22 + 招牌柔影；毛玻璃覆盖色块；点彩纹理。
  - 文案：双语 `中文 · English`；英文 UI 用 Sentence case；无 emoji。
- **官网与 app 同源同感：** 官网是 app 的门面，视觉必须让用户一眼认出是同一个产品。

## 1. 栏目结构 + 上线优先级

> 框架上线 = 把 P0 跑通；P1/P2 可占位先行、内容后补。

| 栏目 | 路由 | 优先级 | 数据来源 | 上线要求 |
|---|---|---|---|---|
| **首页 / 介绍 Intro** | `/`（index hero +「一个底座，两个产品」） | **P0** | 静态 | 定位 + 双产品（world / hello）讲清，主 CTA「开始使用 · Get started」指向 hello/登录 |
| **研发进度 world.cup** | `/#worldcup` | **P0** | **真实 GitHub 数据**（已接 ezagent42 org） | 公开路线图 + 进度，这是官网最大差异化亮点，必须真数据不可 mock |
| **核心团队 Team** | `/#contributors` | **P1** | 真实贡献者 | 占位可上，内容后补 |
| **hello 页面（产品试玩）** | hello 页 | **P0**（你 zhaomato 的主战场） | **backend/world 联通** | 见 §3；这是「官网连通产品」的证明点 |
| **登录 Login** | `/login` | **P1** | app 真实 auth | 框架可先跳 app 登录页 |
| **我的主页 / 成就中心 Me** | `/achievement-center` | **P2** | 登录态 | demo 已有，后续接真实数据 |
| **指挥官驾照 / 团队办公室** | 子页 | **P2** | 静态/趣味 | 增长/裂变用，先不进上线框架 |

**导航统一**（`site-nav.js` 已实现）：介绍 · world.cup · 团队 · GitHub↗ ·（右）我的主页 · 登录 · 主题切换。框架上线沿用这套 nav。

## 2. 交互方向

- **P0 必须：** 主 CTA 钴蓝、唯一；nav 全站一致 + 登录态切换；world.cup 真数据渲染；深浅主题切换不破样式（#1083 已修夜间模式对比度，沿用）。
- **P1：** hello 试玩的「即看即玩」入口；卡片→小球 morph 等微交互（demo 已有，可保留但不阻塞上线）。
- **P2（后续）：** 驾照测试、成就中心、办公室可视化等增长玩法。
- **停手线：** 上 `app.ezagent.chat` 生产前必须与 **Allen / T6** 协调（生产环境）。

## 3. hello 页面 + backend/world 联通（给 zhaomato 的对接点）

- 框架走 hello 已用的 `@json-render` 渲染底座（catalog/registry），与 app 内渲染对齐。
- demo 里的 `mock-ezagent-api.js` 仅用于纯静态预览；**生产框架应连真实 backend/world**，hello 页面渲染真实 hello session/卡片。
- 联通证明（T4 DoD）：hello 页能从 backend/world 取到真实内容渲染一次 + 本地 proof 截图。

## 4. ruihua follow-up list（我后续细化 / 明确 deferred）

- [ ] 首页 Intro 终稿文案（双语 hero + 双产品一句话）—— 明天给。
- [ ] world.cup 栏目的叙事文案 + 空状态/加载态文案。
- [ ] Team 栏目真实贡献者内容与版式。
- [ ] 成就中心 / 驾照 / 办公室的视觉细化（P2，不阻塞上线）。
- [ ] 全站响应式断点核对（移动端，参考 #1083 已修的 overflow 规范）。
- **Deferred（非今天）：** 外部 `ezagent-design` 源仓库升级到 shadcn（#1083 DoD #9 留下的，属设计系统侧，单独 handoff）。

---

## DoD reconciliation

| # | DoD 行 | 状态 | 证据 / 说明 |
|---|--------|------|------|
| 1 | ruihua 给官网栏目/内容/交互方向，unblock zhaomato 框架上线 | met | 本文 §1–§3：栏目+优先级+交互+联通对接点 |
| 2 | ruihua follow-up list | met | §4 |
| 3 | 风格/栏目与 app 一致 | met | §0 对齐 #1083 FP4 token + `ezagent-design-system` |
| 4 | 内容素材就位 | met | 本 PR `docs/website-demo/` 多页 demo |

**Method friction:** 今日 handoff 文件（`t4-ruihua-website-content.md`）发 plan.html 时尚未落库，我据 plan.html 的 task/DoD 直接产出；若 handoff 细节与本文有出入，以 handoff 为准、我再补。原 `docs/website-demo` 分支陈旧未 rebase，已新开 `docs/website-0630`（基于最新 main）避免回退团队工作 —— 建议官网类长分支定期 rebase。
