# SPEC — Capabilities 即数据所有权（框架级 invariant）

**状态：** rev 3（DRAFT）· 2026-05-25
**Tier：** `apps/ezagent_core/`（框架级 invariant + 一个新的 `Ezagent.Behavior` callback）
**触发：** Allen 2026-05-24（Feishu）—— "本质上每个 caps 都是对一类数据的 CRUD 操作的授权，bind 的操作是对什么数据进行的授权，caps 就应该由那个数据（或其创建者）赋权"
**前置：**
- SKILL P15（CapBAC shape；`module()` 不是 atom；scope 形状只收窄）
- SKILL P11 / P1（plugin isolation 北极星；receiver Kind 注册到已有 scheme）
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4（`Ezagent.CapabilityRegistry` —— cap-subject 单入口注册中心）
- `apps/ezagent_core/lib/ezagent/capability.ex:28-43`（`%Capability{}` 6 字段：`kind, behavior, instance, workspace_uri, granted_by, granted_at`；**没有 `action` 字段**）
- `apps/ezagent_core/lib/ezagent/capability_registry.ex`（`register/3`、`register_default_grant/2`、`needed_for/3`、`default_grants_for/2`）
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` moduledoc §"Tightened admin predicate" + §"Threat model" —— PR #303 HIGH-3 修复
**排序：** 在 `ExternalMirror r3` **之前**落地；r3 的 `Behavior.ExternalMirror` 的 `data_owner/1` 返回 `session_owner`，默认 grant 规则 "session 所有者在 session 创建时自动获得自己 session 上的 `Behavior.ExternalMirror` cap" 是从本 SPEC 结构性导出的 —— 即 r3 不能在 `data_owner/1` callback 进 core 之前合并。
**对应：** `2026-05-24-caps-data-ownership-v2.md`（英文主版本；遵循 memory `feedback_bilingual_docs_convention`）。

---

## 0. r2 修订说明（相对 r1 的变化）

r1 被 codex 标记为 needs-attention（2 CRITICAL + 3 HIGH）。r2 结构性修复所有五项：

1. **CRITICAL-1 修复。** Cap 是 **Behavior 级，不是 action 级**。`%Capability{}` 没有 `action` 字段（`apps/ezagent_core/lib/ezagent/capability.ex:28-29`）；持有 `Behavior.X` 上的 cap 授权持有者执行 X 的**所有** action。因此 cap 保护的 data class 是 **Behavior 本身代表的目的**，不是单个 action。r1 的 3 元组 `(Kind, Behavior, action)` audit 表是错的；r2 用 2 元组 `(Kind, Behavior)`，附一列仅供参考的 "Behavior 暴露的 action"，从每个 Behavior 的真实 `cap_subjects/0` 读出。
2. **CRITICAL-2 修复。** `data_owner/1` 签名扩宽：接受存储 cap 可能持有的相同 `instance` 形状（`URI.t() | :any | scope_tuple()`），返回 `URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}`。每种形状的 grant 语义见 §3.1。
3. **HIGH-1 修复。** PR 顺序重排，确保每个 PR 的验收测试只依赖本 PR 或更早 PR 引入的代码。PR-OWN-1（框架 callback + audit，测试用 in-test 的 `TestBehavior` 和合成 `TestEntityKind`，不碰任何真实 Behavior）。PR-OWN-2（Session 迁移 —— 加 `Session.owner/1` 查询 + `Behavior.Chat` 的 `data_owner/1`）。PR-OWN-3+（其他 Behavior 在 PR-OWN-2 之后扩散）。
4. **HIGH-2 修复。** §6 audit 表从真实源码重建。每个 Behavior 的 `cap_subjects/0` 都直接读了文件；action 名已校正（例如 `Behavior.Echo` 暴露 `:say, :receive` —— r1 写的是 `:echo`；`Behavior.Workspace` 暴露 9 个 action —— r1 列了 6 个；`Behavior.CurlAgent` 暴露 `:receive, :reset_conversation, :configure` —— r1 写的是 `:request`；`FeishuOutbound` 暴露 `:notify_external` —— r1 写的是 `:send_to_feishu`）。
5. **HIGH-3 修复。** OQ-OWN-2（target-cap 同意机制）删除 —— dispatch 读的是 `ctx.caps` = caller 的 caps，永远不是 target 的；没有 dispatch 中途读 target caps 的机制。如果未来需要 target 端同意，需要单独的 consent-ledger 模型；放到未来 SPEC，§10（non-goals）里点名。

## 0a. r3 修订说明（相对 r2 的变化）

r2 被 codex 标记为 needs-attention（1 CRITICAL + 3 HIGH）。r3 结构性修复所有四项：

1. **CRITICAL 修复（wildcard cap）。** r2 的 §5.2 第 1 步无条件调用 `needed_cap.behavior.data_owner(needed_cap.instance)`。但 `%Capability{behavior: :any}` 是真实形状（例如 `User.default_caps/1` 铸造 `{kind: :session, behavior: :any, instance: :any, workspace_uri: user_ws}`）；`:any` 不是 module 所以调用会崩。r3 §5.2 加显式**前置检查**在 wildcard `behavior: :any` 和 `kind: :any` 形状上 fail closed —— 只有 bootstrap admin 能授予。记录为新规则 §5.2(0)。
2. **HIGH 修复（workspace_of 在非 URI 上）。** r2 的 §5.2 第 4 步（现在第 5 步）在 `owner == :any` 分支调 `Capability.workspace_of(needed_cap.instance)` —— 但 `instance` 可能是 `:any` 或 scope tuple，而 `workspace_of/1` 只为 `%URI{}` 规范（`apps/ezagent_core/lib/ezagent/capability.ex:319-345`）。r3 用 `needed_cap.workspace_uri` 做 workspace-admin 授权（cap struct 在 Phase 9 PR-3 后已经携带 workspace 维度）；对 `workspace_uri: :any` 或畸形 scope tuple，规则 fail closed。
3. **HIGH 修复（default-grant helper 丢失 grantee）。** r2 的 `default_grants_from_data_owner/2` 返回 `[Capability.t()]` —— 但 `%Capability{}` 携带 `granted_by`，不是 grantee 字段。Caller 没法知道把 cap 写进谁的 Identity slice。r3 把 helper 契约改成返回 `[{grantee_uri :: URI.t(), Capability.t()}]` 让 spawn 路径知道每个 cap 持久化在哪。§4.2 验收现在要求测试断言 spawn 后 cap 持久化在所有者的 Identity slice 上。
4. **HIGH 修复（FeishuOutbound 模块名）。** r2 的 audit 行 #22 命名 `Ezagent.PluginFeishu.Behavior.FeishuOutbound`。真实模块是 `EzagentPluginFeishu.Behavior.FeishuOutbound`（`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex:1`）。r3 在 en + zh_cn 都修了 audit 行，并加 PR-OWN-FINAL 显式验收：invariant 测试在 plugin boot 后把 `CapabilityRegistry` 条目与文档化的 Behavior 行交叉引用，未来本 SPEC 出现错命名的行就 CI 失败。

---

## 1. 问题陈述

今天 ezagent 里每个 capability 都是 `%Ezagent.Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}` struct（`apps/ezagent_core/lib/ezagent/capability.ex:28-43`）。`Capability.matches?/2` 对持有的 cap 与所需的 cap shape 做四字段 pattern match。`Ezagent.CapabilityRegistry`（PR #264）收集 cap **subject**（`{kind, action, behavior, description, dispatchable?}`），所以系统可以枚举 "有哪些 cap 可以被授予"。

但**没有任何地方收集**的问题是：**对一个给定的 cap，最初谁有权授予它？** 代码库里有一个隐式模式 —— User 在创建时自动获得自己 workspace 内 session-class data 的 `default_caps/1`；`workspace://X` 上路由规则修改 cap 隐式由任何持 admin cap 的人持有；notifications-admin cap 隐式由满足某个手写 predicate 的任何人持有。但是：

- 框架级没有规则说 "data D 上的 cap C 只能由 D 的所有者授予。"
- `Behavior` 上没有 callback 让 Behavior 作者声明 "我 gate data class D；D 的所有者是 `f(instance_uri)`。"
- `Behavior.Identity.grant_cap` 存在（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44`），但 caller 没有被结构性地检查 "你是不是这个 cap 关于的 data 的所有者" —— 只检查了 "你是否持有 target principal 上的 admin cap"。
- 写新 Behavior 的 plugin 作者每次都必须**自己发明**他们 cap subject 的信任模型。结果是漏洞百出的 predicate，散布在各个模块里。

### 这个隐式模型已经造成的具体故障

1. **PR #303（NotificationSubscriptions）HIGH-3 —— round-1 admin predicate 匹配了任何 `:any` cap，而不仅仅是 notifications-admin。**
   在 round-1 实现里，决定 "这个 caller 能不能把别人从 notifications 里取消订阅" 的 predicate 实际上是 `has_any_cross_workspace_cap?(caller)`。一个持有**窄**的跨 workspace cap（比如 `Behavior.Chat`）的 user 会静默满足这个 predicate，从而能够取消任何 notifications 订阅。Codex round-2 抓到了；修复方法是把 predicate 收紧成要求 `behavior == Ezagent.Behavior.Notifications AND workspace_uri == :any`（见 `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex:55-61`）。**根因：** predicate 没有结构性锚点 —— 它没法说 "这里的 data class 是 `notifications-stream-for-user-X`，只有这个 data class 的所有者（User X）或被 User X 授权的 delegate 才能授予 admin 级的取消订阅 cap。" 没有 `data_owner/1` callback，predicate 退回到自由形式的 cap pattern，而这个 pattern 碰巧太宽。

2. **`User.default_caps/1` 文档明说 `:any` 是循环依赖妥协。**
   `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:104-116` 给新 user 授予一个形如 `{kind: :session, behavior: :any, instance: :any, workspace_uri: user_ws}` 的 cap。`behavior: :any` 被记录（文件 85-92 行）为循环依赖妥协（identity 域不能引用 `Ezagent.Behavior.Chat`）。这意味着每个新 user 都得到一个 *workspace 级宽度，全 Behavior* 的 session-class cap，因为没办法表达 "这个 cap 实际上关于的 data 是 user **自己将要**生成的 sessions"。没有 `data_owner/1`，grant 的范围比 data 所有权所证明的更宽。

3. **`Behavior.Workspace` 的隐式 grantor 问题。**
   今天，作为 workspace admin（在 `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:60-73` 里的 9 个 action 中任意一个）的 cap 可被任何已持有该 workspace `Behavior.Workspace` cap 的人授予。但 workspace 的 data owner 是谁？代码说 "持 admin cap 的人。"workspace 本身没有记录的 `created_by` / `owner_uri`。如果有两个 admin cap 由不同的 `granted_by` 链铸造，两个都能授予；没人能说哪一个是结构性合法的。未来多 admin federation 会需要解决这个问题；当前代码隐式地推迟它。

4. **`system://routing/default` 上的路由规则没有所有者。**
   `Ezagent.Behavior.Routing` 注册到 System Kind（`apps/ezagent_core/lib/ezagent_core/application.ex:149-152`）—— 但 `system://routing/default` 没有 `created_by` URI。Cap 由 admin 通过 catch-all `instance: :any` 形状持有。没有 "谁能把全局 routing-admin cap 授予新 operator" 的答案，只是 "admin 能。" 这在 v1（单 admin）够用，但一旦出现第二个 admin 就脆弱。

### 为什么这对 ezagent 的 plugin-isolation 北极星（SKILL P1）重要

驱动其他每个决策的单一规则是 "plugin 作者远离 core。" 当 plugin 作者写一个有新 cap subject 的新 Behavior 时，他们今天得读 4-5 份深度文档（CapabilityRegistry SPEC、scope tuple Decision Log 条目、ARCHITECTURE §7.3 default_grants 散文、散布在 plugin 代码里的现有 predicate），然后**自己发明**信任模型。PR #303 HIGH-3 finding 显示连 reviewer 都会漏。

如果框架反过来问 plugin 作者**一个**问题 —— "对你 Behavior gate 的 data，返回它所有者的 URI" —— 那么：

- Default grant 结构性导出（所有者在创建时获得自己 data 上的 cap）。
- grant-cap 入口可以执行 "caller 必须拥有这个 data 或持有回溯到所有者的委托链"。
- admin predicate 的问题消失：没有 "admin 级 predicate" 要写 —— 只有 "我拥有这个 data，所以我能授予" + "我被授予了委托，所以我能代表所有者授予"。

一句话原则：**capability 是对一类数据的授权；数据的所有者（或代表所有者的 creator）是唯一合法的 grantor。**

---

## 2. 心智模型

四个名词，定义精确以让 SPEC 后面有无歧义指代。**重要框架**：ezagent 实际的 `%Capability{}` struct 没有 `action` 字段 —— cap 绑定 `{kind, behavior, instance, workspace_uri}`，授权持有者执行该 Behavior 暴露的**所有** action。数据所有权的单位因此是 **Behavior**，不是 action。

1. **Cap subject（存储形式）** = cap struct 存储的**三元组 `{kind, behavior, instance_or_:any}`**。Action 通过 `Behavior.cap_subjects/0` 暴露用于 catalog / docs / `mix ezagent.caps.list`，但**不在** cap struct 里，**不是** grant 的单位。持有 `%Capability{kind: :session, behavior: Behavior.Chat, instance: S, workspace_uri: W}` 授权 `Behavior.Chat` 的**全部** action（`:send`、`:receive`、`:join`、`:leave`、`:set_working_copy`）在 S 上。如果需要更细粒度的 gate，正确的结构性答案是**声明两个 Behavior**（例如 `Behavior.NotificationsReader` + `Behavior.NotificationsWriter`）—— 不是扩展 cap struct（见 OQ-OWN-6）。

2. **Data owner** = 对 Behavior gate 的数据类拥有唯一授予权的 URI（或哨兵 `:any` / `:no_owner`）。对于 per-tenant Behavior，data owner 是 target instance URI 的函数：
   - `entity://user/team-alpha/alice` 的 identity data 的所有者是 user 自己（`entity://user/team-alpha/alice`）。
   - `session://default/team-alpha/standup` 的 chat data 的所有者是 session 创建者（记录为 session slice 字段；查找规则见 §3.4）。
   - `workspace://team-alpha` 的路由 data 的所有者是 "任一 workspace admin"（cap-class —— workspace 本身是多 admin）。
   - `system://routing/default` 的所有者是 "仅 system admin"（`:no_owner` —— 没有 per-instance 所有者；只有 bootstrap-system 能授予）。

3. **Default grant** = 编码 "Behavior B 里任何新创建实例 D 的 data owner 自动获得 `{kind, B, D, workspace_of(D)}` cap" 的 bootstrap 规则。今天在分散的地方按 Kind 实现（`User.default_caps/1`；Session 和 Template Class spawn 路径有时授予，有时不）。SPEC 形式化这个规则：**对每个注册到 Kind K 的 Behavior B、每个新生成的 K 实例 D，框架给 `B.data_owner(D)` 返回的 URI 授予 cap `(K.type_name(), B, D, workspace_of(D))` —— 只要返回是具体的 `URI.t()`。** Behavior 作者不写 `default_grant_fn` —— 它从 `data_owner/1` 导出。

4. **Delegated grant** = "data 所有者通过记录在案的 grant action 显式地把 cap 授予另一个 entity。" 今天作为 `Behavior.Identity.invoke(:grant_cap, ...)` 变更 target principal 的 `:identity` slice 实现。SPEC 形式化前置条件：**`grant_cap` 的 caller 必须 (a) 是被授予 cap 的 data owner，OR (b) 持有之前由 data owner（或终止于所有者的委托链）授予的、被记录的委托 cap。**

两个 boundary case，框架必须显式命名：

- **Workspace 级 data**（例如 workspace 管理 action、workspace 级路由规则）：没有单一所有者 —— workspace 是设计上的多 admin。编码为 `data_owner/1` 返回 `:any`，意思是 "任何 workspace admin 授予。" admin 状态本身是 workspace 上的 cap（`Behavior.Workspace` cap），由成员身份 gate。
- **System 级 data**（例如 URI scheme registry、scheduler config、bootstrap 规则）：根本没有所有者。编码为 `data_owner/1` 返回 `:no_owner`。只有 bootstrap admin（`entity://user/system/admin`，作为结构性 invariant 持有 `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap，见 `apps/ezagent_core/lib/ezagent/capability.ex:193-202`）能授予。

---

## 3. 新的 Behavior callback：`data_owner/1`

### 3.1 签名

```elixir
@callback data_owner(instance :: URI.t() | :any | Ezagent.Capability.scope_tuple()) ::
            URI.t()
            | :any
            | :no_owner
            | {:scope, :within_session | :within_workspace | :spawned_by, URI.t()}
```

加到 `Ezagent.Behavior`，与已有的 `cap_subjects/0` 和 `dispatchable?/0` callback 并列（参见 `2026-05-23-capability-registry.md` §3.1）。标为 `@optional_callbacks` 保持向后兼容 —— 没定义的 Behavior 默认返回 `:no_owner`（最安全默认 —— 只有 system admin 能授予）。

函数被调用时传入存储 cap 实际携带的 `instance` 值。根据 `Ezagent.Capability`（`apps/ezagent_core/lib/ezagent/capability.ex:31-43`），这个值可以是三种形状之一：

| 输入形状 | 框架何时以此形状调用 | 含义 |
|---|---|---|
| `%URI{}` | Default-grant 时（每次 spawn）AND `grant_cap` 时（needed cap 指向具体实例） | 具体目标 —— Behavior 必须解析 **本** 实例的所有者 |
| `:any` | `grant_cap` 时（needed cap shape 是 `instance: :any`，即类别级 cap） | "整个类别的所有者是谁？" —— 大多数 Behavior 返回 `:any`（只有 workspace admin 类别级授予）或 `:no_owner`（只有 system admin） |
| `{:within_session, %URI{}}` / `{:within_workspace, %URI{}}` / `{:spawned_by, %URI{}}` | `grant_cap` 时（持有的 cap 用 scope 限界委托，Decision #137） | "scope 限界 cap 的授予者是谁？" —— Behavior 可解析 scope URI 的所有者（例如 `{:within_session, S}` → `Session.owner(S)`） |

四种合法返回形状：

| 返回 | 含义 | 谁能通过 `grant_cap` 授予 |
|---|---|---|
| `%URI{}` | Per-instance / per-scope 所有者 | 该 URI 的 principal，或持有链式 cap 的 delegate |
| `:any` | Workspace 级（任何 workspace admin 授予） | 任何持有 `workspace_of(needed.instance)` 上 `Behavior.Workspace` cap 的人 |
| `:no_owner` | System 级（没有 per-instance 所有者） | 只有 bootstrap admin（或显式 system 级 grant 的持有者） |
| `{:scope, scope_kind, scope_uri}` | 转发到 scope 的所有者 | 用 scope 的所有者；例如 `{:scope, :within_session, S}` 意味着 "Session.owner(S) 授予" |

第四种形状是给 gate scope 内 data 的 Behavior 用的桥梁（例如 `Behavior.Routing` 在 Session 上解析为 session owner；在 Workspace 上解析为 `:any`；在 System 上解析为 `:no_owner` —— 见 §3.3）。它让 Behavior 作者把查找推给合适的 scope，不必自己算所有者 URI。

每种输入 × 返回组合的具体例子：

```elixir
# 具体实例 —— 直接所有者
Behavior.Identity.data_owner(%URI{scheme: "entity", host: "user", ...})
#=> %URI{scheme: "entity", host: "user", ...}  （user 自己）

# 具体实例 —— scope 转发
Behavior.Routing.data_owner(%URI{scheme: "session", ...} = session_uri)
#=> {:scope, :within_session, session_uri}

# grant_cap 时的类别级查询 —— 大多数 Behavior 不允许
Behavior.Chat.data_owner(:any)
#=> :no_owner   # 类别级 Chat cap 需要 bootstrap admin

# Scope 限界持有 cap → 通过 scope 解析
Behavior.Chat.data_owner({:within_session, session_uri})
#=> {:scope, :within_session, session_uri}   # session 所有者授予
```

框架的 `Behavior.Identity.grant_cap` 入口（§5）用这个返回结构性地执行 grant 规则 —— Behavior 作者从不写自定义 predicate。

### 3.2 为什么是函数而不是静态字段

所有者是 instance URI 的函数，因为同一个 Behavior gate 多个实例，每个有自己的所有者。`Behavior.Chat` 在每个 session 上运行 —— 每个 session 有不同的创建者。函数形态让 Behavior 作者可以写一行对持久状态（`Ezagent.Persistence` 或 slice 本身）的查询，不把所有权烧进 Behavior 模块属性。

性能注：`data_owner/1` 在两个地方调用：
- Cap 创建 / default-grant 时（罕见；每 spawn 一次）。
- `grant_cap` 时（罕见；admin action）。

它**不**在热分发路径上（5.5 步的 `Capability.matches?/2` 只跑持有 cap struct；所有者问题在 grant 时已解析）。所以函数可以安全做 ETS 查询或小 DB 读。P22 的热路径纪律保持。

### 3.3 例子 —— 5 个现有 Behavior，`data_owner/1` 应返回什么

走真实文件（完整 audit 表见 §6）：

**`Ezagent.Behavior.Identity`**（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44`）—— 暴露 `:list_caps`、`:has_cap?`、`:grant_cap`、`:revoke_cap`；注册到 User + Agent（`apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:233-243`）：

```elixir
def data_owner(%URI{scheme: "entity", host: "user"} = uri), do: uri
def data_owner(%URI{scheme: "entity", host: "agent"} = uri) do
  # Agent 的 identity data 由其 spawner 拥有。
  case Ezagent.AgentLineage.lookup(uri) do
    {:ok, spawner} -> spawner
    :error -> uri   # bootstrap 时的 admin Agent：owner = self
  end
end
def data_owner(:any), do: :no_owner   # 类别级 Identity grant 只允许 bootstrap
def data_owner({:scope, _, _} = scope), do: scope
def data_owner({:within_session, _} = t), do: {:scope, elem(t, 0), elem(t, 1)}
# （以此类推 —— 三种 scope 都原样转发）
```

理由：User 的 identity data（cap 集合）由 User 自己拥有；User 可以从自己的持有里把 cap 授予另一个信任的 User。Agent 由 spawn 它的 principal（跑 `Agent.spawn/4` 的人或 orchestrator）拥有，所以 spawner 能给 agent 授予或撤销 cap。lineage 未知时（例如 bootstrap 时的 admin Agent），默认 agent 自己拥有自己的 data（这意味着只有 system-admin 能授予，因为 agent 在 bootstrap 路径里不能合法自授）。

**`Ezagent.Behavior.Chat`**（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:60`）—— 暴露 `:send`、`:receive`、`:join`、`:leave`、`:set_working_copy`；注册到 Session（前四个 action）和 User/Agent（`:receive`）（`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:453-461`）：

```elixir
def data_owner(%URI{scheme: "session"} = uri) do
  # Session 由 spawn 它的 principal 拥有
  # （PR-OWN-2 通过 Ezagent.Entity.Session.owner/1 加查询）。
  Ezagent.Entity.Session.owner(uri)
end
def data_owner(%URI{scheme: "entity", host: "user"} = uri), do: uri
def data_owner(%URI{scheme: "entity", host: "agent"} = uri) do
  case Ezagent.AgentLineage.lookup(uri) do
    {:ok, spawner} -> spawner
    :error -> uri
  end
end
def data_owner(:any), do: :no_owner
def data_owner({:within_session, s_uri}), do: {:scope, :within_session, s_uri}
def data_owner({:within_workspace, w_uri}), do: {:scope, :within_workspace, w_uri}
def data_owner({:spawned_by, p_uri}), do: {:scope, :spawned_by, p_uri}
```

理由：session 所有者可以把那个 session 上的任何 `Behavior.Chat` cap 授予别人（这就是 session 成员关系的工作方式）。User 在自己 URI 上的 `Behavior.Chat` cap（`:receive` 注册）属于 user 自己。

**`Ezagent.Behavior.Workspace`**（`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:60-73`）—— 暴露 9 个 action：`:list_members`、`:add_member`、`:remove_member`、`:list_templates`、`:add_template`、`:remove_template`、`:list_routing_rules`、`:set_routing_rules`、`:instantiate`；注册到 Workspace（`apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:44-46`）：

```elixir
def data_owner(%URI{scheme: "workspace"}), do: :any  # workspace 级
def data_owner(:any), do: :no_owner
def data_owner({:within_workspace, w_uri}), do: {:scope, :within_workspace, w_uri}
```

理由：workspace 是设计上多 admin；任何 workspace admin 都可以授予 workspace 管理 cap。admin 状态本身是 workspace 上的 `Behavior.Workspace` cap，由成员身份 scope（见 OQ-OWN-1 关于是否升级为单 `workspace_owner_uri`）。

**`Ezagent.Behavior.Routing`**（`apps/ezagent_core/lib/ezagent/behavior/routing.ex:62-69`）—— 暴露 `:add_rule`、`:delete_rule`、`:disable_rule`、`:enable_rule`；注册到 Workspace（`apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:54-56`）、Session（`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:471-473`）、System（`apps/ezagent_core/lib/ezagent_core/application.ex:149-152`）：

```elixir
def data_owner(%URI{scheme: "workspace"}),    do: :any         # workspace admin 授予
def data_owner(%URI{scheme: "session"} = uri), do: {:scope, :within_session, uri}
def data_owner(%URI{scheme: "system"}),       do: :no_owner    # 只有 bootstrap admin 授予
def data_owner(:any),                          do: :no_owner
def data_owner({:within_session, s}),          do: {:scope, :within_session, s}
def data_owner({:within_workspace, w}),        do: {:scope, :within_workspace, w}
```

理由：workspace 上的路由规则是 workspace 级 data；session 上的，session-owner 是授予者；`system://routing/default` 上的是 system 级（没有 per-instance 所有者，只有 bootstrap admin 能授予）。

**`Ezagent.Behavior.Template`**（`apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex:128`）—— 暴露 `:read`、`:write`、`:instantiate`、`:fork`；注册到 AgentTemplate + SessionTemplate（`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:499-502`）：

```elixir
def data_owner(%URI{scheme: "template"} = uri) do
  # Template 由写它的 principal 拥有（在 `:write` 时记录为 slice 字段；
  # PR-OWN-4 加 Template.writer/1）。在那之前，由 :any workspace admin
  # 拥有（pre-write template 没用）。
  Ezagent.Entity.Template.writer(uri) || :any
end
def data_owner(:any), do: :no_owner
def data_owner({:within_workspace, w}), do: {:scope, :within_workspace, w}
```

理由：Template 由写它的人拥有；那个所有者可以把 `:read` / `:fork` 授予别人。workspace 回退处理 bootstrap 情况（没有 writer 记录）。

### 3.4 Session.owner 查询 —— PR-OWN-2 加的是什么

**今天代码库里没有 `Session.owner/1` 函数**（通过对 `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` 的 `grep` 验证）。Session 在 spawn 时带 `owner_uri`（`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:121`），但这个值没存进任何可查询的 slice。PR-OWN-2 引入查询，有三种实现选项按优先级排序：

- **(a)** 在 `Behavior.Chat.init_slice/1` 加 `:owner_uri` 字段（最便宜 —— `Behavior.Chat.init_slice/1` 在每次 Session spawn 时已经运行；一行加）。
- **(b)** 加一个专用 `Ezagent.Entity.Session` slice 携带 `{owner_uri, created_at}` —— 概念上更干净但要新 Behavior 或扩展现有。
- **(c)** 从 URI segment 导出（`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:286-298` 的 `derive_session_uri/3` 把 owner_name 编码进 URI 本身：`session://<class>/<workspace>/<owner_name>-<template_name>`）—— 能用但需要把 owner_name 反查回 `%URI{}`（owner_name 是 display segment，不是完整 URI）。

PR-OWN-2 选 **(a)** 因为是一行 slice 加，不打架现有 spawn flow。`Session.owner/1` 变成通过 `Ezagent.Kind.Runtime.get_slice/2` 的 Kind state 读（其他查询已经用）。如果未来 SPEC 引入专用 Session entity 模块，查询可以迁移而不破 `Behavior.Chat.data_owner/1`。

---

## 4. Default-grant 迁移

### 4.1 结构性恒等式

`CapabilityRegistry.register_default_grant/2` 公共形态不变 —— 框架仍按 Kind 映射 `grant_fn :: (URI.t() | :any -> [Capability.t()])`。变的是 **Behavior 作者如何导出 grant_fn**：不再是手写函数，而是从 `data_owner/1` 机械导出。

规则，在框架里表述一次：

> 对每个注册到 Kind K 的 Behavior B、每个新创建的 K 实例 `target_uri`，框架给 `B.data_owner(target_uri)` 返回的 URI 授予 cap `%Capability{kind: K.type_name(), behavior: B, instance: target_uri, workspace_uri: Capability.workspace_of(target_uri), granted_by: bootstrap_or_owner_uri, granted_at: now}` —— 只要返回是具体的 `URI.t()`。返回 `:any` / `:no_owner` / `{:scope, _, _}` 时**不产生** default grant（那些 subject 依赖 `grant_cap` 显式授予）。

这就是**可导出的** default-grant 规则。正确声明 `data_owner/1` 的 Behavior 作者免费获得正确的 default grant。注意 cap 是 **per-Behavior**，不是 per-action —— 一个 default grant 在那个实例上授权持有者执行该 Behavior 的所有 action，匹配 cap struct 的真实语义。

### 4.2 什么保持，什么改变

**保持不变：**
- `%Capability{}` struct（仍 6 字段 —— `kind, behavior, instance, workspace_uri, granted_by, granted_at`）。
- `Capability.matches?/2` 语义（仍对四个 `kind/behavior/instance/workspace_uri` 字段 pattern-match）。
- cap 和 `CapabilityRegistry` subjects/default-grants 的 ETS 存储。
- `CapabilityRegistry.register_default_grant/2` API（有自定义 grant 需求的 Behavior 仍调它）。
- `User.default_caps/1` 函数（现有调用方 —— `Users.create/3`、Feishu `BindingPolicy`、`mix ezagent.stress` —— 不变继续用；见 §10 non-goal #3）。

**变化（增量）：**
- 新 `Behavior` callback `data_owner/1`（optional，默认 `:no_owner`）。
- 新 helper `CapabilityRegistry.default_grants_from_data_owner(kind, target_uri)` 走遍 `kind` 注册的每个 Behavior，调 `behavior.data_owner(target_uri)`，返回 `[{grantee_uri :: URI.t(), Capability.t()}]` —— 元组形式**强制**因为 `%Capability{}` 没有 grantee 字段（只携带 `granted_by`）。spawn 路径用每个元组的 `grantee_uri` 知道把 cap 写进谁的 Identity slice。被 opt-in 结构性默认的 spawn 路径用（vs 手写 `default_caps/1`）。

```elixir
# Helper 契约（r3 —— 修 r2 HIGH）
@spec default_grants_from_data_owner(kind :: module(), target_uri :: URI.t()) ::
        [{grantee_uri :: URI.t(), Capability.t()}]
def default_grants_from_data_owner(kind, %URI{} = target_uri) do
  # 对每个注册到 `kind` 的 Behavior B，问 B.data_owner(target_uri)。
  # 只有具体 URI 返回产生 default grant；:any / :no_owner /
  # {:scope, _, _} 不产生条目（caller 依赖显式 grant_cap）。
  #
  # r5 修复（codex round-4 HIGH）：用公共 `subjects_for_kind/1` API，
  # **不要**用裸 `:ets.match`。Round-4 SPEC 试 `{{kind, :_}, :"$1", :_}` 但
  # 真实 `CapabilityRegistry.register/3` 写入 shape 是
  # `{{kind, behavior, action}, meta}`（2 元素外 tuple，3 元素 key）——
  # round-4 的 match pattern 返回 ZERO 行，整个 helper 静默产生空 list，
  # 摧毁了 cap-only 的修复。
  #
  # 为什么用公共 API 而不是 `:ets.match_object/2` 加正确 shape
  # `{{kind, :"$1", :_}, :_}`：`subjects_for_kind/1` 是文档化契约且对未来
  # ETS 布局调整（例如 registry 加 sharded 后端存储）有韧性。Round-1
  # SPEC 没抓住是因为抽象错（BehaviorRegistry）；round-4 没抓住是因为
  # ETS pattern 错；round-5 用类型化公共 surface。
  behaviors_for_kind =
    kind
    |> Ezagent.CapabilityRegistry.subjects_for_kind()
    |> Enum.map(& &1.behavior)
    |> Enum.uniq()

  for behavior <- behaviors_for_kind,
      owner = data_owner_of(behavior, target_uri),
      match?(%URI{}, owner),
      uniq: true do
    cap = %Capability{
      kind: kind.type_name(),
      behavior: behavior,
      instance: target_uri,
      workspace_uri: Capability.workspace_of(target_uri),
      granted_by: bootstrap_uri(),
      granted_at: DateTime.utc_now()
    }
    {owner, cap}
  end
end
```

这纯增量 —— 没有现有代码路径破。迁移按 Behavior 分，opt-in（PR-OWN-2 起）。PR-OWN-2 的验收测试断言：以 Alice spawn session 后，`Ezagent.Behavior.Identity.list_caps(alice_uri)` 包含新 session URI 上的 `Behavior.Chat` cap —— 即 grant 落在 Alice 的 identity slice 上，不只是 helper 返回。

---

## 5. Grant action：`Behavior.Identity.grant_cap/3` 成为单一入口

### 5.1 今天

`Ezagent.Behavior.Identity.invoke(:grant_cap, slice, args, ctx)` 存在（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44` —— 在 `actions/0` 和 `cap_subjects/0` 里声明；`invoke/4` 子句已接好）。当前 dispatch 5.5 步的 cap 检查验证 caller 持有目标 principal 上的 admin 级 cap —— 即 "你有权变更这个 user 的 cap 吗"。这个检查必要但不充分：它没验证 caller *合法授予 THIS specific cap*。

### 5.2 SPEC 改变

`grant_cap` 的 pre-invoke 检查增加一个结构性规则：caller（按 `ctx.caller`）必须是被授予 cap 的 data owner，OR 持有之前由 data owner 授予的、被记录的委托 cap。

具体地，变更目标 slice 之前，`Behavior.Identity.invoke(:grant_cap, ...)` 按顺序跑这些步骤。第 0 步和第 0.5 步是 r3 加的，在 `data_owner/1` 不能有意义求值的 cap 形状上 fail closed；防止 r2 CRITICAL（调 `:any.data_owner/1`）和 HIGH（在非 URI 上调 `workspace_of/1`）：

**0. Wildcard 前置检查（r3 —— CRITICAL 修）。**
   如果 `needed_cap.kind == :any` OR `needed_cap.behavior == :any` → 要求 caller 持有 bootstrap admin cap（`Capability.admin_invariant?/1`）；否则返回 `{:error, :grant_wildcard_requires_admin}`。**理由**：`:any` 是哨兵，不是 Behavior module；没有 `data_owner/1` 可调。bootstrap admin 是 wildcard cap 的唯一合法授予者。这阻断了 `User.default_caps/1` 的 `{behavior: :any}` 形状（`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:104-116`）通过 `grant_cap` 被非 admin 重新授予的路径。

**0.5. Workspace 维度前置检查（r3 —— HIGH 修）。**
   为了 `owner == :any` 分支（下面第 4 步）可求值，`needed_cap.workspace_uri` **必须**是具体的 `workspace://` URI。如果 `needed_cap.workspace_uri == :any`（跨 workspace cap），要求 caller 持有 bootstrap admin cap；否则返回 `{:error, :grant_cross_workspace_requires_admin}`。**理由**：跨 workspace grant 没有单一 "workspace admin" 可授权；只有 bootstrap admin 能铸造跨 workspace cap。这是前置检查，所以规则其余部分可以依赖 `needed_cap.workspace_uri` 是 `%URI{}`。

**1. 解析 owner。**
   `owner = needed_cap.behavior.data_owner(needed_cap.instance)` —— 由第 0 步，这里 `needed_cap.behavior` 是真实 module。`needed_cap.instance` 可以是 `%URI{}`、`:any` 或 scope tuple；Behavior 的 `data_owner/1` 子句按 §3.1 处理全部三种。

**2. 规范化 scope 返回。**
   如果 `owner` 是 `{:scope, _scope_kind, scope_uri}`，递归通过 scope-拥有 Behavior 解析（例如 `:within_session` → `Behavior.Chat.data_owner(scope_uri)`）。递归深度上限 = 3（cycle 时 raise `{:error, :grant_scope_cycle}`）。最终解析的 `owner` 是 `%URI{}`、`:any` 或 `:no_owner` 之一。

**3. `owner == :no_owner`。**
   要求 caller 持有 bootstrap admin cap（`Capability.admin_invariant?/1`）；否则 `{:error, :grant_not_owner}`。

**4. `owner == :any`。**
   要求 caller 持有 `needed_cap.workspace_uri`（由第 0.5 步保证是具体 `workspace://` URI）上的 `Behavior.Workspace` cap。用 cap struct 已记录的 workspace 维度；**不要**通过 `workspace_of/1` 重新导出（instance 可能是 `:any` 或 scope tuple）。

**5. `owner` 是 `%URI{}`。**
   要求 `ctx.caller == owner` OR caller 持有之前由 `owner` 授予的 `delegation` cap（delegation cap 形状见 OQ-OWN-2）。

**6. Audit log。**
   `granter_uri (ctx.caller) → grantee_uri (target) granted (cap_shape) — delegation_chain: [...]`。检查通过后、slice 变更前记录。

cap 检查通过当且仅当 (0)/(0.5)/(3)/(4)/(5) 之一满足。否则 action 返回对应的独立错误码（**不是** `:unauthorized`，让 failure mode 在 log 里清楚）。错误码总览：

- `:grant_wildcard_requires_admin` —— kind/behavior wildcard 来自非 admin
- `:grant_cross_workspace_requires_admin` —— `workspace_uri: :any` 来自非 admin
- `:grant_scope_cycle` —— `{:scope, _, _}` 链超过深度上限
- `:grant_not_owner` —— caller 既不是所有者也不是 delegate，并且不是被要求的 bootstrap-admin

### 5.3 为什么单一入口

今天 cap 也在这些地方铸造：
- `Users.create/3`（通过 `User.default_caps/1` prepend）
- `Feishu BindingPolicy.ensure_user_default_caps/2`
- 各种 spawn 路径（`Agent.spawn/4` 等，算初始 cap）

SPEC **不**把这些合并成一个入口 —— 那会强制重度迁移。代之：
- **Default grant**（实例创建时）：走框架的 `default_grants_from_data_owner/2` helper（或在 legacy 路径里留在手写 `default_caps/1`）。这些是 *结构性* 默认；合法性来自 "框架在实例创建瞬间，代表未来所有者授予的" —— 没人类授予者参与。
- **所有其他 grant**（admin action、委托、用户主动）：**必须**走 `Behavior.Identity.invoke(:grant_cap, ...)`。§5.2 的检查是 chokepoint。

一个 invariant 测试（PR-OWN-FINAL）扫描生产代码寻找任何其他铸造 `%Capability{}` 并插入 User/Agent slice 的路径 —— 标记为 bypass 结构性规则。

---

## 6. 现有 Behavior 审计（Kind × Behavior 对）

每个 Behavior 文件直接读了（源码位置在表里引）。按 CRITICAL-1（cap 是 Behavior 级不是 action 级），行是 `(Kind, Behavior)` 对 —— 每对是存储意义上的一个 cap subject。"暴露的 action（仅参考）" 列从 `cap_subjects/0` 逐字读出，只为 catalog 用途；持有 cap 授权所列的**全部** action。

"当前隐式所有者" 列说当前代码事实上把谁当授予者。大多数行答案是 "admin（catch-all `:any` cap）" 因为没其他规则。

| # | 注册到 Kind | Behavior | 暴露的 action（仅参考；已在 path:line 验证） | 当前隐式所有者 | 建议的 `data_owner/1` 返回 | Default-grant 规则（导出） | 迁移成本 |
|---|---|---|---|---|---|---|---|
| 1 | `Ezagent.Entity.User` | `Ezagent.Behavior.Identity` | `:list_caps, :has_cap?, :grant_cap, :revoke_cap`（identity.ex:44） | admin（`:any`） | `URI` 自己 | user 在创建时获得自己 URI 上的 cap | 极小 —— slice 已存在 |
| 2 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Identity` | （同 #1；identity.ex:44，注册在 application.ex:242） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 3 | `Ezagent.Entity.User` | `Ezagent.Behavior.ApiKeys` | `:list_api_keys, :put_api_key, :delete_api_key, :get_api_key`（api_keys.ex:52） | admin（`:any`） | `URI` 自己 | user 在创建时获得自己 URI 上的 cap | 极小 |
| 4 | `Ezagent.Entity.Workspace` | `Ezagent.Behavior.Workspace` | `:list_members, :add_member, :remove_member, :list_templates, :add_template, :remove_template, :list_routing_rules, :set_routing_rules, :instantiate`（workspace.ex:60-73） | admin（`:any`） | `:any`（workspace 级） | 没 per-instance default —— workspace admin 必须显式授予 | 声明 `:any` |
| 5 | `Ezagent.Entity.Workspace` | `Ezagent.Behavior.Routing` | `:add_rule, :delete_rule, :disable_rule, :enable_rule`（routing.ex:62-69；注册在 workspace/application.ex:54-56） | admin（`:any`） | `:any`（workspace 级） | 没 per-instance default | 声明 `:any` |
| 6 | `Ezagent.Entity.Session` | `Ezagent.Behavior.Chat` | `:send, :receive, :join, :leave, :set_working_copy`（chat.ex:60-69；Session 端注册在 chat/application.ex:453-459） | admin（`:any`） | `Session.owner(uri)`（PR-OWN-2 加查询） | session 所有者在 spawn 时获得自己 session 上的 `Behavior.Chat` cap | 小 —— 给 `:chat` slice 加 `:owner_uri` |
| 7 | `Ezagent.Entity.User` | `Ezagent.Behavior.Chat` | `:receive`（User 端注册的 action；chat/application.ex:460） | admin（`:any`） | `URI` 自己 | user 在创建时获得自己 URI 上的 `Behavior.Chat` cap | 极小 |
| 8 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Chat` | `:receive`（chat/application.ex:461） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 获得 spawned agent 上的 cap | 极小 |
| 9 | `Ezagent.Entity.Session` | `Ezagent.Behavior.Routing` | `:add_rule, :delete_rule, :disable_rule, :enable_rule`（注册在 chat/application.ex:471-473） | admin（`:any`） | `Session.owner(uri)`（复用 #6 的查询） | session 所有者在 spawn 时获得自己 session 上的 `Behavior.Routing` cap | 小 —— 共享 #6 工作 |
| 10 | `Ezagent.Entity.System` | `Ezagent.Behavior.Routing` | （同 action；注册在 core/application.ex:149-152） | admin（`:any`） | `:no_owner` | 没 default —— 只有 bootstrap admin 授予 | 极小 |
| 11 | `Ezagent.Entity.AgentTemplate` | `Ezagent.Behavior.Template` | `:read, :write, :instantiate, :fork`（template.ex:128-137；注册在 chat/application.ex:499-501） | admin（`:any`） | `Template.writer(uri) || :any` | writer 在 write 时获得 cap | 小 —— 给 `:template` slice 加 `:writer_uri` |
| 12 | `Ezagent.Entity.SessionTemplate` | `Ezagent.Behavior.Template` | （同 #11；注册在 chat/application.ex:500-501） | admin（`:any`） | `Template.writer(uri) || :any` | writer 在 write 时获得 cap | （#11 覆盖） |
| 13 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Pty` | `:write`（pty.ex:55-58；注册在 chat/application.ex:486-488） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 spawned agent 上的 cap | 极小 |
| 14 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Lifecycle` | `:terminate`（lifecycle.ex:62-67；注册在 chat/application.ex:516-518） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 15 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Sandbox` | `:read, :write_path, :destroy`（sandbox.ex:80-90；注册在 chat/application.ex:527-529） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 16 | `Ezagent.Entity.User` | `Ezagent.Behavior.Notifications` | `:notify, :subscribe`（notifications.ex:26-31；cap-only —— `dispatchable?/0 == false`；注册在 core/application.ex:197-198） | admin（`:any`） | `URI` 自己 | user 在创建时获得自己 inbox 上的 cap | 极小 |
| 17 | `Ezagent.Entity.User` | `Ezagent.Behavior.Presence` | `:online`（presence.ex:28-30；cap-only；注册在 core/application.ex:187） | admin（`:any`） | `URI` 自己 | user 在创建时获得自己 URI 上的 cap | 极小 |
| 18 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Presence` | `:online`（注册在 core/application.ex:188） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 19 | `Ezagent.Entity.Echo` | `Ezagent.Behavior.Echo` | `:say, :receive`（echo.ex:47-52；plugin 注册） | admin（`:any`） | `URI` 自己 | echo entity 拥有自己的 echo（玩具） | 极小 |
| 20 | `Ezagent.Entity.CurlAgent` | `Ezagent.Behavior.CurlAgent` | `:receive, :reset_conversation, :configure`（curl_agent.ex:62-69；plugin 注册在 plugin_curl_agent/application.ex:80-84） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 21 | `Ezagent.Entity.NpAgent` | `Ezagent.Behavior.NpAgent` | `:receive, :reset, :configure`（np_agent.ex:59-66；plugin 注册在 plugin_np/application.ex:85-89） | admin（`:any`） | `AgentLineage.lookup(uri) || uri` | spawner 在 spawn 时获得 cap | 极小 |
| 22 | `Ezagent.Entity.Session` | `EzagentPluginFeishu.Behavior.FeishuOutbound`（真实模块名；r3 修 —— r2 错命名为 `Ezagent.PluginFeishu.Behavior.FeishuOutbound`） | `:notify_external`（feishu_outbound.ex:64-69；plugin 注册到 `Ezagent.Entity.Session` 在 plugin_feishu/application.ex:86-93） | admin（`:any`） | `Session.owner(uri)`（复用 #6 的查询） | session 所有者在 spawn 时获得自己 session 上的 `FeishuOutbound` cap | 极小 —— 共享 #6 工作 |

合计：15 个 Behavior 模块跨 22 个 `(Kind, Behavior)` 对。迁移是行级 —— 每个 Behavior 一个 `data_owner/1` 函数（10-15 行，包含全部四种输入形状），加三个 slice 字段添加（Session `:owner_uri`、Template `:writer_uri`、Agent lineage 已在 `apps/ezagent_core/lib/ezagent/agent_lineage.ex` 的 `Ezagent.AgentLineage` ETS 表里存在）。没 DB 迁移；新字段随下次 DB rebuild 上线，按项目的 wipe-and-rebuild 惯例（SPEC v3 §8 / memory `feedback_let_it_crash_no_workarounds`）。

---

## 7. 迁移计划

每个 PR 独立可发（编译过、测试过、除非声明否则没行为变化）。下面顺序**严格** —— 每个 PR 的验收测试只依赖本 PR 或更早 PR 引入的代码（修复 r1 HIGH-1）。

### PR-OWN-1 —— 框架 callback + audit baseline（无行为变化）

**改：**
- 给 `Ezagent.Behavior` 加 `@callback data_owner(URI.t() | :any | scope_tuple()) :: URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}` 加 `@optional_callbacks [data_owner: 1]`。
- 在 `Ezagent.CapabilityRegistry.data_owner_of/2`（helper）里默认查询：if `function_exported?(behavior, :data_owner, 1)` → 调它；else `:no_owner`。
- 加 `CapabilityRegistry.default_grants_from_data_owner/2` helper —— 走遍 kind 注册的 Behavior 返回 `[{grantee_uri :: URI.t(), Capability.t()}]`（元组形式，与 §4.2 契约对齐）。**还没** spawn 路径调用（只是 opt-in 可用）。
- 加 audit reporter `mix ezagent.caps.audit` task 走遍 `:code.all_loaded` 里名字匹配 `Ezagent.*.Behavior.*` 的 Behavior，打印哪些有/没 `data_owner/1`。
- 更新 `Ezagent.Behavior` moduledoc，写规则 + 四种边界返回。

**验收：**
- `mix compile --warnings-as-errors` 干净。
- `mix ezagent.caps.audit` 报 baseline（PR-OWN-1 后生产 Behavior 0 个有 `data_owner/1`；`--strict` flag 非零退出 —— PR-OWN-FINAL 用）。
- PR-OWN-1 里的单元测试：定义 `Ezagent.TestSupport.OwnedBehavior`（一个仅测试用的 fresh Behavior，实现 `data_owner/1` 和一个合成 Kind），断言 `CapabilityRegistry.default_grants_from_data_owner/2` 返回期望的 `[{grantee_uri, %Capability{}}]` tuple 列表。这个测试**只**依赖 PR-OWN-1 代码 —— 不碰任何真实 Behavior。
- **Registry-shape 回归测试（r5，codex round-4 HIGH）**：注册一个合成 dispatchable Behavior 带**多个** action（如 `:read`、`:write`）**加**一个 cap-only Behavior（`dispatchable?: false`）到同一个测试 Kind。调 `default_grants_from_data_owner/2` 断言**两个** owner/cap tuple 都返回（dispatchable Behavior 通过 `Enum.uniq` 出现一次 + cap-only 一个）。没这个测试，round-4 错 ETS pattern 静默产生空 list —— 用测试锁定公共 API 枚举防止 `subjects_for_kind/1` 语义未来漂移。
- 没有现有测试破。

**LOC 估：** ~120（callback + helper + task + docs + test support）。

### PR-OWN-2 —— Session.owner 查询 + Behavior.Chat data_owner（Session 迁移）

**改：**
- 给 `Behavior.Chat.init_slice/1` 加 `:owner_uri` 字段（一行 —— `Map.put(slice, :owner_uri, Map.get(args, :owner_uri))`）。
- 加 `Ezagent.Entity.Session.owner/1` public 函数：`Ezagent.Kind.Runtime.get_slice(session_uri, :chat) |> Map.get(:owner_uri)`。
- 接 `Session.spawn_from_template/2` 把 `owner_uri` 传到 Chat slice（已有值 —— `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:121`）。
- 按 §3.3 声明 `Behavior.Chat.data_owner/1`（用 `Session.owner/1`）。
- 接 `Behavior.Identity.invoke(:grant_cap, ...)` 执行 §5.2（结构性规则）—— 但**只**对其 Behavior 有 `data_owner/1` 声明的 needed cap 生效。没 `data_owner/1` 的 Behavior 保持旧 admin-cap 检查直到迁移（增量 rollout）。
- **r4 修复（codex CRITICAL）**：更新 `Ezagent.Identity.grant_cap/3` 门面在 `apps/ezagent_domain_identity/lib/ezagent/identity.ex:149-164`，传 **granter 的真实 caps** 通过 `Ezagent.Behavior.Identity.list_caps(granter_uri)`，替代当前硬编码的 `Ezagent.Entity.User.admin_caps()`。如果门面总发 admin caps，§5.2 pre-check 毫无意义 —— 任何 grant 都平凡通过，不管 granter 实际持有什么。向后兼容：现有 caller（`mix ezagent.user.create`、Admin LV grant 按钮等，目前都以 `granter_uri = admin_uri` 调用）继续工作因为那个 admin 确实持有 admin caps；新 caller 路径若传非 admin `granter_uri` 现在正确命中 §5.2 wildcard pre-check + data-owner 规则。验收新加测试 (e)。

**验收：**
- 现有测试全过。
- 新测试，全部只用 PR-OWN-1 + PR-OWN-2 引入的代码：
  - (a) 以 user Alice spawn 一个 session；`Session.owner(session_uri)` 返回 Alice 的 URI。
  - (b) Alice（session 所有者）调 `Behavior.Identity.invoke(:grant_cap, ...)` 给 Bob 授予 Alice session 上的 `Behavior.Chat` cap —— 成功。
  - (c) Bob（非 session 所有者）尝试同一 grant —— 被拒 `:grant_not_owner`。
  - (d) 持有窄跨 workspace `Behavior.Chat` cap 的用户（PR #303 HIGH-3 场景等价）尝试在他们不拥有的 session 上 grant `Behavior.Chat` —— 被拒 `:grant_not_owner`。
  - (e) **r4 验收**：非 admin `Ezagent.Identity.grant_cap/3` caller（传自己 URI 作 `granter_uri`）的真实 caps 被转发到 dispatch ctx，而不是 `User.admin_caps()`。通过 stub `granter_uri = non_admin_alice` + 验证 §5.2 检查看到 `ctx.caps = Behavior.Identity.list_caps(alice)` 而不是 `admin_caps` 来断言。

**LOC 估：** ~120（slice 字段 + 查询 + data_owner + grant_cap 接线 + 4 个测试）。

### PR-OWN-3 —— Identity + Workspace 迁移

**改：**
- 按 §3.3 声明 `Behavior.Identity.data_owner/1`。
- 按 §3.3 声明 `Behavior.Workspace.data_owner/1`（`workspace://` 返回 `:any`）。
- 两者的测试，依赖 PR-OWN-1/2 代码。

**验收：**
- 新测试：
  - 在 Alice 的 URI 上 grant `Behavior.Identity` cap，从非 Alice caller 且没有 Alice 授予的委托 —— 被拒 `:grant_not_owner`。
  - 在 `workspace://team-alpha` 上 grant `Behavior.Workspace` cap，从非 team-alpha admin caller —— 被拒 `:grant_not_owner`。
  - 从 workspace admin grant —— 成功。

**LOC 估：** ~80。

### PR-OWN-4 —— Routing + Template + Pty + Lifecycle + Sandbox + ApiKeys 迁移

**改：**
- 按 audit 表声明 `Behavior.Routing`、`Behavior.Template`、`Behavior.Pty`、`Behavior.Lifecycle`、`Behavior.Sandbox`、`Behavior.ApiKeys` 的 `data_owner/1`。
- 加 `Ezagent.Entity.Template.writer/1` 查询（与 `Session.owner/1` 平行 —— 给 `:template` slice 加 `:writer_uri`）。
- 给 `Behavior.Template.init_slice/1` 加 `:writer_uri`；在 `:write` action 时填。

**验收：**
- workspace X 上 `:add_rule` Routing cap grant 来自非 X-admin：被拒。
- session A 上 `:add_rule` Routing cap grant 来自 session B 的所有者：被拒。
- template T 上 `:read` Template cap grant 来自非 writer：被拒。

**LOC 估：** ~180。

### PR-OWN-5 —— Plugin Behavior（Echo、CurlAgent、NpAgent、FeishuOutbound、Notifications、Presence）

**改：** 按 audit 表声明 `data_owner/1`。Notifications 和 Presence 复用 User-URI / spawner pattern。

**LOC 估：** ~80。

### PR-OWN-6 —— Notifications predicate 清理（仅 refactor；无行为变化）

**改：**
- 把 `notification_subscriptions.ex` 的手写 `has_admin_cap?` predicate 换成 `data_owner`-导出的检查（PR #303 HIGH-3 修复结构性变冗余 —— registry 导出相同答案）。
- 手写 predicate 留作 deprecated alias 一个 release；CI gate 标记新调用方。

**验收：**
- PR #303 的回归测试用新 predicate 仍过。

**LOC 估：** ~60 净。

### PR-OWN-FINAL —— 执行 invariant

**改：**
- `data_owner_declared_for_all_test.exs` invariant 测试：生产里加载的每个 Behavior（`:code.all_loaded` 过滤到 `Ezagent.*.Behavior.*` 和 plugin namespace，例如 `EzagentPluginFeishu.*`）**必须**声明 `data_owner/1`。失败时列 Behavior + 缺失的分支。用与 PR #264 `single_capability_registration_entry_test.exs` 相同的 `:code.all_loaded` 走法。
- `audit_table_matches_registry_test.exs` invariant 测试（r3 加 —— 关闭 FeishuOutbound HIGH）：boot 系统，读 `CapabilityRegistry.list_grantable/0`，断言 live registry 里每个 `(kind, behavior)` 对都出现在本 SPEC §6 audit 表里（从 markdown 源解析）。捕捉未来 SPEC 漂移 / Behavior 模块名拼写错误相对真实注册。
- `mix ezagent.caps.audit --strict` 在任何缺失声明上非零退出。
- 更新 SKILL，加新原则 `P28. Capability = 数据类上的 CRUD（Behavior 级）；data owner 是唯一 grantor`（与 P15 交叉引用）。更新 GLOSSARY，加 `data_owner/1`、`data owner`、`delegated grant`。

**验收：**
- 所有 Behavior 声明 `data_owner/1`；invariant 测试 gate 未来 PR 添加 Behavior 时必须带 callback。
- §6 audit 表结构性绑到真实 registry；SPEC 里错命名的 module 名 CI 失败。

**LOC 估：** ~80（原 50；+30 为 SPEC-vs-registry 解析/断言）。

### 排序说明

- **严格顺序**：PR-OWN-1 → PR-OWN-2 → PR-OWN-3 / PR-OWN-4 / PR-OWN-5（PR-OWN-2 之后并行）→ PR-OWN-6（PR-OWN-5 之后）→ PR-OWN-FINAL（gate 收尾）。
- PR-OWN-2 必须在 PR-OWN-3+ 之前落地，因为 PR-OWN-2 引入 `Session.owner/1`（被 `Behavior.Chat.data_owner`、session scope 的 `Behavior.Routing.data_owner`、`FeishuOutbound.data_owner` 用）AND 在框架层面接 §5.2 grant 检查（PR-OWN-3+ Behavior 插进这个接线而不需要重新实现）。

---

## 8. 给 Allen 的 open question

**OQ-OWN-1: workspace 级 Behavior（`Behavior.Workspace`、workspace 上的 `Behavior.Routing`）—— `data_owner/1` 返回 `:any`（任意 workspace admin 授予）OR `workspace_owner_uri`（每 workspace 单一 grantor）？**

- **(a) `:any`** —— 任何 `Behavior.Workspace` cap 持有者可授予 workspace 管理 cap。匹配当前行为（默认多 admin workspace）。
- **(b) `workspace_owner_uri`** —— workspace 获得单一结构性所有者（创建者）；只有那个所有者能授予 workspace cap，除非委托。
- **(c) 两者，按 workspace 切换** —— `workspace.solo_owned?` boolean。

**推荐：** v1 (a)。多 admin workspace 是运营现实（现有数据模型已支持）。(b) 会强制每个现有 workspace 有记录的所有者，schema 里没有。(c) 是没驱动 use case 的特性蔓延。可以后续加 `workspace_owner_uri` 列并切换 `data_owner/1` 返回升级到 (b)。

**Trade-off：** (a) 让跨 workspace "任何 admin" 授予面保持宽。PR #303 HIGH-3 缓解已要求被授予的 cap 具体是 `Behavior.Notifications` cap，所以失败模式在 grantee-cap-class 级别有界 —— 不是 granter-identity 级别。

---

**OQ-OWN-2：撤销链 —— 如果 granter 是 delegate，撤销也向后链？**

当原 data 所有者 O 给 A 授予委托 cap，A 给 B，B 给 C 铸造了 data D 上的 cap —— O 能直接撤销 C 的 cap 吗？还是必须撤销 A 的委托 cap（链式无效化下面所有的）？

- **(a) 仅向前链** —— 撤销 A 的委托 cap **不**自动撤销 C 的 cap（C 的 cap 独立存储在 C 的 slice）。O 必须手动走链 OR 依赖未来的 "transitively 撤销" 工具。
- **(b) 向后链自动** —— cap 存 `delegation_chain: [granter_uris]` 字段；O 撤销 A 的委托触发 sweep 移除任何链里有 A 的 cap。
- **(c) 按需向后链** —— O 可以调 `revoke_descendants(cap_subject)` 找到并移除委托链下铸造的所有 cap。

**推荐：** v1 (a)。(b) 侵入性 —— 碰每个 cap struct，减速每次 grant。(c) 是未来特性，等 use case 出现。v1 诚实：委托是一次性 "你能授予这个 cap"，不是链。撤销 delegate cap 停止进一步铸造；之前铸造的 cap 需要 sweep。

**Trade-off：** (a) 让恶意 delegate 在 O 注意并撤销委托前能铸造 cap，那些 cap 在 O 撤销后存活。缓解：audit log 显示链；手动清理是脚本。v1 威胁模型（PR #303 §"Threat model"）假设 plugin 在 BEAM 内可信；跨 tenant 恶意 actor 不在范围。

---

**OQ-OWN-3：向后兼容 —— SPEC 之前铸造的现有 cap（没跑过 `data_owner/1` 合法性检查）：grandfather in，还是 re-audit？**

PR-OWN-2/-3/-4 落地后，`users.caps_json` 和 agent slice state 里每个现有 cap 都通过 default_caps（预先存在）或 admin 的 grant_cap（也预先存在）铸造。没有走过新的 §5.2 检查。

- **(a) Grandfather in** —— 现有 cap 原样有效。新 cap（从每个 per-Behavior PR 上线那刻起）走新检查。
- **(b) Re-audit** —— 一次性迁移脚本走每个 cap，回溯算 `data_owner/1`，如果 granter（记录在 `granted_by`）不是 owner / 合法 delegate，cap 被**撤销** + 标记 re-grant。
- **(c) Soft re-audit** —— 同 (b) 但 cap 标记不移除；operator review 后 re-grant 或撤销。

**推荐：** (a)。v1 现有 cap data 通过 admin（满足任何检查）铸造。(b) 和 (c) 引入 zero 安全收益的 churn 在 v1 规模。如果多 admin 场景出现，可以晚点跑 (c) 作为一次性 `mix ezagent.caps.lint`。

**Trade-off：** (a) 意味着如果现有 cap 是 *错误* 铸造（granter 不是合法所有者）它仍有效。这个风险在小现有 cap 面（一个 admin user）受限。

---

**OQ-OWN-4：bootstrap cap —— 首个 admin 的 cap 没有所有者；carve-out 形状？**

Bootstrap admin（`entity://user/system/admin`）持有 `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap，由 `system://bootstrap/default` 授予（`apps/ezagent_core/lib/ezagent/capability.ex:193-202`）。这在任何 `data_owner/1` 能跑之前铸造（字面意义上 DB 里第一个 cap）。SPEC 的结构性故事？

- **(a) Bootstrap-grant 豁免** —— `granted_by == system://bootstrap/default` 结构性合法，停止。在 `Capability.admin_invariant?/1`（已存在代码；只扩 moduledoc）记录。
- **(b) bootstrap admin 是 `:no_owner` data 的所有者** —— system 级 data 由 bootstrap 拥有。system 级 Behavior 的 `data_owner/1` 返回 `entity://user/system/admin` 而不是 `:no_owner`。bootstrap admin 通过是自己的所有者满足新 §5.2 检查。
- **(c) bootstrap 是 `:no_owner` 豁免 + 每个 system action 要求 bootstrap-admin caller** —— `:no_owner` 意思是 "只有 bootstrap admin 能授予"，bootstrap admin 由持有结构性 invariant cap 识别。

**推荐：** (a) 为清晰。bootstrap 路径设计上例外（从虚无创建系统）；假装它是正常 owner case 增加困惑。现有 `admin_invariant?/1` 检查已给结构性锚点。我们记录规则："bootstrap cap 是种子；每个其他 cap 通过 grant chain 追溯回它。"

**Trade-off：** (a) 让框架保持一个结构性例外；(b) 会让规则统一，代价是发明虚构所有权。我们选 rule-explanation 的统一性而不是 mechanism 的统一性。

---

**OQ-OWN-5：跨 Kind grant 流（例如 Alice 给 Bob 授予 Alice session 上的 `Behavior.Chat` cap）—— Bob 的 identity-mutation 端由 Bob 管，不是 Alice。Bob 的同意怎么建模？**

当 user Alice（`entity://user/team/alice`）调 `grant_cap` 给 user Bob（`entity://user/team/bob`）授予 Bob 在 session S 上的 `Behavior.Chat` cap，两个所有权要紧：
- cap 的 data（S 上的 `Behavior.Chat`）—— 由 S 的所有者拥有（本例中 Alice）。
- 被变更的 slice（Bob 的 `:identity` slice）—— 由 Bob 拥有。

§5.2 覆盖第一个（Alice 是所有者 ✓）。第二个由 ezagent 现有 dispatch 管 —— `grant_cap` 已要求 caller 持有目标 principal Identity 上的 cap（`entity://user/team/bob` 上的 `Behavior.Identity` cap），存在是因为 Bob 接受 Alice 为朋友 / 协作者 / 等时给 Alice 授予了。

**没有 dispatch 中途读 Bob caps 的机制**验证 "Bob 同意接收这个 cap" —— dispatch 只读 `ctx.caps` = Alice 的 caps。所以：

- **(a) 现状** —— Alice 满足 §5.2（拥有 data）AND 持有 Bob 上的 `Behavior.Identity` cap（之前 Bob 授予）。双 gate 模型；Bob 的同意是 "Bob 之前给 Alice 授予了变更 Bob identity 的权利"。
- **(b) 同意 ledger** —— Bob 的 slice 记录 Bob opt-in 接收的 grant subject 列表；dispatch 在变更前读 ledger。这是单独 SPEC —— 这里范围外。

**推荐：** (a)。r2 显式删除 r1 的 OQ-OWN-2（提议 dispatch 中途读 target caps）按 codex HIGH-3。现状双 gate 模型正确且已实现：§5.2 加 data-owner 检查；预先存在的 Identity-cap 检查覆盖 grantee 端同意。(b) 是单独未来 SPEC 如果 use case 出现。

---

**OQ-OWN-6：per-action 粒度 —— cap struct 应该长 `action` 字段让例如 "Bob 能读 notifications 但不能 unsubscribe 别人" 可表达？**

今天 cap struct 是 Behavior 级（没 `action` 字段），所以持有 `Behavior.Notifications` cap = 完整 CRUD。CRITICAL-1 重构让这在 SPEC 里明确。

- **(a) 否** —— cap struct 原样保持。如果需要更细粒度 gate，正确答案是**声明两个 Behavior**（例如 `Behavior.NotificationsReader` 只暴露 `:subscribe`，`Behavior.NotificationsWriter` 暴露 `:notify` + admin action）。每个有自己的 cap 和自己的 `data_owner/1` 返回。
- **(b) 是** —— 给 `%Capability{}` 加 `action :: atom() | :any`，更新 `matches?/2` 和 `cap_for_action/3` 和每个持久化路径。

**推荐：** (a)。cap struct 形状有意最小（PR #303 教训：字段越多 = 失败面越多）。把太宽的 Behavior 拆成两个窄 Behavior 是结构性答案；它和现有系统组合而不扩 cap 形状。(b) 会碰每个碰 cap 的文件并破 wire 兼容性。决定也是 P8 / P2 胜利："少发明，多装配" + let-it-crash 在现有形状上。

**Trade-off：** (a) 意味着需要 read-vs-write 区分的 Behavior 作者有稍多 boilerplate（两个模块而不是一个）。现有 Behavior 按惯例粗粒度；没有生产 use case 出现两级分解不够的情况。

---

## 9. Non-goal

1. **不改 `Capability.matches?/2` 语义。** 仍按 `kind / behavior / instance / workspace_uri` pattern-match 完全如今天（`apps/ezagent_core/lib/ezagent/capability.ex:105-110`）。data-ownership 规则在 **grant** 时操作，不在 **dispatch** 时。5.5 步不变。
2. **不改 `%Capability{}` struct 形状。** 仍 6 字段：`kind, behavior, instance, workspace_uri, granted_by, granted_at`。没加 `action` 字段（见 OQ-OWN-6 理由）。
3. **不改 ETS 支持的 `CapabilityRegistry` 存储。** Subject + default-grant fn 留原地。`data_owner_of/2` 是 per-call 函数查询，不是额外 ETS 表。
4. **不碰 `Ezagent.Behavior.Notifications.subscribe` / `notification_subscriptions.ex` 行为。** PR #303 刚发（round-7 结束有 working predicate）。PR-OWN-5 会 *声明* Notifications 的 `data_owner/1` 但 `notification_subscriptions.ex` 里的 predicate 原样留；PR-OWN-6（单独，optional）是从 registry 重新导出 predicate 的 refactor。
5. **不加密码学委托 token。** BEAM same-VM 信任模型（按 PR #303 §"Threat model"）。委托 cap 是存在 slice state 里的 `%Capability{}` struct；没签名；信任 BEAM 进程边界。跨节点 / 跨 tenant 委托是未来 SPEC。
6. **不给 `%Capability{}` 加 `delegation_chain` 字段。** v1 保持现有 6 字段 struct（按 OQ-OWN-2 默认）。未来 SPEC 可以在撤销链支持需要时加。
7. **不迁移现有 cap。** OQ-OWN-3 选 grandfather-in。
8. **不合并四个 cap 铸造路径。** Default-grant + admin grant_cap + spawn 路径铸造 + Feishu binding-policy 铸造都保留入口。只有走 `grant_cap` 的**新** post-SPEC 铸造拿新检查。
9. **不引入 "dispatch 时读 target 的 caps" 机制。** r1 的 OQ-OWN-2（target-cap 同意机制）概念上破，因为 dispatch 只读 caller cap（`ctx.caps`）。如果将来需要 target 端同意，需要单独的 consent-ledger SPEC（off-band 查询）—— 在这里显式范围外。

---

## 10. 对 ExternalMirror r3 的引用

本 SPEC 必须批准（PR-OWN-1 + PR-OWN-2 最少，因为 r3 需要 `Session.owner/1`）才开始 `ExternalMirror r3`。r3 在 cap 设计里用 `data_owner/1` 形式：

- `Behavior.ExternalMirror`（整个 Behavior —— `:bind`、`:unbind`、`:replay` 等 action 都由 Behavior 级 cap 一起授权）。`data_owner(session_uri)` 返回 `Session.owner(session_uri)`（session 创建者）。Default grant：session 所有者在 session 创建时获得自己 session 上的 `Behavior.ExternalMirror` cap。效果：创建 session S 的用户是唯一能把 S 绑到外部系统的 principal（除非他们显式委托）。

这个形式替代否则会是 ExternalMirror 内部的手写 "session-owner predicate"。r3 的 SPEC 会短 ~30% 因为信任模型完全由 `data_owner/1` 返回指定。

---

## 附录 A —— 交叉引用

- SKILL P15（CapBAC shape、module ref、scope 形状收窄）—— `data_owner/1` 用 *谁能授予* 维度扩 P15。
- SKILL P1（plugin isolation 北极星）—— plugin Behavior 作者实现一个新 callback，不是自定义 predicate。
- SKILL P2（let-it-crash）—— `data_owner/1` 在 Behavior 作者返回畸形 shape 时 raise；框架**不**默认-on-error。
- SKILL P3（single source of truth）—— data 所有者是**唯一** grantor；没影子 grant 路径。
- SKILL P6（完成声明需要 invariant 测试）—— PR-OWN-FINAL 发 `data_owner_declared_for_all_test.exs`；那个测试是 gate。
- ARCHITECTURE Decision Log #133（User default cap baseline）—— 保留；`data_owner/1` 给以前是循环依赖妥协的提供结构性理由。
- ARCHITECTURE Decision Log #137（scope 限界 cap 形状）—— 正交；scope 形状收窄 `matches?/2`；`data_owner/1` 收窄 grant 权限。r2 的 `data_owner/1` 签名接受 `scope_tuple()` 输入，两者干净组合。
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 —— 本 SPEC 是 cap 形式 stack 的下一层。
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` moduledoc —— 驱动本 SPEC 的 PR #303 教训。

## 附录 B —— Worked example：PR #303 HIGH-3 在 `data_owner/1` 到位后

今天（PR #303 round-7 后，`apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` §"Tightened admin predicate"）：

```elixir
defp has_admin_cap?(caps) do
  Enum.any?(caps, fn cap ->
    cap.behavior == Ezagent.Behavior.Notifications and
      cap.workspace_uri == :any
  end)
end
```

`data_owner/1` 到位后（PR-OWN-6 后）：

```elixir
defp can_unsubscribe?(caller_uri, entity_uri, caps) do
  cond do
    caller_uri == entity_uri ->
      true   # 自取消订阅

    true ->
      # `entity_uri` 的 Notifications data 的所有者就是 `entity_uri` 自己
      # （user 拥有自己的 inbox）。Caller 只能取消订阅当且仅当持有由所有者
      # 授予的、针对 entity_uri 的 `Behavior.Notifications` cap。
      owner = Ezagent.Behavior.Notifications.data_owner(entity_uri)

      Enum.any?(caps, fn cap ->
        cap.behavior == Ezagent.Behavior.Notifications and
          cap.instance == entity_uri and
          cap.granted_by == owner
      end)
  end
end
```

"admin predicate" 不再自由形式：它问 "你持有这个 inbox 上的、由合法所有者授予的 cap 吗？" HIGH-3 失败模式（窄跨 workspace cap 偶然满足 admin predicate）结构性不可能 —— cap **必须**针对这个具体 inbox AND `granted_by` 该 entity_uri（或其 delegate），通配跨 workspace cap 永远满足不了。

这就是 v2 心智模型在一个例子里：predicate 溶解成 "框架已经知道谁能授予；只要检查你持有正确 data 上的合法 grant"。
