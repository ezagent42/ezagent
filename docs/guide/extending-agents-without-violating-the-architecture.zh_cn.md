# 扩展 agent 时不违反架构（中文摘要）

> 本指南已并入 `ezagent-developer` skill——**那里是权威出处**（每个加载该 skill 的 dev
> 都会内联看到）。本文件是面向中文读者的简明摘要 + 指针，不维护完整平行副本，以免出现
> 第二个 source of truth。完整内容与代码引用见 skill。

新增 agent 类型，或新增 render / feed / transport 能力时，请读：

- **`.claude/skills/ezagent-developer/SKILL.md`** §"Extending agents without
  violating the architecture"——动手前清单（4 个 STOP 检查）+ 两条原则（内联）。
- **`.claude/skills/ezagent-developer/references/extending-agents.md`**——两个走通的
  案例（`Entity.Salesperson` → role × flavor；render-card → 机制 vs 生产者拆分）+
  具体抓手（要加载哪些 docs/skill、SPEC → codex 对抗评审 → 实现 评审闸）。
- `.claude/skills/ezagent-developer/references/anti-patterns.md` 里的两条对应"拒绝"条目。

## 两条红线（各一句）

1. **新 agent 类型 = `role × flavor`**：挂在统一的 `Ezagent.Entity.Agent` 上，经
   `roles/0` 注册一个 recipe（role-foundation #54）——**绝不为它新建 `Entity.*` Kind**
   （P4b 已废弃 own-Kind-per-type：`Entity.PyAgent` → 统一 `Entity.Agent`）。正解先例：
   kanban-as-role（`kanban-manager` recipe 挂 `native` flavor）。新建 Kind 只在出现真正
   全新的*非 agent* 原语时才成立（P9/P10 + lead 签字），绝不为承载一个人设而建。
2. **平台机制必须与业务逻辑可分离**：通用 render/feed/transport 与生产者无关；业务 agent
   *消费*它，而不是把它焊进自己、藏在以人设命名的 cap 之后（参见 #1035：render-card 以
   transport-only 合入，`feed_encoding.ex` 对每条消息读 `body["render"]`，无 `:salesperson`
   cap）。

## 动手前清单（写代码 BEFORE）

| 检查 | 若"是"→ |
| --- | --- |
| 1. 在为某 agent 类型新建 `Ezagent.Entity.*` Kind？ | **STOP。** 是 role × flavor，不是新 Kind。 |
| 2. 把业务逻辑塞进平台路径（通用机制被某业务人设/cap 网关）？ | **STOP。** 把机制和生产者分开。 |
| 3. 该能力是否已有通用机制？`git grep -n "render\|feed_encoding\|RoleRegistry\|agent_flavors" -- apps/` | 有 → 复用，别另起平行实现（台账 P2）。 |
| 4. 让 plugin 作者多学一个概念还是少学一个？（P8） | 多一个 → 否决。新 Kind = 多一个。 |

相关红线：`docs/together/contributing/README.md` 台账 P0–P3。
