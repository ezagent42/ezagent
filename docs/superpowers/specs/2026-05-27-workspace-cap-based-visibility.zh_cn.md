# SPEC — 基于 cap 的 workspace 可见性，替代 `workspaces.visible` 布尔字段

**状态：** r5 — codex r4 HIGH（§11 q#6 残留 r3 风格语言）+ MED（OQ-4 模块放置）已修复。2026-05-27。

**r5 变更（codex r4 评审 verdict REJECT —— 两项发现已处理）：**
- HIGH（codex r4）：§11 问题 #6 仍带 r3 风格语言（"与 cross_workspace?/2 的权威逻辑完全一致"）以及被 r4 拒绝的 helper 名 `Capability.admin_authority?/2`，与 r4 §3.3（有意更窄）+ §10 OQ-7（两个 helper 保持独立）矛盾。**修：** §11 q#6 重写以匹配 r4 语义；两个 helper 共享**三**条 clause 但**不**共享 wildcard-cap 路径；共享 admin helper 只覆盖 admin 捷径。EN + ZH 同步。
- MED（codex r4）：r4 OQ-4 选项 (b) 把 `admin_authority?/2` 放在 `Ezagent.Behavior.Identity`，但四个 admin 谓词实际住在 `Ezagent.Behavior.IdentityAdmin` 内（728、835 行 —— `identity.ex` 在一个文件里有**两个** behavior 模块，在 305-307 行处分界）。r4 也把策略与 Behavior 动作的关注混淆了。**修：** OQ-4 选项 (b) 修订为新建**非 Behavior** 专用策略模块 `Ezagent.Identity.AdminAuthority.admin?/2`（在 `Behavior.*` 命名空间之外）。OQ-4 加入模块结构说明记录源拆分。OQ-7 + 附录 C + §3.3 "对 OQ-7 共享 helper 的含义" 都用 r5 helper 名更新。
- 附加（codex r4 NIT）：OQ-7 加入前瞻可维护性契约 —— 未来加入新 admin-cap 变体的 SPEC 必须回答"该变体是否也产生运行时跨 workspace 旁路？"是则两个 helper 都要更新；否则只更新 admin 捷径。

**r4 变更（保留）：** §3.3 "等价" 改写为 "关系 —— 有意更窄"（codex r3 HIGH 关于 wildcard cap 路径）；OQ-7 默认改为两个 helper 独立；附录 C 改写列全部 7 OQ 默认。

**r4 详细变更（codex r3 评审 verdict REJECT —— 三项发现已处理）：**
- HIGH（codex r3）：r3 §3.3 "与 `Capability.cross_workspace?/2` 等价" 声称过强。`cross_workspace?/2` 的**第一条** clause（`capability.ex:466`）匹配**任何** `%Capability{workspace_uri: :any}`，不限 `kind`/`behavior`/`action`。runtime step 5.6 路径（`runtime.ex:521,609`）与 cross-workspace 隔离 invariant fixture（`cross_workspace_isolation_test.exs:96`）正是利用这点 —— 非 admin 形状的 wildcard cap（例如 `%Capability{kind: :session, workspace_uri: :any}`）产生 per-action 运行时旁路。r3 声称这"被 (i)/(ii) 蕴含" —— **错**，因为 (i)/(ii) 要求严格 admin 形状。**修：** §3.3 "等价" 子节改写为 "**关系 —— 在 wildcard cap 路径上有意更窄**"，记录权威轴不对称：运行时旁路是 per-cap per-action，可见性是 per-caller aggregate。admin 捷径**有意**收窄 wildcard cap 路径（依 §3.3.b + OQ-5）。§3.4 也加了显式的非 admin wildcard 案例。
- MED（codex r3）：r3 OQ-4 选项 (b) 把 `admin_authority?/2` 放在 `Capability`（`ezagent_core`），但四个谓词中**两个**住在 `Identity`（`ezagent_domain_identity` —— **依赖** `ezagent_core`）。`Capability` 调 `Identity.holds_*` 是 umbrella 反向依赖，结构上拒绝。**修：** OQ-4 选项 (b) 已修订 —— helper 迁到 `Ezagent.Behavior.Identity.admin_authority?(caller_uri, caps)`（在 `ezagent_domain_identity`，两个源模块**之上**一层）。每个调用都沿 umbrella 图向下。r3 默认 (b) 已显式标注 "已拒绝 —— 层违例"。
- LOW（codex r3）：附录 C 仍写 "6 个 OQ" + 过时默认（"OQ-4：提升为公开"），尽管 r3 已有 7 OQ。**修：** 附录 C 改写，列出全部 7 OQ 的 r4 默认。EN + ZH 同步。
- OQ-7（r4）：受 HIGH 牵连一并修订 —— `cross_workspace?/2` 重构**不再**在范围内；两个 helper 保持独立，因为编码不同权威轴。

**r3 变更（保留）：** 加 (iii) `home_is_system?(caller_uri)` 为第 4 个 admin 捷径谓词（codex r2 HIGH-B1）。INV-3a + INV-3b 独立测试 (iii) 与 (i) 路径。OQ-4 扩到全部 4 个私有谓词。OQ-7 新增。

**r2 变更（保留）：** §3.3 admin 捷径加 `holds_admin_caps?/1`（r1 静态评审 CRIT-A1）。§5 加 INV-8（MED-C1 —— 代码形状元测试，对抗"把布尔以代码字面复活"的反模式）。

**层次（Tier）：** `apps/ezagent_domain_workspace/` 数据模型 + `Ezagent.Workspace` facade。需要扫除 LV (`apps/ezagent_plugin_liveview/`)、`live_auth` (`apps/ezagent_web/`)、invariant 测试、mix 任务以及 Phase 9 PR-8 SPEC §13.1/§13.2。

**触发：** Allen 2026-05-27 飞书原话 —— "cap-based 可见性：你看到的 workspace = 你 caps 里 workspace_uri 列出的 + member_of 里列出的。这样不需要 visible 字段，访问权决定可见性。"

**配套：** `2026-05-27-workspace-cap-based-visibility.md`（依 `feedback_bilingual_docs_convention`）。

**前置记忆（关键）：**
- `feedback_let_it_crash_no_workarounds` —— 不留 shim，不留 dual-path。`visible` 字段被直接 DROP COLUMN，不"先标记 deprecated 再迁移"。
- `feedback_completion_requires_invariant_test` —— PR 的合并门是一个 invariant 测试：(i) 系统 workspace 不出现在 `list_workspaces_for(无 caps 且非 system 成员)` 的返回里；(ii) 同一个 workspace 对 `workspace://system` 成员是出现的。
- `feedback_north_star_plugin_isolation` —— 插件作者调 `list_workspaces_for/2` 即可，无需知道可见性是怎么算出来的。基于 cap 的查询由 workspace domain 自己拥有，LV 插件永远不直接访问 `visible` 或 cap 逻辑。
- `feedback_destructive_migration_anti_pattern` —— `ALTER TABLE … DROP COLUMN visible` 是破坏性 migration。**本 SPEC 显式将该 migration 标记为人工执行步骤**（操作员先停 phx，跑 `mix ecto.migrate`，再重启）。子代理不自动跑。
- `feedback_subagent_must_load_project_skills` —— 实现子代理调度时必须挂上 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_review_every_pr` —— 本 SPEC 与实现 PR 的 codex 评审，都要带 "no mix" 的逐字克隆条款。

**父代 / 历史上下文：**
- `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md` §13.1 + §13.2 + §13.4 —— 引入 `visible: false` 作为将 `workspace://system` 隔出常规 workspace 选择器的机制。本 SPEC 推翻该决定。
- `apps/ezagent_core/test/invariants/workspace_sot_test.exs` + `system_workspace_membership_test.exs` —— 编码了"`list_visible/0` 是 operator 列出 workspace 的唯一权威"这套老规矩。两个 invariant 测试都需要重写 —— 见 §4.2。
- `2026-05-27-capability-action-axis.md` —— 同期 SPEC，给 capability 结构加 `:action` 轴。两者正交 —— 本 SPEC 只动 `workspace_uri` 轴。

---

## 1. 问题陈述 —— `visible: false` 为什么是错的抽象

`workspaces.visible` 布尔字段是 Phase 9 PR-8 （SPEC v3 §13.1）引入的，目的是让 `workspace://system` 不出现在非 system 成员的常规 workspace 选择器里。它在三处结构上都是错的抽象。

**(a) 过早泛化（premature generalization）。** 这个布尔字段就是为了特殊处理那一个 workspace（`workspace://system`）。代码里没有任何路径会再创造另一个 `visible: false` 行 —— `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:269-275` 是唯一的写入点（`ensure_workspace("system", %{visible: false})`）。其他每个 workspace 都按 `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:66` 的默认值是 `visible: true`。一个取值空间为 `{永远是 true, 除了这一个特殊行}` 的字段，本质不是在建模可见性 —— 是用一个糟糕的名字给系统 workspace 打了个标签。

**(b) 与 cap 不能复合。** Capability 已经携带 `workspace_uri` 轴（`apps/ezagent_core/lib/ezagent/capability.ex:21-26`）。用户能否"对" workspace 做事完全由其 caps + 成员资格决定。用户能否"看到" workspace 理应同问同答 —— 让用户看到他够不着的 workspace 是一种特权泄漏面（他知道了存在一个他进不去的 workspace），这正是 `workspace_sot_test.exs` invariant 测试要防的。布尔字段在 cap-holdings 的下游；把它当主要机制是把轴的次序倒置了。一个对 `workspace://X` 持 `Behavior.Workspace.add_member` 的用户，应当因为"有这个 cap"看到 `workspace://X` —— 而不是因为 `X.visible == true`。

**(c) 不能扩展到按租户隐藏的场景。** 如果将来要"这个 workspace 对 B、C、D 用户隐藏但对 A 可见"，布尔字段表达不了 —— `visible` 是单一全局标志。基于 cap 的模型原生支持（A 的 caps 里有 `workspace://X`；B/C/D 没有）。预期场景：按租户的 staging workspace、只对运维可见的归档 workspace、按角色门控的 workspace（例如只有 finance 看得到 `workspace://billing`）。这些都要求按用户的可见性，`workspaces.visible` 完全没法表达。

**(d) 这个布尔已经是冗余的。** 今天每条检查 `visible: false` 的代码路径，都另有一条配套的路径在检查 system 成员资格 或 admin caps。比如 `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:328-332` —— admin 流程在 `list_visible/0` 过滤掉 system 之后，又把 `workspace://system` 手工塞回选择器。布尔字段和 system 成员检查在编码同一个谓词；system 成员检查才是真正的（cap-derived），布尔是漏抽象。

要预防的 bug 类型：每一个新加的 operator 用 workspace 列表面，必须记得调 `list_visible/0` 而不是 `list_all/0` / `list_persisted/0`。PR #290 (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex` 历史) 与随后的 `workspace_sot_test.exs` invariant，正是因为这个纪律被违反过一次才存在的。把布尔字段删掉就消掉了这条纪律 —— 不再有 `list_visible/0` 让你忘记调。给每个调用方都是 `list_workspaces_for(caller_uri)`；你**结构上**不可能不小心看到隐藏 workspace，因为查询本身就以 caller 为参数。

## 2. 决定

把 `workspaces.visible` 布尔字段替换为**基于 cap 的可见性**。该字段被删除（DROP COLUMN）。不留 shim，不留 dual-path，也没有过渡期 —— 依 `feedback_let_it_crash_no_workarounds`。

唯一的 operator 用查询变为：

```elixir
Ezagent.Workspace.list_workspaces_for(caller_uri :: URI.t(), caps :: [Capability.t()] | MapSet.t())
  :: [Workspace.Store.decoded()]
```

`list_visible/0` 不再存在。`list_all/0`（admin / loader / mix 任务内部用）和 `list_persisted/0`（`list_all/0` 的别名）保留 —— 它们是**有意**不带 caller 过滤的，仅供系统内部使用（loader 重建、cross-prefix 清理 mix 任务、no-default-seeded invariant 测试）。`workspace_sot_test.exs` invariant 测试**改名 + 重写** —— 见 §4.2 —— 用来门控"operator 用面调 `list_workspaces_for/2`，永不调 `list_all/0`"。

## 3. 语义 —— `list_workspaces_for/2` 的精确定义

### 3.1 入参

- `caller_uri` —— 一个 `%URI{}` 表示调用者（通常是 `entity://user/<ws>/<name>`，但泛化接受 `%URI{scheme: "entity"}` 让 agent 调用者也能用）。
- `caps` —— 调用者已加载的 capability 集合（`MapSet.t(%Capability{})` 或 `[%Capability{}]`）。由调用方在上游加载好（例如 `live_auth.ex` 在挂载 LV 之前已经通过 `Users.decode_caps/1` 加载过）。

两个参数有意保持分离：caller URI 决定成员资格；caps 决定 cap-scope。互不包含（system 成员的 caller URI 携带不在 cap 里的权威；委托 workspace admin 的 caps 携带不在 URI 里的权威）。

### 3.2 出参

调用者可以操作的 `Workspace.Store.decoded()` 行列表。每行的结构跟今天 `list_all/0` 返回一致（`id`, `name`, `uri`, `members`, `session_templates`, `routing_rules`, `created_by`, `created_at`, `updated_at`）—— 减去 `visible` 键（已不存在）。排序：按 `name` 升序，跟今天 `list_visible/0` 一致。

### 3.3 联集定义

```
list_workspaces_for(caller_uri, caps) =
  if   holds_admin_caps?(caps)                        -- (i) bootstrap wildcard
       or  holds_cross_workspace_admin_cap?(caps)     -- (ii) 结构性 workspace-only admin
       or  home_is_system?(caller_uri)                -- (iii) caller home workspace 就是 system
       or  member_of_system?(caller_uri)              -- (iv) 显式 system 成员晋升
  then list_all()                                     -- admin 捷径
  else union(
         member_of_workspaces(caller_uri),            -- (a) 成员资格
         workspaces_for_caps(caps)                    -- (b) cap-scope
       )
```

三个贡献源：

**(a) `member_of_workspaces(caller_uri)`** —— 每个 `members` 列表里包含 `caller_uri`（字符串相等比较）的持久化 workspace。实现：扫一遍 `Workspace.Store.list_all/0` 然后过滤；故意 O(N)。N 由 operator 创建的 workspace 数封顶（今天：少数几个；增长模型：≈ 每租户一个）。若 N 增长越线，加索引 —— 本 SPEC §7 把它列为范围外。

**(b) `workspaces_for_caps(caps)`** —— 每个 `uri` 字段能匹配 `caps` 中任一 cap 的 `workspace_uri` 字段的 workspace。`workspace_uri: :any` 的 cap 对此分支**不贡献任何东西**（否则会返回所有 workspace —— 但 admin 捷径已经做了那件事，而非 admin 调用者的 `:any` 是一个结构上的 cross-workspace 标记，不是"全部 workspace"枚举）。`workspace_uri: %URI{}` 的 cap 贡献那个对应的 workspace（若 `Store.list_all/0` 里存在）。实现：收集 `cap.workspace_uri`，过滤出 `%URI{}`，到 `Store.list_all/0` 里查（或加 `Store.get_by_uri/1` —— 见 §10 OQ-3）。指向已删除 workspace 的 cap，跳过即可。

**Admin 捷径** —— **四个**谓词的并集触发即返回 ALL workspaces：

- (i) `holds_admin_caps?(caps)`（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:835-868`）—— 匹配 bootstrap 的完整 wildcard 形状 `kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any`。bootstrap admin（`entity://user/system/admin`）持的恰是这个 cap（由 `Ezagent.SystemPrincipal.caps("system://bootstrap")` 铸造）。
- (ii) `holds_cross_workspace_admin_cap?(caps)`（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:728-755`）—— 匹配更窄的"workspace-only admin"形状 `kind: :workspace, behavior: Workspace, action: :any, instance: :any, workspace_uri: :any`（通过 workspace-Behavior cap 委托的 cross-workspace admin，**不是** kind:any wildcard）。
- (iii) `home_is_system?(caller_uri)`（`apps/ezagent_core/lib/ezagent/capability.ex:480-485`）—— 匹配 **home workspace 就是 `workspace://system`** 的 caller（即 `entity://user/system/<name>`）。这是 `Capability.cross_workspace?/2`（`capability.ex:468-470`）已使用的结构性 admin 路径。admin 通过 `users_live.ex:35` "在 system workspace 创建用户" UI 创建的用户按 URI 结构就是 admin-equivalent，与显式成员资格无关。
- (iv) `member_of_system?(caller_uri)`（`apps/ezagent_core/lib/ezagent/capability.ex:493-507`）—— 匹配 URI 列在 `workspace://system` 的 `members` 里的 caller。这是"Promote to system"路径（LV `users_live.ex:232`）—— 在 `workspace://X` 创建后被晋升为 system 成员的用户，权威靠成员资格不靠 URI host。

四者互不包含：
- bootstrap admin 满足 (i) —— 在 promote-flow 之后也满足 (iii)/(iv)，但 (i) 是启动时的结构地板。
- 委托的 cross-workspace 操作者（例如未来 "tenant-admin" 角色）满足 (ii)，不满足 (i)/(iii)/(iv)。
- 直接在 `workspace://system` 创建（admin 创建，从未被 promote）的用户满足 (iii) —— 他们的 `workspace://system.members` 记录可有可无；URI host 检查是结构性的。
- 在 `workspace://team-alpha` 创建后被晋升为 system 的用户满足 (iv)；其 home **不是** system，所以 (iii) 不通过。

**与 `Capability.cross_workspace?/2` 的关系 —— 在 wildcard cap 路径上 *有意更窄*：** `cross_workspace?/2`（`capability.ex:466-470`）的第一条 clause 是 `cross_workspace?(%Capability{workspace_uri: :any}, _) → true`，匹配**任何**带 `workspace_uri: :any` 的单个 cap，不限 `kind`/`behavior`/`action`。runtime step 5.6 路径（`apps/ezagent_core/lib/ezagent/kind/runtime.ex:521,609`）与 cross-workspace 隔离 invariant fixture（`apps/ezagent_core/test/invariants/cross_workspace_isolation_test.exs:96`）恰是利用这点 —— 一个**非** admin 形状的 cap（例如 `%Capability{kind: :session, behavior: :any, workspace_uri: :any}`）就能触发运行时旁路。

**`list_workspaces_for/2` 的 admin 捷径 *不* 镜像这第一条 clause** —— 这是 §3.3.b 与 §10 OQ-5 的有意设计。一个持此类 wildcard cap 的非 admin **不应**在 operator 面看到全部 workspace；cap-scope 分支（§3.3.b）明确把 `workspace_uri: :any` 从非 admin 贡献里丢掉。admin 捷径要求 (i) 完整 bootstrap wildcard、(ii) 更窄的 `kind:workspace/behavior:Workspace/action:any` admin 形状、(iii) URI host = `system`、或 (iv) 显式 system 成员。

**权威形状不对称，是有意的：** 运行时旁路（`cross_workspace?/2`）是 per-action per-cap —— 它问"这**一个** cap，既然已经通过了 cap_for_action 过滤，是否也旁路 workspace 隔离？"。对任何 `workspace_uri: :any` 的 cap 答案是"是"，因为 dispatch chokepoint 已经授权该 action。可见性（`list_workspaces_for/2`）是 per-caller 且**聚合**所有 caps —— 它问"该 caller 应在列表里看到哪些 workspace（每个 workspace 是 UI 入口）"。一个持 session-wildcard cap 的非 admin 只应看到他能操作的 workspace，不是系统中每一个。不同抽象层 → 不同谓词形状；这是正确的，**不是**漂移。

**对 OQ-7（r3）共享 helper 的含义：** 提议的 `Ezagent.Identity.AdminAuthority.admin?(caller_uri, caps)`（r5 名 —— 见 §10 OQ-4）**不是** `cross_workspace?/2` 的替代品。两者覆盖**重叠但不同**的权威轴。OQ-7 默认（原"在范围内重构"）在 r4/r5 已修订 —— 见 §10 OQ-7。共享 helper 若抽取，只编码 admin 捷径的四谓词；`cross_workspace?/2` 的第一条 wildcard clause 保留原处。

r1 草稿漏掉 (i)：bootstrap admin 启动时 `workspace://system.members` 为空（`ensure_system_workspace/0` 种空成员），`member_of_system?/1` 返回 false；bootstrap wildcard 的 `kind: :any` 不匹配 (ii) 字面 `kind: :workspace`。两个谓词都假，bootstrap admin 落到 cap-scope 分支（丢 `workspace_uri: :any`）—— 结果 `[]`，相对今天 `list_visible/0` 是回归。r2 加 (i) 关闭此漏洞。r3 在 codex r2 评审 HIGH 之后加 (iii) —— admin 创建于 system 的用户（按 `cross_workspace?/2` 的 `home_is_system?` 路径是 admin-equivalent）也被 r2 漏掉了。

捷径在前、联集在后是有意安排：联集更贵（走两个数据源）；admin 跳过。捷径对 admin 来说功能上等价于联集（system 成员就是 `workspace://system` 成员，且持 wildcard cap，联集也会返回全部）—— 只是更便宜，**并且**它把结构意图显式化：admin 看到的是无条件的全集，不是每个 cap 算出来的派生集。

### 3.4 `workspace://system` 这个特殊行怎么办？

`workspace://system` 出现在输出里当且仅当 admin 捷径触发 —— 即**四个**谓词任一成立：(i) bootstrap-wildcard cap（kind:any/behavior:any/action:any/instance:any/workspace_uri:any）、(ii) 结构性 cross-workspace admin cap（kind:workspace/behavior:Workspace/action:any/instance:any/workspace_uri:any）、(iii) home-is-system URI（`entity://user/system/<name>`）、(iv) system 成员晋升。四个谓词都不满足的常规 `workspace://X` 成员将**不会**看到它 —— 跟今天 `list_visible/0` 的行为效果一致。区别在于：原因不再是因为那行 `visible: false`；而是因为该 caller 的 caps + URI host + 成员资格不包含 `workspace://system`。

**注（r4）：** 一个持非 admin 形状 wildcard cap 的非 admin caller（例如 `%Capability{kind: :session, workspace_uri: :any}` —— `cross_workspace_isolation_test.exs:96` 用来测运行时旁路的形状）**不**通过 (i)–(iv) 任一。cap-scope 分支（§3.3.b）把 `workspace_uri: :any` 从非 admin 贡献里丢掉。该 caller 因此**不会**看到全部 workspace —— 只看匹配成员资格或窄 caps 的。这是相对 `Capability.cross_workspace?/2` 第一条 clause 的有意收窄 —— 见 §3.3 "关系" 子节。

### 3.5 边界情况 —— `system://bootstrap` / `system://*` 调用者

非 entity 调用者（例如 `system://workspace-loader` 调 `Loader.load_all/0`）**不用** `list_workspaces_for/2`。它们直接用未过滤的 `list_all/0` —— 那是 LOADER 路径，本来就需要全集而不关心 caller 身份。`list_workspaces_for/2` 是给 operator 用面的；系统内部调用方绕开它。改名后的 `operator_facing_workspace_listing_test.exs`（见 §4.2）只门控 LV / `live_auth` / mix 任务文件；**不**门控 `Loader` 或 `Application.start/2` 回调。

### 3.6 边界情况 —— 无法从 caller URI 推出 workspace

如果 `caller_uri` 不是可解析的 3-segment entity URI，`Ezagent.URI.entity_workspace_uri/1`（`apps/ezagent_core/lib/ezagent/uri.ex:301`）会抛。`list_workspaces_for/2` **不应**在 caller 损坏时抛 —— 它对不可解析的 caller 返回 `[]`，`member_of_workspaces/1` 短路（无法建立成员资格），`workspaces_for_caps/1` 独立按 caps 跑。这是有原则的回答：不可解析的 caller 没有成员资格；他们的可见性纯由 cap 派生。让它崩会出现在 LV 挂载生命周期内 —— 那一层没有有用的恢复路径。本函数是个 READ；"你看不到 workspace"是 caller 身份损坏时的结构兜底。

（注意：上游 `live_auth.ex` 已经在 session cookie 校验时强制 3-segment URI，依 `feedback_register_lookup_key_parity`。若到达本函数的 caller 是畸形的，说明那道门失败 —— 那是独立 bug。这里返回 `[]` 是纵深防御，不是首要路径。）

## 4. 迁移方案

### 4.1 破坏性 DB migration —— 人工执行步骤

Migration 文件 `apps/ezagent_core/priv/repo/migrations/<timestamp>_drop_workspaces_visible.exs`：

```elixir
defmodule EzagentCore.Repo.Migrations.DropWorkspacesVisible do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      remove :visible, :boolean, null: false, default: true
    end
  end
end
```

**实现子代理不得运行此 migration**（依 `feedback_destructive_migration_anti_pattern`）。硬规则：子代理不能在 `phx.server` 正在使用 `workspaces` 表的情况下对 dev DB 跑 `mix ecto.migrate` —— migration 会锁住 `workspaces`，活跃的 phx 进程对该 slice 的写 / loader 查询会把 BEAM 拉崩。

**migration 是 PR checklist 里显式的 operator 步骤：**

1. operator 停掉 `phx.server`（Ctrl+C 两下）。
2. operator 跑 `mix ecto.migrate`（或 `MIX_ENV=dev mix ecto.migrate`）。
3. operator 重启 `phx.server`。

PR 描述与 SPEC 实现计划都把这一步标为 `human-required:db-migration`。子代理交付 migration 文件 + 代码变更；operator 跑 migration。如果 operator 忘了，merge 后首次 `Workspace.Store.list_all/0` 会崩 —— 因为 Ecto schema loader 编译 `field :visible, :boolean` 但列不存在；这次崩本身**就是**结构性提醒，不需要额外的 sidecar 防御。

（反之亦然，`Workspace.Store` schema 定义里的 `field :visible, :boolean, default: true` 行**在同一个 PR commit** 里跟 migration 文件一起删掉。migration-跑过-后启动能成功；migration-没跑就启动会大声崩。这种"不匹配"本身就是结构门。）

### 4.2 代码改动 —— 每个 `list_visible/0` 与 `list_all/0` 的调用方

通过 `grep -rn "list_visible\|Workspace\.list_all\|Workspace\.Store\.list_all" apps/ --include="*.ex" --include="*.exs"` 枚举所有调用点。下表：文件:行 + 改成什么。

**operator 用调用方（SPEC 之后用 `list_workspaces_for/2`）：**

| 文件:行 | 今天 | 之后 |
|---|---|---|
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex:61` | `Ezagent.Workspace.list_visible()` | `Ezagent.Workspace.list_workspaces_for(socket.assigns.current_entity_uri, socket.assigns.current_caps)` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:324-332` | `list_visible/0` + admin 手工塞回 `workspace://system` | `list_workspaces_for/2` —— admin 捷径已经包含 `system`；line 329 的手工塞回 DELETED |
| `apps/ezagent_web/lib/ezagent_web/live_auth.ex:310` | `Ezagent.Workspace.list_visible()` | `Ezagent.Workspace.list_workspaces_for(caller_uri, caps)`（caps 从 session principal 取） |
| `apps/ezagent_web/test/ezagent_web/controllers/onboarding_controller_test.exs:89` | `Ezagent.Workspace.list_visible() \|> Enum.any?(...)` | `Ezagent.Workspace.list_workspaces_for(test_caller, test_caps) \|> Enum.any?(...)` —— 测试更新 |

**系统内部调用方（SPEC 之后保留 `list_all/0`）：**

| 文件:行 | 今天 | 之后 | 理由 |
|---|---|---|---|
| `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex:284` | `Workspace.Store.list_all()` | 不变 | Loader 启动时不分 caller 重建每个 workspace |
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:814` | `Ezagent.Workspace.Store.list_all()` | 不变 | agent flavor 解析需要扫每个 workspace 的 templates；非 operator 用面 |
| `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.cleanup_cross_prefix_members.ex:93` | `Ezagent.Workspace.Store.list_all()` | 不变 | 只读审计 mix 任务；operator tier（跑在 operator shell 不是 user 面） |
| `apps/ezagent_domain_identity/test/ezagent/registration_test.exs:36` | `Ezagent.Workspace.list_all()` | 不变 | 测试专用；读回自己刚建的 workspace |
| `apps/ezagent_core/test/invariants/no_default_workspace_seeded_test.exs:50` | `Ezagent.Workspace.list_all()` | 不变 | 断言无 `default` 行 |
| `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs:103` | `Ezagent.Workspace.list_all()` | 不变（但相邻的 `list_visible/0` 102 行删掉 —— 见下） | 横向验证 system 行存在 |
| `apps/ezagent_domain_workspace/test/ezagent/workspace/store_test.exs:85` | `Store.list_all()` | 不变 | Store 自己的测试 |

**本 PR 删除的函数：**

| 函数 | 文件:行 | 理由 |
|---|---|---|
| `Ezagent.Workspace.list_visible/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:510` | 被 `list_workspaces_for/2` 替代。完成扫除后无遗留调用方。 |
| `Ezagent.Workspace.Store.list_visible/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:187-191` | 底层 Store 查询，无遗留调用方。 |
| `Ezagent.Workspace.list_persisted/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:488` | `Store.list_all()` 的别名 —— 当年保留只为了"用 `list_visible` 不用 `list_persisted`"的口头纪律。基于 cap 的列表之后，operator 用面没人应该再去碰未过滤函数；系统内调用方直接走 `Store.list_all/0`。 |

**invariant 测试重写：**

| 测试 | 文件 | 改动 |
|---|---|---|
| `EzagentCore.Invariants.SystemWorkspaceMembershipTest` | `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` | 删除 line 93 的 `visible: false` 断言。删除 line 99-116 的 `list_visible/0` 排除/包含测试。新增：`list_workspaces_for(regular_user, []) 不含 system`；`list_workspaces_for(system_member, []) 含 system`；`list_workspaces_for(admin, [wildcard_cap]) 返回全集`。47-48 行的 fixture 删 `visible: false` / `visible: true`。 |
| `EzagentCore.Invariants.WorkspaceSotTest` | `apps/ezagent_core/test/invariants/workspace_sot_test.exs` → 改名 `operator_facing_workspace_listing_test.exs` | `@forbidden_patterns` 重写：禁 operator scope 出现 `Workspace.list_visible(`（已消失）+ `Workspace.list_all(` + `Workspace.Store.list_all(`。唯一允许的 reader 是 `Workspace.list_workspaces_for(`。 |
| `EzagentCore.Invariants.NoDefaultWorkspaceSeededTest` | `apps/ezagent_core/test/invariants/no_default_workspace_seeded_test.exs` | 不变。仍用 `list_all/0`；属于系统内部，仍合法。 |
| `EzagentCore.Invariants.PromoteToSystemGrantsCrossWorkspaceTest` | `apps/ezagent_core/test/invariants/promote_to_system_grants_cross_workspace_test.exs:26` | 删 `%{visible: false}` 参数 —— SPEC 之后 `Store.create("system", %{})` 直接可用，因 visible 已不存在。 |
| `EzagentCore.Invariants.WorkspaceLvCliParityTest` | `apps/ezagent_core/test/invariants/workspace_lv_cli_parity_test.exs:51` | 从 `@read_only_exemptions` 删 `list_visible`；替换为 `list_workspaces_for`。 |

**boot seed 重写：**

`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:273` —— 调用变为 `:ok = ensure_workspace("system", %{})`（不传 `visible: false`）。277-319 的 `ensure_workspace/2` helper 不用动 —— `attrs` 透传。

### 4.3 Phase 9 PR-8 SPEC 修订

`docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md` §13.1 + §13.2 + §13.4 在同一 PR 内修订：

- §13.1 第 2 段（`workspace://system 对非 system 成员不出现在常规 workspace 选择器`）改写为："`workspace://system` 不出现在缺少 `workspace://system` 成员资格或跨 workspace admin cap 的 caller 的 per-caller workspace 列表中。机制：`Ezagent.Workspace.list_workspaces_for/2`（SPEC `2026-05-27-workspace-cap-based-visibility.md`）。可见性是 cap 派生的，不是字段派生的。"
- §13.2 第 5 段（常规 workspace 成员从不在选择器里看到 `workspace://system`）原意保留；括注 "(it's hidden per §13.1)" 改为 "(they are not members; their caps don't reference it)"。
- §13.4 boot seed 片段（`Workspace.create("system", %{visible: false})`）改为 `Workspace.create("system", %{})`。"`visible: false` 字段是新加的 —— 默认 true" 那句（§13.4 第 2 段）删除。

中文 SPEC `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.zh_cn.md` 同步修订（依 `feedback_bilingual_docs_convention`）。

### 4.4 一个 PR 包打 —— 不留 dual-path

依 `feedback_let_it_crash_no_workarounds` + 父代 SPEC 的 r1-r9 习惯，本 SPEC 在一个 PR 内落地：

1. Schema 删字段（`Workspace.Store` defstruct + decode + `list_visible/0`）—— 1 commit
2. Facade 重写（`Ezagent.Workspace.list_workspaces_for/2` + `list_visible/0` 删除）—— 1 commit
3. migration 文件 —— 1 commit
4. 所有 caller 扫除 —— 1 commit
5. invariant 测试重写 —— 1 commit
6. Phase 9 PR-8 SPEC 修订（en + zh_cn）—— 1 commit
7. PR-level checklist 标 `human-required:db-migration` —— 在 PR 描述里，不是 commit

子代理交付 1-6；operator 跑 migration；operator（或 auto-merge gate）关 PR。

## 5. Invariant 测试 —— 合并门

依 `feedback_completion_requires_invariant_test`，本 PR "done" 当且仅当下面这个 invariant 测试通过 AND 当架构目标未达成时它能失败。

**测试文件：** `apps/ezagent_core/test/invariants/cap_based_workspace_visibility_invariant_test.exs`

**Setup**（DataCase，`async: false`）：

1. 建三个持久 workspace：
   - `workspace://system`（`Ezagent.Workspace.Store.create("system", %{})`）
   - `workspace://team-alpha`（`Ezagent.Workspace.Store.create("team-alpha", %{})`）
   - `workspace://team-beta`（`Ezagent.Workspace.Store.create("team-beta", %{})`）
2. 定义三个 caller：
   - `regular_user_no_caps` = `URI.parse("entity://user/team-alpha/regular")`，caps = `MapSet.new()`
   - `team_alpha_member_no_caps` = `URI.parse("entity://user/team-alpha/member")`，caps = `MapSet.new()` —— 但也通过 `Ezagent.Workspace.add_member("team-alpha", caller_uri)` 把这个 URI 加入 `workspace://team-alpha` 的 `members`
   - `system_member` = `URI.parse("entity://user/team-alpha/promoted")`，caps = `MapSet.new()` —— home 是 `team-alpha`（**不是** system）但通过 `Ezagent.Workspace.add_member("system", caller_uri)` 显式加入 `workspace://system` members。这隔离 (iv) `member_of_system?` 路径与 (iii) `home_is_system?` 路径；该 caller URI host **不**是 "system"，所以仅成员资格谓词触发。
3. 定义一个"委托 admin"caller：
   - `delegated_workspace_admin` = `URI.parse("entity://user/team-alpha/admin")`，caps = `MapSet.new([%Capability{kind: :workspace, behavior: Ezagent.Behavior.Workspace, action: :add_member, instance: URI.parse("workspace://team-alpha"), workspace_uri: URI.parse("workspace://team-alpha"), granted_by: User.admin_uri(), granted_at: DateTime.utc_now()}])` —— **不是** system 成员；仅持单一 workspace-scoped cap。
4. 定义 "home-is-system" caller（r3 —— codex r2 评审 HIGH）：
   - `home_is_system_user` = `URI.parse("entity://user/system/admin-created")`，caps = `MapSet.new()` —— URI host **就是** `system`（admin 通过 `users_live.ex:35` "在 system workspace 创建用户" UI 创建），但**未**加入 `workspace://system.members`。隔离 (iii) `home_is_system?` 谓词，与 (iv) 解耦。
5. 定义 "bootstrap-wildcard" caller（r3 —— codex r2 评审 HIGH）：
   - `bootstrap_admin` = `URI.parse("entity://user/team-alpha/wildcard")`，caps = `MapSet.new([%Capability{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any, granted_by: URI.parse("system://bootstrap"), granted_at: DateTime.utc_now()}])` —— home 是 `team-alpha`（**不是** system），**未**加入 `workspace://system.members`，但持 `SystemPrincipal.caps("system://bootstrap")` 铸造的完整 5-axis wildcard cap。隔离 (i) `holds_admin_caps?` 谓词，与 (ii)/(iii)/(iv) 解耦。

**断言：**

| # | caller | `list_workspaces_for(...)` 预期 |
|---|---|---|
| INV-1 | `regular_user_no_caps` | `[]` —— 没 system，没 team-alpha（非成员），没 team-beta。URI 查询全为空。 |
| INV-2 | `team_alpha_member_no_caps` | `[team-alpha]` —— 恰好一行 `"team-alpha"`。不含 system。不含 team-beta。 |
| INV-3 | `system_member`（home=team-alpha，在 system.members 里） | `[system, team-alpha, team-beta]` —— 全部三行（admin 捷径，通过谓词 (iv) `member_of_system?`）。 |
| INV-3a [r3] | `home_is_system_user`（home=system，**不**在 members 里） | `[system, team-alpha, team-beta]` —— 全部三行（admin 捷径，通过谓词 (iii) `home_is_system?`）。**独立**测试 URI-host 结构性 admin 路径，与成员资格解耦。 |
| INV-3b [r3] | `bootstrap_admin`（home=team-alpha，**不**在 members 里，持 wildcard caps） | `[system, team-alpha, team-beta]` —— 全部三行（admin 捷径，通过谓词 (i) `holds_admin_caps?`）。**独立**测试 cap-based admin 路径，与 URI host + 成员资格解耦。 |
| INV-4 | `delegated_workspace_admin` | `[team-alpha]` —— 通过 cap-scope 分支恰好一行。不含 system（无 system 成员资格，无 home-is-system，cap 也不指向 system，cap 是 `kind: :workspace, action: :add_member` —— 窄，**不**通过 `holds_admin_caps?` 或 `holds_cross_workspace_admin_cap?`）。不含 team-beta。 |

**变更回归断言（结构门）：**

- INV-5: 调用 `Ezagent.Workspace.add_member("team-beta", regular_user_no_caps_uri)` 之后，重跑 `list_workspaces_for(regular_user_no_caps, [])` 返回 `[team-beta]`。（把用户加入 workspace 改变了他的可见性集合，不需要额外 cap 授予。）
- INV-6: 给 `regular_user_no_caps_uri` 授予一条 `Behavior.Workspace.list_members` cap（`workspace://team-alpha` scope）后，重跑 `list_workspaces_for(regular_user_no_caps, [the_new_cap])` 返回 `[team-alpha]`。（cap-scope 分支触发。）
- INV-7: 关于 system workspace 的具体断言：`regular_user_no_caps` **永远**不该看到 `workspace://system`，不论再加什么非 admin cap。测试通过授予一条 `Behavior.Workspace.list_members` cap（`workspace://team-alpha`）+ 一条 `Behavior.Workspace.add_member` cap（`workspace://team-beta`）然后断言结果不含 `"system"`。

- INV-8 [r2 —— 处理 r1 静态评审的 MED-C1]：**代码形状元测试**，断言实现源文件**不**含字面 workspace 名 `"system"`（moduledoc / `@moduledoc` / 行注释除外）。目标文件：
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex`
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex`

  测试机制：

  ```elixir
  for path <- [
    "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
    "apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex"
  ] do
    src = File.read!(path)
    # 先剥离 moduledoc/heredoc 与行注释，再搜
    sanitized =
      src
      |> String.replace(~r/@moduledoc\s+"""[\s\S]*?"""/, "")
      |> String.replace(~r/@doc\s+"""[\s\S]*?"""/, "")
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.join("\n")

    refute sanitized =~ ~r/"system"/,
      """
      INV-8 违反：#{path} 在代码体（不是 moduledoc/注释）中
      出现字面串 "system"。此检查抓的是 boolean-restoration 反模式
      —— `if workspace.name == "system"` 是被禁的，因为它把字段化
      的特殊处理以代码形式复活。system workspace 对非成员的
      隐藏是结构性的（cap + 成员资格缺失），**不是**字面匹配过滤。
      """
  end
  ```

  **为什么 INV-8 是代码形状元测试 —— 有意为之：** INV-7 只测负方向（非 admin 看不到 system）。一个 hardcode `if ws.name == "system" and !system_member, exclude` 的部分实现能通过 INV-7 —— 测试 fixture 的常规用户拿到的 caps 不涉及 system，字面字符串过滤恰好把 system 排除给非成员，断言通过。INV-8 在源代码层而不是行为层抓这个反模式。这是对"测行为不测实现"原则的有意例外：在测试 fixture 选择的 cap 形状下，正确实现与 boolean-restoration 实现在行为上**结构上不可区分**，所以行为测试不能甄别。修法是直接测代码形状。

  权衡承认：若未来某次重构合理地需要在 workspace.ex 中出现 `"system"` 字面（例如 doc 中代码示例、日志消息），INV-8 会失败。sanitizer 已剥离 moduledoc/注释；若出现非 doc 的合理用途（例如错误消息格式），INV-8 的正则需要更新加入有论据的例外列表。这个例外列表**即**是审计轨迹 —— 添加项要解释清楚为何不是 boolean 复活。

**为什么这能门控架构目标：**

- 一个对所有人都返回 `list_all()` 的部分实现，INV-1 + INV-4 + INV-7 失败（可见性过宽）。
- 一个对所有人都返回 `[]` 的部分实现，INV-2 + INV-3 + INV-4 + INV-5 + INV-6 失败。
- 成员对了但漏掉 cap-scope 分支的部分实现，INV-4 + INV-6 失败。
- cap-scope 对了但漏掉成员资格的部分实现，INV-2 + INV-5 失败。
- 把布尔字段复活成代码字面（`if ws.name == "system" and !system_member, exclude`）的部分实现会**通过** INV-7 —— 测试 fixture 的 caps 不涉及 system，字面过滤恰好让结果不含 system，断言成立。仅 INV-7 抓不到这个反模式。**INV-8 抓得到** —— 它 grep-断言源文件不含 `"system"` 代码字面。
- admin 捷径写错的部分实现（例如让 `team_alpha_member_no_caps` 也看到 system）让 INV-2 失败。

**部分实现不能通过** —— codex r1 评审问题 #3（§9）会专门攻击这点；如果 codex 找到能通过的部分实现，下一轮加严测试。

## 6. 插件隔离分析

依 `feedback_north_star_plugin_isolation`：目标是"未来插件作者互不协调地工作"。架构缝：

| 层 | 知道什么 | 不知道什么 |
|---|---|---|
| `ezagent_core` | `Capability.workspace_uri` 轴 | workspaces.visible（无此概念） |
| `ezagent_domain_workspace`（领域） | `list_workspaces_for/2` 实现：成员资格 + cap-scope + admin 捷径 | LV 渲染细节、admin promote UX |
| `ezagent_plugin_liveview`（LV 插件） | 调 `list_workspaces_for/2`；遍历结果渲染 | 联集内部逻辑、admin 捷径判据、`member_of_system?` 在哪 |
| `ezagent_web`（auth 插件） | 在 `live_auth.ex` 挂载时调 `list_workspaces_for/2` | 同 LV 插件 |

未来 LV 插件作者写新"workspace 选择器"面，调 `list_workspaces_for/2` 结构上就是对的。他**不能**误调 `list_all/0`，因为 §4.2 的 operator-facing-listing invariant 测试堵了。他**不能**调 `Capability.cross_workspace?` 或 `member_of_system?`，因为 workspace facade 没暴露这些 —— 它们是 `Ezagent.Workspace.list_workspaces_for/2` 内部实现细节。

不对称在哪：今天 LV 作者**可能**误调 `list_persisted/0` 泄漏隐藏 workspace。修法是 invariant 测试。SPEC 之后这种不对称消失 —— `list_workspaces_for/2` 是唯一的 operator 用查询，按构造就以 caller 过滤。

判断标准测试（依 `feedback_north_star_plugin_isolation` 的 "keeps plugin authors out of core"）：`list_workspaces_for/2` 暴露 cap 结构内部给 LV 插件吗？答：不。LV 传 caps（它本来就从 `live_auth` → session principal 拿到了），拿回 workspace 列表。cap 结构在 `ezagent_domain_workspace` 与 `ezagent_domain_identity` 内部保持不透明。✅

## 7. 权衡 / 已考虑过的备选

### 7.1 保留 `visible` 字段，**并**加 cap-based 列表（加法叠加）

**拒绝。** 两套可见性机制让调用方困惑（"我查字段、查 cap、还是都查？"）。"两个都查"这种纪律恰是原 Phase 9 PR-8 设计失败的同款症状（一个 LV 用 `list_persisted/0`、另一个用 `list_visible/0` —— 同款纪律失败）。单机制是结构的，双机制是政策的。

### 7.2 URI scheme 改用 `system://` 而不是 `workspace://system`

**拒绝。** `system://` scheme 已经存在（`apps/ezagent_core/lib/ezagent/uri.ex` —— 六 scheme 白名单），但用于系统内部 principal（`system://bootstrap`、`system://workspace-loader`），不是 workspace。把 `workspace://system` 升格成 `system://workspace` 会 (a) 破坏 workspace scheme 的一致性 —— 所有其他 workspace 都是 `workspace://<name>`，为什么这一个例外？(b) 让所有处理 workspace scope 的代码都要兼顾两个 scheme（`workspace://` 和 `system://`），对作者认知负担更糟。系统 workspace **就是**一个 workspace —— 让它的 URI scheme 反映这点才是正确的结构不变量。"系统性"应当编码在成员资格里，不在 URI scheme 里。

### 7.3 不要字段、改成代码硬编码"system 隐藏"

**拒绝。** 同款反模式（依 `feedback_let_it_crash_no_workarounds` 的 no-defaults / no-whitelist）。一个字面量 `if workspace.name == "system"` 过滤器就是把布尔的形状搬进代码 —— 恰是 Allen 在触发指令里拒绝的。更糟的是：把 system workspace 的"隐藏"从数据模型里的声明式表达搬进代码里的隐式 if。基于 cap 的可见性把规则结构化（"你看到你持 cap 或者是其成员的 workspace"），无名字过滤。

### 7.4 按租户的 `visible`（如 `visible_to_users`, `hidden_from_users`）

**拒绝。** 即便实现，也是 cap-membership 轴的复制：`hidden_from_users` ≈ "没有 cap 或成员资格的用户"。两套并存就是双源（类比 `project_uuid_is_canonical_identifier`：可见性是 mutable display-only over 一个 canonical 权威轴）。一个 workspace 的权威集**就是**它的可见集；按构造让它们是同一个表达式，才是结构修复。

### 7.5 在 LV 渲染时按 cap 过滤

**拒绝。** 把过滤推给 LV（"LV 取 `list_all/0`，按 caller cap 逐行过滤"）等于把领域逻辑挪到插件层。依 `feedback_north_star_plugin_isolation`：把插件作者挡在 core 外 —— workspace domain 拥有 cap 算法。LV 调 `list_workspaces_for/2` 就结构强制走 domain 算法。

## 8. 与 §3.6.1(b) 的交互 —— 通配 action 授予检查

同期 SPEC `2026-05-27-capability-action-axis.md` §3.6.1(b) 引入运行时授予边界检查：`Identity.grant_cap/3` 拒绝非特权 caller（不满足 `holds_admin_caps?/1`）的 `Capability.action_of(cap) == :any` 授予。

**问：** 本 SPEC 影响该检查吗？

**答：** 不影响。交互面：

- `list_workspaces_for/2` 是 **READ**。它不授予 cap。它不调 `Identity.grant_cap/3`。
- `list_workspaces_for/2` 的 admin 捷径用 `holds_cross_workspace_admin_cap?/1`，依父 SPEC option-B narrowing 要求 `action: :any`（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:737-754`）。这意味着持仅 `:add_member` 的 cap 的委托 workspace admin **不会**触发 admin 捷径 —— 他们走 cap-scope 分支（正确地仅返回他们 scope 的 workspace）。这是设计。
- `action: :any` 配 `workspace_uri: :any` 的 cap 是 admin 通配；`list_workspaces_for/2` 的 admin 捷径会匹配（返回 `list_all/0`）。持此 cap 的 caller 按两个轴都是 admin（依父 SPEC §3.6.1 政策表）。
- 未来对 `Identity.grant_cap/3` 的政策收紧（例如限制可授予的 action）不改变 `list_workspaces_for/2` 的语义。两个 SPEC 正交：action 轴是关于 cap 在 dispatch 时允许什么；workspace 轴（本 SPEC）是关于在列表里把哪些 workspace 呈现给 caller。

**缝在哪：** 若未来 grant 政策让"给非 admin caller 授予 `workspace://team-alpha` 上 `Behavior.Workspace.add_member` 这条窄 cap"这件事不可达，上面 INV-4 在测试里就不可达 —— 测试 setup 需要放松（例如改由 system principal 授予，或换一个携 cap 的方案）。setup 注释里记一句："delegated_workspace_admin 的 cap 由测试 setup 中 `User.admin_uri()` 铸造；若未来政策限制 admin 也不能授予窄 cap，更新 setup 但不动断言。"

## 9. 向后兼容 / 外部 API

### 9.1 Mix 任务

- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.cleanup_cross_prefix_members.ex:93` 用 `Workspace.Store.list_all/0`，不引用 `visible`。不动。
- 其他 `apps/*/lib/mix/tasks/` 不引用 `list_visible/0` 或 `visible`。验证：
  ```
  rg -nP "list_visible|\.visible\b" apps/*/lib/mix/tasks/ → 0 命中
  ```

### 9.2 CLI / shell 脚本

- `scripts/` 目录：不引用 `visible` 或 `list_visible`。（`grep -rn "visible" scripts/ → 0 命中`。）
- cc-openclaw bootstrap（`cc-openclaw-ds.sh` 等）不与 workspace 可见性交互。不动。

### 9.3 文档引用

- `docs/runbook/`：`common-failures.md:266` 在无关 migration 上下文里提到"明示可见性"。不动。
- `docs/notes/2026-05-24-architecture-audit-v1.md:59-63` 记述 Phase 9 PR-8 `list_persisted/0 → list_visible/0` 的迁移。**保留**（历史记录）。可选新增 `docs/notes/2026-05-27-cap-based-workspace-visibility.md` —— 本 SPEC 不强制（SPEC 本身就是持久记录）。
- `docs/scenarios/` 目录：不存在。无 scenario 影响。

### 9.4 外部 JSON / API 端点

- 今天没有公开 HTTP/JSON API 暴露 workspace 的 `visible` 字段。`Workspace.Store.decoded()` 是内部结构；LV 模板渲染 `ws.name` / `ws.uri` / `ws.members` / `ws.session_templates` / `ws.routing_rules` —— 从不渲 `ws.visible`。
- `tmpl.visible` 这种混淆不存在：SessionTemplate Kind 没有 `visible` 字段；`workspaces.visible` 是孤本。

### 9.5 外部集成（飞书、MCP、插件作者）

- 插件作者约定（`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`）：不引用 workspace 可见性。
- 飞书 / MCP：workspace 可见性是内部概念；不外露。

**净评估：** 零外部 API 影响。`visible` 字段纯内部基础设施。

## 10. 待 Allen 决定的开放问题

1. **OQ-1：`caps` 入参形状。** `list_workspaces_for(caller_uri, caps)` 接受 caps 为 `MapSet.t() | [Capability.t()]`。要不要在 API 边界归一到单一形状？今天 `holds_cross_workspace_admin_cap?/1`（`identity.ex:728`）两种都收；保持一致。OK？

2. **OQ-2：caps 由调用方加载。** LV / `live_auth.ex` 在挂载前已经加载好 `caller_caps`（通过 `Users.decode_caps/1`）。`list_workspaces_for/2` **要求**调用方传 caps —— 它自己不从 `Identity` slice 重抓。这避免每次挂载多一轮 DB 往返，但意味着旧的 caps 参数会得到旧的 workspace 列表。能接受吗，还是应当让函数自己从 `caller_uri` 抓 caps？

3. **OQ-3：`Store.get_by_uri/1` accessor。** cap-scope 分支（§3.3.b）需要按 URI 查 workspace。今天 `Store.get_by_name/1` 存在，无 `get_by_uri/1`。加一个薄包装，还是从 `list_all/0` 在内存里过滤？内存里过滤更简单（一次 DB 查全集，然后过滤）也与 loader 模式一致；如果性能压力来了再加 `get_by_uri/1`。默认：内存过滤。

4. **OQ-4 [r3 —— 扩展；r4 —— codex r3 MED 层违例后选项 (b) 已修订]：共享 admin-shortcut 谓词的可见性。** §3.3 admin 捷径命名的**四个**谓词在源里全是 `defp`（私有）：
   - `holds_admin_caps?/1` —— `defp` 于 `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:835`（在 `ezagent_domain_identity`）
   - `holds_cross_workspace_admin_cap?/1` —— `defp` 于 `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:728`（在 `ezagent_domain_identity`）
   - `home_is_system?/1` —— `defp` 于 `apps/ezagent_core/lib/ezagent/capability.ex:480`（在 `ezagent_core`）
   - `member_of_system?/1` —— `defp` 于 `apps/ezagent_core/lib/ezagent/capability.ex:493`（在 `ezagent_core`）

   **Umbrella 依赖方向（codex r3 MED 发现）：** `ezagent_domain_identity` 依赖 `ezagent_core`（`apps/ezagent_domain_identity/mix.exs:34`、`apps/ezagent_core/mix.exs:37`）。`Capability`（ezagent_core）里的函数调用 `Identity.holds_*` 是**反向**依赖 —— 被 umbrella 图结构拒绝。**任何**把四谓词合并的 helper 必须放在 `ezagent_domain_identity`（或图中更高层），**不在** `Capability`。

   r4 修订后的三个选项：

   **(a) 四个全部在原地提升为公开。** 加 `IdentityAdmin.holds_admin_caps?/1` + `IdentityAdmin.holds_cross_workspace_admin_cap?/1`（目前是 `Ezagent.Behavior.IdentityAdmin`（`identity.ex:307`）里的 `defp` —— 见下方模块结构说明）+ `Capability.home_is_system?/1` + `Capability.member_of_system?/1` 为公开函数。`Ezagent.Workspace.list_workspaces_for/2` 直接调这四个（用 `Capability.*` 和 `Ezagent.Behavior.IdentityAdmin.*` 限定 —— `ezagent_domain_workspace` 已经同时依赖 `ezagent_core` 和 `ezagent_domain_identity`，调用点合法）。surface 增 4 个函数，每个语义清晰单一。**无层违例。**

   **(b —— r5 修订 —— codex r4 MED) 在 `ezagent_domain_identity` 新建 `Ezagent.Identity.AdminAuthority` 策略模块。** Helper 住在**专用的非 Behavior 策略模块**：`Ezagent.Identity.AdminAuthority.admin?(caller_uri, caps) :: boolean()`。内部调 `IdentityAdmin.holds_admin_caps?/1` + `IdentityAdmin.holds_cross_workspace_admin_cap?/1`（在其原模块提升为公开）+ `Capability.home_is_system?/1` + `Capability.member_of_system?/1`（capability.ex —— 提升为公开）。`Ezagent.Workspace.list_workspaces_for/2`（在 `ezagent_domain_workspace`，依赖 `ezagent_domain_identity`）调 `Ezagent.Identity.AdminAuthority.admin?/2`。surface 增 5 个函数，但仅 `AdminAuthority.admin?/2` 是 operator 复用面；其他 4 个是可单元测的原语。**无反向依赖** —— 每个调用都沿 umbrella 图向下。

   **模块结构说明：** 本 SPEC 起初引用这些谓词为 `Ezagent.Behavior.Identity` 上的，但实际源码在同一文件里有**两个** behavior 模块：`Ezagent.Behavior.Identity`（1-305 行）与 `Ezagent.Behavior.IdentityAdmin`（307 行起）。四个 admin-shape 谓词（`holds_admin_caps?/1` 在 835、`holds_cross_workspace_admin_cap?/1` 在 728）住在 `IdentityAdmin`**内部**，不在 `Identity`。codex r4 评审（MED）指出这点 —— 把 `admin_authority?` 挂在 `Behavior.Identity` 错在 (a) 谓词不在那个模块、(b) 把策略 helper 挂在 Behavior 动作模块混淆了策略与 Behavior。因此 r5 新建专用 `Ezagent.Identity.AdminAuthority` 策略模块 —— **在 `Behavior.*` 命名空间之外** —— 来承载该 helper。

   **(b —— r3 原版，r4 已拒绝)：** r3 默认把 `admin_authority?/2` 放在 `Capability`（`ezagent_core`）。codex r3 评审把此标为 MED 层违例 —— `Capability` 调 `Identity.holds_*` 是 umbrella 反向依赖。r4 迁了 helper；r5 终确定模块名。

   **(b —— r4 原版，r5 已被取代)：** r4 把 helper 放为 `Ezagent.Behavior.Identity.admin_authority?(caller_uri, caps)` 挂在 `Behavior.Identity` 模块。codex r4 评审（MED）指出此错：谓词住在 `IdentityAdmin`，不是 `Identity`；且把策略挂在 Behavior 模块混淆关注。r5 把放置最终确定为新的 `Ezagent.Identity.AdminAuthority` 策略模块。

   **(c) 在 `Ezagent.Workspace` 里重新实现四个谓词。** `list_workspaces_for/2` 把四个模式 inline。surface 不变但**有漂移风险** —— 如果 `identity.ex` 更新 `holds_admin_caps?/1`（例如未来 SPEC 加入新 wildcard 变体），`Workspace` 必须呼应该改动。此外：(c) 会强制 `workspace.ex` 含 `member_of_system?` 查询，引用 `"system"` 字面 —— 被 INV-8 结构性否决。

   **默认（r5）：(b —— 已修订) —— 新建 `Ezagent.Identity.AdminAuthority.admin?/2`。** 理由：四个谓词功能上是同一个决定（"该 caller 在 operator 列表意义上是不是 admin？"）；单个 helper 把它们绑为一个原子检查；放在专用策略模块（**不**在 `Behavior.*` 下）让 helper 在语义上与 Behavior 动作分开；在 `ezagent_domain_identity` 尊重 umbrella 依赖方向。(a) 也是可接受备选，若 Allen 偏好减少新模块 —— 见 OQ-7 的权衡。

   **与 INV-8 的交互：** 选项 (a) 和 (b-r5) 让 `"system"` 字面留在 `Capability.member_of_system?/1`（在 `capability.ex`）。`Store.get_by_name("system")` 调用通过 `apply/3` 从 `capability.ex` 间接发起（与今天同款）。`workspace.ex` 与 `store.ex` 仍无字面。选项 (c) 触发 INV-8 —— 多重否决。

5. **OQ-5：非 admin caller 的 `:any` action 轴 cap。** 依同期 SPEC `2026-05-27-capability-action-axis.md` §3.6.1，运行时授予边界拒非 admin 的 `:any` 授予。`list_workspaces_for/2` 是否也应在 cap-scope 分支里跳过非 admin caller 的 wildcard —— 即若 `cap.workspace_uri == :any` 且 caller 非 admin，视该 cap 不贡献于列表？目前 §3.3 说：`:any` workspace_uri 的 cap **不贡献任何东西**。admin 捷径处理合法的 `:any` 路径。这是防御性设计 —— 显式标注请确认。

6. **OQ-6：飘移 / 取证恢复。** 如果未来某次操作误把 `visible` 加回（例如 migration 回滚），schema-load 不匹配会在启动时崩。这是想要的取证信号，还是应该加一个启动检查断言"该列不存在"？

7. **OQ-7 [r3 —— 新增；r4 —— codex r3 HIGH 发现后已修订]：`Identity.admin_authority?/2` 与 `Capability.cross_workspace?/2` 的关系？** codex r3 评审确认（HIGH）r3 的"等价"声称被夸大了 —— `cross_workspace?/2` 的**第一条** clause 匹配**任何** `%Capability{workspace_uri: :any}`（不限 `kind`/`behavior`/`action`）。runtime step 5.6 路径（`runtime.ex:521,609`）与 cross-workspace 隔离 invariant fixture（`cross_workspace_isolation_test.exs:96`）正是有意利用 —— 非 admin 形状的 wildcard cap（例如 `%Capability{kind: :session, behavior: :any, workspace_uri: :any}`）触发 per-action 运行时旁路。可见性的 admin 捷径**有意**不覆盖这条路径（依 §3.3.b + OQ-5 —— 非 admin wildcards 不进列表）。

   **结论：** `Ezagent.Identity.AdminAuthority.admin?(caller_uri, caps)`（r5 名 —— 见 OQ-4）与 `Capability.cross_workspace?(cap, caller_uri)` 是**两根**权威轴：
   - `cross_workspace?/2` 是 per-cap, per-action："此**一个** cap 已经授权了**此**action，是否也旁路 workspace 隔离？"
   - `AdminAuthority.admin?/2` 是 per-caller, **aggregate**："此 caller 在 operator 列表意义上是不是 admin？"

   `AdminAuthority.admin?/2` **不应**委托给 `cross_workspace?/2`（会把可见性放太宽）。`cross_workspace?/2` **不应**委托给 `AdminAuthority.admin?/2`（会把 per-action 旁路放太窄）。二者作为独立公开 helper 并存。§3.3 admin 捷径与 `cross_workspace?/2` 共享**三**条 clause（home_is_system?、member_of_system?、(i)/(ii) 形状下的 `workspace_uri: :any`），**但不**共享不受限的 wildcard 路径。

   **前瞻可维护性契约（codex r4 NIT）：** 若未来 `holds_admin_caps?/1` 变体仍带 `workspace_uri: :any`，`cross_workspace?/2` 通过其第一条 clause 自动接住 —— 无需额外工作。若未来 admin 变体**不**带 `workspace_uri: :any` 但**应**也旁路运行时隔离，则 `cross_workspace?/2` 需要显式更新。每个加入新 admin-cap 变体的 SPEC 必须回答："该变体是否也产生运行时跨 workspace 旁路？" —— 是则两个 helper 都要更新；否则只更新 admin 捷径。

   **默认（r5）：** 本 PR**不**重构 `cross_workspace?/2`。admin 捷径 helper（`Ezagent.Identity.AdminAuthority.admin?/2`，依 OQ-4 选项 (b — r5)）与 `cross_workspace?/2` 保持独立。前瞻：若未来 SPEC 需要合并，由更高层 helper 同时调两者 —— **不**靠把一个塞进另一个。

## 11. Codex 对抗式评审问题（供 r1 评审用）

1. **system 成员但 system workspace 的 `members` 行里没他。[r2 已解决 —— 见 #6。]** 如果 `workspace://system` 存在但其 `members` 列表不含 `entity://user/system/admin`（启动顺序竞争、snapshot 错读，**或** —— 如 r1 确认 —— 启动时本来就是这样，因为 `ensure_system_workspace/0` 种空 members 列表），`list_workspaces_for/2` 的 admin 捷径对该 admin 在 `member_of_system?/1` 上**不会**触发 —— 他只会看到 cap-scope 分支贡献的 workspace（对于 bootstrap admin 持 `kind: :any, behavior: :any, instance: :any, workspace_uri: :any, ...`，cap-scope 分支**不贡献任何东西** —— 因 `:any` 在 cap-scope 分支里被过滤）。r2 闭上这条路：admin 捷径也在 `holds_admin_caps?(caps)` 触发，该谓词直接匹配 bootstrap wildcard 形状。启动顺序问题变得无关 —— bootstrap admin 的权威来自 cap（`SystemPrincipal.caps("system://bootstrap")`），不来自成员资格。

2. **`system://workspace-loader`（封闭 catalog principal）铸造的 cap。** 清理 mix 任务以 `system://workspace-loader` 发起 dispatch。`list_workspaces_for/2` 会不会收到 `system://workspace-loader` 持有的 caps？若是，cap-scope 分支给出的答案对吗？（很可能不会 —— operator 用面不会加载 workspace-loader 的 caps；但需验证。）

3. **§5 invariant 测试 —— 部分实现能否通过？** 具体：仅返回 `member_of_workspaces(caller_uri)`（完全丢掉 cap-scope 分支）的实现能通过 INV-4 吗？—— 不能（INV-4 的 `delegated_workspace_admin` 不是 `team-alpha` 成员；会返回 `[]`）。能通过 INV-1 / INV-2 / INV-3 吗？—— INV-1 能（`[]`），INV-2 能（`[team-alpha]`），INV-3 能**如果**也实现了 admin 捷径。所以一个仅有 membership + admin-shortcut 而无 cap-scope 的部分实现通过 4 个基础 INV 中的 3 个；INV-4 + INV-6 失败。测试门控架构目标。

4. **破坏性 DB migration（DROP COLUMN visible）。** SQLite 对 ALTER TABLE 的 DROP COLUMN 行为？验证：SQLite 3.35.0（2021-03）原生支持 `ALTER TABLE … DROP COLUMN`。Ecto 的 SQLite 适配（Exqlite）支持。任何更老的 sqlite_dev 版本会失败？（2026 年不太可能，但标一下。）operator 侧 merge 后：operator 的 dev DB 有此列；migration 删掉。Schema 删 `field :visible, :boolean, default: true` 与 post-migrate 一致。migration 会有静默失败的路径吗？（例如 SQLite 限制：该列有活动索引。没有 —— `20260602000000_phase9_pr8_workspace_visible.exs` 没加索引。验证。）

5. **删除布尔是否破坏任何 operator pinned artifact？** 依 §9.1，mix 任务不引用 visible。依 §9.4，无公开 API。grep 审计已完成。`apps/*/test/support/fixtures/` 里有没有 pinned snapshot 文件 / fixture 会反序列化老的带 `visible: ...` 的 `Workspace.Store.decoded()` map 然后崩？（可能没有 —— fixture 通常不序列化内部 map；它们通过 `Store.create/2` 建行。用 grep 验。）

6. **cross-workspace cap 路径。[r1 已确认 —— r2 已折入 §3.3；r3 在 codex r2 评审后加 home_is_system?；r4 在 codex r3 找到 wildcard-cap 路径未被蕴含后把"等价"改写为"有意更窄"；r5 在 codex r4 评审后修复本段残留的 r3 风格语言。]** `holds_cross_workspace_admin_cap?/1` 匹配 `kind: :workspace, behavior: Workspace, action: :any, instance: :any, workspace_uri: :any`（`identity.ex:738-744`）。admin caller 的主 cap（bootstrap 形状）是 `kind: :any, behavior: :any, action: :any, ...` —— **不是** `kind: :workspace`，所以**不**通过 `holds_cross_workspace_admin_cap?/1`。它**通过** `holds_admin_caps?/1`（`identity.ex:835-868`）。此外：启动时 `workspace://system` 的 `members` **是空的**（`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:269-275` 的 `ensure_system_workspace/0` 种空 members；admin 只在 LV "Promote to system" 路径 `users_live.ex:232` 被加入）。所以 `member_of_system?/1` 对启动时的 bootstrap admin **也**返回 false。**r2 解决方式：** 加 `holds_admin_caps?(caps)`。**r3 解决方式（codex r2 评审 HIGH）：** codex 指出 r2 漏了另一条 admin 路径 —— `Capability.cross_workspace?/2`（`capability.ex:466-470`）通过 `home_is_system?(caller_uri) or member_of_system?(caller_uri)` 处理 caller，其中 `home_is_system?` 匹配 `entity://user/system/<name>`（URI host = "system"）。在 workspace `system` 创建（admin 通过 `users_live.ex:35` UI 创建）但**不**在 `workspace://system.members` 的用户，按 `cross_workspace?/2` 是 admin-equivalent，但 r2 会错把他们当非 admin。r3 加 (iii) `home_is_system?(caller_uri)`，admin 捷径成为四谓词并集，与 `cross_workspace?/2` 共享**三**条 clause（home_is_system?、member_of_system?、收窄的 (i)/(ii) 形状下的 workspace_uri:any）。**r4 解决方式（codex r3 评审 HIGH）：** codex 指出 r3 "与 cross_workspace?/2 完全一致" 声称过强 —— `cross_workspace?/2` 第一条 clause 匹配**任何** `%Capability{workspace_uri: :any}`，不限 kind/behavior/action；admin 捷径**有意不**镜像（依 §3.3.b + OQ-5）。r4 把 §3.3 改写为 "关系 —— 有意更窄"，OQ-7 改为两个 helper 保持独立。**r5 解决方式（codex r4 评审 HIGH）：** 本段先前措辞仍写 "与 cross_workspace?/2 的权威逻辑完全一致" 并提议 `Capability.admin_authority?/2` —— 都与 r4 修订矛盾。r5 重写本段以匹配 r4 §3.3 与 §10 OQ-7：两个 helper 保持独立；提议的共享 admin helper `Ezagent.Identity.AdminAuthority.admin?/2`（按 OQ-4 选项 (b-r5)）只覆盖 admin 捷径，**不**覆盖 `cross_workspace?/2`。附录 A 序列图仍正确显示四谓词。

## 12. 回滚方案

revert merge commit。revert 之后状态：
- schema 的 `field :visible, :boolean, default: true` 复活。
- DB 列**已删**（migration 已跑）。schema-load 不匹配 —— `field` 声明、无列 —— 每次 `Repo.all(Workspace)` 都崩。
- **operator 必须同时回滚 migration**：`MIX_ENV=dev mix ecto.rollback --step 1` 恢复列。

这是两步回滚（代码 + DB）。PR 描述的 revert 计划写明两步。代价：operator runtime；好处：显式 + 可审计的回滚，而不是静默的兼容 shim。依 `feedback_let_it_crash_no_workarounds`。

两步回滚是安全网的承认，不是抵御本次改动。如果本 SPEC 的设计错了，回滚是可行的；§8 的 `:any` 交互与 §5 的 invariant 测试在 revert 之前给了多个结构门。

---

## 附录 A — 序列图（挂载时流）

```
LiveAuth.on_mount/4         (apps/ezagent_web/lib/ezagent_web/live_auth.ex)
  │
  │  caller_uri ← parse_entity_uri(session["entity_uri"])
  │  caps      ← Users.decode_caps(caller_uri)        ← 今天已加载
  │
  ▼
Ezagent.Workspace.list_workspaces_for(caller_uri, caps)
  │
  │  cond:
  │    holds_admin_caps?(caps)                    → list_all()    -- bootstrap wildcard
  │    holds_cross_workspace_admin_cap?(caps)     → list_all()    -- 结构性 workspace admin
  │    home_is_system?(caller_uri)                → list_all()    -- caller URI host = "system"
  │    member_of_system?(caller_uri)              → list_all()    -- system-member 晋升
  │    其他:                                       → union(
  │                                                   member_of_workspaces(caller_uri),
  │                                                   workspaces_for_caps(caps)
  │                                                 )
  │
  ▼
[Workspace.Store.decoded()]  — 按 name 升序
  │
  ▼
LV 赋值 :workspaces           — 给 AppShell.app_shell perspective 渲染用
```

## 附录 B — 本 SPEC 为何中长

比 action-axis SPEC 长，是因为扫除涉及更多调用点（12 处 file:line 编辑 vs ~3 处 cap 结构编辑）并且要求上游 SPEC 修订（Phase 9 PR-8 §13）。决定本身小；落实是机械的。机械细节在 §4.2 的表里，不在 §3 的语义里。评审重点是 §3（语义）+ §5（invariant 测试）；其余是实现清单。

## 附录 C — §10 OQs 留给 Allen 决定

依 `feedback_brainstorming` 习惯 —— 决定分叉到不门控结构答案的旁问题时，标为 OQ 然后继续。§10 的 **7 个** OQ 各自在本 SPEC 里有默认答案：
- OQ-1：`MapSet | List` 两种 cap 形状都收
- OQ-2：caller 传 caps（不重抓）
- OQ-3：cap-scope 查询用内存过滤
- OQ-4（r5 —— 已修订）：在 `ezagent_domain_identity` 新建 `Ezagent.Identity.AdminAuthority.admin?/2` 策略模块（选项 b-r5），同时把 4 个源谓词在原地（`IdentityAdmin` + `Capability`）提升为公开
- OQ-5：cap-scope 分支跳过非 admin caller 的 `workspace_uri: :any`
- OQ-6：不加启动检查；schema 不匹配崩本身是取证信号
- OQ-7（r5 —— 已修订）：**不**重构 `cross_workspace?/2`；两个 helper（`AdminAuthority.admin?/2` 与 `cross_workspace?/2`）保持独立，因为它们编码**不同**的权威轴（见 §3.3 "关系" 子节）；前瞻可维护性契约规定未来加入新 admin-cap 变体的 SPEC 何时必须更新两个 helper

Allen 可对任意一个确认或推翻。Allen 不推翻则子代理按默认继续。
