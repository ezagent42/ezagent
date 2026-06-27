# contributing — 开发原则 & 暴露问题台账

> **每次 handoff 前必读**（lead 下发任务前 / dev 返回 PR 前）。这里记录开发中
> 暴露的**原则违反、深层问题、过程摩擦**——目的是让同类坑只踩一次。每个 dev/agent
> 在 handoff 前对照本台账自检，返还时附 `contributing_read_through` 确认。

新增条目格式：`### <日期> · <一句话标题>` + **现象 / 根因 / 原则 / 适用范围**。

---

## 核心原则（违反过、已成红线）

### P0 · 涉及 core 的开发：先与 lead programmer 确认设计，再检查实现条件 ★最根本
**现象**：kanban 首版直接动手实现 board，没先对齐设计、也没检查设计的实现前提。**根因**：跳过了"设计对齐 + 前提检查"这一步。**原则**：任何**触及 core** 的开发，动手前必须 ——
1. **先与 lead programmer 确认设计思路**（不是自己定方向就实现）；
2. **再检查该设计的实现条件**：它依赖的地基/契约是否已存在？不存在就先补地基，别在功能里硬凑。

kanban 暴露的具体症状（resource 当 GenServer、role-foundation 未建、agent 定义不清，见 P1–P3）**都是跳过 P0 的后果**——若先对齐设计+查前提，这些会在动手前就被发现。**适用**：所有 core-touching 任务（新 Kind/Behavior/资源模型/agent 类型/路由/lifecycle…）。

### P1 · resource 必须是可读写的静态文件（P0 的一个设计事实）
`resource://` 只能是可被读写的**静态文件**；有状态、需读写协调的东西是 **agent/actor**（entity://），不是 resource。已有 `resource_kind_as_genserver` arch gate（cap 0）锁死回归。

### P2 · 地基/契约先行（P0 的"检查实现条件"）
动手前确认依赖的地基/契约已存在或同 PR 建好；缺地基就先建（spec+评审+plan）。RF-1..9 走 spec→2 轮评审→plan→实现后几乎零返工，即此原则的正例。

### P3 · agent = 角色×风味（P0 的一个设计事实）
agent = **角色（role，决定内容）× 风味（flavor，决定形式）**，行为 per-instance 加载，状态归 behavior 的 slice（本周期 role-foundation 已落地）。新建/改造 agent 按此模型。

> 展开版操作指南（动手前清单 + 两个案例 + "机制 ≠ 业务"原则）已并入
> **`ezagent-developer` skill**（权威出处）：`.claude/skills/ezagent-developer/SKILL.md`
> §"Extending agents without violating the architecture" +
> `references/extending-agents.md`。中文摘要：
> `docs/guide/extending-agents-without-violating-the-architecture.zh_cn.md`。

## 过程红线

### P4 · 评审/分析的基准 = origin/main
**现象**：一次对抗评审误读了落后 19 commit 的工作树，得出"地基未建"的错误结论。**原则**：派评审/分析一律 worktree-on-`origin/main` 或 `git show origin/main:<path>`，**禁读未 pull 的工作树**。**适用**：所有对抗评审、现状分析、"X 是否已存在"判断。

### P5 · flake 不得长期靠 admin-merge 绕过
**现象**：PluginIsolation/AnonUserGC flake 反复偶发红，多个干净 PR 被 admin-merge 绕过 CI 闸。**原则**：admin-merge 仅用于"已本地验证干净 + 红仅为已知无关 flake"的临时兜底，且**必须立项根治**（#108）；不得让 flake 成为常态绕过。**适用**：任何反复出现的 CI flake。
