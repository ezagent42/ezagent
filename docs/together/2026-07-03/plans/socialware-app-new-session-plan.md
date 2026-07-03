# 2026-07-03 Dev Plan — socialware=app · 新建-session 页面 · 基座瘦身

Lead: `allenwoods`. 起草: lead-agent (`claude`)。**草案,待 Allen grill。**
承接 0703 讨论(#1125/#1126/#1136 收编 + config:// 已废 + 新建-session 页面截图)。

---

## 0. 收编后的概念模型（锁定，进 GLOSSARY 由 Allen 落笔）

| 概念 | 是什么 | 寻址 | 状态 |
|---|---|---|---|
| **app = socialware** | 发布/可勾选的**产品单元**（一个 `Definition`：`agents` + `views` + shape/bases） | **`socialware:<name>`**（不透明 ConfigStore subject，workspace 独立字段） | ✅ T2 已胖化 |
| **SessionTemplate** | **"新建 session 页"的预设**（session name + 勾了哪些 socialware(=`installs`) + 邀请了哪些成员） | `template://<ws>/session/<名>`（实体 URI，待核 T1 是否碰过） | 部分（installs/members 在） |
| **session** | 跑起来的**实例**（左栏 Session List 一条） | `session://<ws>/<name>` | ✅ |

**关键判定（本次讨论定）**：
- **config:// 已废**（T1，prod 0 处）。socialware 用 `socialware:<name>`，recipe 用 `recipe:<name>`，都是**不透明 key**，不是 `<scheme>://`。
- **`socialware:` 不升成可路由 URI scheme** —— 它是**配置数据/目录键**，不是 actor；只有装进 session 才有跑着的 actor（session/agent 才有实体 URI）。保持 T1 的"数据 vs actor"边界。
- **#1126「app=变胖 SessionTemplate」判定为"混淆"** —— 它把"可勾选单元(app/socialware)"和"勾选表单(SessionTemplate)"当成一个。以 **#1136（app=socialware Definition）为准**。#1126 标注澄清，不 re-litigate 结论。

---

## 1. Build-state 审计（origin/main，已核对）

| 能力 | 现状 | 差距 |
|---|---|---|
| 建会话 | `create_session(name, template_name)`（按**模板名**建） | ❌ 不是"勾选 socialware"表单 |
| 邀请成员 | 有（Conversation.tsx Invite，#76） | ⚠️ 只能**建完后**往已有 session 邀请，不在新建表单里 |
| 列出可装 socialware | **无**（DefinitionRegistry 无 list/all） | ❌ 勾选框/目录的数据源缺 |
| socialware 勾选表单 UI | **无** | ❌ 从零 |
| app center / 目录 | **无**（最接近=挑模板名 + public_view 种子页） | ❌ 从零 |
| 发布 socialware | CR-governance `stage→preview→publish_cr`(#1042) 原语在 | ⚠️ 无单一"发布 app"动作 |
| 导游/客服 concierge | #1134 做成 hello 插件专用 `HelloConcierge` | ⚠️ 未走通用 `Definition.agents` |

**一句话**：Allen 画的"新建 session 页(name + 勾选 socialware + 邀请)"**基本从零**；且它**内嵌了 app-center**（浏览可装的 app）——后端数据源两用。

---

## 2. Phase 0 — 官网上线关键路径：新建-session 页面端到端

> 目标 = 把收编后的模型变成用户能摸到的东西。本周硬目标，不被基座阻塞。

- **P0-1 后端：列 socialware（app 目录数据源）** — `DefinitionRegistry.list(workspace)` → 该 workspace 下 `socialware:*`（+ public 可见的），返回 `[{name, title, summary, public?}]`。app-center 与新建页共用此源。
  *落点*：`socialware/definition_registry.ex`（加 `list/1`）。*性质*：domain。
- **P0-2 后端：create_session 接收显式 socialware 列表 + 成员** — 现在只吃 `template_name`；扩成也能吃 `installs: [socialware_name]` + `members: [uri]`（ad-hoc 一次性组装，等价于"临时 SessionTemplate"）。保留 template_name 向后兼容。
  *落点*：`session_creator.ex:125 create_session/3` opts。*性质*：domain（core-adjacent，走 dispatch+CapBAC）。
- **P0-3 前端：新建-session 表单** — name 输入 + socialware **勾选框**（数据来自 P0-1）+ 邀请 user/agent（复用 #76 的 invite 组件，前移到建之前）+ 建立按钮 → 调 P0-2。
  *落点*：`ezagent_plugin_world/assets/src/`（新组件）+ `world_live.ex` 事件。*性质*：世界 UI。
- **P0-4 验证（DoD）** — 官网/世界里真的：填名 → 勾 2 个 socialware(如 kanban+autoservice) → 邀请 1 个 agent → 建 → 进 session → **两个 socialware 的 agents 物化、views 渲染**。agent-browser 截图 + LiveViewTest。

**依赖**：P0-1 → P0-3(数据源)；P0-2 ‖ P0-1；P0-3 → P0-4。可两人并行（后端 P0-1/2 一人，前端 P0-3 一人，插 mock 契约）。

---

## 3. Phase 1 — 官网之后：基座瘦身（#1125 步骤，按澄清模型大幅缩水）

> 因为 app=socialware 已有寻址(`socialware:<name>`)、已有发布(CR-governance)、Definition 已胖化(T2)，
> #1125 里「新建 app package 顶层概念 / config://app / 泛化 installs 到新概念」**大部分不需要了**。剩下真基座：

- **P1-1 conformance gate** — `mix ezagent.socialware.check` 已在(T2)；扩成校验"一个 socialware 声明合规 + 能装能跑能发布"，拿 kanban + 官网当两个 conformance example。
- **P1-2 统一"发布 socialware"动作** — 现在是 CR-governance 原语 + public_view 拼；收成一个"发布"动作(写公开门控 + 登记目录可见)。
- **P1-3 socialware 编辑/上传 UX** — 运行时创作/编辑一个 socialware Definition（表单 → ConfigObject → CR 发布 → 出现在目录）。这才是"上传一个 app"的真形态（不是 plugin manifest.json）。
- **P1-4 app-center 独立页**（可选）— 复用 P0-1 数据源，做一个可浏览/搜索的 socialware 目录页。

---

## 4. 导游/客服 concierge（Handoff A 的落地方向）

- **收敛到通用 `Definition.agents`**：导游/客服 = 两个 socialware/recipe（`guide` / `support`），随会话勾选或默认装入 → `materialize_definition_agents`（T2 已有）。
- **#1134 的 `HelloConcierge`**：待 Allen 定 —— 重构上 `Definition.agents`(推荐，符合"不特殊处理") / 保留共存 / 删。
- **客服触发语义**（唯一新点）：永远转发 vs 超时兜底 vs 显式升级 —— 待定（Handoff A §讨论点 3）。
- 归 **ruihua**（设计，Handoff A）先把机制说清楚，再落 build。

---

## 5. Ledger 收编 + owners（建议）

- **GLOSSARY**（Allen 落笔）：记 §0 的三层模型 + "config:// 已废、socialware: 是目录键非路由 URI、app=socialware、#1126 澄清"。
- **#1126 doc**：加"已被 #1136 收编 / 判为混淆"的顶部 banner（不改历史正文）。
- **owners 建议**：P0-1/2 后端 = gaga 或 fatnine；P0-3 前端 = zhaomato/zyli；P0-4 验证 = 同 P0-3 持有者；导游/客服设计 = ruihua；基座 Phase 1 = 官网后再排。

---

## 待 Allen grill 的点
1. Phase 0 的 4 块拆 PR / 派谁 / 并行契约 —— 认不认这个切法?
2. `create_session` 加 `installs`+`members`(P0-2) vs "临时生成一个 SessionTemplate 再建" —— 哪个?（我倾向前者，轻）
3. app-center：本周就要独立页(P1-4 提前)，还是先只做"内嵌进新建页的勾选"?
4. `socialware:` 保持目录键(我的推荐) —— 认可否?
5. #1134 HelloConcierge 去留。
