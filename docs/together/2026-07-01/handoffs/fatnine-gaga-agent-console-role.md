# Handoff → FatNine（戴明）& gaga（黄佳佳） · Agent Console 上线 + 向「创建岗位」迁移

> **From:** ruihua（designer） · **Date:** 2026-07-01
> **Ladder:** lead 2026-07-01「产品形态收口」问③——Agent Console 今天上线 + 后面向「创建岗位」迁移，入口在哪
> **权威文档:** `docs/together/2026-07-01/design-ui-convergence.md` §5.3

## 先读文档这几段
1. **§1④ Agent Console** —— 定义：world 内的一个 surface（`world_live.ex` 路由 clause），不是独立 app。
2. **§5.3（重点，全读）** —— 今天上线 / 「配置 agent」→「创建岗位」两层拆分 / 入口决定 / preset / 讨论待办。
3. **§2 共通** —— 品牌 token 唯一源 `ezagent-design-system` rev `ebce041`。

## 已定的方向（ruihua 拍板，供你们落技术）

**核心：不是"配置 agent"，是"招一个人"。** 端用户描述想要的角色 → 系统给一张**候选人 profile 卡**（人名/头衔/"我能帮你做什么"/技能）→ Onboard；flavor/model/caps 全不露，藏「高级配置」。

- **今天上线**：当前 Agent Console（Agents tab + New Agent 表单）作为"靠后的配置/operator 面"**按现状上线，不为招聘改造挡上线**。
- **🎬 交互 demo（照它做）:** `docs/website-demo/agent-hire-demo/index.html`（真 world 壳 + 候选人 profile 卡 + 场景播放）。
- **✅ 推荐路径（先实现这一条）= 花名册空位 + 流程B：**
  - 入口 = 成员区一个**主色蓝、醒目**的「招聘新 agent」空位；**邀请人（Invite）另存成员区头部**，人/agent 分清。
  - 流程 = **发职位（标题+brief）→ 2 位候选人应聘 → 对比 profile → 录用**（LinkedIn 式）。
  - Agent Console（raw config）降为岗位详情里的「高级配置」。
- **备选（demo 里已各出一版，若推荐路径不合适再选）:**
  - 备选① **和 Invite 按钮结合**：一个「邀请成员」入口并列"邀请人 / 招 agent"。
  - 备选② **对话召唤**：会话里说「@hire 我需要一个…的人」，候选人卡出现在对话流。
- **preset / 热门角色 = GTM 工程 / 客服 / 研发助手**（描述框下的 chips，灵感非门槛；研发助手贴 cc/codex、客服贴 socialware autoservice）。

## 你们要做什么

### 今天（P0）
- **FatNine + gaga:** 确认 Agent Console 就绪、按现状上线，不被岗位改造阻塞。

### 后面改造（P1，落技术）
- **gaga（后端契约）:** 复用既有 **`Ezagent.Role`**（`skills`/`plugins`/`prompt`/`behaviors`/`requested_caps`）+ `AgentTemplate.desired_skills/desired_caps`，把 raw config（flavor/cwd/model/tools/caps）收成一个"岗位 preset"。给 GTM 工程/客服/研发助手 三个 preset 定默认值。运行时可编辑吗？
  - 参考：`docs/together/2026-06-25/analysis/agent-console-gap-analysis.md` §5-6（domain 有 Role，缺 operator 可视化管理面 = 要补的）。
- **FatNine（UI）:** 照推荐路径实现 **一条完整 prototype**（lead T4 要求：一个 path 做到可用可验证，不并行多 IA 分支）——① 成员区蓝色「招聘新 agent」空位 → ② 发职位 → ③ 候选人 profile 卡应聘 → ④ 录用入职；现有技术表单（`27-agent-new.png`）降为「高级配置」。分几步落你定。
- 品牌：壳/表单扣上游 design-system token。

## 请回给我什么
- 岗位层技术可行性（`Ezagent.Role`/`AgentTemplate` 能不能承这个 preset 抽象）+ UI 迁移分步计划。
- 三个 preset 岗位的默认 skills/prompt/caps 值。
- 有拿不准的入口/流程随时喊我出设计。

## 关联
- 当前 Agent Console 截图 `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/`（26-agents / 27-agent-new）
- CRUD 证据 `docs/together/2026-06-24/evidence/agent-console-crud/`
- gap-analysis `docs/together/2026-06-25/analysis/agent-console-gap-analysis.md`
