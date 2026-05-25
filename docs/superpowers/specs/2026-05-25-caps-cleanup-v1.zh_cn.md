# SPEC — Caps 清理 v1（三件架构纠偏）

**状态:** r1 (DRAFT)。2026-05-25。
**层级:** `apps/ezagent_core/` 框架纠偏 + 所有 domain + plugin 的清扫。
**触发:** Allen 2026-05-25 (Feishu) — 在 data-ownership-v2 / external-mirror-audit 工作中暴露的三条逐字指令，针对累积的 cap 系统病灶：

1. "在代码中，完全不应该体现 admin_caps 的特殊性。admin 的特殊性是在验证权限的时候，通过 wildcard 匹配实现的"
2. "caps 的调用应该仅仅在 entity x behavior 的领域中实现。behavior 实现的时候，要求调用的 entity 需要持有某个权限，entity 中提供这个权限的凭证（目前就是简单的字符串）。所有其他的域理论上应该是透明不感知 caps 存在的"
3. "使用宏是必要的吗？还是可以通过其它方式更直接地完成？"（关于编译期强制约束）

**前置（均已合入 `main`，均未被本 SPEC 取代）:**
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 — `Ezagent.CapabilityRegistry` 单入口注册。本 SPEC 在 cap *执行* 上取代它；cap *主体目录* 的用途坍缩到 Behavior callback 中。
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` rev 3 — `data_owner/1` callback + "cap 是某类数据 CRUD 授权，且只有唯一合法授权者" 原则。本 SPEC 保留数据所有权原则与 `data_owner/1` callback；只改变 cap 的 *表示* 与 *校验* 方式。
- `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` r1 — 4 门强制 + FacadeNonceTable 防伪造。本 SPEC 保留 FacadeNonceTable；它与 cap 表示正交。
- `apps/ezagent_core/lib/ezagent/capability.ex` — 本 SPEC 简化的 6 字段 struct。
- `apps/ezagent_core/lib/ezagent/capability/parser.ex` — 本 SPEC 将其从 "operator CLI 输入" 提升为 "canonical 线格式" 的现有字符串语法。
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — 本 SPEC 扩展的现有编译期 gate。

**前置 memory（重要）:**
- `feedback_let_it_crash_no_workarounds`（Allen 2026-05-05）— 本 SPEC 中每个 "删除" 都是硬删除。无 `User.admin_caps()` 弃用期。无 "若是 struct，则在边界转字符串" 的垫片。旧调用点在编译期 raise。
- `feedback_completion_requires_invariant_test`（Allen 2026-05-05）— 三个 issue 每个都有一个 invariant test，当架构目标未达成时该测试失败（§9）。
- `feedback_north_star_plugin_isolation`（Allen 2026-05-05）— 设计抉择的最终裁决是 "把 plugin 作者挡在 core 之外"。Issue 2 是该原则的直接应用。
- `feedback_uuid_is_canonical_identifier`（Allen 2026-05-12）— cap 字符串命名 *权限类型*，而非用户名。身份绑定由 instance URI 完成。
- `feedback_bilingual_docs_convention` — 中文镜像在 `.zh_cn.md`。

**配套:** `2026-05-25-caps-cleanup-v1.md`（英文）。

---

## 0. 待 Allen 审定的开放问题

brainstorm 浮出的六个问题。SPEC 当前选择标 **[picked]**；Allen 同意会在实施前翻转任一选择。

### OQ-CC-1 — Cap 字符串格式：`@<instance_uri>` 是否保留？

现有 `Capability.Parser` 语法已经支持 `"chat.send@session://default/team/standup"`（kind.behavior@instance）。Allen 逐字说 "目前就是简单的字符串"，但未明确 instance-scoping 是否保留。

- **[picked] 选项 A — instance 后缀保留。** cap 字符串语法为 `<kind>.<behavior>[.<action>|.*][@<instance_uri>]`。若无 instance-scoping，data-ownership-v2 不变式坍塌：session owner cap（绑定到自己的 session instance）无法与 global session-admin cap 区分。例：`"session.chat@session://default/team/standup"`、`"workspace.workspace@workspace://team"`、`"*"`。
- 选项 B — 不要 instance-scoping；cap 只剩 `<kind>.<behavior>`。简单，但彻底破坏 data-ownership-v2。需要另一套 "scoped-by" 机制（可能是 2-string-tuple），比保留后缀更糟。

**为什么 A：** 保留我们刚出货的结构不变式（data-ownership-v2 rev 3），无需新机制，语法已存在。

### OQ-CC-2 — cap 简化后的 workspace 隔离机制

今天 workspace 隔离通过 cap struct 的 `workspace_uri` 字段 + dispatch step 5.6 的 `cross_workspace?/2` 谓词存在于 `Capability.matches?/2`。改字符串后 cap 不再携带 workspace 字段。

- **[picked] 选项 A — workspace 隔离改为 Behavior 的 `workspace_scoped?/0` callback（默认 `true`）。** 跨 workspace 旁路 = caller 是 `workspace://system` 成员（Phase 9 PR-8 的 Keycloak realm-admin 模型）OR caller 持有显式跨 workspace cap 字符串 `"cross-workspace:*"`。Dispatch step 5.6 位置不变，但读 Behavior callback 而非 cap struct 字段。
- 选项 B — workspace 隔离编码到 cap 字符串中作 `@workspace://X.<rest>` 前缀。两个关注点混在一个语法；难推理；后缀已用于 instance-scoping。
- 选项 C — 移出 dispatch 整体；每个 Behavior 在 `invoke/4` 自己做。违反 "其他域透明" — 每个 Behavior 写一样的检查；典型的 "每个 plugin 都有一份原语" 反模式（memory `feedback_north_star_plugin_isolation`）。

**为什么 A：** workspace 隔离是 *该 Behavior 操作何种数据* 的结构属性，每 Behavior 一次声明，每次 dispatch 一次强制。

### OQ-CC-3 — Cap-only Behavior（Presence 模式）简化后

今天 `Behavior.Presence` 返回 `dispatchable?/0 == false` — 它只为声明 cap subject（`:online`）供 `NotificationSubscriptions` 作为权限 gate 使用，本身不是 dispatch target。简化后，cap subject catalog 消失 — cap 只是字符串，消费 gate 的代码从 Behavior 读 `required_caps/0`。

- **[picked] 选项 A — 彻底去掉 cap-only Behavior。** 这个模式是 "我想声明 cap subject 但不暴露可 dispatch 的 action" 的变通。无中央 subject catalog 后，变通不需要了：`Behavior.Presence` 变成普通 Behavior 且 `:online` 可 dispatch（或 gate 消费者直接读 cap 字符串，不经 Behavior）。审计显示今天恰好两个 cap-only Behavior：`Presence` 和 `Sandbox`。两者均可在 PR-CC-2 的 1-2 个 PR 内迁移。
- 选项 B — 保留 `dispatchable?/0` callback。保留现有模式但留下退化概念（不可 invoke 的 "Behavior" 在概念上是标签而非 Behavior）。

**为什么 A：** 心智模型更简；该模式仅在 `CapabilityRegistry` 存在时才承载关键作用；`CapabilityRegistry` 删除后该模式溶解。

### OQ-CC-4 — `Behavior.IdentityAdmin` 拆分 — 保留还是合回？

今天 `Behavior.Identity` 按 data-ownership-v2 PR-OWN-3 拆为安全的 `Identity`（`:list_caps`、`:has_cap?`）+ 特权的 `Behavior.IdentityAdmin`（`:grant_cap`、`:revoke_cap`）。拆分的存在因为 cap struct 是 Behavior-scoped — 在 `Behavior.Identity` 上授一个 cap 会同时授读与授权。

简化后：`required_caps/0` 是 per-action 的，因此 `Behavior.Identity` 可合并 — `:list_caps` 要求 `"user.identity.list_caps"`，`:grant_cap` 要求 `"user.identity.grant_cap"` — 不同 cap 字符串。

- **[picked] 选项 A — 保留拆分。** 即便 per-action cap 字符串，双 Behavior 拆分让权限边界在模块树中可见（任何人读 `Behavior.IdentityAdmin` 都知道 "这里敏感"）。合回省 1 个模块，但把权限差异埋进 action 命名纪律里。拆分与 cap 表示无关；它是模块组织的事。
- 选项 B — 合回单一 `Behavior.Identity`。少 1 个模块，但读者必须看每个 action 的 `required_caps/0` 才知道哪些是 admin-only。

**为什么 A：** 模块拆分廉价；可见性收益持久。

### OQ-CC-5 — Issue 1 的 system principal catalog 如何与 Issue 2 的 cap 形态交互？

每个 system principal（如 `system://boot-reconciler`）需要 cap 表达 "我可以 dispatch 什么"。Issue 2 后这些 cap 是字符串。即 `system://boot-reconciler` 的 cap 形如 `["session.external_mirror.*"]`。存哪里？

- **[picked] 选项 A — System principal 是持久化的 Entity slice，形态与 User 相同。** 每个 system principal 在 boot 时作为 Entity Kind spawn（`:identity` slice 带 cap 列表，与 User Kind 同形，仅 URI 是 `system://...` 而非 `entity://user/...`）。存于现有 `users` 表（或同 schema 的独立 `system_principals` 表）。`Ezagent.Identity.list_caps_for(uri)` 对两者一致工作。Bootstrap 脚本播种目录（§4.1 列出的 14 个 principal）。User Kind 也处理 "system://" URI — 无需新 Kind；仅 URI scheme 区分。
- 选项 B — System principal 仅内存，存于 `SystemPrincipal` ETS 表。避免 DB 迁移，但失 crash-safety（principal 每次 boot 必须从编译期默认值重新播种）。
- 选项 C — 不存在 system principal；每个调用点传硬编码 cap 列表。换名重新引入 ambient authority；被 Allen "audit log 显示真实 principal" 的要求拒绝。

**为什么 A：** 与 User cap 一致 = 无新原语；现有 snapshot 路径持久化；现有 `:identity` slice 契约即用；LV `/admin/caps` 页面通过现有路径就能看到。

### OQ-CC-6 — 迁移数据路径：原地 vs 抹掉重建？

现有 user `caps_json` 列存储 `[%Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`。新形态是 `[String.t()]`。struct → string 转换在两处有损：

- `granted_by` / `granted_at` 丢失（cap 字符串无 provenance）。Provenance 迁到独立 `grants` 审计表（或彻底丢弃 — 见下面子问题）。
- `workspace_uri` 从 cap 中丢失（按 OQ-CC-2 选项 A — workspace 隔离迁到 Behavior callback）。cap 字符串的 instance 后缀通过 URI 结构携带 workspace 信息。

- **[picked] 选项 A — 抹掉 dev DB 重建；生产出货一次性转换脚本。** 匹配 data-ownership-v2 / external-mirror-domain 模式（Phase 9 SPEC v3 §8）。转换脚本：读取每个 `caps_json` 行，按 §5.8 映射表导出 cap 字符串，写回。provenance 丢弃（需要 Allen 明确决定 — 见子问题）。Dev `mix ezagent.reset` 重新生成。
- 选项 B — 原地迁移，provenance 保留到并列 `cap_grants` 审计表。运动部件多；PR 多。

**子问题 — provenance：** 彻底丢弃 granted_by/granted_at，还是保留到独立审计表？

- **[picked] 彻底丢弃。** 今天无生产代码路径读 `granted_by`（grep 验证 — 仅 test fixture 与序列化回环用）。data-ownership-v2 的授权链思想（cap-A 由 cap-B 持有者授权）延期到未来 SPEC 且从未落地。若未来需要 provenance，加一个 `cap_grants` 审计表与 caps_json 并列 — additive 变化。

**为什么 A + 丢弃：** 匹配抹掉重建惯例；今天无 provenance 消费者；未来需要时可 additive 加回。

---

## 1. Context — 我们是如何到这里的

ezagent 今天的 cap 系统把六个关注点混在一个 `%Ezagent.Capability{}` struct + 一个 `CapabilityRegistry` ETS + 一个 `User.admin_caps()` 逃生口中：

1. **何种** 权限（kind + behavior 字段）
2. **针对何 target**（instance 字段）
3. **在哪个 workspace**（workspace_uri 字段）
4. **由谁授权**（granted_by 字段）
5. **何时授权**（granted_at 字段）
6. **发现 / 目录**（CapabilityRegistry — 哪些 cap 存在，描述是什么，data owner 是谁）

混合产生了过去 3 个 SPEC 中每个吃掉 5+ 轮 codex review 的三种病灶：

### 1.1 病灶 A — 通过 `User.admin_caps()` 的 ambient authority

当 system-internal 操作（BootReconciler、AdapterInstall、迁移 mix task、ChatRouter 回复 dispatch、Worker publish）需要 dispatch 时，它没有真实 user URI。便利逃生口是 `User.admin_caps()` — 结构上 :any 的 cap MapSet，匹配一切。审计显示 **16 个生产点 + 21 个测试点**（57 grep 结果，减去 20 docstring 提及与注释引用）。

| 类别 | 样本调用点 |
|---|---|
| Boot / reconciler | `EzagentDomainIdentity.Application`（admin User spawn）、`EzagentDomainChat.Application`（CC orchestrator seed）、`EzagentDomainWorkspace.Workspace.Loader`（boot loader） |
| Mix task | `mix ezagent.agent.create`、`mix ezagent.demo.seed_cc_agent`、`mix ezagent.demo.seed_cc_sandbox` |
| Plugin 回复 dispatch | `Plugin.CurlAgent`（LLM 回复 dispatch）、`Plugin.NP`（NP-agent 回复）、`Plugin.CC.Channel`（channel 回复）、`Plugin.Echo`（echo 回复）、`Plugin.Feishu.BindingPolicy` |
| Chat domain 内部 | `Behavior.Chat`（回复发送、system 消息）、`Behavior.Template`（模板实例化）、`Entity.Session`（成员同步、slice 变更）、`Entity.Agent`（default caps 授权）、`Orchestrator.{MCPServer, Tools, CCSeed}` |
| LV admin 默认 | `terminal_live`、`agent_extensions_live`、`agent_detail_live`、`entity_caps_live`、`agent_new_live`、`admin_live`、`routing_live`（当 caller 为 `nil` 时） |
| Web 根 | `home_live`（无 current_entity 时） |
| Worker | `Behavior.ExternalMirrorWorker`（publish-to-adapter dispatch） |

每个点都 *可伪造*（调用代码声明 "我是 admin"）且 *无法追踪*（审计日志说 "admin did X"，而非 "BootReconciler did X"）。

### 1.2 病灶 B — Cap 检查逻辑散落在非 Behavior 层

今天的契约是 "dispatch step 5.5 通过 `Capability.matches?/2` 检查 cap"。但现在代码在以下位置有 cap 检查的副本或同义版本：

- `Behavior.Identity.invoke(:grant_cap, ...)` — `check_grant_authorized/2` 按 data-ownership 规则重新检查 cap 形态（200+ LOC）
- `Behavior.ExternalMirror` facade — `Ezagent.ExternalMirror.bind/5` 中的 Gate 1、2、3（200+ LOC 的 facade 级 cap 检查，per external-mirror-audit §2）
- `NotificationSubscriptions` admin 谓词 — `has_admin_cap?/1` 手写形态匹配
- `MemberPanel` LV — `cc_agent_uri?/1` workspace 成员检查
- `SenderResolver`（Feishu）— `Ezagent.Identity.list_caps_for(bound_uri)` 后成员检视
- 多个 `_live` 模块 — cap-driven UI gating 的 `MapSet.member?` 检查

Plugin 作者每次都需 *发明* trust model。PR #303 NotificationSubscriptions HIGH-3 finding 就是这个 — 手写谓词太宽因为无框架级 "你必须在 data-D 上持有 cap-X" gate。

### 1.3 病灶 C — 编译期约束散于 `use Macro` + after_compile + Mix compiler

今天 `Behavior` 经 `@behaviour Ezagent.Behavior`（编译警告）+ `CapabilityRegistry.register/3` 时 `cap_subjects/0` 查找（action 缺失则 raise）强制。一些 plugin 作者还在上层加了 `use SomeMacro` 模式。编译期 gate 分散在三种机制。Allen Q3："使用宏是必要的吗？还是可以通过其它方式更直接地完成？" — 答案是不必要。现有 `:ezagent_plugin_check` Mix compiler 已是正确的表面；它只需长出 cap 相关检查。

### 1.4 本 SPEC 修复什么

本 SPEC 在一次协同清理中拆解三种病灶：

- **Issue 1** 去掉 ambient authority。System 操作声明自己的 named principal。Admin 的 wildcard 权限保留，但通过数据（admin Entity 的 cap MapSet）而非代码（`User.admin_caps()` 删除）。
- **Issue 2** 把 cap 声明迁到 per-action Behavior callback。Entity 持有 cap 字符串。其他所有代码对 cap 透明 — dispatch 是 gate 运行的唯一处。`Capability` struct + `CapabilityRegistry` ETS + `Identity.{grant_cap,list_caps_for,revoke_cap}` 全删或简化。
- **Issue 3** 把强制迁到现有 `:ezagent_plugin_check` Mix compiler。无宏。~50-100 LOC 新增。

---

## 2. Goals（结果陈述）

本 SPEC 的 3 个 PR 合并后：

**G1 — Ambient authority 消失。** `grep -rn "User.admin_caps" apps/` 在 `test/support/` 之外返回 0。每次 dispatch 在 `ctx.caller` 携带真实 principal URI。审计日志显示每次内部操作的真实操作 principal。Admin Entity 的 cap slice 仍包含 wildcard `"*"` cap 字符串 — admin 权限是数据，不是代码。

**G2 — Caps 仅在 Behavior × Entity 存在。** `Behavior.required_caps/0` 声明 per-action cap 字符串。`Entity.holds_cap?/2` 决定成员关系。`Invocation.dispatch/1` step 5.5 调用两者。其他每个模块对 cap 透明。`grep -rn "Capability.matches\|cap_subjects\|list_caps_for\|grant_cap" apps/` 在 `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex` 与 `apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex` 之外返回 0 个生产结果。

**G3 — 编译期约束是数据，不是宏。** 每个 `@behaviour Ezagent.Behavior` 模块导出有效 `required_caps/0`。Build 在以下情况以精确诊断失败：(a) callback 缺失、(b) key 集合与 `actions/0` 不同、或 (c) 任意值非 binary cap 字符串。零宏新增；`:ezagent_plugin_check` compiler 长 ~50-100 LOC。

---

## 3. Non-goals

- **不切换 RBAC**（role-based）— cap 模型不变。"role" 只是命名的 cap 字符串 bundle，调用方可一次性授权。
- **不替换 external-mirror-audit 的 FacadeNonceTable**。facade Task 与 action body 间的 trust transfer 与 cap 简化正交。
- **不动 dispatch 其他 step**（1–4、5.1–5.4、5.6–10、11–12）。仅 step 5.5（CapBAC）与 5.6（workspace 隔离）改。Step 5.5 读 `Behavior.required_caps()` + 调 `Entity.holds_cap?/2`；step 5.6 读 `Behavior.workspace_scoped?/0`。
- **不改 data-ownership-v2 的 `data_owner/1`**。callback 签名与 default-grant 派生不变。只改 cap *表示*（struct → string）；data-ownership *规则*（只有 owner 授本数据的 cap）保留。
- **本 SPEC 不加 cap provenance 审计表。** 按 OQ-CC-6 丢弃 `granted_by` / `granted_at`。若 provenance 变需要，作为独立 `cap_grants` audit-only 表 additive 落地。
- **不改 UI cap 列表显示** 超出字段缩减。`/admin/caps` LV 仍通过 `Behavior.required_caps/0` 跨所有注册 Behavior 聚合枚举 "存在哪些 cap 字符串"。

---

## 4. Issue 1 — Ambient authority 移除

### 4.1 System principal 目录

每个 system-internal dispatch 得到 `system://` scheme 下的 named principal URI。Principal URI 在 app boot 作为 Entity Kind spawn（按 OQ-CC-5 选项 A），cap 列表从编译期目录播种。

| Principal URI | 操作上下文 | 所需 cap 字符串 |
|---|---|---|
| `system://bootstrap` | 首次 boot 时 admin User spawn（仅用于产生 admin Entity 自身） | `"*"`（一次性使用，从编译期常量授权） |
| `system://boot-reconciler` | `EzagentDomainExternalMirror.BootReconciler` — boot 时按运行 adapter 协调持久 binding | `"session.external_mirror.*"` |
| `system://adapter-install` | `EzagentDomainExternalMirror.AdapterInstall` — plugin boot 时在 Session Kind 上安装 adapter cap subject | `"session.*.bind"`（注册 per-adapter Behavior） |
| `system://chat-router` | `Behavior.Chat` 的 system 消息 dispatch 路径（系统发送的欢迎消息、reaction 通知） | `"session.chat.send"`、`"session.chat.system_message"` |
| `system://chat-reply` | Plugin 回复 dispatch（Echo、CurlAgent、NP、CC、Feishu）— "agent 对 session 的响应" 路径 | `"session.chat.send"`、`"session.chat.reaction"` |
| `system://worker-publish` | `Behavior.ExternalMirrorWorker` 外发 publish dispatch | `"session.external_mirror.publish"` |
| `system://template-materialize` | `Behavior.Template` 模板实例化 dispatch | `"workspace.template.*"`、`"session.*"` |
| `system://orchestrator-tools` | `Orchestrator.{MCPServer, Tools, CCSeed}` agent-tool dispatch | `"session.*"`（agent 在其 session lineage 内操作） |
| `system://session-internal` | `Entity.Session` slice 内部 dispatch（成员同步、scope 变更） | `"session.chat.*"`、`"workspace.workspace.read"` |
| `system://agent-internal` | `Entity.Agent` agent spawn 时默认 cap 授权 | `"user.identity.grant_cap"`（限于被 spawn 的 agent） |
| `system://workspace-loader` | `Workspace.Loader` 重新 spawn 持久 workspace 的 boot 路径 | `"workspace.workspace.*"` |
| `system://mix-task` | `mix ezagent.agent.create`、`mix ezagent.demo.seed_*` 操作员 task | `"*"`（操作员已有 shell 访问；principal 为审计追踪而存在） |
| `system://feishu-binding-policy` | `Plugin.Feishu.BindingPolicy.apply/2` 默认 session cap 的重新授权 | `"user.identity.grant_cap"` |
| `system://lv-anon-mount` | session 中无 `current_entity_uri` 时的 LV mount 路径 | `[]`（空 — LV 匿名 mount 不能 dispatch；替代隐藏 auth bug 的静默 `User.admin_caps()` 回退） |

共 14 个 principal。列表是穷举的 — 任何未来 system-internal dispatch 点在此添加行，永不重新引入 `User.admin_caps()`。

### 4.2 播种流程

每个需要 system principal 的 domain Application 在其 `start/2` 中播种：

```elixir
Ezagent.SystemPrincipal.ensure(
  URI.parse("system://boot-reconciler"),
  ["session.external_mirror.*"]
)
```

`Ezagent.SystemPrincipal.ensure/2`（`apps/ezagent_core/lib/ezagent/system_principal.ex` 新模块）：
- 以 `:identity` slice 携带 cap 列表 spawn Entity Kind（与 User Kind 同形，仅 URI 是 `system://...` 而非 `entity://user/...`）。
- 幂等：若已 spawn，no-op。
- 经现有 `users` 表持久化（列 `caps_json` 携字符串列表）。
- 若以非 `system://` URI 调用则硬 raise（防意外误用）。

`Behavior.Identity.init_slice/1` 已处理 slice shape — 仅 URI scheme 改变。

### 4.3 System 调用点迁移

| 旧 | 新 |
|---|---|
| dispatch ctx 中 `caps: User.admin_caps()` | `caps: Ezagent.SystemPrincipal.caps(URI.parse("system://<service>"))` |
| dispatch ctx 中 `caller: User.admin_uri()` | `caller: URI.parse("system://<service>")` |
| 裸 `User.admin_caps()` 调用 | 删除 — 函数从 `Entity.User` 删除（若使用则编译错误） |

每个今天为匿名 mount 回退到 `User.admin_caps()` 的 LV（`agent_extensions_live`、`terminal_live` 等）切到带空 cap 的 `system://lv-anon-mount`。原先静默提升为 admin 的 LV mount 路径现在会正确拒绝匿名访问。这是现有的 auth-bug 暴露器 — 匿名 LV mount **本应** 被拒绝；`User.admin_caps()` 回退在隐藏它。按 memory `feedback_let_it_crash_no_workarounds`，修复是让 bug 在 gate 处可见，而非保留回退。

### 4.4 审计日志变更

`telemetry.execute([:ezagent, :authz, :granted], ...)` 的 `caller` 字段今天对真实 admin 操作 AND 每次 system-internal dispatch 都显示 `entity://user/system/admin`。本 PR 后分裂：真实 admin 操作仍显示 admin URI；system 操作显示 `system://<service>`。

Codex r2 会要求审计消费者（今天：`audit.ex` 写入 `audit_events` 表）处理新 URI scheme。它们已处理 — `audit_events.caller` 是字符串列无 scheme 约束。CSV / `/admin/audit` LV 逐字显示 URI。

### 4.5 Invariant test

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs`（新）：

```elixir
test "no production code calls User.admin_caps/0" do
  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.filter(fn path -> not String.contains?(path, "test/support") end)
    |> Enum.filter(fn path ->
      File.read!(path) =~ ~r/\bUser\.admin_caps\(\)|Ezagent\.Entity\.User\.admin_caps\(\)/
    end)

  assert offenders == [],
         "ambient authority leak: #{inspect(offenders)} call User.admin_caps()"
end

test "User module does not export admin_caps/0" do
  refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
         "Ezagent.Entity.User.admin_caps/0 must be deleted per caps-cleanup-v1 §4"
end
```

第一个断言清理完成；第二个断言逃生口结构性移除。

---

## 5. Issue 2 — Caps 在 Behavior × Entity 边界

### 5.1 `Behavior.required_caps/0` callback（普通函数）

加到 `Ezagent.Behavior` 作为强制 callback（无宏）：

```elixir
@doc """
从 action 原子到所需 cap 字符串的映射。Invocation.dispatch/1 step 5.5
读它派生 caller 必须持有的 cap。

cap 字符串遵循 §5.4 语法。例：

    %{
      send: "session.chat.send",
      receive: "session.chat.receive",
      join: "session.chat.join"
    }

`actions/0` 返回的每个 action 必须在此有一项。
由 `:ezagent_plugin_check` 编译期强制（Issue 3）。
"""
@callback required_caps() :: %{required(action()) => String.t()}
```

Behavior 作者写一个 map。无宏，无 DSL，无独立 "boot 时注册" 步骤。

### 5.2 `Entity.holds_cap?/2` callback（默认实现 + wildcard 语义）

加到 `Ezagent.Kind`（Entity 契约 — Entity 是带 persistence + identity 的 Kind）：

```elixir
@doc """
本 entity 的持久状态是否授予给定 cap 字符串？

默认实现读 `slice[:identity][:caps]` 并按 glob（`*` = wildcard 段）匹配。
仅 cap 来源非标准时（少见）plugin 作者 override。
"""
@callback holds_cap?(entity_slice :: map(), cap_string :: String.t()) :: boolean()

# 由 Ezagent.Kind 提供默认实现（具体 Kind 除非 override 否则继承）。
# 遍历 cap 列表，按 §5.4 wildcard 语义 glob-match 每个持有的 cap 与
# 所需字符串。
def holds_cap?(slice, cap_string) when is_binary(cap_string) do
  caps = get_in(slice, [:identity, :caps]) || []
  Enum.any?(caps, &Ezagent.Cap.matches?(&1, cap_string))
end
```

`Ezagent.Cap.matches?/2`（`apps/ezagent_core/lib/ezagent/cap.ex` 新辅助模块）：
- `matches?("*", _needed)` → true（admin wildcard）
- `matches?("chat.*", "session.chat.send")` → true（kind-glob）
- `matches?("session.chat.*", "session.chat.send")` → true（action-glob）
- `matches?("session.chat.send", "session.chat.send")` → true（精确）
- `matches?("session.chat@session://X", "session.chat.send@session://X")` → true（instance-scoped 同 instance）
- `matches?("session.chat@session://X", "session.chat.send@session://Y")` → false（不同 instance）
- `matches?("session.chat", "session.chat.send")` → true（behavior 级 cap 授该 behavior 的所有 action — 保留 cap struct "无 action 字段" 语义）

匹配器 ~50 LOC，完整单测，无外部依赖。

### 5.3 Dispatch step 5.5 简化

今天 `apps/ezagent_core/lib/ezagent/kind/runtime.ex:215-239`（`authz_check/4`）读 `Capability.cap_for_action/3` + 通过 `Capability.matches?/2` 迭代 `ctx.caps` MapSet。本 SPEC 后：

```elixir
defp authz_check(kind_module, action, target, ctx) do
  behavior = lookup_behavior(kind_module, action)  # 同今天
  needed_cap = Map.fetch!(behavior.required_caps(), action)
  needed_with_instance = "#{needed_cap}@#{URI.to_string(Ezagent.URI.instance(target))}"

  caller_slice = read_caller_slice(ctx.caller)  # 经 Ezagent.Identity.get_slice/1

  if kind_module.holds_cap?(caller_slice, needed_with_instance) do
    :telemetry.execute([:ezagent, :authz, :granted], %{}, meta(ctx, target, action, needed_with_instance))
    :ok
  else
    :telemetry.execute([:ezagent, :authz, :denied], %{}, meta(ctx, target, action, needed_with_instance))
    {:error, :unauthorized}
  end
end
```

关键变化：
- `ctx.caps` 消失。Cap 检查通过 `read_caller_slice/1`（经 `Ezagent.Identity.get_slice/1` — 轻量 ETS 查找，非 dispatch）直接读 caller slice。这坍缩了 "caller 必须预先把 cap 加载到 ctx" 模式，该模式强迫每个 dispatcher 要么提前知道 cap 要么回退 `User.admin_caps()`。
- `Capability.matches?/2` 消失 — 由 `Kind.holds_cap?/2` 替代，委托给 `Ezagent.Cap.matches?/2`。
- `Capability.cap_for_action/3` 消失 — 由 `Behavior.required_caps()[action]` 查找替代。

### 5.4 Cap 字符串格式（canonical 语法）

```
cap_string := all_wildcard | scoped_cap
all_wildcard := "*"
scoped_cap := authority [ "@" instance_uri ]
authority := kind "." behavior ( "." action | ".*" )?
kind := atom_string | "*"
behavior := atom_string | "*"
action := atom_string
instance_uri := URI.t() 字符串形式

例：
"*"                                          # admin all
"session.*"                                  # 所有 session-kind action
"session.chat"                               # 所有 session.chat.* action
"session.chat.send"                          # 特定 action
"session.chat@session://default/team/main"   # 一个 session 上所有 chat action
"session.chat.send@session://default/team/main"  # 一个 session 上一个 action
"cross-workspace:*"                          # 跨 workspace 旁路 cap（§5.5）
```

该语法是现有 `Capability.Parser` 语法的严格扩展 — 今天 CLI 接受的每个字符串继续可用。

### 5.5 Workspace 隔离分离（按 OQ-CC-2）

`Behavior.workspace_scoped?/0`（新可选 callback，默认 `true`）：

```elixir
@doc """
dispatch 是否对本 Behavior 上 action 强制 workspace 隔离？

默认 `true` — caller 的 workspace 必须匹配 target 的 workspace，
OR caller 持有 `"cross-workspace:*"` cap，OR caller 是
workspace://system 的成员。

操作跨 workspace 数据的 Behavior（如 system://、template://、resource://）
override 为 `false`。今天的例子：System Kind 上的 `Behavior.Routing`、
跨 workspace template lookup 的 `Behavior.Template`。
"""
@callback workspace_scoped?() :: boolean()
```

Dispatch step 5.6 读本 callback 替代 cap struct 的 `workspace_uri: :any` 谓词：

```elixir
defp workspace_isolation_check(behavior, target, ctx) do
  if behavior.workspace_scoped?() do
    caller_ws = workspace_of_caller(ctx.caller)
    target_ws = Ezagent.URI.workspace_of(target)

    cond do
      caller_ws == :any -> :ok                                 # system caller
      target_ws == :any -> :ok                                 # 跨 workspace target
      caller_ws == target_ws -> :ok                            # 同 workspace
      caller_holds?(ctx.caller, "cross-workspace:*") -> :ok    # 显式旁路 cap
      caller_in_system_workspace?(ctx.caller) -> :ok           # 成员旁路（Phase 9 PR-8）
      true -> {:error, :cross_workspace_denied}
    end
  else
    :ok
  end
end
```

Cap struct 的 `workspace_uri` 字段消失；隔离是 per-Behavior 数据 + per-caller 成员关系。

### 5.6 FacadeNonceTable 交互（保留）

External-mirror-audit 的 `FacadeNonceTable`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex`）不变。Nonce 保护 facade Task 与 action body 间的 trust-transfer — 它是独立的防伪造原语，在 cap 检查之下操作。本 SPEC 后：

- Facade 仍通过新 `holds_cap?` 流程运行 Gate 1、2、3（3 个 cap-check 调用点更新为读 `required_caps/0` + `Kind.holds_cap?/2`）。
- Gate 4（target_ownership_check）不变 — 是 adapter I/O，不是 cap 检查。
- FacadeNonceTable claim/consume 不变。
- Dispatch step 5.5 仍作 defense-in-depth — external-mirror-audit §6 的 invariant test 继续验证。

### 5.7 Cap 检查调用点迁移

| 表面 | 数量 | 迁移 |
|---|---|---|
| `Capability.matches?/2` 直接调用 | 4 个生产 + ~30 个测试 | 删生产调用（dispatch 处理）；测试调用迁到 `Ezagent.Cap.matches?/2` |
| `CapabilityRegistry.register/3` 调用 | 5 个点 | 删 — Behavior 通过 `required_caps/0` callback 声明；compiler 读 |
| `CapabilityRegistry.needed_for/3` 调用 | 0 个生产（仅 dispatch 内部） | 与模块一起删 |
| `CapabilityRegistry.lookup_subject/2` 调用 | 4 个点（多为测试断言注册） | 删；测试迁到 `Behavior.required_caps()[:action]` 直接调用 |
| `Identity.list_caps_for/1` 调用 | 22 个点（LV mount、MCPServer、BindingPolicy 等） | 删该函数；dispatch 直接读 slice。需要列表 *显示* 的 LV mount 用新 `Identity.read_caps_for_display/1`（只读，不 dispatch，返回 `[String.t()]`） |
| `Identity.grant_cap/3` 调用 | ~10 个点 | 替换为 `Ezagent.Entity.add_cap/3(entity_uri, cap_string, granter_uri)` — 经 `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 上的 dispatch 直接 slice 变更（cap_string 是参数；dispatch step 5.5 按 data-ownership-v2 验证 granter 对 data owner 持有 `"user.identity_admin.grant_cap"`） |
| `Identity.revoke_cap/3` 调用 | ~5 个点 | 同 grant_cap 模式 |
| Plugin 代码内联 `MapSet.member?(caps, ...)` cap 检查 | ~8 个点（LV、Feishu、NP、CC） | 删 — 这些是 cap 检查泄漏到非 dispatch 表面的症状。经相关 Behavior 上的 dispatch |
| `Behavior.Identity.check_grant_authorized/2`（200 LOC） | 1 个模块 | 把逻辑移入 dispatch step 5.5 — data-ownership-v2 的 owner 检查现在是标准 cap 检查路径的一部分 |
| `Behavior.ExternalMirror` facade Gate 1、2、3 | 1 个模块 | 更新为读 `required_caps/0` + `holds_cap?/2`；逻辑形态保留 |

总触及文件：~50-70 跨 PR CC-2a..2d（按 §7.2 子拆分）。

### 5.8 数据迁移

现有 `users.caps_json` 行存 `[%{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`。一次性转换脚本（`apps/ezagent_core/priv/repo/data_migrations/20260525_caps_to_strings.exs`）：

```elixir
defmodule CapMigration do
  def convert(%{"kind" => "any", "behavior" => "any", "instance" => "any"}), do: "*"

  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => "any"}) do
    "#{kind}.#{deatomize_behavior(behavior)}"
  end

  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => instance_str}) do
    "#{kind}.#{deatomize_behavior(behavior)}@#{instance_str}"
  end

  defp deatomize_behavior("any"), do: "*"
  defp deatomize_behavior("Elixir.Ezagent.Behavior." <> name), do: Macro.underscore(name)
end
```

Workspace 维度丢弃（按 OQ-CC-6）— instance URI 结构性携带 workspace 信息。Provenance（`granted_by`、`granted_at`）按 OQ-CC-6 子问题丢弃。

脚本：
1. 读每行 `users`。
2. JSON-decode `caps_json`。
3. 经 `CapMigration.convert/1` 转每个 cap map 为字符串。
4. 写回新 JSON 字符串列表。
5. `caps_schema_version` 列从 `1` 升到 `2`。

Application boot 读 `caps_schema_version` — 若是 `1`，以 `MIGRATION_REQUIRED` log 行拒启。按 Phase 9 SPEC v3 §8 惯例。Dev `mix ezagent.reset` 重新生成。

### 5.9 Plugin 作者流程（北极星回报）

本 SPEC 后，添加带新 "create session" action 的 `Plugin.CC` 的 plugin 作者写：

```elixir
defmodule Ezagent.Plugin.CC.Behavior.CreateSession do
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:create]

  @impl true
  def required_caps, do: %{create: "session.create_session.create"}

  @impl true
  def workspace_scoped?, do: true

  @impl true
  def invoke(:create, slice, args, ctx) do
    # 普通 action body。无 cap 检查代码。Dispatch 已 gate。
    # 无 admin 回退。ctx.caller 是真实 principal。
    # 无 ambient authority。被 create 的 Session 结构性
    # 在其 created_by 字段携带 ctx.caller。
    new_session = build_session(args, created_by: ctx.caller)
    {:ok, Map.put(slice, :sessions, [new_session | slice.sessions])}
  end
end
```

Plugin 作者的 cap 系统接触总面：2 行 callback（`required_caps/0`、`workspace_scoped?/0`）。永不接触 `CapabilityRegistry`（删）、`Capability` struct（删）、`Identity.grant_cap`（重命名 + 仅 dispatch）、`User.admin_caps`（删）。

这就是北极星：plugin 作者远离 core（memory `feedback_north_star_plugin_isolation`）。

---

## 6. Issue 3 — 经 `:ezagent_plugin_check` 的编译期强制

### 6.1 现有 compiler 扩展

`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` 长出三个新 check（~80 LOC）：

```elixir
# 新 check 8 — 每个 @behaviour Ezagent.Behavior 模块导出 required_caps/0
defp check_required_caps_exported(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_kind, _action, behavior} -> behavior end)
  |> Enum.uniq()
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    cond do
      not function_exported?(behavior, :required_caps, 0) ->
        [diagnostic("#{inspect(behavior)} (a declared Behavior) does not " <>
          "export required_caps/0. Every Behavior MUST declare per-action " <>
          "cap strings (caps-cleanup-v1 SPEC §5.1).") | acc]

      true ->
        acc
    end
  end)
end

# 新 check 9 — required_caps/0 key 等于 actions/0
defp check_required_caps_keys_match_actions(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_, _, b} -> b end)
  |> Enum.uniq()
  |> Enum.filter(&function_exported?(&1, :required_caps, 0))
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    declared_actions = MapSet.new(behavior.actions())
    cap_keys = MapSet.new(Map.keys(behavior.required_caps()))

    cond do
      declared_actions == cap_keys -> acc

      true ->
        missing = MapSet.difference(declared_actions, cap_keys)
        extra = MapSet.difference(cap_keys, declared_actions)
        [diagnostic("#{inspect(behavior)}: required_caps/0 keys must " <>
          "equal actions/0 exactly. Missing: #{inspect(MapSet.to_list(missing))}; " <>
          "extra: #{inspect(MapSet.to_list(extra))} (SPEC §6).") | acc]
    end
  end)
end

# 新 check 10 — 每个 required_caps/0 值是 binary
defp check_required_caps_values_are_strings(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_, _, b} -> b end)
  |> Enum.uniq()
  |> Enum.filter(&function_exported?(&1, :required_caps, 0))
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    bad = Enum.reject(behavior.required_caps(), fn {_k, v} -> is_binary(v) end)

    if bad == [] do
      acc
    else
      [diagnostic("#{inspect(behavior)}: required_caps/0 values must be " <>
        "cap strings (binary). Offending entries: #{inspect(bad)} (SPEC §6).") | acc]
    end
  end)
end
```

接入现有 `run/1` pipeline：

```elixir
diagnostics =
  []
  |> check_uses_behaviour(plugin_module)
  |> check_declared_modules(plugin_module)
  |> check_agent_flavors(plugin_module)
  |> check_adapters(plugin_module)
  |> check_spawns_empty(plugin_module)
  |> check_config_surface(plugin_module)
  |> check_no_direct_registry_calls()
  |> check_required_caps_exported(plugin_module)        # 新
  |> check_required_caps_keys_match_actions(plugin_module)  # 新
  |> check_required_caps_values_are_strings(plugin_module)  # 新
```

另加：`ezagent_core` 自身需要对住在 `ezagent_core` / `ezagent_domain_*` 的 `@behaviour Ezagent.Behavior` 模块作并行检查（compiler 对每个 app 运行，wiring 相同）。每个 domain app 已在 `mix.exs` 接入 `:ezagent_plugin_check`（或在 PR-CC-3 加上）。

### 6.2 失败模式

- 缺 `required_caps/0` → 以 `(ezagent_plugin_check) Ezagent.Behavior.X (a declared Behavior) does not export required_caps/0...` 失败 build。
- Key 与 `actions/0` 不匹配 → 以 missing + extra key 的 diff 失败 build。
- 非字符串值 → 以错误条目列表失败 build。

按 memory `feedback_let_it_crash_no_workarounds`：无 warning + degrade。Build 失败。CI 在合并前抓住。

---

## 7. 迁移计划（3 个 PR，有序）

### 7.1 PR-CC-1 — Issue 1（Ambient authority 移除）

**分支:** `feat/caps-cleanup-pr1-ambient-authority`
**工作量:** 3-5 天（聚焦；14 个 principal × 播种 + ~30 个生产调用点迁移）。

范围：
- 加 `Ezagent.SystemPrincipal` 模块（§4.2）。
- 在所属 Application `start/2` 中播种 14 个 principal（§4.1）。
- 迁移 30 个生产调用点：`User.admin_caps()` → `SystemPrincipal.caps(...)` 按目录。
- 迁移 21 个测试点 — 多数变 `SystemPrincipal.test_principal("test-xyz")`（测试专用辅助，以任意 cap 产 principal）。
- 删 `Ezagent.Entity.User.admin_caps/0`（let-it-crash — 残余调用点 build 失败；清扫跟进）。
- 加 §4.5 invariant test。
- 审计日志已接受非 `entity://` URI — 无 schema 变更。

验收：
- `grep -rn "User.admin_caps" apps/ | grep -v test/support` 返回 0 行。
- 所有现有测试通过。
- §4.5 invariant test 通过。
- `/admin/audit` 在至少 3 个独立 system 操作上显示 `system://` caller。

独立于 PR-CC-2 — 可独立出货。

### 7.2 PR-CC-2 — Issue 2（Caps 在 Behavior × Entity）

最大的 PR。子拆分为 4 个 sub-PR 以使每个可 review：

**PR-CC-2a — 加新原语（additive，无删除）：**
- `Ezagent.Cap.matches?/2`（字符串匹配器，§5.2）。
- 在 `Ezagent.Behavior` 声明 `Behavior.required_caps/0` callback（强制；初期作为新可选 callback）。
- `Behavior.workspace_scoped?/0` callback（可选，默认 true）。
- `Kind.holds_cap?/2` 默认实现（additive）。
- 每个 Behavior 实现 `required_caps/0`（29 个 Behavior × 每个 2 行新增）。此时新旧路径并存。

**PR-CC-2b — 切 dispatch 到新路径：**
- Dispatch step 5.5 按 §5.3 重写（读 `required_caps/0`，调 `holds_cap?/2`）。
- Dispatch step 5.6 按 §5.5 重写（读 `workspace_scoped?/0`，丢 cap struct workspace 字段读）。
- 所有测试通过新路径。旧 `Capability.matches?/2` 仍存但未用。

**PR-CC-2c — caps slice + cap 检查调用点迁移：**
- 数据迁移脚本（§5.8）— wipe-dev，对 staging/prod 跑脚本。
- `caps_schema_version` 升到 2。
- 按 §5.7 表迁移所有 `Identity.list_caps_for/1` 调用点（22）。
- 按表迁移所有 `Identity.grant_cap/3` 调用点（~10）。
- 迁移 plugin LV 中内联 `MapSet.member?` cap 检查。
- 更新 `Behavior.Identity.invoke(:grant_cap, ...)` 消费 cap 字符串。
- 更新 `Behavior.ExternalMirror` facade Gate 1、2、3 到新 API（保留 FacadeNonceTable）。

**PR-CC-2d — 删旧机器：**
- 删 `Ezagent.Capability` struct（`apps/ezagent_core/lib/ezagent/capability.ex`）。
- 删 `Ezagent.CapabilityRegistry`（`apps/ezagent_core/lib/ezagent/capability_registry.ex` + `apps/ezagent_core/lib/ezagent/capability_registry/`）。
- 删 `Ezagent.Identity.list_caps_for/1`、`grant_cap/3`、`revoke_cap/3`（导出替换为 `Ezagent.Entity.add_cap/3`、`remove_cap/3`、`read_caps_for_display/1`）。
- 删 `Behavior.cap_subjects/0` callback（按 OQ-CC-3 坍缩 — 由 `required_caps/0` 替代）。
- 删 `Behavior.dispatchable?/0` callback（按 OQ-CC-3 — cap-only Behavior 移除；Presence + Sandbox 变正常可 dispatch Behavior）。
- 更新 `Capability.Parser` → `Cap.Parser`（CLI 语法同）。

**工作量:** 跨 4 个 sub-PR 2 周（CC-2a = 2 天，CC-2b = 2 天，CC-2c = 5 天，CC-2d = 2 天）。

每个 sub-PR 验收：
- 2a：所有 Behavior 导出 `required_caps/0`；CI 绿；dispatch 侧尚未改。
- 2b：Dispatch 用新路径；`[:ezagent, :authz, :granted]` telemetry 带新形态，`needed_cap` 为字符串。
- 2c：所有 env 上 `caps_schema_version == 2`；旧 cap 检查调用点全迁；§G2 grep 返回 0 结果。
- 2d：旧模块已删；build 绿；grep `Capability\.matches\|CapabilityRegistry\|admin_caps` 返回 0 结果。

### 7.3 PR-CC-3 — Issue 3（编译期强制）

**分支:** `feat/caps-cleanup-pr3-compile-time-gate`
**工作量:** 1-2 天。

范围：
- 按 §6.1 加 3 个新 check 到 `:ezagent_plugin_check` compiler。
- 接入 compiler 到每个 domain app 的 `mix.exs`（尚未的 — 审计显示多数已有，但 `ezagent_core` 自身不对自己的 Behavior 跑 gate；新 check 也应跑 core + domain）。
- 验证 build 在以下情况失败：
  - 加 `actions: [:foo]` 的 Behavior 但 `required_caps/0` 无 `:foo` key。
  - Behavior 的 `required_caps/0` 返回 `%{foo: :not_a_string}`。

验收：
- 故意破坏的 fixture Behavior 以精确诊断失败 build。
- 所有现有 Behavior 通过新 check（PR-CC-2a 已为它们加 `required_caps/0`）。

---

## 8. 验收准则（每 PR）

| PR | Gate |
|---|---|
| CC-1 | (a) Invariant `no_admin_caps_fallback_test.exs` 通过；(b) `grep -rn "User.admin_caps" apps/lib` 返回 0 行；(c) `/admin/audit` 在 fresh boot 5 秒内显示 boot-reconciler dispatch 的 `system://` URI |
| CC-2a | 全部 29 个 Behavior 导出 `required_caps/0`；`mix test apps/ezagent_core` 绿 |
| CC-2b | Dispatch `[:ezagent, :authz, :granted]` telemetry payload 含 `needed_cap` 为 binary；全测试运行中旧 `Capability.matches?/2` 调用 0 次（经 :telemetry hook 在 invariant test 验证） |
| CC-2c | `caps_schema_version == 2`；全部 22 个 `list_caps_for/1` 调用点删除（grep `Identity\.list_caps_for` test/support 外返回 0）；带 seed cap 的现有 user 迁后对其 session 仍授权（e2e test） |
| CC-2d | `Capability`、`CapabilityRegistry`、`Identity.{list_caps_for,grant_cap,revoke_cap}` 模块 / 函数删除；`mix compile` 绿；全测试套件绿 |
| CC-3 | 故意破坏的 fixture Behavior 以 `(ezagent_plugin_check)` 诊断失败 build；现有 Behavior 全通过 |

---

## 9. Invariant test（按 `feedback_completion_requires_invariant_test` 的架构 gate）

每个 issue 的结构目标由当目标未达成时失败的测试 gate — 这些是防止未来回归的锁。

### 9.1 G1 — Ambient authority 消失

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs`（§4.5）：
1. 无生产文件调用 `User.admin_caps/0`。
2. `User` 模块不导出 `admin_caps/0`。

### 9.2 G2 — Caps 仅在 Behavior × Entity 边界

`apps/ezagent_core/test/invariants/caps_only_at_boundary_test.exs`（新）：

```elixir
test "no production module calls Capability.matches? / cap_subjects / list_caps_for / grant_cap" do
  allowed_paths = [
    "apps/ezagent_core/lib/ezagent/behavior",       # Behavior callback 定义
    "apps/ezagent_core/lib/ezagent/entity",         # Entity holds_cap? 默认
    "apps/ezagent_core/lib/ezagent/invocation",     # Dispatch
    "apps/ezagent_core/lib/ezagent/kind",           # Kind runtime
    "apps/ezagent_core/lib/ezagent/cap.ex",         # 匹配器本身
    "apps/ezagent_domain_identity/lib/ezagent"      # Identity facade（只读路径）
  ]

  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.reject(fn p ->
      String.contains?(p, "test/support") or
        Enum.any?(allowed_paths, &String.starts_with?(p, &1))
    end)
    |> Enum.filter(fn p ->
      File.read!(p) =~ ~r/Ezagent\.Capability\.(matches|cap_for_action)|cap_subjects\(|list_caps_for\(|Identity\.grant_cap\(/
    end)

  assert offenders == [],
         "caps escaped the Behavior×Entity boundary into: #{inspect(offenders)}"
end
```

### 9.3 G3 — 编译期强制非可旁路

`apps/ezagent_core/test/invariants/required_caps_compile_gate_test.exs`（新）：

```elixir
test "build fails when a Behavior omits required_caps/0" do
  # 在 tmp/ 下创建 fixture app，复制 minimal mix.exs + 一个带
  # actions/0 但无 required_caps/0 的 Behavior，跑 mix compile，
  # 断言 build 以 ezagent_plugin_check 诊断失败。
  fixture = create_broken_fixture(omit: :required_caps)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "(ezagent_plugin_check)"
  assert output =~ "does not export required_caps/0"
end

test "build fails when required_caps/0 keys differ from actions/0" do
  fixture = create_broken_fixture(mismatch_keys: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must equal actions/0 exactly"
end

test "build fails when required_caps/0 has a non-string value" do
  fixture = create_broken_fixture(non_string_value: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must be cap strings"
end
```

3 个 sub-test 覆盖 §6.2 的 3 种失败模式。每个 spawn 真实 `mix compile` 到 fixture 以验证 gate 不可旁路。

---

## 10. 风险 + 回滚

### 10.1 风险 — PR-CC-2 进行中与并发 SPEC 冲突

`feat/workspace-default-to-system-impl`（#335）和 `feat/agent-duplicate-simple-from-flag`（#338）在进行中。两者都邻接触 cap。缓解：PR-CC-1 独立可先落地；PR-CC-2 等它们合并 OR 协调同步 rebase。

### 10.2 风险 — 生产陈旧状态的数据迁移

若生产 user 有 `CapMigration.convert/1` 未预见的 cap 形态，脚本 raise。缓解：先在快照上 dry-run；脚本记录每次转换；失败带涉事 row UUID 报告供手动修复。按 `feedback_let_it_crash_no_workarounds`，无回退 — 暴露未知形态优于静默默认。

### 10.3 风险 — Cap 字符串拼写错误通过编译但运行时失败

Behavior 作者写 `required_caps: %{send: "session.chta.send"}`（笔误）。Build 通过（是 binary）。运行时 dispatch 对 `"session.chta.send"` 检查，无 caller 持有 → 所有 dispatch 拒绝。

缓解：对首次 dispatch 比较 cap 字符串的 kind/behavior 前缀与 Behavior 实际 `state_slice/0` + parent Kind 的软运行时检查（warn-only）。若不匹配，emit `:telemetry` warning。一旦约定形成可由未来 PR 提升为硬失败。编译期检查需要 Behavior-to-Kind 解析，对 plugin boot-order 敏感 — 停留 runtime 保持简单。

### 10.4 回滚

每个 sub-PR rebase-and-revert 干净。迁移脚本是单向（无 undo）— `caps_schema_version` 升是 Rubicon。回滚到 PR-CC-2c 之前需要 DB 恢复，非代码 revert。这可接受，因为抹掉重建模式匹配 Phase 9 SPEC v3 §8 且该部署故事是 Allen 明确选择。

---

## 11. 范围外（futures）

- **Cap provenance 审计表** — 若未来用例需要 "谁授我 cap X"，`cap_grants(grantee_uri, cap_string, granter_uri, granted_at)` 表 additive 落地，不改 cap 形态。
- **Role bundle** — 把 "frontend-admin" 作为命名 cap 字符串 bundle 授权的操作员 UX 是 UI feature，非结构变化。Cap 形态不变；bundle 是 grant 时的 server 端展开。
- **跨 workspace cap delegation** — 今天只 admin 持有 `"cross-workspace:*"`。未来 SPEC 可允许 per-Behavior 跨 workspace 授权（如 "User-X 可跨 workspace dispatch chat action"）。会作新 cap 字符串语法落地（可能 `"session.chat@*"`）；与本 SPEC 正交。
- **Cap 过期 / TTL** — caps 今天持久。若 TTL 变需要，cap 字符串格式长出 `;expires=<iso8601>` 后缀；匹配器运行时检查。正交。

---

## 12. r2 codex review 排序

本 SPEC 按 dispatch prompt 有 Round-2 cap。若 codex r1 返回的 HIGH/CRIT finding 集中于：

- **OQ-CC-1 / 2 / 6**（cap 表示选择）— in-SPEC 修并重交。
- **§5.7 迁移表准确性**（真实调用点数与估计不符）— 重 grep、更新表、重交。
- **§9 invariant test 欠规定** — 强化断言。

若 r2 仍 HIGH/CRIT 升级到 Allen。按 memory `feedback_spec_codex_adversarial_review`。
