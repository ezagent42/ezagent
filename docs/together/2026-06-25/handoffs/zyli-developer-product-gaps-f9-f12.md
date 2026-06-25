# Handoff — 产品日用缺口 F9/F12 + e2e 场景文档（zyli-developer / 李震宇）

> **任务**: ①实现人肉验证暴露的两个 Feishu 日用入口缺口（F9/F12）②把人肉测试过程沉淀为 agent 可自动执行的 e2e 场景文档。
> **分支**: `feat/product-gaps-f9-f12`（F9/F12）+ `docs/e2e-scenarios`（e2e 文档，可拆两个 PR）
> **本周目标**: 团队日用（目标①）。

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

## 注意（F9/F12）
- 触及 world UI 与 `gagameow`(console)/`zhaomaota97`(hello) 协调声明面。
- 先确认 F9/F12 的需求边界（绑定的粒度、@ 的语法）—— 不确定就先 clarify 再做（discuss-first）。

---

## 任务 ②：e2e 场景文档（@林懿伦 2026-06-25 新增）

**目标**：把人肉测试过程沉淀成一个 **agent 能直接读取、用 agent-browser 自动推进**的 e2e 测试资料夹 `docs/e2e/`，以后跑流程测试不用人肉。

**要做什么**：
1. **`docs/e2e/scenario-<no>.md`**：把你 2026-06-24 的人肉全流程拆成编号场景（至少第一个 `scenario-1.md`）。每个场景写成 **agent 可机读的步骤脚本**：前置/seed、逐步操作（每步：在哪个 URL、点/填什么、期望看到什么断言）、所需凭据来源、清理。语言要让一个 agent 拿 agent-browser 就能照着自动跑。
2. **`docs/e2e/guide.md`**：怎么用这个资料夹 —— agent 如何选场景、起 stack/seed、用 agent-browser 逐步执行、判定通过/失败、产出 evidence。
3. **evidence example**：放一份示例 evidence（截图 + 一个 `scenario-1` 跑通的 evidence 目录结构样例），让后来者知道"证据长什么样"。

**DoD（四性质）**：
- [ ] `docs/e2e/` 有 `guide.md` + ≥1 个 `scenario-<no>.md` + 一份 evidence example。
- [ ] **可机读验证**：场景文件足够具体到"一个不熟悉的 agent 拿 agent-browser 能照着把 scenario-1 自动跑通"——最好你自己用 agent-browser 跑一遍 scenario-1 验证它可执行，并把那次的 evidence 作为 example。
- [ ] 与现有 `docs/guide/world-e2e-seed.md` 不重复、相互引用（seed 复用那份）。
- [ ] CI 绿（纯 docs）+ rebase。

**关键文件**：新建 `docs/e2e/{guide.md, scenario-1.md, evidence/...}`；参考 `docs/guide/world-e2e-seed.md` + 你 2026-06-24 的人肉 return/evidence；skill `agent-browser`。

**注意**：这是把"人肉"变"agent 自动化"的资料底座，重点是**场景文件的机器可执行性**（步骤够具体、断言明确），不是写给人看的散文。
