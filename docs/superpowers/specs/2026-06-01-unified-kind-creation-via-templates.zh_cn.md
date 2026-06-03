# 统一 Kind 创建（经由 Template）— 设计 (rev 6)

**日期：** 2026-06-01（rev 6：2026-06-02）
**状态：** 草稿 rev 6 — 已经 codex 验证 SOUND（5 轮）；所有 open question 已由 Allen 拍定；待 Allen spec review
**作者：** Claude（与 Allen）

> 本文件是 `2026-06-01-unified-kind-creation-via-templates.md`（英文）的中文平行版本，
> 内容须与英文版保持同步。

## 1. 问题与背景

team-routing 的"管理权"讨论暴露出一个结构性问题，并经一次只读审计确认：

- **存在**一个机械层的单一 spawn chokepoint —— `Ezagent.Kind.spawn/2` → `Kind.Server.init/1`
  → `KindRegistry.put_new/2`（`kind.ex:294` / `server.ex:104` / `kind_registry.ex:42`），
  由 `single_spawn_entry_test.exs` 守护。**但它授权盲 + owner 盲**，只做 URI→pid 注册。
  **注册 ≠ 授权创建。**
- **今天并不存在一个通用的授权创建入口。** `template.instantiate` 只在 AgentTemplate/SessionTemplate
  上有（`template.ex:280`），且 SessionTemplate 显式拒绝它（`:285` → `{:error, :use_generator}`）。
  Session/Workspace/User 创建走各自的 domain 函数 —— `create_session/3`、`Workspace.create/2`、
  `Users.create/3` —— **都不带 `ctx.caller`**。授权只 bolt 在被 dispatch 的 `workspace.create_*`
  动作上；约 7 条直接 `spawn` 路径绕过它（最严重：agent-bridge channel join，`channel.ex:146`，
  会物化一个无主 Agent，且因用变量参数躲过了 `agent_create_single_path_test.exs`）。
- **owner-cap-at-creation 模式已局部存在**（Session `owner_uri` + `grant_first_join_owner_cap`；
  Template `grant_*_owner_cap`；测试里的 `OwnedBehavior` 惯例），但没接进 chokepoint，且 Agent
  （只有 lineage）、Workspace（无 owner）、User 都没有。

**所以"统一授权创建入口"是这次工作要建的**，不是对现成动作的包装。Allen 指示（2026-06-01）：
为所有 Kind 引入 Template 概念，把创建+修改收口到一个授权 chokepoint，穿 `created_by` 并在创建时
授予管理 cap；这层地基先做。

R/B/K = Router/Behavior/Kind（内部引擎）；Lifecycle = 对外 API（ARCHITECTURE §153）。
**Template** = Template **Class**（实现 `Ezagent.Kind.Template` 的模块）+ Template **Instance**
（运行时 Kind）。本设计是推广现有模式。

## 2. 目标 / 非目标

**目标**
1. 每个 Kind 类型（Session/Agent/Workspace/User/AgentTemplate/SessionTemplate）经由 Template Class，
   通过一个**授权的、带 `ctx.caller` 的** dispatched 入口创建 —— 该入口由本工作**建立**。
2. 该入口在**仅创建分支**授予 `cap(:<kind>, Ezagent.Behavior.Manage, :any, instance)` 给 `created_by`
   （=`ctx.caller`），"创建"由 CORE 信号判定（非 Class 返回值）。
3. **修改**（`reconfigure`/`delete`）经每个 Kind 上的 `Ezagent.Behavior.Manage` 统一，由 manage-cap
   把门；通过**新增的 per-Class `reconfigure` hook** 对活着的 Kind 重新物化、保身份 + 保运行时 state
   （绝不销毁重建）。
4. 每个 Template Class 声明一个 **teardown 契约**，用于失败回滚 + `manage.delete`。
5. 约 7 条 ad-hoc 创建路径收口到入口（或经显式 existence 判定拒绝创建）。
6. CI 不变量让未来的绕过失败时大声报错。

**非目标（本 spec）**
- 消费 manage-cap 的路由行编辑授权（team-routing 后续）。
- 版本化/blueprint template 合成。
- 重构 Behavior 或 Lifecycle 引擎（只 ADD 一个 hook + 一个 behavior）。

## 3. 设计

### 3.1 "新鲜"= 原子持久化 INSERT 的结果（A-1）

授权 grant 必须**当且仅当本次调用真的持久化创建了该 Kind** 时触发 —— 无竞态，不在 adopt/rehydrate 上触发。
两个被否的做法：(a) Class 的 `instantiate/3` 的 `fresh?` meta 是可选的（`GenericSession` 返 2-tuple）；
(b) **spawn 前**的 `exists_durably?` 探测是 **TOCTOU**（探测与 spawn 之间别人可能创建它，且插件
`instantiate` 可能通过 adopt 一个 `:already_started` worker 而成功）。

**修法 —— grant 锁定在原子 INSERT 的结果上，而非读：** 权威的"本次是否创建了行"来自数据库自己的原子
`INSERT … ON CONFLICT` 判定，**不是**那个 gate `create/1` 的 `ever_created?` 预读（codex 指出它在 upsert
之前跑，因此不受 transition 保护）。

- **快照型 Kind**（Agent/Session/User/Template）：初始快照写入（`save_now/4`，今天返 `:ok`）改为返回
  **`:created`**（本次 INSERT 了新行）vs **`:existed`**（冲突）。`KindRegistry.put_new` 已保证每个 URI
  只有一个活进程，故创建副作用不会重复；grant 额外锁在原子 INSERT 结果上，即便并发 spawn 也只对真正的
  创建者触发一次。
- **临时态 Workspace**（无快照；`workspace.ex:55`）：`Workspace.Store.create/2` 改为区分 **`:created`**
  vs **`:exists`**（唯一约束冲突）—— 临时态路径的同一原子信号。
- **`created_by` 作为 create 参数穿入** `Kind.spawn` → `init`（正如 Session 穿 `owner_uri`），让 grant 在
  原子创建成功内/后拿到已认证的创建者，无需重读易竞态的状态。

这三处是**明确的 in-scope CORE 改动**（§3.10）。grant 当且仅当原子 INSERT 返回 `:created` 时触发；
`:existed`/adopt → 不 grant（durable manage-cap 已存在）。

（`exists_durably?(uri)` 探测 —— `KindSnapshot.ever_created?/1`，一个 `Repo.get`；或 `Workspace.Store`
行 —— **仅**保留给 §3.8 的 bridge-join existence 检查，那里竞态无害。）

### 3.2 统一授权创建入口（要建）（B-1）

引入一个所有 Kind 创建都经过的 dispatched 创建面：

- 一个创建动作 —— `kind.create`（挂在 core/domain 的创建 behavior 或推广后的 `Ezagent.Behavior.Template`）——
  dispatch 到拥有新 Kind 的**作用域**（agent/session/user 用 workspace；workspace 用 system/bootstrap），
  这样 `Kind.Runtime` step 5.5 CapBAC 会跑、`ctx.caller` 即已认证的 `created_by`。授权**复用现有 per-scope
  create cap**（OQ-1）—— 本工作不放宽"谁能创建"，只让授权统一且不可绕过。
- handler：解析目标 Template Class → `validate/1` → `instantiate/3`（穿 `created_by`）→ 原子创建给出
  `:created` vs `:existed`（§3.1）→ 若 `:created` 跑 grant（§3.3）；若 fresh spawn 后任何失败，跑 Class
  teardown 再 `destroy/2`（§5/G-1）。
- **把现有创建路径迁到入口上**（工作主体）：`create_session/3`、`Workspace.create/2`、`create_user`、
  Loader fresh-create 分支、`Agent.spawn_fresh/4` / `spawn_from_template_content/4`、插件 Class spawn —— 都
  改为入口的调用者（或被替换），各自提供真实 `created_by`。Boot/login/bridge **rehydrate** 仍走
  `SpawnRegistry.spawn`（无需 ctx.caller —— rehydrate 不 grant）。

`Kind.spawn/2` 仍是 rehydrate 的机械原语；**入口之外的 fresh 创建是 CI 失败**（§6）。

### 3.3 Manage-cap grant —— CORE 步骤、`:any` action、Session caveat 已解决（A-1, C-1）

fresh 创建后（原子创建返回 `:created`，用穿入的 `created_by`），core handler 为每个新建的 owned Kind URI 授予：

```
cap(kind_of(uri), Ezagent.Behavior.Manage, :any, instance: uri)  → 授给 ctx.caller
```

- **`action: :any`**（非 `:manage`）：dispatch 会把 needed cap 的 action 覆写为具体动作（`runtime.ex`），
  `matches?` 比较 `action_of(cap)` 与 needed action。持有 `:manage` 动作的 cap **不会** match `:reconfigure`/
  `:delete`。`:any`（限定在 `Behavior.Manage` + 具体 `instance`）= "对本实例的任何管理动作" = 恰好是"manage"，
  且**不**过宽（behavior + instance 都钉死）。
- grant 用 `created_by`=`ctx.caller`；Class 影响不了被授予者。
- rehydrate 上跳过（cap 已 durable）。重启幂等。
- 归并现有 Session/Template 的零散 owner-cap。

**Session caveat（C-1）—— 已解决：收窄过宽的默认 cap（OQ-4 = B，Allen 2026-06-02）。** kind 轴干净地把
普通用户挡在 `:agent`/`:workspace`/`:user` 的 manage-cap 之外（kind 不同）。**唯一**暴露是 `:session` 的
manage-cap：用户默认 `cap(:session, :any, :any, :any, ws)`（`user.ex:175`，注释自称"intentionally broad"）
会 match `cap(:session, Manage, :any, S)`（S 在用户 workspace 内）—— 一旦 Manage 给 Session 加了
`:delete`/`:reconfigure`，该默认 cap 就能让任意 workspace 成员解散任意 session。今天没炸只是因为 Session
还没有破坏性动作；加 Manage 会武器化这个潜在越权。

**修法（B）—— 收窄默认 cap，而非加 per-Kind 补丁。** 把 `:session/:any/:any` 默认换成普通用户实际需要的
**具体**动作（`Chat :send`/`:join`/`:leave`/`:set_working_copy`），不再用 `:any` action。则 Manage 类动作不被
隐含授予，session-manage 与其它所有 Kind **一样**由 manage-cap 把门 —— 无 Session 特例、无 `owner_uri` 补丁
（补丁是 workaround，`feedback_let_it_crash_no_workarounds`）。同时清掉一个系统级潜在越权。**必做步骤
（在 plan 里）：审计今天所有依赖 `:session/:any/:any` 默认的 dispatch**（确保收窄不破坏合法
send/join/leave 等）；缺的具体动作补进新默认 cap。见 §3.11。

### 3.4 `Ezagent.Behavior.Manage` —— 统一管理面

新 core behaviour，经 `CapabilityRegistry.register(<Kind>, <action>, Ezagent.Behavior.Manage)` 注册在**每个**
Kind 上（同 `register(Session, :join, Chat)` 机制）。动作：

- `:reconfigure` —— 参数 `%{template_data: map}` → 活体重新物化（§3.5）。
- `:delete` —— `manage.delete`，经 Class teardown 映射到 Lifecycle `destroy/2`（§5）。

`required_caps[:reconfigure] = required_caps[:delete] = cap(:any, Manage, :any)`，在 dispatch 时对目标 instance
解析。被授予的 manage-cap（§3.3）满足两者。**无 Session 特例** —— 默认 cap 收窄后（§3.3/§3.11/OQ-4=B），
manage-cap 对 Session 与其它 Kind 一致把门。

### 3.5 `reconfigure` 是一个新的 per-Class hook（D-1）

不存在"把 instantiate 重跑到活体 Kind 上"的能力 —— `instantiate/3` 是创建/adopt 过程（spawn、起 sidecar、
join 成员）；重跑会撞 `put_new` `{:already_started}`。

**层级约束（codex D-1）：** Template Class 不是 Kind 的运行 Behavior。dispatch 只把 effect 归约进被
dispatch 的 behavior 自己的 slice；`{:set, key, v}` 写当前 behavior 的 slice，不能写任意 sibling slice。所以
Class 不能直接写活体 Kind 的 config slice。

**修法：** `manage.reconfigure` 是 **`Ezagent.Behavior.Manage`** 上的动作；Manage 拥有一个小 **`:spec` slice**
记录 Kind 创建/上次 reconfigure 用的 `template_data`（经 Manage 注册在每个 Kind 上）。handler：

1. 对 `new_data` 跑 Class `validate/1`；拒绝身份不可变字段（username、workspace name —— OQ-3）。
2. 把 `new_data` 写进自己的 `:spec` slice（`{:set, :spec, new_data}` —— 同 behavior effect，合法）。
3. 执行 Class 新可选回调返回的 **dispatch effect**：

   ```
   @callback reconfigure(uri, old_data, new_data, ctx) ::
               {:ok, [dispatch_effect]} | {:error, term()}
   ```

   `reconfigure/4` 返回 `{:dispatch, %Ezagent.Cmd{}}` effect（**真实的** effect 文法 —— `{:dispatch, target,
   action, args}` 不是合法形状）—— 用于 re-bind / re-grant / 路由 reconcile / **经 Kind 自己 behaviors 的动作
   更新 config** / 经 `ensure_subprocess_alive/2` 重启 sidecar。effect 管线已执行 dispatch bucket，故这些经
   正常 dispatch 路径到达正确 slice（无新跨 slice 机制）。**内部 dispatch 授权：** 这些是**自分发** ——
   `%Cmd{}` 带 `caller: self_uri`（Kind 重配自己的 behaviors）；config-update 动作允许自分发（Kind 可改自己的
   slice），不牵涉外部 caller 的 cap。需要 config 的 behaviors 经现有 `reads_sibling_slices` 读 Manage 的
   `:spec` slice。

- 同 URI、同身份；运行时 `transients` 不动（除非返回的 dispatch 显式重启 sidecar）。durable `state` 持久，
  `transients` 由 `activate/2` 重建。
- 没有 `reconfigure/4` 的 Class → `manage.reconfigure` 返 `{:error, :reconfigure_unsupported}`（不可变 Kind）。

是一个有界的新增（一个 Manage slice + 一个返回 dispatch 的可选 Class 回调）—— 不是"重跑 instantiate"、也不是
新的跨 slice effect 类型。

### 3.6 Workspace Template Class（提议）

`Ezagent.Template.Workspace`（workspace domain）。`template_data`：`name`、`owner`（默认 `created_by`）、
`default_agent_template`（播种 `<username>-default`）、可选 `default_caps_policy`。`instantiate/3` =
`Workspace.Store.create/2` + `Kind.spawn(Workspace)`。`exists_durably?` 读 `Workspace.Store` 行（Workspace 是
`:ephemeral`，无快照标记；§3.1）。`teardown` 删 Store 行 + 撤销 binding（**不**终止 —— `destroy/2` 负责；§5）。
`Workspace.create/2` 变成入口的薄调用者（授权过）。

### 3.7 User Template Class —— 明确顺序 + 回滚（E-1）

`Ezagent.Template.User`（identity domain）。`template_data`：`username`、`initial_caps`、`default_workspace`、
`default_agent_spec`。**顺序（每步在失败时回滚前一步）：**

1. 持久化 user 行（`Users.create/3`），`caps_json = default_caps ++ initial_caps`，**含用户对自己的
   manage-cap** —— 故自我所有权从建行起就 durable，先于任何 Kind 存在（避免"给还没活的 Kind 授 cap"）。
   回滚：删行。
2. spawn/hydrate User Kind（原子 `:created`）。回滚：终止 + 删行。
3. 经 dispatch 给**创建者 admin/registrar** 授 user 的 manage-cap（即 §3.3 的 core grant，`created_by`=registrar）。
   回滚：revoke。
4. **经同一创建入口**创建 `<username>-default` agent（嵌套）。回滚：teardown agent。

manage-cap 接收者（Allen 批准）：用户本人（self，第 1 步）+ 创建的 admin/registrar（第 3 步）。
`Entity.ensure_spawned/1`（登录）是 rehydrate → 不 re-grant。

**嵌套创建顺序说明：** 默认 agent 创建（第 4 步）经入口递归，但**非**互递归（user 不要求先有 agent；agent 的
`created_by` 是刚建的 user 或 registrar）。无 bootstrap 环。

### 3.8 收编 ad-hoc 路径 + bridge existence 判定（G-2）

| 路径 | 改为 |
|---|---|
| agent-bridge join（`channel.ex:146`） | 调**同一个 `exists_durably?(uri)` 判定**（§3.1）再 spawn：`true`（durable 行存在但未活）→ rehydrate（合法）；`false`（从未创建）→ `{:error, :agent_not_created}`（不静默创建）。Agent 的 `exists_durably?` = `KindSnapshot.ever_created?/1`（spawn 前 `Repo.get`）。判定是"是否 durable 存在"，非"当前是否活着"。 |
| `Workspace.create/2` | dispatch 创建入口（Workspace Template），授权过 |
| 插件 Class `instantiate/3` | Class 代码不变；core 经 `ctx.caller` + 原子 `:created` 结果 grant（§3.1） |
| `Agent.spawn_fresh` / `spawn_from_template_content` | 经入口走；lineage 保留（正交） |
| boot Loader / BootReconciler / login | rehydrate —— 不变，durable 行已存在 → INSERT 返 `:existed` → 不 grant |
| mix tasks / seeds | 经入口（operator 主体）；优先级最低 |

### 3.9 组件小结（隔离边界）

- `Ezagent.Kind.Template`（core）—— Class 契约（签名不变）。
- `Ezagent.Behavior.Template`（core/domain）—— 承载 `kind.create`；**拥有 core 的创建后 manage-cap grant**，
  锁在原子 `:created` + `ctx.caller`。
- `Ezagent.Behavior.Manage`（core）—— `:reconfigure`/`:delete`；注册在每个 Kind 上；manage-cap 把门。
- `Ezagent.Template.Workspace`（workspace domain）—— 新 Class。
- `Ezagent.Template.User`（identity domain）—— 新 Class。
- CI 不变量（test）—— §6。

### 3.10 In-scope 的 CORE 返回值改动（codex rev4 Q4 —— 明确列出）

§3.1 的原子 INSERT 信号需要三处小的、列举出来的 core 改动 —— 是工作项，不是假设：

1. **`Ezagent.Kind.Snapshot.save_now/4`**（及底层 `KindSnapshot` upsert）：初次持久化时返回 **`:created`**
   （新 INSERT）vs **`:existed`**（ON CONFLICT），不再把两者都塌成 `:ok`。现有 `:ok` 调用者容忍更丰富的返回。
2. **`Ezagent.Workspace.Store.create/2`**：区分 **`:created`** vs **`:exists`**（唯一约束冲突），不再透传原始
   `Repo.insert` 错误。
3. **`Kind.spawn/2` → `Kind.Server.init/1`**：把可选 `created_by` create 参数穿进初始 slice / create 上下文
   （Session 的 `owner_uri` 已走这条路）。

### 3.11 收窄默认 user session cap（OQ-4 = B）

`Ezagent.Entity.User.default_caps/1`（`user.ex:175`）现在授予一条 `cap(:session, :any, :any, :any, ws)` ——
"我 workspace 里任何 session 动作"。把 `:any` **action** 换成普通用户实际需要的列举集合，使新 `Behavior.Manage`
动作（`:reconfigure`/`:delete`）**不**被隐含授予：

```
default_caps(ws) = [
  cap(:session, Chat, :send,             instance: :any, ws),
  cap(:session, Chat, :join,             instance: :any, ws),
  cap(:session, Chat, :leave,            instance: :any, ws),
  cap(:session, Chat, :set_working_copy, instance: :any, ws),
]
```

（`behavior` 保持 `Chat` —— 或图简单用 `:any` —— 但 `action` 是列举的，**不是** `:any`。）**必做审计步骤
（在 plan 里，翻转默认前）：** grep 所有 `session://…?action=…` dispatch + Session 上注册的 behaviors 的
`required_caps`，确认列举集合覆盖了今天普通用户合法调用的所有动作。发现用户必须保留的就加进集合；不在集合里的
变成 manage-cap 把门（预期的收紧）。现有用户由 OQ-2 迁移重新授予收窄后的集合。

这是 spec 里**爆炸半径最大**的改动（动系统级 session 授权）—— 它单独一个 PR，审计作为显式前置步骤，
§6 的"正常使用仍可用"回归测试，且（按 merge 边界）hold 待审。

## 4. 数据流

**创建：** caller → dispatch `kind.create`（CapBAC create cap）→ 解析 Class → `validate/1` → `instantiate/3`
（穿 `created_by`=`ctx.caller`）→ 若原子创建返 `:created`（§3.1）授 `cap(:<kind>, Manage, :any, uri)` 给
`created_by` → 返回 uris。spawn 后失败 → Class teardown（§5）。

**修改：** caller → dispatch `manage.reconfigure`（cap `cap(:<kind>, Manage, :any, instance)`，跨 Kind 一致 ——
默认 cap 收窄后无 Session 特例）→ `validate/1` → Class `reconfigure/4` effect 作用于活体 Kind →（若有 sidecar）
`ensure_subprocess_alive/2`。

**删除：** `manage.delete` → Class teardown → Lifecycle `destroy/2`。

**Rehydrate：** `SpawnRegistry.spawn(uri)` → `load_or_init` 找到行 → rehydrate，不 grant。

## 5. teardown / 回滚契约（G-1）

每个 Template Class 声明 teardown —— `@callback teardown(uri, data, ctx) :: :ok | {:error, term()}` —— 只撤销
其 `instantiate` 在**引擎边界之外**造的 durable 副作用（domain 行、授的 cap、workspace/MCP binding、外部
sidecar）。它**不得**终止 Kind 或删快照 —— 那归引擎（codex G-1）。

终止 + 删快照 + developer destroy hook drain 由 Lifecycle `destroy/2` 负责。Class teardown 与之**复合**，不重复
不绕过。用于：
- **创建失败回滚**（fresh spawn 在 grant 处/后失败）：跑 Class teardown（撤 durable）**再** `destroy/2`（终止 +
  删快照）。
- **`manage.delete`**：Class teardown（撤 durable）**再** `destroy/2`。

teardown best-effort + 幂等（双 teardown 安全）；失败记日志、原始 create 错误浮现。grant 是创建最后一步，故 grant
失败只需撤 spawn + Class durable。

## 6. 测试 / CI 不变量

- **单一授权创建路径：** 强化 `agent_create_single_path_test.exs` —— 检测**变量参数**的
  `SpawnRegistry.spawn`/`Kind.spawn` fresh-create 调用，覆盖所有 scheme；只 allowlist 引擎 + rehydrate；
  bridge join 不得被当作 create allowlist。
- **创建即授：** 新建的 Agent/Workspace/User 带 `cap(:<kind>, Manage, :any, self)`（给 `created_by`）；
  rehydrate 不 re-grant、不重复。
- **并发创建只授一次（A-1）：** N 个对同一 URI 的并发 `kind.create` → 恰好一个拿到 `:created` 并授予，
  其余拿 `:existed`/`{:already_started}` 不授（无重复 cap、无缺失 cap）。
- **Template Class + Manage 覆盖：** 每个 Kind 类型都有注册的 Template Class，且 `Behavior.Manage` 已注册。
- **reconfigure 保身份 + state：** `manage.reconfigure` 保持同 URI 且一个代表性运行时 state 字段（Session
  成员；Agent 会话/PTY 存活）。
- **Manage 授权：** 无 manage-cap 的 caller 被拒 `:reconfigure`/`:delete` —— 包括对 Session 的普通 workspace
  成员（证明收窄后的默认 cap 不再吃掉 session-manage；OQ-4=B）。
- **收窄默认 cap 不破坏正常使用：** 新用户用收窄后的默认 cap 仍能对自己 session `send`/`join`/`leave`/
  `set_working_copy`（回归守护 §3.11 审计）。
- **`created_by` 不可外部伪造：** `created_by` 是 `ctx.caller`（已认证）；`template_data` 不能带它。

## 7. 非范围（本 spec）

路由行编辑授权（team-routing 后续）；`manage.transfer`；版本化 template。
（收窄默认 user `:session` cap 现已 IN scope —— OQ-4 = B，§3.11。）

## 8. 决策（Allen 批准）

1. **D1：** 为所有 Kind 引入 Template；统一创建 chokepoint（本工作建立）。
2. **D2：** 修改 = 符合 lifecycle 的重新物化、保身份 + state（非销毁重建）—— 由新 `reconfigure/4` Class hook
   实现（§3.5）。
3. **Manage 面：** 每个 Kind 上一个专用 `Ezagent.Behavior.Manage`；manage-cap = `cap(:<kind>, Manage, :any,
   instance)`（`:any` action —— C-1）。
4. **User manage-cap 接收者：** 用户（self，建行时进 `caps_json`）+ 创建的 admin/registrar。
5. **grant 位置：** core 创建步，由原子 INSERT 结果（`:created` vs `:existed`，§3.1/§3.10）把门，用穿入的
   `created_by`=`ctx.caller`（插件 Class 不变）。

## 9. Open questions（均已拍定 2026-06-02）

- **OQ-1（已定）：** `kind.create` **复用现有 per-scope create cap**（`workspace.create_agent` 等）；入口是
  dispatch 面，cap 是 per-scope。不新造 create-cap。
- **OQ-2（F-1，已定）：** 一次性迁移脚本从 durable 表推 owner（Session `owner_uri`；Agent
  lineage/`creator_uri`）；**Workspace 无 owner 字段 → 默认 owner = bootstrap-admin**。显式"找不到 owner"
  处理（不静默跳过）。非 activate-backfill。
- **OQ-3（已定）：** 身份字段（username、workspace name）不可变 —— `validate`/`reconfigure` 拒绝其变更。
- **OQ-4（C-1，已定 = B）：** 收窄默认 user `:session/:any/:any` cap 到列举的安全动作（§3.3/§3.11）；
  无 Session `owner_uri` 补丁。
