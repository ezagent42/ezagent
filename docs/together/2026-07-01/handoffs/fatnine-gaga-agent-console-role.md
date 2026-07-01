# Handoff → FatNine（戴明）& gaga（黄佳佳） · Agent Console 上线 + 向「创建岗位」迁移

> **From:** ruihua（designer） · **Date:** 2026-07-01
> **Ladder:** lead 2026-07-01「产品形态收口」问③——Agent Console 今天上线 + 后面向「创建岗位」迁移，入口在哪
> **权威文档:** `docs/together/2026-07-01/design-ui-convergence.md` §5.3

## 先读文档这几段
1. **§1④ Agent Console** —— 定义：world 内的一个 surface（`world_live.ex` 路由 clause），不是独立 app。
2. **§5.3（重点，全读）** —— 今天上线 / 「配置 agent」→「创建岗位」两层拆分 / 入口决定 / preset / 讨论待办。
3. **§2 共通** —— 品牌 token 唯一源 `ezagent-design-system` rev `ebce041`。

## 已定的方向（ruihua 拍板，供你们落技术）
- **今天上线**：当前 Agent Console（Agents tab + New Agent 表单）作为"靠后的配置/operator 面"**按现状上线，不为岗位改造挡上线**。
- **入口 = A**：把「创建岗位/招一个 agent」**并入 org 的「邀请成员」**——邀请成员时可选"人 或 agent 岗位"，并列。复用 hello-ui 已有的 MEMBERS+Invite（人/agent 混排），贴 world→IM 的"往频道邀成员"。**Agent Console（raw config）降为岗位详情里的"高级设置"。**
- **preset 岗位 = GTM 工程 / 客服 / 研发助手**（研发助手贴 cc/codex flavor、客服贴 socialware autoservice）。

## 你们要做什么

### 今天（P0）
- **FatNine + gaga:** 确认 Agent Console 就绪、按现状上线，不被岗位改造阻塞。

### 后面改造（P1，落技术）
- **gaga（后端契约）:** 复用既有 **`Ezagent.Role`**（`skills`/`plugins`/`prompt`/`behaviors`/`requested_caps`）+ `AgentTemplate.desired_skills/desired_caps`，把 raw config（flavor/cwd/model/tools/caps）收成一个"岗位 preset"。给 GTM 工程/客服/研发助手 三个 preset 定默认值。运行时可编辑吗？
  - 参考：`docs/together/2026-06-25/analysis/agent-console-gap-analysis.md` §5-6（domain 有 Role，缺 operator 可视化管理面 = 要补的）。
- **FatNine（UI）:** ① 把「邀请成员」扩成含 agent 岗位（入口 A）；② 现有技术表单（`27-agent-new.png` 那套）降为岗位详情里的"高级配置"；③ 岗位层做"招一个"流程。分几步落你定。
- 品牌：壳/表单扣上游 design-system token。

## 请回给我什么
- 岗位层技术可行性（`Ezagent.Role`/`AgentTemplate` 能不能承这个 preset 抽象）+ UI 迁移分步计划。
- 三个 preset 岗位的默认 skills/prompt/caps 值。
- 有拿不准的入口/流程随时喊我出设计。

## 关联
- 当前 Agent Console 截图 `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/`（26-agents / 27-agent-new）
- CRUD 证据 `docs/together/2026-06-24/evidence/agent-console-crud/`
- gap-analysis `docs/together/2026-06-25/analysis/agent-console-gap-analysis.md`
