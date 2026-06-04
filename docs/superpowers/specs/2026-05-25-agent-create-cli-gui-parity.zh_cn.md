# SPEC — Agent 创建：CLI ↔ GUI 收敛到一个 dispatch 路径

**状态:** DRAFT rev 1 · 2026-05-25
**Tier:** `apps/ezagent_domain_workspace/`（新 Behavior action）+ `apps/ezagent_domain_identity/`（CLI 改写）+ `apps/ezagent_plugin_liveview/`（LV 改写）
**触发:** Allen 2026-05-25 — CLI 与 LV 创建 agent 必须收敛到一个 Behavior `:create_agent` action，然后删掉 bypass 路径。关闭审计 Finding #137 中 "agent.create" 那一行。
**前置文档:**
- `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137 still partial)" — `mix ezagent.agent.create` 行
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md`（data_owner 契约）
- `docs/superpowers/specs/2026-05-23-capability-registry.md`（cap-subject 单一注册入口）
- SKILL P14（dispatch 是 Kind 间的唯一路径）、P19（dispatch 三条卫生规则）、P3（单一数据源）
- Codex PR #304 round-2 HIGH（"NOT a bare FacadeRegistry op — that bypasses dispatch"）
- `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` `add_template/3`（LV 当前使用的编排路径）
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex` `register_and_instantiate/3`（当前 LV 路径）
- `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.create.ex`（当前 CLI bypass — `SpawnRegistry.spawn + Identity.grant_cap`，无 template，无 PTY）
**英文配套:** `2026-05-25-agent-create-cli-gui-parity.md`。

---

## 0. Allen 指令（原文 2026-05-25）

> "CLI 和 GUI 创建 agent 的路径必须收敛到一个 Behavior `:create` action — 一个代码路径。CLI 是薄包装。LV 也走同一个 dispatch。然后把 bypass path 删掉。no back-compat。"

操作约束（2026-05-25 再次确认）：不做 back-compat shim（`feedback_let_it_crash_no_workarounds`）。

---

## 1. 目标

**一个可 dispatch 的 Behavior action — `Behavior.Workspace.:create_agent` — 是 agent 创建的唯一代码路径**，无论调用方是 CLI（`mix ezagent.agent.create`）、LV（`/admin/agents/new`）、未来的 MCP 工具，还是程序化的测试 fixture。该路径有 CapBAC 检查（调用方需对目标 workspace 持有 `Behavior.Workspace` cap），并产出一个完全初始化的 agent（Kind 活着、sandbox slice 已填、cc 启动了 PTY、echo 在 `with_pty: true` 时也启动 PtyServer）。

本 SPEC 的实现 PR 落地后：
- `mix ezagent.agent.create` 和 LV 表单都调用同一个 facade `Ezagent.Workspace.create_agent/3`，由它 dispatch `:create_agent`。
- CLI 旧的 `SpawnRegistry.spawn + Identity.grant_cap` bypass 路径 **删除**（无 stub，无 back-compat）。
- LV 旧的直接调用 `Ezagent.Workspace.add_template + invoke_template_now` **删除**（编排逻辑搬进 dispatched action body）。
- 用 CLI 创建的 cc-flavor agent 现在带 PTY（审计指出的 bug）；CLI 与 LV 行为一致。
- 一个 invariant test 守护收敛：在新 `:create_agent` action body 之外，对 `entity://agent/` URI 的直接 `SpawnRegistry.spawn(...)` 调用会让 CI 失败。

---

## 2. 范围

In-scope：
- 在 `Ezagent.Behavior.Workspace` 上新增 `:create_agent` action，附带 cap subject、`data_owner/1` 沿用现有 Workspace Behavior 的 workspace-admin 语义、以及包裹当前 LV 编排的 `invoke/4` body。
- 新 facade `Ezagent.Workspace.create_agent/3`（CLI + LV 都调用它做 dispatch）。
- 重写 `Mix.Tasks.Ezagent.Agent.Create`（`mix ezagent.agent.create`）— `do_create` 变成薄薄的"组装参数 + dispatch"包装。
- 重写 `EzagentPluginLiveview.AgentNewLive.handle_event("create_agent", ...)` — 删除 `register_and_instantiate/3`，改为调用 `Workspace.create_agent/3`。
- Invariant test：`apps/ezagent_core/test/invariants/agent_create_single_path_test.exs` — grep production 代码，找在 action body 之外针对 `entity://agent/` URI 的直接 `SpawnRegistry.spawn(...)` 调用。Allowlist 是 action body + reconciler。
- Acceptance tests（在实现 PR 中，不在本 SPEC）— 见 §7。

Out-of-scope：
- 其他 `mix ezagent.*` 任务（user.create、user.set_password、feishu.bind 等）— 每个走自己的后续 PR，按 `docs/futures/todo.md` 中的审计表执行。
- Reconciler 的 `spawn_fresh/4` 路径（它的 `SpawnRegistry.spawn_detailed/1` 显式 allowlist — orchestrator-spawned workers 是不同的表面；agent CREATE via 本 SPEC 是 operator-facing 表面）。
- Phoenix.Channel bridge 重新 spawn 路径（`EzagentPluginCc.Channel.join/3` 调用 `SpawnRegistry.spawn(agent_uri)` 在绑定 channel 前确保 URI 活着 — 那是防御性 ensure，不是 CREATE；allowlist）。
- 联邦 / 跨 runtime agent 创建（保持 single-machine 假设；CLI 通过分布式 Erlang RPC 与本地 runtime 通信，与今天一致）。

---

## 3. 设计

### 3.1 Behavior action — `Ezagent.Behavior.Workspace`

在已有 Workspace Behavior 上新增 action（**不**新建 Behavior — `Workspace` 是 scope-owning Kind；agent 创建是 workspace-scoped）：

```elixir
@impl Ezagent.Behavior
def actions, do: [..., :create_agent]   # 加入已有列表

@impl Ezagent.Behavior
def cap_subjects do
  [
    ...,
    {:create_agent,
     "create a new agent in this workspace (registers Template Class, " <>
       "spawns Agent Kind, starts PTY for cc/echo-with-PTY)"}
  ]
end

@impl Ezagent.Behavior
def interface do
  %{
    ...,
    create_agent: %{
      description: "Provision a new agent (Template Class + spawn) in this workspace",
      args: %{
        flavor: :string,         # "cc" | "echo" | "curl" | 未来
        name: :string,           # entity-name 后缀（拼出 <flavor>_<name>）
        cwd: :string,            # 不需要时传 ""
        with_pty: :boolean       # echo 选项 — /bin/bash -i sidecar
      },
      returns: %{agent_uri: :uri, template_name: :string},
      modes: [:call]
    }
  }
end
```

`data_owner/1` 保持 `:any`（`Behavior.Workspace.data_owner/1` 已返回 — workspace 管理员可通过 §5.2 admin branch 授予）。data_owner 语义不变。

### 3.2 Action body

`invoke(:create_agent, slice, args, ctx)` callback 在 Workspace Kind GenServer 内部运行，编排 LV facade 今天做的完全一样的事，但是 inline + dispatched：

```elixir
def invoke(:create_agent, slice, %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?}, ctx) do
  workspace_uri = Map.get(ctx, :self_uri)
  workspace_name = workspace_uri.host

  with :ok <- validate_flavor(flavor),
       :ok <- validate_name(name),
       :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
       {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
       :ok <- refuse_if_exists(agent_uri),
       {:ok, tmpl_name, new_slice} <- register_template_and_mutate_slice(slice, flavor, agent_uri, %{cwd: cwd, with_pty?: with_pty?}, workspace_name),
       :ok <- invoke_template(workspace_uri, tmpl_name, flavor, agent_uri) do
    {:ok, new_slice, %{agent_uri: agent_uri, template_name: tmpl_name}}
  else
    {:error, _} = err -> err
  end
end
```

实现要点：

- **Template 注册** 对 `cc` 和 `echo` flavor 写入 workspace-scoped template（与当前 LV `register_and_instantiate/3` 逐字一致）+ 持久化到 `Ezagent.Workspace.Store` + 加入 `slice.session_templates`。
- **直接 spawn** 对 `curl` / `np` / 未来无 Template Class 的 flavor：在 inline 处调用 `SpawnRegistry.spawn(agent_uri)`（按 §4 invariant，这是 `entity://agent/` URI 唯一被 allowlist 的调用点）。
- **Loader.invoke_template** 对 cc/echo 调用以完整 provision（Agent Kind + sidecar）。这是从 GenServer **外部** 同步调用 — 安全，因为 Loader.invoke_template 不会回 dispatch Workspace（它只调 Template Class 的 `instantiate/3`，由后者 spawn Agent + PtyServer）。
- **`refuse_if_exists/1`** 检查 `KindRegistry.lookup(agent_uri)`，返回 `{:error, {:already_exists, _}}`（与 LV 同 shape）。
- Action 返回 `{:ok, new_slice, %{agent_uri, template_name}}`；dispatch 回复把该 map 传回给调用方。

### 3.3 Facade — `Ezagent.Workspace.create_agent/3`

```elixir
@spec create_agent(URI.t(), map(), map()) ::
        {:ok, %{agent_uri: URI.t(), template_name: String.t()}}
        | {:error, term()}
def create_agent(%URI{} = workspace_uri, args, %{caller: caller_uri, caps: caps} = ctx)
    when is_map(args) do
  target = URI.new!("#{URI.to_string(workspace_uri)}?action=workspace.create_agent")

  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: target,
    mode: :call,
    args: args,
    ctx: %{caller: caller_uri, caps: caps, reply: {:caller_inbox, self()}}
  })
end
```

create_agent dispatch 成功后，**调用方**（CLI 或 LV）通过已有的 `identity.grant_cap` dispatch 循环授权初始 caps（调用方 ctx，调用方 caps — 保留 CapBAC）。facade **不** inline cap grants — 保留 caller-context-bound 是规范的授权 shape（§3.4）。

### 3.4 Cap grants 保持 caller-context

LV 已有的 `grant_all/3` 循环（每个 cap 一次 `identity.grant_cap` dispatch，调用方 ctx）保留。CLI 获得同样的循环（之前是直接调用 `Ezagent.Identity.grant_cap/3`，是 facade bypass）。两个调用点现在都 dispatch：

```elixir
Invocation.dispatch(%Invocation{
  target: URI.new!("#{agent_uri}?action=identity.grant_cap"),
  mode: :call,
  args: %{cap: cap},
  ctx: %{caller: caller_uri, caps: caller_caps, reply: {:caller_inbox, self()}}
})
```

这与 LV 已用的模式相同，提到共享 helper `Ezagent.Workspace.grant_initial_caps/3`，CLI 和 LV 都调用它。

### 3.5 CLI 改写 — `Mix.Tasks.Ezagent.Agent.Create`

```elixir
defp do_create(agent_uri_str, opts) do
  caps_str = Keyword.get(opts, :caps, "")
  allow_allcaps = Keyword.get(opts, :allow_allcaps, false)
  cwd = Keyword.get(opts, :cwd, "")
  with_pty? = Keyword.get(opts, :with_pty, false)

  with {:ok, agent_uri} <- parse_uri(agent_uri_str),
       {:ok, workspace_uri, flavor, name} <- decompose(agent_uri),
       :ok <- check_allcaps_flag(caps_str, allow_allcaps),
       {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()),
       {:ok, %{agent_uri: created_uri}} <-
         Ezagent.Workspace.create_agent(workspace_uri,
           %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
           %{caller: Ezagent.Entity.User.admin_uri(), caps: Ezagent.Entity.User.admin_caps()}
         ),
       :ok <- Ezagent.Workspace.grant_initial_caps(created_uri, caps,
         %{caller: Ezagent.Entity.User.admin_uri(), caps: Ezagent.Entity.User.admin_caps()}) do
    Mix.shell().info("✓ created #{URI.to_string(created_uri)}")
    Mix.shell().info("  caps: #{length(caps)}")
  else
    {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
  end
end
```

新增 `--cwd` 和 `--with-pty` flag，使 CLI 与 LV 的 PTY / cwd 控制完全对等（按 Allen 审计 Finding 4 — LV 有 PTY + cwd；CLI 也必须有）。

删除：
- `--no-spawn` flag（LV 没有"只注册不 spawn"模式；它依赖的 bypass-only 路径删了）。
- 直接 `SpawnRegistry.spawn` 调用点。
- 直接 `Ezagent.Identity.grant_cap` 调用点。

### 3.6 LV 改写 — `EzagentPluginLiveview.AgentNewLive`

`handle_event("create_agent", ...)` 从 ~40 行（含 cc/echo/其他三个 `register_and_instantiate/3` 子句）收缩到一次 dispatched 调用：

```elixir
def handle_event("create_agent", %{"agent" => params}, socket) do
  with :ok <- validate_flavor(...),
       :ok <- validate_name(...),
       :ok <- validate_cwd_for_flavor(...),
       {:ok, caps} <- Capability.Parser.parse(caps_str, caller_uri(socket)),
       workspace_uri = current_workspace_uri(socket),
       {:ok, %{agent_uri: agent_uri}} <-
         Ezagent.Workspace.create_agent(workspace_uri,
           %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
           %{caller: caller_uri(socket), caps: caller_caps(socket)}),
       :ok <- Ezagent.Workspace.grant_initial_caps(agent_uri, caps,
         %{caller: caller_uri(socket), caps: caller_caps(socket)}) do
    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:noreply, push_navigate(socket, to: "/identities/agents/#{encoded}")}
  else
    {:error, reason} -> {:noreply, assign(socket, :flash_error, friendly_error(reason))}
  end
end
```

从 LV 删除（搬进 action body 或 facade）：
- `register_and_instantiate/3`（三个子句）。
- `compose_uri/3`（action body 拥有 URI 组合）。
- `refuse_if_exists/1`（action body 拥有 existence check）。
- `grant_all/3`（facade 拥有 cap-grant 循环）。
- `agent_name/1`（LV 层不再需要 — action body 拥有）。

表单验证（`validate_flavor/2`、`validate_name/1`、`validate_cwd_for_flavor/3`、`validate_cwd_dir/1`）**留在 LV** — 这些是早期反馈 UX 验证器；action body 重新跑作为安全网（纵深防御 — LV 验证器不会经 RPC 到达未来的 remote LV）。

### 3.7 为什么 cap subject 是 `Behavior.Workspace.create_agent`（不是 Agent Kind 上的新 Behavior）

三个原因：

1. **Dispatch 需要现有 target.** `:create` action 把 dispatch target 指向新 agent URI 会失败 ReadyGate（target 还不存在）。Workspace URI 存在；对它 dispatch 可行。
2. **授权 shape 匹配.** 在 workspace X 中创建 agent 是 workspace-scoped 操作 — workspace 管理员应能做，与 `:add_template` / `:add_member` / `:set_routing_rules` 一致。Cap shape 与现有 Workspace cap subjects 一致。
3. **不需要新 Behavior 文件.** Allen 指令偏好最少新抽象（`feedback_let_it_crash_no_workarounds`；SKILL P8 "少发明,多装配"）。在现有 Behavior 上加一个 action 是最少发明的选项。

Allen 任务描述提到 `Ezagent.Behavior.Agent.:create` 作为选项（"or create that Behavior if it doesn't exist"）— 本 SPEC 选择更简单的等价方案。cap_subject 字符串让 operator 清楚意图。

---

## 4. Invariant test

`apps/ezagent_core/test/invariants/agent_create_single_path_test.exs`：

```elixir
defmodule EzagentCore.Invariants.AgentCreateSinglePathTest do
  use ExUnit.Case, async: true

  # 在 allowlist 外，对 entity://agent/ URI 的直接 SpawnRegistry.spawn(...)
  # 是被禁止的。统一的 create 路径走 Behavior.Workspace.:create_agent action。
  @forbidden ~r/SpawnRegistry\.(spawn|spawn_detailed)\s*\(\s*[^)]*entity:\/\/agent/

  # Allowlist 的调用点 — 每个都有理由说这不是 operator-facing create：
  @allowlist [
    # 新 action body — 唯一合法的 operator-facing create。
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
    # cc channel 重新 spawn（防御性 ensure — 见 EzagentPluginCc.Channel.join/3）。
    "apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/channel.ex",
    # Reconciler / spawn_fresh — orchestrator-spawned workers，非 operator-facing。
    "apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex",
    # SpawnRegistry 自身。
    "apps/ezagent_core/lib/ezagent/spawn_registry.ex"
  ]

  test "operator-facing create goes through Behavior.Workspace.:create_agent only" do
    # ... grep production 文件，跳过 test/，跳过 allowlist，断言无命中 ...
  end
end
```

如果未来 PR 重新引入直接 spawn `entity://agent/` URI 而不走 `:create_agent` action 的 CLI / LV / mix task，这个 invariant **失败**。

---

## 5. 迁移

按 Allen no-back-compat：

- `Mix.Tasks.Ezagent.Agent.Create.do_create/2` 就地改写；旧 `--no-spawn` flag 删除；新增 `--cwd` + `--with-pty` flag；usage 错误信息更新。
- `EzagentPluginLiveview.AgentNewLive.register_and_instantiate/3` + helpers 删除；`handle_event("create_agent", ...)` 改写。
- 不做 DB migration。不加 version flag。不留 stub。
- 用旧 CLI flag `--no-spawn` 的测试更新到新 dispatch 路径（测试数量小 — audit module-level doc 已标记 bypass 性质）。

如果外部脚本调用 `mix ezagent.agent.create --no-spawn`，它会以 usage 错误 BREAK（故意，按 `feedback_let_it_crash_no_workarounds`）。

---

## 6. PR 序列

单一实现 PR — 变更紧凑，足以原子落地：

**PR：`feat/agent-create-cli-gui-parity`**
1. 在 `Ezagent.Behavior.Workspace` 上加 `:create_agent` action + cap subject + interface 条目。
2. 实现 `Ezagent.Behavior.Workspace.invoke(:create_agent, ...)` body（template 注册 + slice 修改 + Loader.invoke_template + 直接 spawn 兜底）。Helpers（`validate_flavor/2`、`compose_agent_uri/3` 等）从 LV 搬入 Behavior 模块。
3. 加 facade `Ezagent.Workspace.create_agent/3` + `Ezagent.Workspace.grant_initial_caps/3`。
4. 重写 `Mix.Tasks.Ezagent.Agent.Create`（CLI 薄包装）。
5. 重写 `EzagentPluginLiveview.AgentNewLive.handle_event("create_agent", ...)`（LV 薄包装）。
6. 从 LV 删除过时 helpers。
7. 加 invariant test `agent_create_single_path_test.exs`。
8. 更新 + 加 acceptance tests（§7）。
9. 手动跑 `mix ezagent.agent.create entity://agent/system/test-parity --flavor cc --cwd /tmp`；验证 agent 在 KindRegistry 中 + 有 PTY（sandbox slice `config_dir_path` 非 nil）。
10. `mix test`、`mix format --check-formatted`、`mix ezagent.caps.audit` 全部 clean。
11. Codex r1 + r2，按 round-2 cap。
12. Admin merge。

---

## 7. Acceptance tests（在实现 PR）

`apps/ezagent_domain_workspace/test/ezagent/behavior/workspace_create_agent_test.exs`：

1. **CLI 路径产生带 PTY 的 cc-flavor agent.** Dispatch `:create_agent`，`flavor: "cc", cwd: <tmpdir>`。断言 agent URI 在 KindRegistry，`Sandbox.invoke(:read, ...)` 返回非 nil `config_dir_path`，PtyServer 已注册。
2. **LV 路径产生相同状态.** 同 dispatch，不同 caller URI。断言相同 shape — agent URI、sandbox slice、PtyServer。
3. **echo-with-PTY 产生 /bin/bash -i sidecar.** Dispatch `flavor: "echo", with_pty: true, cwd: <tmpdir>`。断言 PtyServer 起来。
4. **echo-without-PTY 不产生 sidecar.** Dispatch `flavor: "echo", with_pty: false`。断言无 PtyServer。
5. **curl 直接 spawn 工作.** Dispatch `flavor: "curl"`。断言 agent URI 在 KindRegistry，无 PtyServer。
6. **Cap 拒绝：caller 在该 workspace 上无 Workspace cap.** 从无 workspace cap 的非 admin caller dispatch → `{:error, :unauthorized}`。
7. **创建后 cap grant 工作.** 创建成功后，从同 caller dispatch `identity.grant_cap` → `{:ok, _}`。
8. **已存在则拒绝.** 用同 flavor/name dispatch 两次 → 第二次返回 `{:error, {:already_exists, _}}`。

Invariant test（§4）是按 SKILL P6 的闸门（completion claim requires invariant test）。

---

## 8. Open questions

- **OQ-1: `:create_agent` 应该 `:cast` 还是 `:call`？** `:call` — 调用方需要 agent_uri 来导航 / 授 caps。`:cast` 会强制单独 read-back，翻倍往返。已决：`:call`。
- **OQ-2: action body 应直接调 `Loader.invoke_template`，还是 dispatch `:invoke_template`？** 直接调 — `Loader.invoke_template` 是 `Workspace.add_template/3` 已用的 facade 模式。该路径无 dispatch action 存在。为本 SPEC 发明一个违反 P8（少发明）。已决：直接调。
- **OQ-3: 是否需要 args 里的 `template_args` 字段？** 不需要 — `cwd` + `with_pty` 覆盖所有当前 template 参数。未来更复杂参数的 flavor 可扩展 args map；action body 按 flavor 校验。已决：args 扁平。

---

## 9. 风险

- **R-1: Template instantiate 在 Workspace GenServer 内 block GenServer.** Workspace Kind 串行处理所有 workspace mutations；进行中的 create_agent 会 block add_member / set_routing_rules 调用。缓解：SpawnRegistry.spawn 通常很快（<200ms）；Workspace mutations 不频繁（operator-driven，非 chat 流量）。如果这真的成为瓶颈，后续：在 Task 中 spawn template invoke，返回 pending-status reply。
- **R-2: Action body 变大.** ~150 LOC 的验证 + 编排放在一个 `invoke/4` 子句。缓解：helpers 提取为同模块私有函数（镜像现有 `Behavior.Workspace` 风格）。
- **R-3: 依赖旧 CLI flag `--no-spawn` 的测试断.** 缓解：grep + 更新；表面小（Allen 说生产 runbook 无）。

---

## 10. Non-goals

- 泛化的"创建任何 Kind"action（会变成 P8 过度抽象）。
- 联邦感知的 create（single-machine；runtime RPC 仍是边界）。
- Template Class 写作工具包（每个 plugin 的 Template Class 是自己的 SPEC；本 SPEC 只通过 `Loader.invoke_template` 消费已存在的 Class）。
