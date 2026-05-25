# SPEC — Agent 复制/克隆原语 (Behavior.Agent `:duplicate`)

**状态:** DRAFT rev 3 · 2026-05-25（codex r1 + r2 修复）
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

#### 3.4.2 `rollback_partial_target/3` —— **durable cleanup（codex r2 CRITICAL 修复）**

Codex r2 CRITICAL: Agent 声明 `persistence: :on_terminate`。如果在 slice 已 mutated 之**后**调用 `Kind.terminate/1`，部分状态会持久化 —— 同 URI 下次 spawn 会 rehydrate 失败的 clone state。

```elixir
defp rollback_partial_target(target_uri, staged_path, err) do
  # 1. 同步 dispatch Sandbox.:destroy —— 清 :sandbox slice + plugin 端 FS 清理
  _ = dispatch_sandbox_destroy(target_uri)
  # 2. 撤销 grant 的 caps
  _ = revoke_initial_caps_if_granted(target_uri)
  # 3. 忘掉 AgentOwnership + AgentLineage + WorkspaceRegistry
  _ = Ezagent.AgentOwnership.forget(target_uri)
  _ = Ezagent.AgentLineage.forget(target_uri)
  _ = Ezagent.WorkspaceRegistry.unbind(target_uri)
  # 4. 删 KindSnapshot 持久行
  _ = Ezagent.Kind.Snapshot.delete(target_uri)
  # 5. 清 staging temp dir
  _ = File.rm_rf(staged_path)
  err
end
```

每步幂等。**Failure-injection 验收测试**（§7 rows 7-9）：对每个 post-spawn 步骤注入失败，断言 rollback 后无 `Kind.Snapshot` 行、无 registry 绑定、无 lineage、无 ownership 行、无 config dir、无 staged path。

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

### 3.8 `Ezagent.AgentOwnership` registry —— 新 ETS 表（codex r2 HIGH-2 修复）

```elixir
defmodule Ezagent.AgentOwnership do
  @moduledoc """
  Agent 所有权 registry —— agent_uri → owner_user_uri.

  与 AgentLineage 不同：
  - AgentLineage.spawned_by(agent_uri) = 谁 SPAWN（orchestrator 链）
  - AgentOwnership.lookup(agent_uri) = 哪个 USER 拥有（永远 entity://user/...）

  在 agent-spawn 时由 Behavior.Workspace.:create_agent 填充：
  调用 user 成为新 agent 的 owner. V1 是 spawn 时一次写。
  """

  @table :ezagent_agent_ownership

  @spec record(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def record(agent_uri, owner_uri) do
    :ets.insert(@table, {to_string(agent_uri), to_string(owner_uri)})
    :ok
  end

  @spec lookup(URI.t() | String.t()) :: {:ok, URI.t()} | :error
  def lookup(agent_uri) do
    case :ets.lookup(@table, to_string(agent_uri)) do
      [{_, owner_str}] -> {:ok, URI.parse(owner_str)}
      [] -> :error
    end
  end

  @spec forget(URI.t() | String.t()) :: :ok
  def forget(agent_uri) do
    :ets.delete(@table, to_string(agent_uri))
    :ok
  end
end
```

让 `Behavior.Agent.data_owner -> user_uri`，`default_grants_from_data_owner` 正确合成 `:duplicate` cap 给 owner user. User 通过 `Identity.grant_cap` 委托.

**Behavior 与 ESR-domain registry 耦合的关注**：同样耦合已存在 `Behavior.Chat`（读 Session slice `:owner_uri`）。north-star 针对 PLUGIN-to-CORE，不是 Behavior-to-domain-registry. AgentOwnership 在 `ezagent_core`，Behavior.Agent 在 `ezagent_domain_chat` —— core-from-domain（合法）。

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
- **Rev 3**（本版本）：codex r3 将跑. r3 干净则通过 admin merge.

---

## 12. User-assist steps

**无。** 实现 PR 完全跑 CI + 本地 mix 测试.
