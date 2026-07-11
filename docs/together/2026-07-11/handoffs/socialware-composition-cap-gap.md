# Handoff → Allen：socialware 缺一条"组合关系 → 成员级窄 cap"的通用授权车道（★core gap★）

> **提出人**：jjkysy（开发 dealscout 改版时撞出）· **日期**：2026-07-11 · **类型**：架构缺口 + 方案 proposal，需你拍板
> **一句话**：授权模型没错，但平台缺一条"把 socialware 声明的成员组合关系，自动变成一把精确指向目标成员的窄钥匙"的正规车道；现在 kanban / autoservice / hello 全靠 admin 万能钥匙或手写脚本兜底，dealscout 直接撞死。代码库自己把它标成 `★core gap★`，seam 都留好了，就是没人接线。

---

## 一、为什么提这个（怎么撞出来的）

在做 dealscout 改版时，我要让它的 cc 操作员（dealscout-assistant）触发爬取/入库，一直被 CapBAC 拒。排查根因时顺手把系统上所有 socialware（kanban / autoservice / orchestrator / hello）"一个 agent 怎么驱动另一个 agent 的动作"全查了一遍，发现一个共同的东西：

**没有任何一个 socialware 用"正规的窄授权"跨 agent dispatch。四个能跑通的，全是兜底：**

| socialware | 现状怎么跑通的 | 是不是正路 |
|---|---|---|
| **kanban**（assistant → board） | docstring 说该由 `EzagentPluginKanban.PmCoordinatorSeed` 发一把 board-scoped 窄钥匙——**但这个 seed 文件在 origin/main 根本不存在**（`git ls-tree` 查无）。实际 e2e 是拿 admin/owner 的万能钥匙代跑 | ❌ 兜底 |
| **autoservice**（编排器 → kb agent） | 一段**手写安装脚本** `scripts/autoservice_tier1_seed.exs` 里显式 grant `kb.query` cap（脚本注释:21 "holds the `kb.query` cap"） | ❌ 兜底（boundary 文档点名的坏味道） |
| **hello**（front-desk → builder/sharer/publisher） | front-desk 用 `admin_genesis_cap()`（五轴通配万能钥匙）跨 agent dispatch | ❌ 兜底（特权中继） |
| **orchestrator**（→ 会话成员） | materialize 时一个**硬编码只认 orchestrator recipe** 的 hook 发 `{:within_session}` 委派 cap | ⚠ 半正路（但只给 orchestrator 开，普通 socialware 够不着；且是 session-kind，不覆盖 agent↔agent） |
| **dealscout**（我做的） | 照抄 kanban 形态，撞死（详见依据三） | ❌ 撞墙 |

---

## 二、依据（代码实证，都带 file:line）

**1. 授权是唯一的操作 chokepoint，检查的是发起者、且钥匙必须精确指向目标实例**
- dispatch step 5.5（`apps/ezagent_core/lib/ezagent/kind/runtime.ex:344-441`）是唯一的 Behavior×Entity 授权点（`cap_check_only_at_chokepoint_test.exs` 强制）。它算出的 needed cap 把声明的 `:any` **替换成目标 URI 的真实 instance**（`resolve_required_cap`，`URI.instance(target)`）。
- 匹配是**精确字符串相等**（`match.ex` `instance_match?`）——**一把"指向自己"的钥匙，结构上就开不了"别的 agent"的锁**。
- 这是刻意的：防越权 / confused-deputy——"能构造出另一个 agent 的 URI ≠ 能操作它"。

**2. 所有生产 recipe 钥匙默认都只指向"自己"**
- `GrantRecipeCaps.grant_recipe_caps/4`（`apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex:217`）：`scope_uri = Map.get(instance_overrides, behavior, agent_uri)`——默认 `agent_uri`（自己）。
- 唯一的生产调用者是 socialware 物化 `definition_agents.ex`（`grant_recipe_caps(...)` **不传第 4 参**）→ 全部 self-scope。

**3. 代码库自己承认这是 ★core gap★，还留好了 seam——但没人接线**
- 同文件 docstring（:118-134）**原文**：
  > "some recipe caps must authorize a dispatch to a DIFFERENT instance: **pm-coordinator's kanban caps gate the BOARD agent**, not pm itself, so a self-scoped cap is denied at the dispatch chokepoint (**act3 ★core gap★**)."
- 它给了 seam：第 4 参 `instance_overrides`（`%{behavior => target_uri}`）能把某个 behavior 的钥匙 scope 到目标实例，**且明确说这是 least-priv 窄钥匙、不放松任何 no_wildcard/no_unowned 不变量**。
- **但**：docstring 承诺该由 `PmCoordinatorSeed` + `definition_agents` 传这个 map——`PmCoordinatorSeed` **文件不存在**，`definition_agents` **传的是空 map**。`git grep` 全树，唯一传非空 overrides 的地方是一个**测试**。**seam 现成，零生产 caller。**

**4. dealscout 撞得比 kanban 还死**
- kanban 的 board 是 agent，overrides seam（`kind=:agent` 具体实例）勉强对症。dealscout 的 `crawl_now` 宿主是 **session**（needed `kind=:session`），而 assistant 的 self-scope cap 是 `kind=:agent`——**kind 轴 + instance 轴双不匹配**，连 overrides 都救不了（它只发 `kind=:agent` 的钥匙）。

**5. 这条缺口正是 Decision #154 想收敛的方向**
- Decision #154（GLOSSARY:165）Allen 原话："自动派发的权限由一条 **RULE** 驱动，**配置该 rule 的实体就是该权限的 granter**；极限情形 granter 是 `entity://system/user/admin`。抽象 `system://…` principal 拿来当 granter 违反本原则。"
- #153 manager-delegated grant 就是它的落地机制（把 orchestrator caps 从抽象 principal 代发，换成 session owner 亲自 delegate）。
- boundary 文档（`docs/together/contributing/socialware-data-deployment-boundary.md:48-49`）明文："或 hand-write working-copy bindings **is treated as evidence that a supported install/runtime path is missing**。"——autoservice 那段手写 grant 正是这个证据。

---

## 三、结论

1. **dispatch 授权本身是对的、必需的护栏，不该轻量化。** "能寻址（路由层 P14 + 6 个 URI scheme）"和"能操作（授权层 target-scoped cap）"是刻意分开的两件事。轻量化会同时拆掉 workspace 隔离、confused-deputy 防护、Decision #154 的可问责性——代价远大于收益。正交 + 组合的哲学**不跟授权冲突**：组合恰恰需要这道护栏，否则装进来的任意 socialware 就能越权操作别人的 agent。

2. **真正缺的是一条"把 socialware 声明的组合关系 → 自动 mint 一把精确指向目标成员的窄 cap"的通用 materialize 车道。** 引擎 seam（`instance_overrides` / scope-tuple）**已经现成**，Decision #154/#153 也**已经指明** granter 该是谁——就差 socialware 物化路去驱动它 + 一个"组合关系怎么在 Definition 里声明成可 mint 的 cap"的映射规则。

3. **这不是 dealscout 一家的事，是平台三个已落地 socialware 的共同兜底缺口。** 而且 **kanban 的 assistant → board 是绕不开、必须靠这条正路的**——因为 board 是 passive 无脑数据宿主，收不了聊天没法"自己执行"，assistant 只能 dispatch 动作到它、就必须持一把指向它的窄钥匙。（autoservice → kb 同理。dealscout 短期能用"角色自执行 + routing"绕开，但那是因为 dealscout 的页面腿有 handler 能自执行。）

---

## 四、方案

**核心**：给 socialware materialize 加一条正规车道——按 Definition 里声明的成员组合关系，经已有的 `instance_overrides` seam，为需要跨成员操作的角色 mint 精确的 target-scoped 窄 cap，granter 记为**配置这条组合关系的 owner**（安装该 socialware 的用户 / session owner），满足 Decision #154、承 #153。

**要定的三件事（这是拍板项）**：

1. **组合关系怎么在 Definition 里声明？** 候选：复用 legend 的 `member_set` / `bound_rule_set`（已有结构），或加一个显式的"角色 A 可对角色 B 执行动作 X"声明。materialize 时把角色名解析成实例 URI，喂给 `instance_overrides`。
2. **granter 是谁？** 按 #154，应是"配置这条 rule 的 owner"——即安装 socialware 的用户。materialize 路径要能拿到并记录这个 granter（不能再用抽象 `system://` principal）。
3. **kind 轴怎么办？** kanban（board=agent）用现有 `kind=:agent` overrides 就够；但 dealscout 那种"动作宿主在 session"的情况，需要 seam 也支持 `kind=:session` 的 scope（或者把数据宿主一律做成独立 agent，避开 session-host 动作——这也是一个设计取舍，见下）。

**落地后的收益（一次修，三方受益）**：
- **kanban**：assistant → board 从"admin 代跑 / 承诺却不存在的 PmCoordinatorSeed"换成正规窄 cap——这是它**唯一**的正路。
- **autoservice**：删掉手写脚本 grant，编排器 → kb 走正规窄 cap。
- **dealscout**：若把线索数据做成独立宿主 agent（data-as-a-role 模范，像 board/kb），也走这条；若走"角色自执行 + routing"（车道①，短期方案），则不依赖它。
- **通用**：任何未来"socialware 里成员 A 操作成员 B"的组合，都有正规路，不再靠 admin 通配 / 脚本兜底——正是 Decision #154 的收敛目标。

**不做什么**：不轻量化 dispatch 授权（护栏必要）；不推广 admin_genesis 通配（那是反方向）；dealscout 短期先用车道①绕开，不等这条落地。

---

## 五、需要你（Allen）拍板

1. 认不认这个缺口值得填正规车道（vs 继续容忍 admin/脚本兜底）？
2. 若认，组合关系在 Definition 里怎么声明（复用 legend / 新声明）、granter 怎么取（#154）、kind 轴要不要扩到 session——这三点定了，实现就是接线 `instance_overrides` seam。
3. 这是不是也顺带把 kanban 的 assistant → board 从兜底扶正的正路（我的判断：是，而且是它唯一的正路）。

（附：完整四条授权车道对比 + 逐 socialware 实证，可展开；本 handoff 只放结论级证据。dealscout 短期走车道①的方案已另行记录，不阻塞本 proposal。）
