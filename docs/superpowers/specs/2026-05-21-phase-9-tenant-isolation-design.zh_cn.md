# Phase 9 — 租户隔离设计（URI / Capability / Dispatch 的 SPEC v3）

> **状态**: DRAFT — 2026-05-21。下一轮开发者按照 Phase 9 handoff
> (`/tmp/phase-9-handoff-prompt.md`) 起草。Allen AFK；预先决策直接
> 取自 framing doc (`docs/notes/workspace-as-deployment-unit.md`)。
> 未决问题集中在 §10。

## 0. 为什么需要 Phase 9

`docs/notes/workspace-as-deployment-unit.md` 把 workspace 定义为
**deployment unit（部署单元）**。当前（Phase 8c）workspace 隔离了
70% — session 归属、routing rules、session templates、members。剩余
30%（entities、capabilities、跨 workspace dispatch、持久化、auth）
就是 Phase 9 要补齐的部分。

Phase 9 之后，"部署单元" 这个承诺从运维约定升级为结构性保证。同
一台主机上两个 workspace 互相看不见对方的 users / agents /
sessions / messages / caps，除非显式持有 cross-workspace cap。
Auth 携带 workspace 上下文。从此进入多主机部署只是运维变更，不再是
架构变更。

## 1. 目标

1. **每个 entity URI 携带 workspace** — 所有 `entity://` URI 把
   workspace 作为 path segment（framing doc 的 Option A）。
2. **Capability 加入 workspace 维度** — `Ezagent.Capability` 新增
   `workspace_uri` 字段；matcher 拒绝跨 workspace 使用，除非
   caller 持有 `cross-workspace:dispatch`。
3. **跨 workspace dispatch 策略** —
   `Ezagent.Invocation.dispatch/1` 新增隔离 step：caller 所在
   workspace == target 所在 workspace，或 caller 持有 cross-workspace
   cap。
4. **租户感知 auth** — 登录时从 `current_entity_uri` 推导出
   `current_workspace_uri`；workspace 下拉菜单变成真正的上下文切换
   器（需要 cross-workspace cap）。
5. **每 workspace 数据隔离** — sessions / messages / invocations /
   snapshots / caps 表加 `workspace_uri` 列；读时按 workspace 过滤；
   写时断言非空。

## 2. 非目标

- **不做多主机部署。** Phase 9 让多主机变得可行，但实际落地是 Phase 10+。
- **不做每 workspace 独立数据库/schema。** 暂时共享单个 SQLite；
  隔离靠列而不是 tablespace。
- **不做 workspace 级别的限流或配额。** 留待将来。
- **不复活 `user://` / `agent://`。** SPEC v2 的删除决定不变。
- **不为 Phase-9 前的 URI 形态写兼容垫片。** 直接 wipe + rebuild
  （遵循 memory `feedback_let_it_crash_no_workarounds`）。
- ~~**不改 session/template 的 URI 形态。** Phase 9 只动 `entity://`。~~
  **Amendment 2 (Allen 2026-05-21): URI scheme 统一在本期完成。**
  session/template/resource 也加 workspace 段（§3.6）。原因：不统一
  workspace 迁移就不完整 — sessions 仍然要 out-of-band
  `WorkspaceRegistry` lookup 才能知道 workspace，违反 "URI 告诉你
  一切" 原则。
- **永远不支持多 workspace 成员**（Allen 2026-05-21 确认）。
  Keycloak realm 模型：一个 entity 永久属于唯一一个 workspace。
  `workspace://system` 成员有跨 workspace 权限但**不是**其它
  workspace 的成员 — 他们操作 ON 其它 workspace，不是 IN 其它
  workspace。见 §13。

## 3. URI 形态 — SPEC v3（仅 entity scheme）

### 3.1 新形态

    entity://<type>/<workspace_name>/<entity_name>

| 当前（SPEC v2）              | Phase 9（SPEC v3）                        |
|------------------------------|-------------------------------------------|
| `entity://user/admin`        | `entity://user/default/admin`             |
| `entity://user/allen`        | `entity://user/team-alpha/allen`          |
| `entity://agent/echo_default`| `entity://agent/default/echo_default`     |
| `entity://agent/cc_demo`     | `entity://agent/team-alpha/cc_demo`       |

- `<type>` ∈ `{user, agent}`（封闭集，SPEC v2 §5.12 不变）。
- `<workspace_name>` 是 workspace 的裸名称（即 `workspace://<name>`
  里的 `<name>` 段）。必须匹配正则 `^[a-z][a-z0-9_-]*$`（小写+数字+
  短横+下划线；workspace 创建已经强制，Phase 9 把它编码到 URI
  parse-time 检查里）。
- `<entity_name>` 保留现有的自由格式约定（小写，agent 带 flavor
  前缀：`cc_demo`, `curl_my-thing`, `echo_default`）。

### 3.2 Parser 改动

`Ezagent.URI.parse!/1` 对 `entity://` 的扩展：

- 仅接受 3-segment authority path (`/<workspace>/<name>`) —
  2-segment 路径 (`/admin`) 抛
  `ArgumentError: entity URI must include workspace segment`。
- 拒绝 4+ segments — 子资源位（sub-resource）保留不变。

`Ezagent.URI.instance/1` 对 `entity://` 的行为：

- 返回带完整 3-segment path 但去掉 query/fragment 的 URI:
  `entity://user/default/admin?action=identity.list_caps` →
  `entity://user/default/admin`.

### 3.3 新 helper: `entity_workspace_uri/1`

```elixir
@spec entity_workspace_uri(URI.t()) :: URI.t()
def entity_workspace_uri(%URI{scheme: "entity", path: "/" <> rest}) do
  [workspace_name, _entity_name] = String.split(rest, "/", parts: 2)
  URI.new!("workspace://" <> workspace_name)
end
```

被以下模块调用：
- Dispatch（§5）提取 caller / target workspace。
- LiveAuth（§6）从 `current_entity_uri` 推导 `current_workspace_uri`。
- Cap matcher（§4.2）执行 workspace 维度判定。

### 3.4 持久化存储

- 数据库列里存的 entity URI（caps、audit、users、agents、workspace
  memberships、message authorship 等）一律存 3-segment 完整字符串。
  不做"按需拆分老数据"的迁移脚本 —— wipe + rebuild。

### 3.6 URI scheme 统一（Amendment 2 — Allen 2026-05-21）

**原 SPEC 把 Phase 9 限定在 entity scheme。** Allen 纠正：
`session://`, `template://`, `resource://` 的统一**必须**在 Phase 9
完成。否则 session 仍然要 out-of-band `WorkspaceRegistry` lookup，
违反 "URI 告诉你一切"。

新 SPEC v3 形态对所有 per-tenant scheme:

| Scheme | 今天 (v2) | Phase 9 (v3) |
|--------|-----------|--------------|
| `entity://` | `entity://user/admin` | `entity://user/default/admin` |
| `session://` | `session://default/main` | `session://default/default/main` (template/workspace/name) |
| `template://` | `template://agent/cc-orch` | `template://agent/default/cc-orch` |
| `resource://` | `resource://uploads/x` | `resource://uploads/default/x` |
| `workspace://` | `workspace://default` | 不变 (workspace 是 tenant root) |
| `system://` | `system://routing/default` | 不变 (system 是 cross-cutting) |

统一后:
- `WorkspaceRegistry` 从权威 source 降级为一致性 cache。新 invariant
  test: 每个 `WorkspaceRegistry` binding 等于被绑定 session URI 的
  workspace 段。
- Dispatch step 5.6 的 `workspace_of/1` 变成纯结构性 — O(1) 从 URI
  字符串提取 workspace，不再 ETS lookup。
- 所有 entity 创建路径（sessions, templates, resources）要显式 workspace
  参数；数据层边界没有"默认 default"兜底（只在用户输入解析边界，
  参见 SessionPrincipal §6.2）。

### 3.5 为什么选 URI 携带 workspace（Option A）而不是 ambient context（Option B）

参考 framing doc §"Per-workspace entity URIs" — Option A：

- URI 告诉你一切；不需要 out-of-band lookup。
- Auth token 携带完整 URI；租户上下文跟随 principal。
- 同样的 handle 在两个 workspace 里就是两个独立 entity（隔离干净）。
- Cap matching 从 URI 字符串 O(1) 提取 workspace。

Option B（dispatch envelope 里塞 `%{workspace: ws_uri}`）被否决：
ambient context 容易忘；cap matcher 要做 2-key lookup；如果
envelope 没有被验证就有数据泄露风险。

## 4. Capability — workspace 维度

### 4.1 struct 改动

```elixir
defstruct [
  :kind,
  :behavior,
  :instance,
  :workspace_uri,   # 新增 — %URI{scheme: "workspace"} | :any
  :granted_by,
  :granted_at
]
```

- `workspace_uri` 构造时**必填**（不允许默认 `:any`）。
- `:any` 仅用于 bootstrap admin cap 和显式的 cross-workspace 授权。
  结构上必经路径是具体的 workspace URI。
- 之前构造 `Capability` 的所有调用点必须传 `workspace_uri:` —
  通过 `@enforce_keys` 在编译期强制。

### 4.2 Matcher 改动

```elixir
def matches?(%__MODULE__{} = cap, %{kind: k, behavior: b, instance: i, workspace_uri: w}) do
  field_match?(cap.kind, k) and
    field_match?(cap.behavior, b) and
    instance_match?(cap.instance, i) and
    workspace_match?(cap.workspace_uri, w)
end

defp workspace_match?(:any, _), do: true
defp workspace_match?(%URI{} = held, %URI{} = needed),
  do: URI.to_string(held) == URI.to_string(needed)
defp workspace_match?(_, _), do: false
```

- `Ezagent.Capability.cap_for_action/3` 扩展：从 target URI 通过
  `URI.entity_workspace_uri/1` 推导 needed workspace（entity target），
  或通过 `WorkspaceRegistry.lookup/1`（session target）。

### 4.3 Grant API 改动

```elixir
# 之前:
Ezagent.Identity.grant_cap(entity_uri, %{kind: ..., behavior: ..., instance: ...}, granter_uri)

# 之后:
Ezagent.Identity.grant_cap(
  entity_uri,
  %{kind: ..., behavior: ..., instance: ..., workspace_uri: workspace_uri_or_any},
  granter_uri
)
```

- granter 所在 workspace 是 grantee workspace 的默认值（绝大多数 cap
  是 intra-workspace）。
- Cross-workspace grant 要求 granter 持有 `cross-workspace:dispatch`
  **且**显式传 `workspace_uri: :any` 或与自己不同的 workspace URI。
  在 grant-time 就拒绝，不留到 use-time —— fail loudly。

### 4.4 Bootstrap admin cap

Decision #81 的结构性 invariant 变为：

```elixir
%Ezagent.Capability{
  kind: :any,
  behavior: :any,
  instance: :any,
  workspace_uri: :any,        # 结构上的 cross-workspace
  granted_by: URI.parse("system://bootstrap/default"),
  granted_at: ...
}
```

`Ezagent.Capability.admin_invariant?/1` 同步更新，要求
`workspace_uri: :any` 与原本的 triple-:any 一起判定。

### 4.5 User self-cap default

`Ezagent.Entity.User.default_caps/0`（Decision #133 / invariant 6）
返回限定在该 user 所在 workspace 的 cap：

```elixir
def default_caps(workspace_uri) do
  [%Ezagent.Capability{
    kind: :session,
    behavior: :any,
    instance: :any,
    workspace_uri: workspace_uri,   # 不是 :any
    granted_by: URI.parse("system://bootstrap/default"),
    granted_at: DateTime.utc_now()
  }]
end
```

User 默认可以在自己 workspace 里发消息；跨 workspace 发消息需要
显式的 cross-workspace cap。

## 5. 跨 workspace dispatch 策略

### 5.1 新 cap

```elixir
%Ezagent.Capability{
  kind: :any,
  behavior: :any,
  instance: :any,
  workspace_uri: :any,    # 结构上的 cross-workspace 标记
  granted_by: ...,
  granted_at: ...
}
```

与 admin invariant cap 形态一致。一个**非 admin 的 cross-workspace
cap**可以收窄 `kind` / `behavior` / `instance`，但保持
`workspace_uri: :any`。

约定：`workspace_uri == :any` 的 cap 即**cross-workspace cap**。
故意稀有 + admin 管理。

### 5.2 Dispatch step

`Ezagent.Invocation.dispatch/1` 在 cap-check（step 5.5）和
target-resolution 之间插入新 step：

```
5.6 Workspace isolation check:
    caller_ws = URI.entity_workspace_uri(ctx.caller)
    target_ws = workspace_of(invocation.target)
    cond do
      caller_ws == target_ws -> :ok
      Enum.any?(ctx.caps, &cross_workspace?(&1)) -> :ok
      true -> {:error, :cross_workspace_denied}
    end
```

- `cross_workspace?/1` 返回 true 当 `workspace_uri == :any` **且**
  cap 仍然授权该 action（即已经过了 step 5.5）。
- 拒绝返回 `:cross_workspace_denied`（新错误 atom），与
  `:unauthorized` 区分开。Inbound transports 按 invariant 9
  发出不同的错误消息。

### 5.3 Workspace-of resolver

```elixir
defp workspace_of(%URI{scheme: "entity"} = uri),
  do: Ezagent.URI.entity_workspace_uri(uri)

defp workspace_of(%URI{scheme: "session"} = uri) do
  case Ezagent.WorkspaceRegistry.lookup(uri) do
    {:ok, ws} -> ws
    :error -> raise "session #{uri} has no workspace binding (invariant 4 violated)"
  end
end

defp workspace_of(%URI{scheme: "workspace"} = uri), do: uri
defp workspace_of(%URI{scheme: "system"} = _uri), do: :system_scope
```

`:system_scope` 直接跳过 workspace isolation —— system scheme
（routing / bootstrap）按设计是 cross-cutting 的。

### 5.4 Invariant test

`apps/ezagent_core/test/invariants/cross_workspace_isolation_test.exs`：

- Setup: 2 个 workspace（default、team-alpha），每个一个 user，
  各持默认 caps。
- 断言: `entity://user/default/admin` 不能向
  `entity://agent/team-alpha/cc_demo` dispatch `chat.send` →
  `{:error, :cross_workspace_denied}`。
- 断言: 给 admin 授予 cross-workspace cap → 同样的 dispatch 成功。
- 断言: 撤销 → 再次失败。

## 6. 租户感知 auth

### 6.1 登录流程

`EzagentWeb.SessionPrincipal.put/2`（`:current_entity_uri` 的唯一
合法 writer）新增副作用：同时写
`:current_workspace_uri`，从 entity URI 的 workspace 段推导。

```elixir
def put(conn, raw) when is_binary(raw) do
  canonical = canonicalize(raw)
  entity_uri = URI.parse(canonical)
  workspace_uri = Ezagent.URI.entity_workspace_uri(entity_uri)

  conn
  |> configure_session(renew: true)
  |> put_session(:current_entity_uri, canonical)
  |> put_session(:current_workspace_uri, URI.to_string(workspace_uri))
end
```

### 6.2 Bare-handle canonicalization

Phase 8c 的 bare-handle 路径
（`SessionPrincipal.canonicalize("admin")` → `"entity://user/admin"`）
现在必须携带 workspace。两个 UX 选项：

- **A** — 默认 workspace 回退：bare `"admin"` →
  `"entity://user/default/admin"`。快、无需 UI surface 暴露
  workspace。
- **B** — 必须显式 workspace：bare `"admin"` 拒绝；user 必须输入
  `"default/admin"` 或 `"team-alpha/admin"`。

**推荐 A** —— canonicalize-time 用默认 workspace 兜底；登录表单加
一个可选的 "Workspace" 字段（默认 `default`）。保留 Phase 8c 已经
建好的 bare-handle ergonomics。

### 6.3 LiveAuth on_mount

`EzagentWeb.LiveAuth.on_mount/3` 同时读两个 session slot 并 assign：

```elixir
socket
|> assign(:current_entity_uri, parsed_entity)
|> assign(:current_workspace_uri, parsed_workspace)
```

LV scope（live_session :require_entity）自动继承两个。

### 6.4 Workspace 选择器 = 权限分支（Amendments 1 + 3）

**经过两次修正。** 原 SPEC 的"保持身份 + 换 workspace"结构性不
通。Amendment 1（2026-05-21 上午）说"统一 logout + 重登"。
Amendment 3（2026-05-21 下午）进一步：行为按 caller 权限分支：

**统一流程**（点选其它 workspace）:

1. POST `/workspaces/switch` 带 target ws。
2. Controller 检查: caller 是 `workspace://system` 成员吗?
   - **是（system 成员）** → 上下文切换。更新
     `:current_workspace_uri` 到 target；**保留**
     `:current_entity_uri`。LV 在新 workspace scope 下重 mount；
     UI 显示 "Operating on `<target_ws>` as `system/admin`"。
     （详见 §13.2 系统成员视图。）
   - **否（普通 user）** → 拒绝。渲染提示页:
     "您无权查看 workspace `<target_ws>`。请以该 workspace 成员
     身份登录。" 提供 "登录到 `<target_ws>`" 按钮 → 重定向到
     `/login?workspace=<target_ws>`，清当前 session 并预填
     workspace。

普通 user 路径**不**自动 logout；user 必须显式选择登出 + 重登。
避免普通 user 误点不属于自己的 workspace 时丢失 session。

**为什么权限分支而不是统一 logout（Amendment 3 理由）**:

- system 成员**应该**无缝切换上下文 —— 这就是 Keycloak realm-admin
  模型 (§13) 的精髓。
- 普通 user **应该**被告知为什么不能，不是被静默登出。Phase 8c
  bare-handle bounce bug 教训：静默 session 变化是最糟糕的 UX
  （user 无法判断发生了什么）。
- 权限检查在 cap 层；controller 不需要预判 "switch vs re-login"
  —— 评估 cap 后再分支。

为什么这是对的：

- **URI 告诉你一切（Option A）** —— 如果 workspace 在 URI 里，
  那么 "current entity" 已经钉住了 workspace。再单独维护一个
  "current workspace" assign 可以和
  `entity_workspace_uri(current_entity_uri)` 不一致 —— 这是结构性
  不一致。
- **Cross-workspace cap 是给 DISPATCH 用的，不是冒充** —— admin
  在 `default` workspace 持 cross-workspace cap 可以**发送**消息
  给 `team-alpha` 的 agent。但不能**变成** `team-alpha` 的
  admin —— 那需要重新认证为那个不同的 entity。
- **可审计性** —— 每个 action 的 `ctx.caller` 明确属于一个
  workspace 的 entity。没有"环境 workspace"叠加层让你忘记。

冗余 assign 说明: `:current_workspace_uri` 仍然由
`SessionPrincipal.put/2`（§6.1）写入，因为 LV scope 直接读它，避免
每次 render 都 re-parse entity URI —— 它是个 derived cache。但它
**必须**始终等于 `entity_workspace_uri(current_entity_uri)`；一个
invariant test 断言这一点。

### 6.5 SessionPrincipal codebase invariant 更新

现有的 invariant test
(`session_principal_test.exs:101 — no direct put_session(:current_entity_uri, _)`)
扩展为：

- `:current_workspace_uri` 也不允许在 `SessionPrincipal.put/2` 和
  workspace-switch controller 的 clear 路径之外直接 `put_session`。
- 新 invariant test: 任何 session 同时设了两个 slot 时，
  `:current_workspace_uri` ==
  `entity_workspace_uri(:current_entity_uri)`。

## 7. 数据隔离 — 每租户表加列

### 7.1 加 `workspace_uri` 的表

| 表                 | 用途                                  | 说明                          |
|--------------------|---------------------------------------|-------------------------------|
| `caps`             | Identity slice 持久化                | 新增列；从 cap struct 派生 |
| `sessions`         | Session Kind 持久化 (Snapshot)        | Workspace.Loader 已经隐式带；升为显式列 |
| `messages`         | MessageStore                          | 新增列；从 session 的 workspace 复制 |
| `invocations`      | 审计日志                              | 新增列；从 caller+target 推导 |
| `snapshots`        | per-Kind on-change snapshots          | 新增列；从 owning Kind URI 推导 |
| `users`            | User Kind 基础表                     | 新增列；从 URI 推导 |
| `agents`           | Agent Kind 基础表                    | 新增列；从 URI 推导 |
| `routing_rules`    | 已有 `workspace_uri`                  | 无改动 |
| `workspaces`       | Workspace.Store                       | 无改动（workspace 本身不带 tenant scope） |
| `templates`        | SessionTemplate/AgentTemplate         | 新增列；template 是 per-workspace |

### 7.2 读时过滤

per-tenant 表的每个读查询必须按 `workspace_uri = ?` 限定。模板
（Ecto）：

```elixir
def list_messages(session_uri, %URI{} = workspace_uri) do
  from(m in Message,
    where: m.session_uri == ^session_uri and
           m.workspace_uri == ^URI.to_string(workspace_uri)
  )
  |> Repo.all()
end
```

Helper: `Ezagent.Persistence.scope_by_workspace/2` 统一 where-clause
方便审计。

### 7.3 写时断言

Insert 必须设置 `workspace_uri`；changeset 规则拒绝 nil。单独
test 用 grep gate 断言没有 `insert(... %{workspace_uri: nil})` 调用点。

### 7.4 Invariant test

`apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`：

- 遍历注册的 schema；断言每个 per-tenant 表都有
  `workspace_uri` 列（或在显式豁免名单上：`workspaces`,
  `system_*`）。
- 将来加 schema 时忘了 `workspace_uri`，立刻失败。

## 8. 迁移方案 — wipe + rebuild

遵循 `feedback_let_it_crash_no_workarounds` + SPEC v2 §5.11 先例。

### 8.1 迁移步骤

1. **删 dev DB** (`apps/ezagent_core/priv/repo/data/*.db`)。
2. **重置 Ecto migration**（表 schema 改了 —— `workspace_uri` 列
   新增 + entity URI 字符串格式）。
3. **启动 phx** —— `Ezagent.Workspace.create("default", %{})`
   （PR-M 的幂等 seed）先跑；admin + echo_default seed 进
   `workspace://default` 用新的 URI 形态。
4. **跑 invariant tests** 确认干净状态。

### 8.2 生产数据说明

ezagent 还没 v1.x 生产部署；wipe-rebuild 没有用户数据影响。**如果
将来有了**，Phase 10 的 "namespacing migration" 带 backfill 脚本
作为独立工作项。

### 8.3 文档更新

- `ARCHITECTURE.md` Decision Log: 追加 Decision #145（URI SPEC v3
  + per-workspace entity scoping），带 WHY + DRIFT DEFENSES。
- `docs/notes/uri-design.md` §5: 追加 `§5.15 — Per-workspace
  entity URIs (SPEC v3, Phase 9)`。§5.12（entity:// 合并）保留；
  v3 是扩展不是替换。
- `.claude/skills/ezagent-developer/SKILL.md`:
  - 更新 invariant 11 注明 entity 的 3-segment。
  - 加 invariant 13: 跨 workspace dispatch 需要
    `cross-workspace:dispatch` cap。
  - 更新 §"Anti-patterns": "我写一个 workspace-scoped cap 但不带
    workspace_uri 字段" → 拒绝。
- `docs/notes/workspace-as-deployment-unit.md`: 把 "30% gap →
  Phase 9" 表述改成 "100% — Phase 9 在 <YYYY-MM-DD> 关闭"。
  `.zh_cn.md` 同步。

## 9. PR 序列（6 个 PR）

| PR | 标题 | LOC 估 | 依赖 |
|----|------|--------|------|
| 1  | SPEC + framing-doc 更新 + Decision Log 条目 | 600（纯文档）| — |
| 2  | URI v3 parser + entity 迁移（wipe + seed）+ invariant test | 900 | 1 |
| 3  | Capability workspace 维度 + grant API + admin invariant 更新 | 700 | 2 |
| 4  | 跨 workspace dispatch enforcement + cap + invariant test | 600 | 3 |
| 5  | 租户感知 auth + workspace switcher + UI 门控 | 800 | 4 |
| 6  | 数据隔离列 + 读过滤 + 写断言 + invariant test | 1200 | 5 |

PR-6 落地后，按 `feedback_completion_requires_invariant_test` 的
完成标准 Phase 9 "完成"：4 个新 invariant tests 如果任何一个 PR
被回滚或代码漂移会立即失败。

## 10. 未决问题（小）

故意收窄 —— 绝大多数决策已由 framing doc + 本 SPEC 锁定。Allen
可在 PR review 时推翻任何一个。

- **Q1 — Bare-handle 登录行为（§6.2）**：A（默认 workspace 回退）
  还是 B（必须显式 workspace）？**推荐 A**。
- **Q2 — Workspace-switch 时 session-slot 语义（§6.4）**：~~我原本
  判断：**不** —— 身份固定；workspace 只是行动范围。~~
  **Allen 纠正 2026-05-21: 是，切换 workspace 同时清
  `:current_entity_uri` 和 `:current_workspace_uri`。** 原因:
  entity URI 是 workspace-bound（3-segment）；
  `entity://user/default/admin` 和
  `entity://user/team-alpha/admin` 是不同的 entity。没有"保持身份
  + 换 workspace"的语义。切换跳转到
  `/login?workspace=<target>`。详见 §6.4 修正后的流程。
- **Q3 — 跨 workspace grant 时 granter 的 workspace 默认（§4.3）**：
  admin 授权时，cap 应该默认 granter 的 workspace 还是 grantee
  的？**推荐 grantee 的** —— grantee 是真正用 cap 的 principal。
  Granter 必须显式传 `workspace_uri: <grantee_ws>` 或 `:any`。
- **Q4 — Workspace name 保留字**：`_system`, `admin`, `default`,
  `system`。Workspace 创建表单应该拒绝哪些？**推荐拒
  `_system` 和 `system`（前向兼容），允许 `admin` / `default`
  （bootstrap 已经在用）**。

## 11. 验证清单

6 个 PR 全部落地后，以下断言必须成立：

1. `entity://user/admin` 被 `Ezagent.URI.parse!/1` 拒绝，错误
   信息 "must include workspace segment"。
2. `entity://user/default/admin` 能 parse；
   `entity_workspace_uri/1` 返回 `URI.new!("workspace://default")`。
3. `Ezagent.Capability` struct 6 个字段；构造时不传
   `workspace_uri:` 编译失败（`@enforce_keys`）。
4. `Ezagent.Identity.grant_cap("entity://user/default/admin", %{...,
   workspace_uri: ws}, granter)` 成功；cap 出现在
   `list_caps_for/1` 输出里，保留 workspace 维度。
5. 双-workspace-双-user invariant test
   (`cross_workspace_isolation_test.exs`) 通过：没有 cross-workspace
   cap 时跨 workspace dispatch fail closed。
6. 登录 admin → session 同时有 `:current_entity_uri` 和
   `:current_workspace_uri`。
7. 没有 cap 的 workspace-switch POST → 403；有 cap → session
   更新。
8. SQLite 查询: `SELECT count(*) FROM messages WHERE workspace_uri
   IS NULL` 在干净 DB 上返回 0。
9. `mix test --include slow` 全绿（没有 Phase 8c 遗留 test 因
   URI 形态变化而坏掉）。

## 12. 超出范围（留给 Phase 10+）

- 每 workspace 独立 SQLite DB（多租户 SaaS 部署）。
- Workspace export / import / migration 工具。
- Workspace 级别配额（max sessions、max API keys 等）。
- 多 workspace 成员关系（同一 user 一个身份出现在两个 workspace）。
- 统一所有 scheme 的 URI 形态（session:// / template:// /
  resource:// 也加 workspace 段）—— SPEC v4。
- Workspace 计费 / 用量上报。

---

## 13. System workspace + Keycloak-realm membership (Amendment 2)

Allen 2026-05-21 引入 Keycloak realm-admin 模型。两个结构变化:

### 13.1 `workspace://system` 是真实 workspace

Bootstrap admin (`entity://user/system/admin`，**不是** PR-2 seed 的
`entity://user/default/admin`) 住在 `workspace://system` workspace。
该 workspace 在 boot 时与 `workspace://default` 一起创建，结构性特权:

- `workspace://system` 成员**因成员身份**而持有 bootstrap admin cap
  (`workspace_uri: :any`)，不是逐 cap 显式 grant。
- `workspace://system` 在缺少 `workspace://system` 成员身份或跨
  workspace admin cap 的 caller 的 per-caller workspace 列表里
  **不出现**。机制：`Ezagent.Workspace.list_workspaces_for/2`
  （SPEC `2026-05-27-workspace-cap-based-visibility.md`）。
  可见性由 cap 派生，不再依赖字段 — 原 `:visible` 布尔字段已
  **删除**。**2026-05-27 由 SPEC #423 §4.3 修订。**
- 迁移: PR-2 已 seed 的 `entity://user/default/admin` 变为
  `entity://user/system/admin`。Bootstrap seed 更新。

### 13.2 Workspace 切换 UX 分支（system vs. 普通）

**Amendment 3 进一步澄清。** §6.4 权限分支 switcher 按 caller 成员
身份双分支:

对 `workspace://system` 成员:

- UI 里的"workspace 选择器"标签为"Operate on workspace"
  （或"操作 workspace"）。
- 点其它 workspace → 上下文切换（不登出）。更新
  `:current_workspace_uri` 到 target；**保留**
  `:current_entity_uri` 为 `entity://user/system/admin`。
- 系统成员的 `:current_workspace_uri` 可以是任何 workspace；
  §6.5 invariant
  (`current_workspace_uri == entity_workspace_uri(current_entity_uri)`)
  对系统成员**放宽**。
- 所有 UI surface 显示"Operating on `<workspace>` as `system/admin`"，
  让系统管理员始终知道操作影响哪个 workspace。

对普通 workspace 成员（不在 `workspace://system` 里）:

- Workspace 选择器显示所有 workspace，但除自己 workspace 外都加
  锁视觉标记。点击锁定 workspace → "登录到 `<workspace>`" 提示
  （按 §6.4 Amendment 3）。
- 自己的 workspace 高亮为"当前"。
- 永远看不到 `workspace://system`（他们不是成员；caps 也不引用它
  — 由 cap 派生，按 §13.1 2026-05-27 修订 / SPEC #423）。

这就是 Keycloak master-realm admin 模型 — 系统管理员保持自己身份
+ 上下文切换；普通用户固定在自己的 workspace，除非显式重新认证。

### 13.3 Cap-loading flow

Step 5.6 (`Capability.cross_workspace?/1`) 扩展:

```elixir
def cross_workspace?(%Capability{workspace_uri: :any}), do: true
def cross_workspace?(%Capability{} = cap, %URI{} = caller_uri) do
  # 基于成员身份的跨 workspace: caller 是 workspace://system 成员
  caller_workspace = Ezagent.URI.entity_workspace_uri(caller_uri)
  URI.to_string(caller_workspace) == "workspace://system"
end
```

Dispatch step 调 `cross_workspace?(cap, caller_uri)` 而不是
`cross_workspace?(cap)`。原有 test 通过 arity overload 保留。

### 13.4 Bootstrap seed 改动

`apps/ezagent_core/priv/repo/seeds/*` (或等效 `Application.start/2`
boot-time seeding):

```elixir
# system workspace 先建
{:ok, _} = Ezagent.Workspace.create("system", %{})

# default workspace
{:ok, _} = Ezagent.Workspace.create("default", %{})

# admin 在 system workspace (不是 default)
{:ok, _} = Ezagent.Users.create("entity://user/system/admin", "<password>", [])
```

**2026-05-27 由 SPEC #423 §4.3 修订。** workspaces schema 上的
`:visible` 布尔字段已删除；`workspace://system` 不再需要逐行
隐藏标志。可见性由 cap 派生，通过
`Ezagent.Workspace.list_workspaces_for/2` 计算 —
`workspace://system` 出现在 caller 的列表里当且仅当 4 谓词
admin shortcut 触发（bootstrap-wildcard cap、结构性跨 workspace
admin cap、URI host = `system`、或 `workspace://system` 显式
成员身份）。

### 13.5 与已合并 PR-2 的迁移影响

- PR-2 seed admin 为 `entity://user/default/admin`。Amendment 2 要求
  `entity://user/system/admin`。PR-7 (URI 统一) 会包含 re-seed 作为
  wipe + rebuild 步骤。
- 任何 `granted_by: entity://user/default/admin` 的 cap grant 需要
  re-key。因为是 wipe-rebuild，自动处理。
- LV `Ezagent.Identity.admin?/1` 检查保留 — 只是改对比
  `entity://user/system/admin`。

## 14. PR 序列 (Amendment 2 — supersedes §9)

| # | 标题 | 状态 |
|---|------|------|
| 1 | SPEC + framing-doc 更新 | ✅ merged #158 |
| 2 | URI v3 parser + entity 迁移 (entity scheme only) | ✅ merged #159 |
| 2.5 | SPEC amendment — workspace switch = logout | ✅ merged #160 |
| 3 | Capability workspace 维度 | ✅ merged #161 |
| 4 | Cross-workspace dispatch enforcement | ✅ merged #162 |
| 5 | Tenant-aware auth + workspace switcher | ✅ merged #163 |
| 6 | per-tenant 数据隔离列 | ✅ merged #164 |
| 6.5 | Test pool size fix (根因: dispatch concurrency) | ✅ merged #165 |
| 6.6 | SPEC amendment 2 (本文件) | ← in flight |
| 7 | URI scheme 统一 (session/template/resource 加 workspace) | pending |
| 8 | System workspace + Keycloak-realm membership 模型 | pending |
| 9 | Demo 录制 (admin + cc + echo + routing) | pending |

PR-7 是最大改动。PR-8 落地后，amended Phase 9 关闭。

## 实施指引

PR-1 落地后，下一会话应使用
`superpowers:subagent-driven-development`，遵循
`feedback_subagent_must_load_project_skills`（subagent prompt 必
须 load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`）。

分支策略：从 main 拉 feat branch（如
`feat/phase-9-tenant-isolation`），每个 PR squash-merge。如果
main 已经有差异，按 `feedback_promote_dev_to_main` 的 promote
模式。Admin-merge 已预授权（`feedback_admin_merge_authorized`）。
