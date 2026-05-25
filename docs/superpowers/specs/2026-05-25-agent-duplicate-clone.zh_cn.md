# SPEC — Agent 复制/克隆原语 (Behavior.Agent `:duplicate`)

**状态:** DRAFT rev 2 · 2026-05-25（codex r1 修复）
**层级:** `apps/ezagent_domain_chat/`（新 `Behavior.Agent` + action）+ `apps/ezagent_core/`（Kind.Template snapshot callback + BehaviorRegistry 插槽）+ `apps/ezagent_plugin_cc/`（cc snapshot 实现）+ `apps/ezagent_domain_workspace/`（mix task 薄包装）
**触发:** Allen 2026-05-24（memory `feedback_agent_clone_not_via_template`）—— "agent 创建的 template 如果不走正常的 template 创建和 fork 流程，可能导致开发 drift，但如果走标准流程，又可能导致 Template Registry 里面大量临时创建后再也不用的 template"。Clone 必须作为 domain.agent primitive 存在，**绝不**走 Template Registry。
**前置:**
- `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md` —— `Behavior.Workspace.:create_agent`（**不**复用 spawn —— 详 §3.4 rev-2 修复）
- PR #289 (`2c66903`) —— per-agent config_dir + Kind.Template 扩展回调
- PR #288 —— `Ezagent.Behavior.Sandbox`（持有 `config_dir_path` + `template_class` 的 slice）
- PR #330 (`8277d08`) —— `Ezagent.Workspace.create_agent/3` facade（引用但不复用）
- `feedback_let_it_crash_no_workarounds` —— 不要 `:warning + degrade`、不要 shim
- `feedback_uuid_is_canonical_identifier` —— agent URI 为权威标识；username 仅显示
- `feedback_fork_is_generic_template_concern` —— Template 级 fork（PR1 #287）和本 Agent 级 clone 是两件事
- SPEC `caps-data-ownership-v2.md` §3.3 + §5.2（CapBAC 默认 grant + admin 分支）
**英文对照:** `2026-05-25-agent-duplicate-clone.md`

**Rev 2 变更（codex r1 verdict needs-attention → 已处理）:**
- CRITICAL: 现在**要求**源端授权 —— 仅有目标 ws-admin **不能**外泄源 config（§4）
- HIGH: `data_owner/1` 返回 `:no_owner`；duplicate cap 是 admin 显式 grant，不自动推导（§4.2）
- HIGH: 全有或全无的 target spawn —— config 在 target Kind 起来**之前**已 stage 到 temp 并验证（§3.5）
- HIGH: 不走 `Workspace.create_agent` —— 专用原语避免 template 残留 + adoption TOCTOU（§3.4）
- MEDIUM: 新 `Kind.Template.snapshot_config_dir/2` callback —— plugin 拥有 quiesce + manifest（§3.6）

---

## 0. 设计决策（Allen `wake-but-don't-stop` 已预设默认值）

| # | 问题                              | 默认                                   | 理由                                                                                                            |
|---|-----------------------------------|----------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| 1 | 转移所有权 **还是** 复制？        | **复制**                               | 源 agent 保持存活并由源用户所有；目标是 `target_owner_uri` 所有的新实例。回退更干净。                            |
| 2 | 复制对话历史？                    | **无（fresh）**                        | Agent Kind 不携带聊天历史 slice（那是 Session 的）。Identity caps 重置。要历史就继续用源 agent。                  |
| 3 | `config_dir` 语义？               | **Plugin 拥有 snapshot+restore**        | 源 plugin Template Class 拥有 snapshot（quiesce + manifest）；core 写入到 target 的 per-agent dir。               |

SPEC review 时人工复核；只在实现 PR 发现根本性阻塞时通过飞书升级。

---

## 1. 目标

**新增一个可 dispatch 的 Behavior action —— `Ezagent.Behavior.Agent.:duplicate` —— 把一个已存在 agent 克隆到一个新的 agent URI，可选地放在不同的 workspace、由不同的用户所有，具备全有或全无语义和显式双向授权。** 不走 Template Registry 中转；不走 `save_as_template + fork + spawn`；无 Template-Class drift；**不**走 `Workspace.create_agent`（避免 template 残留 + TOCTOU adoption —— codex r1 HIGH-4）。

本 SPEC 的实现 PR 落地后：
- `mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` 产生一个全新存活 agent，位于 `target_uri`，拥有自己的 config_dir（FS 与源独立，点时刻一致的 snapshot）、新鲜的 Identity caps、与源**无**聊天历史耦合。
- 克隆原语住在 **Agent Kind** 上，不在 Template Registry 上。Template Class 元数据被**引用**但不**注册**新 Template Class。
- **双向授权**（codex r1 CRITICAL）：caller 需要 (a) 源上的 `{Behavior.Agent, :duplicate}` cap（源所有者或源 ws admin 持有）**和** (b) **目标** workspace 上的 `{Behavior.Workspace, :create_agent}` cap（目标所有者或目标 ws admin 持有）。仅目标 ws-admin **不能**外泄源 config。
- **全有或全无**（codex r1 HIGH-3）：config snapshot + 验证发生在 target Kind 起来之**前**。snapshot 失败则没创建 target。snapshot 之后 spawn 失败则 staged dir 清理 + caller 看到干净错误。
- Invariant test 断言克隆 `config_dir` 在结构上独立于源。

---

## 2. 范围

In-scope:
- 新模块 `Ezagent.Behavior.Agent`（apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex）—— Agent Kind 目前没有自己的 Behavior 文件。新模块以 `:duplicate` 为首 action。
- 该 Behavior 上的新 action `:duplicate`。参数 `%{target_uri: URI.t(), target_owner_uri: URI.t()}`（source_uri 是 dispatch self_uri）。
- 新 `Kind.Template` 可选 callback: `snapshot_config_dir/2`（源 plugin 端 quiesce + temp-dir manifest）—— 配现有 `create_config_dir/2`（目标 plugin 端 unpack）。cc plugin 实现两者。
- Cap subject `{Behavior.Agent, :duplicate}` —— `data_owner/1` 返回 `:no_owner`（codex r1 HIGH-2：返回源 agent URI 会静默把 cap grant 给 agent 自己而非 owning user）。Cap 在 **agent-spawn 时显式 grant** 给 agent 的创建者。
- Target spawn 走专用路径（**不**走 `Workspace.create_agent`）：直接 `SpawnRegistry.spawn_detailed/1` 对 `target_uri`，然后显式 `WorkspaceRegistry.bind` + `AgentLineage.record` + `Sandbox.write_path` + plugin 端 `restore_from_snapshot` + PTY 启动。原子 `:started` vs `:already_started` 显式 —— 拒绝 adoption（codex r1 HIGH-4）。
- Mix task `Mix.Tasks.Ezagent.Agent.Duplicate`（`mix ezagent.agent.duplicate`）。
- ExUnit 验收测试覆盖：happy path、两种 cap 拒绝场景（源 cap 缺 / 目标 cap 缺）、冲突、源缺失、跨 workspace 双向同意、snapshot 失败 rollback、snapshot 后 spawn 失败 rollback。
- Invariant test `apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`。
- Invariant test `apps/ezagent_core/test/invariants/agent_duplicate_no_create_agent_routing_test.exs` —— grep action body 断言 `:duplicate` 不调用 `Workspace.create_agent`（codex r1 HIGH-4 锁定）。
- 在 `agent_create_single_path_test.exs` 加允许名单条目，给新 SpawnRegistry 使用点（依 SPEC #330 PR 惯例）。

Out-of-scope:
- 克隆的 LV admin UI。V1 仅 CLI（§10）。
- "Save as template" 语义。那是 `Behavior.Template.:fork`（PR1 #287）。
- 任何现有数据迁移。
- MCP 工具暴露。
- 运行中 cc PTY 的 snapshot quiesce。V1 cc 实现诚实地记录 live-write race window（§3.6）；未来 cc PR 添加真正 quiesce（若 Anthropic 出 `claude --quiesce`）。Snapshot manifest 检测部分状态，duplicate action 据此重试或失败。

---

## 3. 设计

### 3.1 Behavior 模块 —— `Ezagent.Behavior.Agent`

新文件 `apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex`。

```elixir
defmodule Ezagent.Behavior.Agent do
  @moduledoc """
  Agent Behavior —— 主语是 agent 自身的 action（不归 Chat /
  Identity / Sandbox 管的 agent-domain 操作）。

  ## Actions

  - `:duplicate` (`:call`) —— 克隆源 agent 到 `target_uri` 的
    新 agent，由 `target_owner_uri` 所有。

  未来 actions（V1 范围外）: `:rename`, `:archive`, `:restore`.

  ## CapBAC —— `data_owner/1` 是 `:no_owner`

  `data_owner/1` 返回 `:no_owner`（**不**是源 agent URI）。
  理由（codex r1 HIGH-2）：现有
  `CapabilityRegistry.default_grants_from_data_owner/2` 把返回的
  URI 直接当作 grantee。如果返回 source_uri，cap 会静默 grant 给
  **AGENT 自己**而不是 owning user。当前架构中没有内置
  "agent → owning user" resolver（lineage 持有 `granted_by`，
  不是 `owner`）；与其通过这个 Behavior 偷渡一个，不如声明
  `:no_owner`，在 agent-spawn 时把 cap **显式** grant 给 agent
  的创建者（详 §4.3）。
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:duplicate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:duplicate,
       "克隆该 agent 到 <target_uri> 的新 agent，由 <target_owner_uri> 所有。" <>
         "Snapshot+restore config_dir; 新鲜 Identity caps; 无聊天历史。源不变。" <>
         "还需要 target workspace 上的 Workspace.create_agent cap。"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :agent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:duplicate, slice, args, ctx), do: # ... 详 §3.2

  @impl Ezagent.Behavior
  def interface, do: # ... 详 §3.3

  # codex r1 HIGH-2 修复 —— :no_owner，不是 source_uri。
  # Identity 风格的 "entity 是自己的 owner" 模式在这里不行，
  # 因为 Behavior 主语（agent）**不是**我们想 grant 的 user。
  # Cap 在 agent-spawn 时显式 grant 给创建者（详 §4.3）。
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner
end
```

并修改 `Ezagent.Entity.Agent.behaviors/0`：

```elixir
def behaviors,
  do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity,
       Ezagent.Behavior.Sandbox, Ezagent.Behavior.Agent]
```

### 3.2 Action body —— `:duplicate`（rev-2 全有或全无）

在**源 agent** 的 Kind GenServer 中运行。Action 强制**双向**授权、执行 **SNAPSHOT-BEFORE-SPAWN**、任何失败原子 rollback。

```elixir
def invoke(:duplicate, _slice, args, ctx) do
  source_uri        = Map.fetch!(ctx, :self_uri)
  target_uri        = Map.fetch!(args, :target_uri)
  target_owner_uri  = Map.fetch!(args, :target_owner_uri)
  caller            = Map.fetch!(ctx, :caller)
  caps              = Map.fetch!(ctx, :caps)

  with {:ok, target_uri}     <- validate_target_uri(target_uri),
       :ok                   <- refuse_if_target_exists(target_uri),
       {:ok, source_meta}    <- read_source_metadata(source_uri),
       {:ok, target_ws_uri}  <- workspace_uri_from_agent(target_uri),
       # 双向授权（codex r1 CRITICAL）：
       :ok                   <- check_target_create_cap(caller, caps, target_ws_uri),
       # 源端 cap 已被 dispatch 检查（:duplicate cap 在 source_uri 上是本 action
       # 运行所依的 cap_subject）。目标 create cap 是这里的第二道显式检查。

       # STAGE —— snapshot 源 config 到 temp dir（codex r1 MEDIUM-5）：
       {:ok, staged_path}    <- snapshot_source_config_to_temp(source_meta, source_uri, target_uri),

       # SPAWN —— 专用路径，**不**走 Workspace.create_agent（codex r1 HIGH-4）：
       {:ok, result}         <- spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, staged_path) do
    {:ok, %{}, %{
      source_uri: source_uri,
      target_uri: result.agent_uri,
      owner_uri: target_owner_uri
    }}
  else
    {:error, _reason} = err ->
      # 原子 rollback（codex r1 HIGH-3）—— staged_path 由 spawn_target_directly
      # 失败时清理；这里不需额外清理因为我们在 target 注册**之前**已中止。
      err
  end
end
```

辅助函数：

- `check_target_create_cap/3` —— 合成所需 cap
  （`%Capability{kind: :workspace, behavior: Behavior.Workspace, instance: target_ws_uri, ...}`），
  对 caller caps 用 `Ezagent.Capability.matches?/2` 匹配。与 workspace-admin
  路径同样的检查（依 `caps-data-ownership-v2.md` §5.2）。
- `read_source_metadata/1` —— dispatch `sandbox.read` 到源拿 `config_dir_path` + `template_class`。
- `snapshot_source_config_to_temp/3` —— 调用 plugin Template Class 的新
  `snapshot_config_dir/2` callback（详 §3.6）。返回 TEMP 目录绝对路径。
- `spawn_target_directly/5` —— 详 §3.4。

### 3.3 Interface schema

```elixir
def interface do
  %{
    duplicate: %{
      description:
        "克隆源 agent 到 target_uri 的新 agent，由 target_owner_uri 所有。" <>
          "Snapshot+restore config_dir; 新鲜 Identity caps; 无聊天历史。" <>
          "双向授权：源端 :duplicate cap（dispatch-time）+ 目标 workspace" <>
          " :create_agent cap（action-body-time）。",
      args: %{
        target_uri: :uri,
        target_owner_uri: :uri
      },
      returns: %{
        source_uri: :uri,
        target_uri: :uri,
        owner_uri: :uri
      },
      modes: [:call]
    }
  }
end
```

### 3.4 Target spawn —— 专用原语（**不**走 Workspace.create_agent）

按 codex r1 HIGH-4，路由经 `Ezagent.Workspace.create_agent/3` 会：
1. 在 workspace 的 `session_templates` slice 注册 workspace-scoped template（cc/echo 路径）→ 持久化到 `Workspace.Store` → 正是 memory `feedback_agent_clone_not_via_template` 警告的 "废弃 template 残留"。
2. create_agent 路径的全捕获 `:already_started` → `:ok` 折叠意味着 `target_uri` 上的并发 spawn 会被静默接受为成功，之后第 5 步（config restore）就会覆盖外来 agent 的 dir。

专用 `spawn_target_directly/5`：

```elixir
defp spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, staged_path) do
  with {:ok, :started, _pid}   <- spawn_atomic_fresh(target_uri),  # 不 adoption（§3.4.1）
       :ok                     <- WorkspaceRegistry.bind(target_uri, target_ws_uri),
       :ok                     <- AgentLineage.record(target_uri, target_owner_uri),
       {:ok, final_dir}        <- restore_snapshot_into_target(source_meta, target_uri, staged_path),
       :ok                     <- dispatch_sandbox_write_path(target_uri, final_dir, source_meta.template_class),
       :ok                     <- grant_initial_caps_for_owner(target_uri, target_owner_uri),
       :ok                     <- start_pty_or_no_pty(target_uri, source_meta, target_ws_uri) do
    {:ok, %{agent_uri: target_uri}}
  else
    err -> rollback_partial_target(target_uri, staged_path, err)
  end
end
```

#### 3.4.1 `spawn_atomic_fresh/1` —— 拒绝 adoption

```elixir
defp spawn_atomic_fresh(target_uri) do
  case Ezagent.SpawnRegistry.spawn_detailed(target_uri) do
    {:ok, :started, pid} -> {:ok, :started, pid}
    {:ok, :already_started, _pid} -> {:error, {:adopted_not_fresh, target_uri}}  # 不算成功
    {:error, _} = err -> err
  end
end
```

与现有 `:already_started → :ok` 模式不同。复制时我们**必须**是创建 target 的那个 —— adopted target 的 config 不归我们 overwrite。

#### 3.4.2 `rollback_partial_target/3`

```elixir
defp rollback_partial_target(target_uri, staged_path, err) do
  # 顺序：先终止 Kind（停止任何 in-flight 操作），后 registry 清理，后 FS 清理。
  _ = Ezagent.Kind.terminate(target_uri)
  _ = Ezagent.WorkspaceRegistry.unbind(target_uri)
  _ = Ezagent.AgentLineage.forget(target_uri)
  _ = File.rm_rf(staged_path)
  case template_class_for(target_uri) do
    {:ok, tc} when is_atom(tc) -> _ = tc.destroy_config_dir(target_uri, tc.agent_config_dir(target_uri))
    _ -> :ok
  end
  err
end
```

这是 `feedback_let_it_crash_no_workarounds` 下唯一允许的 "checked rollback" 形状 —— 不是防御性 catch-all，是对**本 action 创建的资源**的确定性 teardown，错误原样保留。

### 3.5 Stage → spawn 顺序理由（codex r1 HIGH-3）

Pre-rev-2：spawn target → cp_r config 覆盖 → cp_r 失败时让 target 存活。

Rev-2：snapshot 源到 temp → spawn target → snapshot restore 入 target → 任何 post-spawn 失败时完全 rollback target。

两阶段理由：SNAPSHOT 阶段纯源端 + temp-dir；失败则 target 从未创建（target_uri 仍空）。SPAWN 阶段由 `rollback_partial_target/3` 兜底。唯一可能造成不一致的失败（cp_r 在 target 起来但 rollback 前失败）现在自愈：rollback 跑 Kind termination + dir 清理，让 target_uri 空出供重试。

### 3.6 `Kind.Template.snapshot_config_dir/2` —— 新可选 callback

在 `Ezagent.Kind.Template` 上新 `@optional_callback`：

```elixir
@doc """
对源 agent 的 config_dir 取点时刻 snapshot 到 temp dir，返回 temp 路径 +
manifest.

Plugin 拥有 quiesce 语义 —— cc V1 含义：记录源 PTY 状态，跑 `cp_r`
带 marker，验证文件数等于 pre-cp_r 的 `find . | wc -l`（基本的
partial-write 检测器）。未来 cc V2 可加真 quiesce（暂停 claude、
fsync、复制、恢复）。

Temp dir 在 `Ezagent.Home.path("cc-agents/.snapshots")/<uuid>/` 下，
在 agent-config 树之外，可安全 rm。

返回 `{:ok, %{path: String.t(), manifest: map()}}` 或 `{:error, term()}`.
失败时 plugin **必须**清自己的 temp 残留 —— caller (Behavior.Agent.:duplicate)
**不**尝试清它从未收到的路径。

@param source_uri  —— 源 agent URI
@param source_dir  —— 源当前 config_dir_path

Manifest 携带 plugin 特定的元数据供 `restore_from_snapshot/3` unpack 用。
cc V1: `%{file_count: N, marker: "...", taken_at: DateTime}`.
"""
@callback snapshot_config_dir(source_uri :: URI.t(), source_dir :: String.t()) ::
            {:ok, %{path: String.t(), manifest: map()}} | {:error, term()}

@doc """
把 snapshot（由 `snapshot_config_dir/2` 产）restore 到 target agent
的 per-agent config_dir 位置。Plugin 用 `agent_config_dir/1`
builder 算 target 路径，原子移动 snapshot 到位，最后写
`.ezagent-config-complete` marker。

Caller (Behavior.Agent.:duplicate) 负责 success/failure 都 rm snapshot temp dir。

返回 `{:ok, final_path}` 或 `{:error, term()}`.
"""
@callback restore_from_snapshot(
            target_uri :: URI.t(),
            snapshot_path :: String.t(),
            manifest :: map()
          ) :: {:ok, String.t()} | {:error, term()}

@optional_callbacks snapshot_config_dir: 2, restore_from_snapshot: 3
```

不实现两者的 plugin（echo、curl、np —— 任何不管 config_dir 的）：`source_meta.template_class.snapshot_config_dir` 返回 `:no_op`，action body 跳过 stage+restore —— 那些 agent "结构上"克隆（spawn 发生，但无 FS 状态可携带）。

对 echo/curl/np：`snapshot_config_dir/2` **应**实现并显式返回 `{:ok, %{path: nil, manifest: %{}}}` —— 让 "我无 config_dir 可 snapshot" 成为肯定的 callback，而非 missing-function 默认。Action body 检查 `path == nil` 完全跳过 restore。

#### 3.6.1 cc V1 snapshot 实现（示意）

```elixir
@impl Ezagent.Kind.Template
def snapshot_config_dir(%URI{} = source_uri, source_dir) when is_binary(source_dir) do
  snapshots_root = Path.join(Ezagent.Home.path("cc-agents"), ".snapshots")
  snapshot_dir = Path.join(snapshots_root, "#{:erlang.unique_integer([:positive])}-#{System.os_time(:millisecond)}")

  with :ok               <- File.mkdir_p(snapshots_root),
       pre_count          = file_count(source_dir),
       {:ok, _}           <- File.cp_r(source_dir, snapshot_dir),
       post_count         = file_count(snapshot_dir),
       true               <- pre_count == post_count or {:error, {:partial_copy, pre_count, post_count}},
       :ok                <- File.chmod(snapshot_dir, 0o700),
       :ok                <- chmod_credentials(snapshot_dir) do
    manifest = %{
      file_count: post_count,
      taken_at: DateTime.utc_now(),
      source_uri: URI.to_string(source_uri)
    }
    {:ok, %{path: snapshot_dir, manifest: manifest}}
  else
    {:error, _} = err ->
      _ = File.rm_rf(snapshot_dir)
      err
    other ->
      _ = File.rm_rf(snapshot_dir)
      {:error, {:snapshot_failed, other}}
  end
end
```

`pre_count == post_count` 检查是 "我们漏文件了吗" 的粗门控。它**不**捕获 `.credentials.json` 中途轮换（文件数不变，内容变）；V1 记此限制。Invariant test（§8）用静态 canary 文件不触发此 race。

### 3.7 Mix task —— `mix ezagent.agent.duplicate`

新文件 `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.duplicate.ex`。

```bash
mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>
```

例：

```bash
mix ezagent.agent.duplicate \
    entity://agent/system/cc_linyilun-default \
    entity://agent/acme/cc_linyilun-acme \
    --owner entity://user/acme/linyilun
```

Body 镜像 `agent.create.ex`。Dispatch target 是 `<source_uri>?action=agent.duplicate`。Caller context 是 operator-admin。

---

## 4. Cap-BAC —— 双向授权（codex r1 CRITICAL）

### 4.1 需要的两个 cap

| # | Cap                                          | 在哪                | 谁持有                                  | 何时检查           |
|---|----------------------------------------------|---------------------|------------------------------------------|--------------------|
| 1 | `{Behavior.Agent, :duplicate}`              | **源** agent        | 源所有者或源 ws admin                    | Dispatch-time      |
| 2 | `{Behavior.Workspace, :create_agent}`       | **目标** workspace  | 目标所有者或目标 ws admin                | Action-body-time   |

**两者**必须都成功。Pre-rev-2 的 "目标 ws-admin 单独够" 是 codex r1 CRITICAL —— 它把目标 admin 变成了源数据导出能力。Rev-2 关闭这个：目标 ws-admin 若不满足 cap #1 看到干净的 dispatch 拒绝；它在目标 workspace 上的 cap 在源端未授权前与本操作无关。

### 4.2 Cap 解析

`Behavior.Agent.data_owner/1` 返回 `:no_owner`。结果：`default_grants_from_data_owner/2` 在 agent-spawn 时**不**自动 grant `{Behavior.Agent, :duplicate}`。Cap 在 agent-spawn 时**显式** grant（详 §4.3）。

这是有意的。备选（返回 source_uri 作为 data_owner）会静默把 cap grant 给 agent 自己（codex r1 HIGH-2 —— `default_grants_from_data_owner/2:371` 把返回的 URI 原样当 grantee）。而加 "agent → owning user" 解析需要 (a) 不存在的新 lineage 字段 **或** (b) 从 Behavior 里面反向取 Workspace owner_uri / AgentLineage.granted_by —— 让 Behavior 耦合 ESR-domain 注册表（反模式依 `feedback_north_star_plugin_isolation`）。

### 4.3 `:duplicate` cap 从哪来

在 agent-spawn（`Behavior.Workspace.:create_agent` action body，target Agent Kind 起来后），运行一个额外的显式 grant：

```elixir
# 在 Behavior.Workspace.:create_agent action body 中，target spawn 后的新步骤
:ok <- grant_initial_caps(agent_uri, [
  {Behavior.Agent, :duplicate, instance: agent_uri},
  # ... 现有 Identity grant
], ctx_with_creator_caps)
```

Agent 的**创建者**（调用 `create_agent` 的 user）在新 agent URI 上获得 `{Behavior.Agent, :duplicate}`。Workspace admin 也通过 §5.2 admin 分支在源 workspace 上获得这个 cap（Workspace `cap_subjects` 枚举 + `Workspace.data_owner = :any` 已按 `caps-data-ownership-v2.md` 路由 admin grant）。

意思是：刚创建的 agent 的 `:duplicate` cap 由 (a) 它的创建者 和 (b) 源 workspace 的 workspace admin 持有 —— **绝不**自动由目标 workspace admin 持有（除非源端显式 grant 给它）。

Grant 步骤住在 SPEC #330 已发布的 `Behavior.Workspace.:create_agent` body（`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` 158-176 行）；本 SPEC 实现 PR 把 duplicate-cap 行加到那个 grant 列表里。

### 4.4 Caller 场景（rev-2）

| Caller                                                | 源端 :duplicate cap   | 目标 ws :create_agent cap | 允许? |
|-------------------------------------------------------|------------------------|---------------------------|-------|
| 源创建者，克隆到自己 workspace                          | 有（spawn 时 grant）   | 有（自己 workspace）       | **是**|
| 源创建者，克隆到别人 workspace                          | 有                     | 无（目标无 admin）         | **否**|
| 源 ws admin，克隆到自己 workspace                       | 有（admin §5.2）       | 有                         | **是**|
| 源 ws admin，克隆到别 ws（无 admin）                    | 有                     | 无                         | **否**|
| 目标 ws admin，**无**源端 cap                           | **无**                 | 有                         | **否** ← codex r1 CRITICAL 修复 |
| 双向：源所有者授权目标 ws admin                          | 有（源 grant 给）      | 有                         | **是**|
| 随机 user                                              | 无                     | 无                         | **否**|

"双向" 是双方同意的跨租户克隆路径：源所有者显式 grant `{Behavior.Agent, :duplicate}` 给目标 workspace admin（通过 Identity `grant_cap`），然后目标 workspace admin 跑 duplicate。

---

## 5. Audit

Dispatch 链记录每个 `Invocation.dispatch/1`。Duplicate audit 记录携带：

- `caller` —— 谁发起
- `target` —— `<source_uri>?action=agent.duplicate`
- `args` —— `%{target_uri:, target_owner_uri:}`
- `result` —— `{:ok, %{source_uri, target_uri, owner_uri}}` 或 `{:error, _}`

**另外**，snapshot manifest（§3.6）在 snapshot 时间被 log（info 级）+ hash，方便 operator 关联 audit + snapshot artifact。

---

## 6. 迁移

**Schema 层:** 无。新 Behavior 的 slice 为空；新 Kind.Template callback `@optional`.

**已有 agent cap:** PR 前已存活 agent 上的 `{Behavior.Agent, :duplicate}` cap **不**会回溯 grant。Grant 只发生在 §4.3 grant-list 变更后的**新** agent-spawn。想克隆 legacy agent 的 operator 必须显式跑 `mix ezagent.identity.grant_cap`（已有 CLI）。在实现 PR CHANGELOG 中记录。

理由：一次性回溯 grant 迁移是对存活 cap 集的破坏性变更（`feedback_destructive_migration_anti_pattern`）；显式 grant 路径是标准 cap 工作流。

---

## 7. 验收测试

实现 PR 中。底线：

1. **Happy path（同 workspace 同 owner）** —— 创建者克隆自己 cc agent → 新 agent 有独立 config_dir；sandbox slice 携带新路径；新 Identity caps 是创建者的默认；源不变。
2. **双向跨租户克隆** —— 源所有者 grant `:duplicate` 给目标 workspace admin；目标 ws admin 跑 duplicate；成功。
3. **Cap 拒绝 —— 目标 ws admin，无源 grant** —— dispatch-time `{:error, :unauthorized}`. 没尝试 target spawn. 没拍 snapshot.
4. **Cap 拒绝 —— 源所有者，无目标 ws admin** —— action-body-time `{:error, :unauthorized}`. 没尝试 target spawn. 没拍 snapshot.
5. **Target URI 冲突** —— `target_uri` 已存活 → `{:error, {:already_exists, target_uri}}`. 没拍 snapshot（冲突检查按 §3.2 `with` 顺序在 snapshot **之前**跑）。
6. **源缺失** —— lookup 时间 dispatch 失败。
7. **Snapshot 失败** —— 在 `snapshot_config_dir/2` 注入 partial-cp_r 故障；验证返回 `{:error, {:partial_copy, _, _}}`；验证**没**发生 target spawn；验证 snapshot temp dir 已清。
8. **Snapshot 后 restore 失败** —— 在 `restore_from_snapshot/3` 注入失败；验证 target Kind 已终止；WorkspaceRegistry 已 unbound；AgentLineage 已 forgotten；staged_path 已 rm；target_uri 空出供重试。
9. **深拷贝隔离** —— 克隆后修改源 `config_dir` 中文件；target 同相对路径文件未变。**(Invariant —— §8.)**
10. **非 cc flavor (echo)** —— `snapshot_config_dir/2` 返回 `{:ok, %{path: nil, manifest: %{}}}`；restore 跳过；target 无 FS 状态 spawn；sandbox slice `config_dir_path: nil`.
11. **Adoption-refused TOCTOU** —— race：用并发 `SpawnRegistry.spawn` 预创 target_uri，然后跑 duplicate；验证 duplicate 失败 `{:adopted_not_fresh, target_uri}`. 预存 agent 不变。
12. **Invariant: 无 `Workspace.create_agent` 路由** —— 静态 grep test 断言 `:duplicate` action body 永不调用 create_agent facade.

---

## 8. Invariant tests（依 `feedback_completion_requires_invariant_test`）

### 8.1 FS 隔离 invariant

`apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`:

```elixir
test "cloned agent's config_dir is FS-independent of source" do
  # 1. spawn 源 cc agent
  # 2. 在源 config_dir 写 canary 文件
  # 3. dispatch :duplicate → target agent
  # 4. 从源读 canary —— 在
  # 5. 从 target 读 canary —— 在（snapshot+restore 带过来了）
  # 6. 改源 canary
  # 7. 读 target canary —— **未变**（无 symlink / 共享 inode）
  # 8. 删源整个 config_dir
  # 9. target 的 config_dir 仍完整且可用
end
```

### 8.2 不路由 create_agent invariant

`apps/ezagent_core/test/invariants/agent_duplicate_no_create_agent_routing_test.exs`:

```elixir
test ":duplicate action body 不调用 Workspace.create_agent" do
  source = File.read!("apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex")
  refute source =~ "Ezagent.Workspace.create_agent("
  refute source =~ "Behavior.Workspace.:create_agent"
  # 这个原语全部的意义（memory feedback_agent_clone_not_via_template）：
  # 克隆在 Agent Kind 上，不走 Template/Workspace facade。
end
```

两个 invariant 都必须通过本 PR 才能 merge。

---

## 9. CLAUDE.md / 文档

无 CLAUDE.md 改动。Mix task `--help` 自动渲染。Operator 文档放在实现 PR 的 `docs/operations/agent-duplicate.md`（双语依 `feedback_bilingual_docs_convention`）。

---

## 10. 待办（推后 —— 依 `feedback_dont_defer_what_is_solvable_now` 标记）

- **真正的 cc quiesce。** V1 cc snapshot 用 pre/post 文件数门控。snapshot 期间的 `.credentials.json` 轮换不会被检测到。未来 PR：加 `claude --quiesce` 类比 **或** PTY 短暂暂停 + fsync **或** hash manifest. V1 记此限制；克隆刚 token 轮换的 agent 罕见。
- **克隆的 LV admin UI。** `/admin/agents/<uri>/clone` 表单。按 §2 推后。
- **MCP 工具面。** 原语稳定后 10 行包装。
- **批量克隆。** 原语的微小包装。
- **跨主机 federation。** 跨主机克隆的 cwd 语义；V1 范围外。
- **legacy agent 的回溯 duplicate-cap grant.** §6 记录 —— operator 显式跑 `mix ezagent.identity.grant_cap`.

---

## 11. Codex 对抗 review（依 `feedback_spec_codex_adversarial_review`）

- **Rev 1**（初稿）：codex 返回 `needs-attention`，1 CRITICAL、3 HIGH、1 MEDIUM。Rev 2 全部处理（详 header `Rev 2 changes` 列表 + §3.4 §3.5 §3.6 §4 重写）。
- **Rev 2**（本版本）：codex 对抗 review 将在实现 PR 开之前对本分支跑。

---

## 12. User-assist steps（依 `feedback_flag_user_assist_steps`）

**无。** 实现 PR 完全跑 CI + 本地 mix 测试。端到端手动验证（建议 `mix ezagent.agent.duplicate` 跑 `linyilun-default`）是**建议**而非门控。
