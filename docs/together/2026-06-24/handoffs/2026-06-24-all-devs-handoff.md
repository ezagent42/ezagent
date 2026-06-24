# 2026-06-24 团队 handoff（全员·可转发）

> 周目标：① ezagent 团队内跑起来 ② 建官网。本周所有 track 在**各自主机**上跑（disposable stack 停用），看别人的运行成果走**内网 tailnet 地址**。
> 每条 track 末尾有「讨论项」标注需参与的人。完成后晚上 close 前各自 merge ≥1 次。

---

## @李震宇（zyli）— 人肉跑通全流程（goal ①，本周度量）

**任务**：在你自己主机上，端到端人肉走一遍 ezagent 全流程（注册→登录→建 workspace/agent→绑 Feishu→@提及→各 flavor agent 回复→多 agent 接力→world 页面渲染），每步留证据（截图/日志行）到 `docs/together/2026-06-24/evidence/`。**第一件事**：复现你 06-23 根因的 `create_session` 快照竞争（#912 解耦已合，确认还崩不崩）。
**DoD（可演示）**：每条腿一张证据；跑出的每个 blocker 开一个 `fix/<症状>` 分支并路由给对应的人。
**必读**：你自己的 `2026-06-23/returns/world-deploy-e2e-pg.md` §7 + `docs/guide/world-e2e-seed.md`。
**讨论项**：**@林懿伦 @李震宇**——快照竞争今天还复不复现？复现则 @林懿伦 修（见他的 core handoff）；你只验证+路由，别自己改 core。

## @黄佳佳（gaga）— 上午 cc-headless 真实现 → 下午 agent-config 后端（goal ①）

**任务 1（上午）**：把 `cc-headless` 从 spawn-stub 做成**真**的无 PTY Claude agent。3B（`server:esr-bridge` 无 PTY）已验证不可行 → 按 handoff 实施 **3A**。
**任务 2（下午，与 fatnine 并行）**：`feat/agent-config-backend` —— agent 配置**后端完整性**：确保完整 config cascade 可读 + 每个 config key 都能经 `apply_config_delta` 写 + console 需要的后端函数齐全 + **后端测试逐个证明每项配置功能在 domain 层真能用**（不碰 UI）。这是 fatnine 前端 #84 能调的契约。
**分支**：`feat/cc-headless-real`、`feat/agent-config-backend`。
**DoD**：cc-headless 能真正 spawn + 会话往返；agent-config 后端每项 CRUD 有断言测试，与 fatnine 对齐接口契约。
**必读**：`2026-06-23/handoffs/cc-headless-real-implementation.md`（§3A）+ `2026-06-24/handoffs/agent-console-crud-handoff.draft.md`（看 fatnine 那边需要哪些后端）。
**讨论项**：**@黄佳佳 @戴明**——下午开工前对齐 agent-config 后端↔前端接口契约（避免前端做完后端对不上）。

## @张宁（zhaomato）— 官网（goal ②）

**任务**：建 ezagent 官网，复用 hello 已在用的真 `@json-render` 渲染底座（`@json-render/core`+`react` 0.19.0 + `catalog.ts`/`registry.tsx`）。
**分支**：`feat/official-site`。
**DoD**：官网首屏可访问（tailnet 地址给团队看）；内容/栏目按下面讨论定。
**必读**：`apps/ezagent_plugin_hello/assets`（json-render 用法）+ #65（CF Workers 部署）。
**讨论项**：**@林懿伦 @张宁**——官网范围需你拍：内容/栏目、托管（用 #65 的 CF Workers？）、公开路由。你刚接，先定范围才好起步。

## @戴明（fatnine）— #84 Agent Console CRUD（goal ①）

**任务**：world 里 agent 的 增/查/改/删 前端。**改 = 全量 config cascade 编辑**（经 `apply_config_delta`，先全量再按 UX 删）；**删 = manage-cap + 确认弹窗 + 绑定 live session 时禁删**；创建字段保持只读；live-status（Phase/Flavor/Bridge unknown）本任务内修。建立在 #905 之上。
**分支**：`feat/agent-console-crud`。
**DoD（反 demo，钉在后端状态）**：建→reload 后在 agents_table + KindRegistry 查得到；改→reload 后值仍在 + ConfigStore 读得到；删→列表消失**且** KindRegistry.lookup not-found（光列表消失不算）；每个 verb 带失败路径证据（cap 拒绝等）。
**必读**：`2026-06-24/handoffs/agent-console-crud-handoff.draft.md`（READY，含全部锁定决策）+ #905。
**讨论项**：**@戴明 @黄佳佳**——见 gaga 那条，接口契约对齐。

## @林懿伦（Allen）— 两个 core bug（goal ①）

**任务**：(A) session 创建快照竞争（→ :no_such_actor）；(B) resolver Registry 单独重启丢插件 resource type。
**详见**：`2026-06-24/handoffs/core-session-create-and-resolver-restart-handoff.md`（完整方案 + 讨论项已在其中）。

---

## 今日早会必拍板（@林懿伦）
1. **session-create 快照竞争今天还复不复现 / 谁修**（@李震宇 验证 → 你修）——决定 goal① 能不能推进，优先级最高。
2. **官网范围**（@张宁 需要）——内容/栏目/托管/路由。
3. （次要）Bug B 优先级、stale 分支清理提醒。
