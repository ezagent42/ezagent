# SPEC — Agent 复制/克隆原语 (Behavior.Agent `:duplicate`)

**状态:** DRAFT rev 4 · 2026-05-25（codex r1 + r2 + r3 修复）
**层级:** `apps/ezagent_domain_chat/`（新 `Behavior.Agent` + action）+ `apps/ezagent_core/`（新 `AgentOwnership` registry + Kind.Template snapshot callback 适配器 + BehaviorRegistry 插槽）+ `apps/ezagent_plugin_cc/`（cc snapshot+restore 实现）+ `apps/ezagent_domain_workspace/`（mix task 包装 + `:create_agent` 的 ownership-write）
**触发:** Allen 2026-05-24（memory `feedback_agent_clone_not_via_template`）—— "agent 创建的 template 如果不走正常的 template 创建和 fork 流程，可能导致开发 drift，但如果走标准流程，又可能导致 Template Registry 里面大量临时创建后再也不用的 template"。Clone 必须作为 domain.agent primitive 存在，**绝不**走 Template Registry。
**前置:** 同英文版。
**英文对照:** `2026-05-25-agent-duplicate-clone.md`

**Rev 2 变更（codex r1 verdict needs-attention → 已处理）:**
- CRITICAL: 现在**要求**源端授权 —— 仅有目标 ws-admin **不能**外泄源 config（§4）
- HIGH: `data_owner/1` 返回 `:no_owner`；duplicate cap 是 admin 显式 grant，不自动推导（§4.2）
- HIGH: 全有或全无的 target spawn —— config 在 target Kind 起来**之前**已 stage 到 temp 并验证（§3.5）
- HIGH: 不走 `Workspace.create_agent` —— 专用原语避免 template 残留 + adoption TOCTOU（§3.4）
- MEDIUM: 新 `Kind.Template.snapshot_config_dir/2` callback —— plugin 拥有 quiesce + manifest（§3.6）

**Rev 4 变更（codex r3 verdict needs-attention → 已处理）:**
- CRITICAL: rollback 现在**同步**等待 target Kind 进程死后**再**删 `Kind.Snapshot` 行。Rev-3 中 `Sandbox.:destroy` 的延迟 termination Task 可能在我们 delete 之**后**重写 snapshot. Rev 4 改顺序：先用 `DynamicSupervisor.terminate_child` + `Process.monitor` 同步等 `:DOWN`，**再**删 snapshot。Snapshot 删时进程已死，无 re-write 可能（§3.4.2 重写）。
- HIGH: 新 `Ezagent.Agent.Provisioning.provision_agent/3` 模块（`apps/ezagent_domain_chat/lib/ezagent/agent/provisioning.ex`）供 `Behavior.Workspace.:create_agent` **和** `Behavior.Agent.:duplicate` 共用。步骤：(1) `AgentOwnership.record/2`，(2) `CapabilityRegistry.default_grants_from_data_owner/2` 对 Agent Kind 每个 Behavior → 通过 `Identity.grant_cap` apply，(3) (2) 失败回滚 (1)。关闭 codex r3 HIGH-2（避免"spawn lifecycle 自动合成"的假设 —— codex grep 证伪）。§3.9 新.
- HIGH: `Ezagent.AgentOwnership` 现在是 **SQLite-backed ETS cache**（不是纯 ETS）。镜像 `Workspace.Store` 的 SQLite-backing 模式：SQLite 表 `agent_ownership(agent_uri pk, owner_uri, created_at)` 是 durable source of truth；ETS 是 boot-time-hydrated 读缓存。`record/2` 写两者（同步）。`forget/1` 删两者。Restart 测试（§7 row 15 新）创 agent、重启 runtime、验证 owner 仍解析+能 delegate `:duplicate`.

**Rev 3 变更（codex r2 verdict needs-attention → 已处理）:**
- CRITICAL: rollback 现在堵上 `:on_terminate` 持久化漏洞 —— 在 `Kind.terminate/1` 之**前**先 dispatch `Sandbox.:destroy`（清 slice + plugin 端清理）+ 删 `KindSnapshot` 行 + 撤销已 grant 的 caps。每个 post-spawn 步骤都加 failure-injection 测试（§3.4.2 + §7）。
- HIGH: `Behavior.Agent.data_owner(agent_uri)` 现在通过新 `Ezagent.AgentOwnership` registry（ETS，平行于 `AgentLineage`）解析到**所属 user URI**。源所有者通过标准 `Identity.grant_cap` 把 `:duplicate` cap 委托给目标 ws admin —— 双向 consent 现在结构上可能，不是 bootstrap-admin 限定（§3.8 + §4.2）。
- HIGH: `Kind.Template` snapshot callback 仍 `@optional`，但 action body 调用核心适配器 `Ezagent.Kind.Template.snapshot_or_default/2`，检查 `function_exported?` 并对缺失 callback 归一化为 `{:ok, %{path: nil, manifest: %{}}}`。加无 callback 的 plugin 验收测试（§7 row 10 扩）。
- MEDIUM: cc snapshot manifest 现在对每个文件 copy 前+后做 content-hash，任何 hash 差则失败。Snapshot 期间 `.credentials.json` 轮换会被检测（§3.6.1 重写）。§1 措辞软化：snapshot 一致性由 manifest 验证保证；snapshot 期间的 live writes 干净 ABORT。

---

## 0. 设计决策

| # | 问题                              | 默认                                   |
|---|-----------------------------------|----------------------------------------|
| 1 | 转移所有权 **还是** 复制？        | **复制**                               |
| 2 | 复制对话历史？                    | **无（fresh）**                        |
| 3 | `config_dir` 语义？               | **Plugin 拥有 snapshot+restore**        |

---

## 1. 目标

`mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` 产生全新存活 agent：独立 config_dir（snapshot 一致性由 per-file hash manifest 保证）、新鲜 Identity caps、无聊天历史耦合。Clone 原语住在 **Agent Kind**，**双向授权**（源端 :duplicate cap + 目标 workspace :create_agent cap），**全有或全无**。

---

## 2. 范围

- 新 `Ezagent.Behavior.Agent`（apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex）
- 新 action `:duplicate`，args `%{target_uri, target_owner_uri}`
- 新 **`Ezagent.AgentOwnership`** ETS registry（agent_uri → owner_user_uri；§3.8）
- 新 `Kind.Template` 可选 callback `snapshot_config_dir/2` + `restore_from_snapshot/3`，配核心适配器 `snapshot_or_default/2` + `restore_or_noop/3`
- Cap subject `{Behavior.Agent, :duplicate}` —— `data_owner/1` 通过 AgentOwnership 解析到 user URI
- 专用 spawn 路径（**不**走 `Workspace.create_agent`），拒绝 adoption
- Mix tasks: `mix ezagent.agent.duplicate` + `mix ezagent.agent.set_owner`（legacy 回填）
- 14 行 ExUnit 验收测试 + 2 invariant tests

Out-of-scope:
- 克隆的 LV admin UI
- "Save as template"（走 `Behavior.Template.:fork`）
- MCP 工具
- 真正的 cc quiesce（V1 检测+abort）

---

## 3. 设计

### 3.1 Behavior 模块 —— `Ezagent.Behavior.Agent`

```elixir
defmodule Ezagent.Behavior.Agent do
  @moduledoc """
  Agent Behavior —— 主语是 agent 自身的 action。
  Actions: :duplicate (V1). Future: :rename, :archive, :transfer_ownership.

  CapBAC —— data_owner 通过 AgentOwnership 解析（rev 3）：
  data_owner(agent_uri) 通过 Ezagent.AgentOwnership.lookup/1
  解析到 agent 所属 user URI。让标准 default_grants_from_data_owner/2
  合成 :duplicate cap 给 user；user 然后可通过 Identity.grant_cap
  委托 —— bilateral consent 是 normal user op，不是 bootstrap-admin op。
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:duplicate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:duplicate,
       "克隆该 agent 到 <target_uri> 的新 agent，由 <target_owner_uri> 所有。" <>
         "Snapshot+restore config_dir; 新鲜 Identity caps; 无聊天历史。" <>
         "需要 target workspace 上的 Workspace.create_agent cap。"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :agent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:duplicate, slice, args, ctx), do: # 详 §3.2

  @impl Ezagent.Behavior
  def interface, do: # 详 §3.3

  # rev 3 —— 通过 AgentOwnership 解析到 owner user URI
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "entity", host: "agent"} = agent_uri) do
    case Ezagent.AgentOwnership.lookup(agent_uri) do
      {:ok, %URI{} = owner_user_uri} -> owner_user_uri
      :error -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
```

修改 `Ezagent.Entity.Agent.behaviors/0`：

```elixir
def behaviors,
  do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity,
       Ezagent.Behavior.Sandbox, Ezagent.Behavior.Agent]
```

### 3.2 Action body —— `:duplicate`（全有或全无）

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
       :ok                   <- check_target_create_cap(caller, caps, target_ws_uri),
       {:ok, snapshot}       <- Kind.Template.snapshot_or_default(source_meta.template_class, source_uri, source_meta.config_dir_path),
       {:ok, result}         <- spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, snapshot) do
    {:ok, %{}, %{source_uri: source_uri, target_uri: result.agent_uri, owner_uri: target_owner_uri}}
  end
end
```

### 3.3 Interface schema

```elixir
def interface do
  %{
    duplicate: %{
      description: "克隆源 agent 到 target_uri 的新 agent。双向授权。",
      args: %{target_uri: :uri, target_owner_uri: :uri},
      returns: %{source_uri: :uri, target_uri: :uri, owner_uri: :uri},
      modes: [:call]
    }
  }
end
```

### 3.4 Target spawn —— 专用原语

```elixir
defp spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, snapshot) do
  with {:ok, :started, _pid}   <- spawn_atomic_fresh(target_uri),
       :ok                     <- WorkspaceRegistry.bind(target_uri, target_ws_uri),
       :ok                     <- AgentLineage.record(target_uri, target_owner_uri),
       :ok                     <- AgentOwnership.record(target_uri, target_owner_uri),
       restore_result          <- Kind.Template.restore_or_noop(source_meta.template_class, target_uri, snapshot),
       {:ok, final_dir}        <- normalize_restore(restore_result),
       :ok                     <- dispatch_sandbox_write_path(target_uri, final_dir, source_meta.template_class),
       :ok                     <- grant_initial_caps_for_owner(target_uri, target_owner_uri),
       :ok                     <- start_pty_or_no_pty(target_uri, source_meta, target_ws_uri) do
    {:ok, %{agent_uri: target_uri}}
  else
    err -> rollback_partial_target(target_uri, snapshot.path, err)
  end
end
```

#### 3.4.1 `spawn_atomic_fresh/1` —— 拒绝 adoption

```elixir
defp spawn_atomic_fresh(target_uri) do
  case Ezagent.SpawnRegistry.spawn_detailed(target_uri) do
    {:ok, :started, pid} -> {:ok, :started, pid}
    {:ok, :already_started, _pid} -> {:error, {:adopted_not_fresh, target_uri}}
    {:error, _} = err -> err
  end
end
```

#### 3.4.2 `rollback_partial_target/3` —— **terminate-then-purge（codex r3 CRITICAL 修复）**

Codex r3 CRITICAL: rev-3 顺序中 `dispatch_sandbox_destroy/1` 调度一个延迟 Task（20ms）调 `Kind.Server.terminate/2`。那个 terminate 的 `:on_terminate` snapshot 写可能在我们 `Kind.Snapshot.delete(target_uri)` 之**后**触发 —— 重写我们刚删的行。Rev-4 修复：**同步**终止（等 `:DOWN`），**再**在已死的进程上删 snapshot。

```elixir
defp rollback_partial_target(target_uri, staged_path, err) do
  # 1. 撤销 grant 的 caps（Identity slice 清空）。
  _ = revoke_initial_caps_if_granted(target_uri)
  # 2. 同步 dispatch Sandbox.:destroy —— 清 :sandbox slice + plugin FS 清理。
  _ = dispatch_sandbox_destroy(target_uri)
  # 3 (rev-4 critical fix): SYNCHRONOUSLY 终止 target Kind + AWAIT 死亡。
  :ok = terminate_target_synchronously(target_uri)
  # 4. 忘掉 registries
  _ = Ezagent.AgentOwnership.forget(target_uri)
  _ = Ezagent.AgentLineage.forget(target_uri)
  _ = Ezagent.WorkspaceRegistry.unbind(target_uri)
  # 5. 现在可安全删 KindSnapshot（进程已死，无 race）
  :ok = Ezagent.Kind.Snapshot.delete(target_uri)
  # 6. 清 staging temp dir
  _ = File.rm_rf(staged_path)
  err
end

# 同步 terminate + 等死。:ok 只在进程确认死后才返回。
defp terminate_target_synchronously(target_uri) do
  case Ezagent.KindRegistry.lookup(target_uri) do
    {:ok, pid} ->
      ref = Process.monitor(pid)
      _ = DynamicSupervisor.terminate_child(target_supervisor(target_uri), pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> {:error, :terminate_timeout}
      end
    :error -> :ok
  end
end
```

**为何 slice-clear 在 terminate 之前（不在之后）**：步 1+2 通过 dispatch 路径同步清 slice，Kind.Server `commit_and_notify/3` 在 dispatch 返回前已提交。步 3 跑 `terminate/2` 时读到（已清空的）slice，`:on_terminate` 写空。步 5 删（空）行。所以 rev 4 中 `:on_terminate` snapshot 写无害：写空 slice；步 5 删空行。

**Failure-injection 验收测试**（§7 rows 7-9）：对每个 post-spawn 步骤注入失败，断言 rollback 后无 `Kind.Snapshot` 行、无 registry 绑定、无 FS 残留，**和**无进程 `KindRegistry.lookup(target_uri)`. Rollback 测试必须包含 `Process.alive?(pid)` 返回 false **之前**再检查 snapshot 不存在 —— 否则脆性测试可能看到行删后 terminate 的 snapshot 写 race-replace 它。

### 3.5 Stage → spawn 顺序

snapshot 源 → spawn target → restore → 任何 post-spawn 失败完全 rollback。

### 3.6 `Kind.Template.snapshot_config_dir/2` —— 新可选 callback + 核心适配器（codex r2 HIGH-3 修复）

```elixir
@callback snapshot_config_dir(source_uri :: URI.t(), source_dir :: String.t()) ::
            {:ok, %{path: String.t() | nil, manifest: map()}} | {:error, term()}

@callback restore_from_snapshot(target_uri :: URI.t(), snapshot_path :: String.t(), manifest :: map()) ::
            {:ok, String.t()} | {:error, term()}

@optional_callbacks snapshot_config_dir: 2, restore_from_snapshot: 3
```

**核心适配器** `Ezagent.Kind.Template.snapshot_or_default/2` / `restore_or_noop/3`：检查 `function_exported?`，缺失 callback 返回 `{:ok, %{path: nil, manifest: %{}}}` / `:noop`。Action body 调适配器，不直接调 plugin。

#### 3.6.1 cc V1 snapshot 实现 —— 内容 hash manifest（codex r2 MEDIUM-4 修复）

```elixir
@impl Ezagent.Kind.Template
def snapshot_config_dir(%URI{} = source_uri, source_dir) when is_binary(source_dir) do
  snapshots_root = Path.join(Ezagent.Home.path("cc-agents"), ".snapshots")
  snapshot_dir = Path.join(snapshots_root, "#{:erlang.unique_integer([:positive])}-#{System.os_time(:millisecond)}")

  with :ok                <- File.mkdir_p(snapshots_root),
       # 1. 拷贝前 manifest —— %{relpath => %{size, mtime, sha256}}
       {:ok, pre_manifest} <- build_file_manifest(source_dir),
       # 2. 原子 cp_r
       {:ok, _}            <- File.cp_r(source_dir, snapshot_dir),
       :ok                 <- File.chmod(snapshot_dir, 0o700),
       :ok                 <- chmod_credentials(snapshot_dir),
       # 3. 拷贝后 SOURCE manifest —— 验证 cp_r 期间源未变
       {:ok, post_manifest} <- build_file_manifest(source_dir),
       :ok                 <- compare_manifests(pre_manifest, post_manifest) do
    manifest = %{
      file_count: map_size(pre_manifest),
      files: pre_manifest,
      taken_at: DateTime.utc_now(),
      source_uri: URI.to_string(source_uri)
    }
    {:ok, %{path: snapshot_dir, manifest: manifest}}
  else
    {:error, _} = err -> _ = File.rm_rf(snapshot_dir); err
    other -> _ = File.rm_rf(snapshot_dir); {:error, {:snapshot_failed, other}}
  end
end
```

Pre/post-source manifest 比较检测：同文件 sha256 突变（`.credentials.json` 轮换）、文件加/删、size/mtime 变。`build_file_manifest/1` 拒绝 symlink/special-file。

### 3.7 Mix tasks

```bash
mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>
mix ezagent.agent.set_owner <agent_uri> <user_uri>   # legacy agent 回填
```

### 3.8 `Ezagent.AgentOwnership` registry —— SQLite-backed ETS cache（codex r2 HIGH-2 + codex r3 HIGH-3 修复）

**存储布局（rev 4）**：两层 —— SQLite 表 `agent_ownership(agent_uri pk, owner_uri, created_at)` 为 durable source of truth；ETS 表 `:ezagent_agent_ownership` 为 boot-time-hydrated 读缓存。Rev-3 是 ETS-only；codex r3 HIGH-3 指出 ETS 易失，重启后所有 agent 落到 `:no_owner`。镜像 `Workspace.Store` 的 SQLite-backing 模式。

```elixir
defmodule Ezagent.AgentOwnership do
  @moduledoc """
  Agent 所有权 registry —— agent_uri → owner_user_uri.
  Durable: SQLite. Cache: ETS, boot-loaded.

  API:
  - record/2 — 先写 SQLite，再写 ETS. 同步.
  - lookup/1 — 读 ETS; cache miss 时 fall back SQLite + warm ETS.
  - forget/1 — 删 SQLite + ETS.
  - boot_load/0 — EzagentCore.EtsOwner 启动后调一次，SQLite → ETS.
  """

  @table :ezagent_agent_ownership

  @spec record(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def record(agent_uri, owner_uri) do
    a = to_string(agent_uri)
    o = to_string(owner_uri)
    :ok = persist(a, o)            # SQLite first
    :ets.insert(@table, {a, o})    # then ETS cache
    :ok
  end

  @spec lookup(URI.t() | String.t()) :: {:ok, URI.t()} | :error
  def lookup(agent_uri) do
    a = to_string(agent_uri)
    case :ets.lookup(@table, a) do
      [{_, owner_str}] -> {:ok, URI.parse(owner_str)}
      [] -> lookup_from_sqlite_and_warm(a)
    end
  end

  @spec forget(URI.t() | String.t()) :: :ok
  def forget(agent_uri) do
    a = to_string(agent_uri)
    :ok = delete_from_sqlite(a)
    :ets.delete(@table, a)
    :ok
  end

  @spec boot_load() :: :ok
  def boot_load do
    :ets.delete_all_objects(@table)
    for {a, o} <- load_all_from_sqlite(), do: :ets.insert(@table, {a, o})
    :ok
  end
end
```

让 `Behavior.Agent.data_owner -> user_uri`，`default_grants_from_data_owner` 正确合成 `:duplicate` cap 给 owner user. User 通过 `Identity.grant_cap` 委托.

**Behavior 与 ESR-domain registry 耦合的关注**：同样耦合已存在 `Behavior.Chat`（读 Session slice `:owner_uri`）。north-star 针对 PLUGIN-to-CORE，不是 Behavior-to-domain-registry. AgentOwnership 在 `ezagent_core`，Behavior.Agent 在 `ezagent_domain_chat` —— core-from-domain（合法）。

### 3.9 `Ezagent.Agent.Provisioning.provision_agent/3` —— 共享 owner+caps helper（codex r3 HIGH-2 修复）

Codex r3 HIGH-2 指出 rev-3 §4.3 宣称 "`Kind.Server` 的现有 post-spawn 路径会自动合成 cap" —— 但 `default_grants_from_data_owner/2` **没**被任何现有 spawn lifecycle 调用（grep 证实）。Rev-2 spawn body 还在用 `grant_initial_caps_for_owner/2`. Owner-derived `:duplicate` grant 路径是幻影.

Rev 4 让 provisioning 显式且共享。新模块 `Ezagent.Agent.Provisioning`:

```elixir
defmodule Ezagent.Agent.Provisioning do
  @moduledoc """
  共享 agent-provisioning helper —— 记录 ownership 并应用 data_owner-derived
  默认 caps。被 BOTH `Behavior.Workspace.:create_agent` 和
  `Behavior.Agent.:duplicate` 用. 一个 helper → 一条 code path → 一处 cap 语义.

  步骤：
  1. AgentOwnership.record(agent_uri, owner_user_uri) —— durable write
  2. CapabilityRegistry.default_grants_from_data_owner(Entity.Agent, agent_uri)
     遍历 Agent Kind 每个 Behavior，问 data_owner/1，合成 [{grantee, cap}]
  3. 对每个 {grantee, cap} dispatch identity_admin.grant_cap （admin 模式）
  4. 任何 grant 失败回滚 (1)
  """

  @spec provision_agent(URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def provision_agent(%URI{} = agent_uri, %URI{} = owner_user_uri, ctx) when is_map(ctx) do
    with :ok                 <- validate_owner_is_user(owner_user_uri),
         :ok                 <- Ezagent.AgentOwnership.record(agent_uri, owner_user_uri),
         {:ok, grants}        = {:ok, Ezagent.CapabilityRegistry.default_grants_from_data_owner(Ezagent.Entity.Agent, agent_uri)},
         :ok                 <- apply_grants(grants, ctx) do
      :ok
    else
      {:error, reason} ->
        _ = Ezagent.AgentOwnership.forget(agent_uri)
        {:error, {:provisioning_failed, reason}}
    end
  end
end
```

`Behavior.Workspace.:create_agent` action body 加：

```elixir
:ok <- Ezagent.Agent.Provisioning.provision_agent(agent_uri, ctx.caller, ctx),
```

`Behavior.Agent.:duplicate` 的 `spawn_target_directly/5` 把 `grant_initial_caps_for_owner` 步**替换**为：

```elixir
:ok <- Ezagent.Agent.Provisioning.provision_agent(target_uri, target_owner_uri, %{caller: bootstrap_granter(), caps: bootstrap_admin_caps()}),
```

验收测试 row 16 显式断言 `:create_agent` 后 caller user 在新 agent URI 上持 `{Behavior.Agent, :duplicate}` cap（通过 `Identity.list_caps` 查）。

---

## 4. Cap-BAC —— 双向授权

### 4.1 需要的两个 cap

| # | Cap                                          | 在哪                | 谁持有                                  | 何时检查           |
|---|----------------------------------------------|---------------------|------------------------------------------|--------------------|
| 1 | `{Behavior.Agent, :duplicate}`              | **源** agent        | 源所有者或源 ws admin                    | Dispatch-time      |
| 2 | `{Behavior.Workspace, :create_agent}`       | **目标** workspace  | 目标所有者或目标 ws admin                | Action-body-time   |

**两者**必须都成功。

### 4.2 Cap 解析（rev 3 —— AgentOwnership 支撑）

`Behavior.Agent.data_owner(agent_uri)` 通过 `AgentOwnership.lookup(agent_uri)` 解析到所属 USER URI（§3.8）。`default_grants_from_data_owner/2` 在 agent-spawn 时自动合成 `{Behavior.Agent, :duplicate}` grant 给该 user. Owner 可通过 `Identity.grant_cap` 委托 —— bilateral consent 是 normal user op.

Pre-AgentOwnership agents 通过 `mix ezagent.agent.set_owner` 回填.

### 4.3 `:duplicate` cap 从哪来（rev 3 —— 合成，不显式）

在 `Behavior.Workspace.:create_agent` action body（target spawn 后，post-spawn obligations 前）新加一行：

```elixir
:ok <- Ezagent.AgentOwnership.record(agent_uri, ctx.caller),
```

然后 `Kind.Server` 标准 PR-OWN-1 post-spawn 路径自动合成 `{Behavior.Agent, :duplicate}` cap 给 owner. Rev-2 的"显式 grant_initial_caps"行**被移除** —— 少特例，一机制.

### 4.4 Caller 场景

| Caller                                                | 源 :duplicate cap     | 目标 :create_agent cap | 允许? |
|-------------------------------------------------------|------------------------|------------------------|-------|
| 源创建者，克隆到自己 workspace                          | 有（spawn 时合成）     | 有                     | **是**|
| 源创建者，克隆到别人 workspace                          | 有                     | 无                     | **否**|
| 目标 ws admin，**无**源端 cap                           | **无**                 | 有                     | **否**|
| 双向：源所有者授权目标 ws admin                          | 有（源 grant 给）      | 有                     | **是**|
| 随机 user                                              | 无                     | 无                     | **否**|

---

## 5. Audit

Dispatch 链记录每个 `Invocation.dispatch/1` + snapshot manifest hash.

---

## 6. 迁移

**Schema 层:** 无。**已有 agent ownership**: 无 AgentOwnership 行 → `:no_owner`. Operator 通过 `mix ezagent.agent.set_owner` per-agent 回填.

---

## 7. 验收测试

14 行覆盖。关键：

1. Happy path
2. Bilateral 跨租户克隆（NON-bootstrap user，证 codex-r2 HIGH-2 修复结构上真实）
3. Cap 拒绝（目标 ws admin 无源 grant，dispatch-time）
4. Cap 拒绝（源所有者无目标 ws admin，action-body-time）
5. Target URI 冲突（snapshot 之前拒）
6. 源缺失
7. Snapshot 失败 rollback
8. **restore_from_snapshot 失败 → DURABLE rollback（codex r2 CRITICAL）** —— 验证 Kind.Snapshot 删、registry 清、FS 清
9. **sandbox.write_path 失败 → DURABLE rollback** —— 验证 `:sandbox` slice **没**通过 `:on_terminate` 持久化
   - 9a. grant_initial_caps 注入
   - 9b. start_pty 注入
10. **Plugin 无 snapshot callback**（codex r2 HIGH-3 适配器）—— path: nil, restore noop
11. **Adoption-refused TOCTOU**
12. **Invariant: 无 `Workspace.create_agent` 路由**
13. **Live mutation during snapshot**（codex r2 MEDIUM-4）—— `{:error, {:source_changed_during_snapshot, _}}`
14. **AgentOwnership 在 spawn 时写入**（codex r2 HIGH-2 前置）
15. **Restart 持久性**（codex r3 HIGH-3）—— 创 agent → 确认 AgentOwnership 有行 + caller 有 `:duplicate` cap → 模拟 runtime 重启（stop+start `EzagentCore.EtsOwner`）→ 确认 `AgentOwnership.lookup(agent_uri)` 从 SQLite-backed boot reload 仍返回 owner_user_uri → 确认 owner 能 dispatch `:duplicate`（无需 bootstrap-admin）. 也测 ETS owner 中途 crash：杀 ETS owner 进程，让 supervisor 重启，确认 `boot_load` 从 SQLite 重新 populate.
16. **Provisioning end-to-end**（codex r3 HIGH-2）—— `:create_agent` 后，caller user 通过 `Identity.list_caps` 查到 `{Behavior.Agent, :duplicate}` cap 在新 agent URI 上. 断言 `Provisioning.provision_agent/3` helper 实际触发并端到端应用 grants（不只是 row 14 那样隔离地 record ownership）.

---

## 8. Invariant tests

### 8.1 FS 隔离

`apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`：克隆后改源 canary，target 不变；删源整 config_dir，target 仍可用.

### 8.2 不路由 create_agent

`apps/ezagent_core/test/invariants/agent_duplicate_no_create_agent_routing_test.exs`：grep `Behavior.Agent` 源文件，断言不调用 `Ezagent.Workspace.create_agent` / `Behavior.Workspace.:create_agent`.

---

## 9. CLAUDE.md / 文档

无 CLAUDE.md 改动. Operator 文档在实现 PR 的 `docs/operations/agent-duplicate.md`（双语）.

---

## 10. 待办（推后）

- 真正的 cc quiesce（V1 检测+abort，不 prevent）
- 克隆的 LV admin UI
- MCP 工具面
- 批量克隆
- 跨主机 federation
- legacy agent AgentOwnership 回填（`mix ezagent.agent.set_owner` 本 PR 发）
- `Behavior.Agent` 未来 actions（:rename, :archive, :transfer_ownership）

---

## 11. Codex 对抗 review

- **Rev 1**：1 CRITICAL + 3 HIGH + 1 MEDIUM. Rev 2 处理.
- **Rev 2**：1 CRITICAL（rollback durable 漏洞）+ 2 HIGH（data_owner 关闭 bilateral consent；snapshot optional callback 抛错）+ 1 MEDIUM（snapshot 不 point-in-time）. Rev 3 处理.
- **Rev 3**：codex 返回 `needs-attention`，1 CRITICAL（rollback 在延迟 terminate 重写 snapshot 前删 snapshot）+ 2 HIGH（default_grants_from_data_owner 没被 spawn lifecycle 调用 → owner-derived caps 是幻影；AgentOwnership 易失 ETS → 重启丢失授权）. Rev 4 处理（§3.4.2 重写为 terminate-then-purge、§3.9 新 Provisioning helper、§3.8 改为 SQLite-backed cache、§7 加 row 15+16）.
- **Rev 4**（本版本）：codex r4 将跑. r4 干净则通过 admin merge. r4 若仍 CRIT+ 则视为 "需更多架构输入"，飞书通知 Allen 再迭代.

---

## 12. User-assist steps

**无。** 实现 PR 完全跑 CI + 本地 mix 测试.
