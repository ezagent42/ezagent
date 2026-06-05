# SPEC — Caps 清理 v1 r4 实现（PR-CC-2-v2）

**状态:** r1（草稿，待 codex review）。2026-05-25。
**层级:** `apps/ezagent_core/` 框架 callback + 跨所有 Behavior 清扫。
**触发:** 父 SPEC `2026-05-25-caps-cleanup-v1.md` §0d.7 action item #2 —— PR-CC-2-v2 实施的阻断依赖。解决 codex 在 PR #350 r1 标记的 SPEC-vs-代码漂移（HIGH-1、HIGH-2、MED-1）。
**配套:** `2026-05-25-caps-cleanup-v1-r4-impl.md`（英文）。

**前置:**
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` r4 —— 父 SPEC，本实施 SPEC 收紧 r4 的细节。r4 §0d 文档化 struct-kept 决策（PR-CC-2a/2b revert 后）；§0d.7 action item #2 标记本 sibling SPEC 为 ⛔ 阻断 PR-CC-2-v2。

**前置 memory（关键）:**
- `feedback_let_it_crash_no_workarounds` —— 无 shim、无 dual-path、无迁移窗口。PR 是一次性协调改动。
- `feedback_completion_requires_invariant_test` —— 每个 deliverable 一个 invariant test。PR 合并 gate 是 §9.2 12 探针 invariant + 新的 catalog cap-shape gate + G3 编译期 check。
- `feedback_north_star_plugin_isolation` —— 每个新增 API 必须把 plugin 作者挡在 `apps/ezagent_core/` 之外。Behavior 作者写一个 `required_caps/0` map + 零宏。
- `feedback_subagent_must_load_project_skills` —— PR-CC-2-v2 subagent dispatch 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_companion_no_mix` —— PR-CC-2-v2 上的 codex review 含逐字 "no mix" 子句。

---

## 1. 为什么本 SPEC 独立存在

父 SPEC `2026-05-25-caps-cleanup-v1.md` r4 必须在 revert 后做修订而不丢失历史 context（r1–r3 string-cap 设计 + codex review 历史）。Body 章节 §5–§9 作为历史记录保留，附带内联 `> 🔄 r4 修订:` marker 把读者重定向到 §0d。

那种保留策略造成一个缺口：§0d 对 **WHAT 全面**（struct 保留、结构性目标存活、catalog gap 存在）但**对 HOW 简略**（无 file:line、无 signature 精度、无测试代码）。当 codex 对 PR #350 (r4 SPEC 修订) 做 round 1 review 时，MED-1 正好命中："PR-CC-2-v2 under-specified —— §0d 说保留 `CapabilityRegistry`、`cap_subjects/0`、struct caps，但 §9.2 / §9.3 还定义删 registry/callback API 的 test 并 assert '必须是 cap 字符串'。"

本 SPEC 显式写出 PR-CC-2-v2 的 WHEN/WHERE/HOW 关闭这个缺口。它不重新讨论 WHY（父 §0d.2 拥有）或 WHAT（父 §0d.1 / §0d.3 / §0d.4 / §0d.5 拥有）。它锁定：

1. `Behavior.required_caps/0` callback 精确签名（§2）
2. `Kind.holds_cap?/2` callback 契约 + default 实现（§3）
3. `Capability.cap/N` 构造帮助函数 for plugin 作者 UX（§4）
4. `SystemPrincipal.Catalog` cap-shape 转换（§5；解决 §0d.1b 阻断 gate）
5. §9.2 12-probe invariant 的 grep 目标重新指向 struct 构造点（§6）
6. §9.3 G3 编译期 check 10/11 struct-shape predicate（§7）
7. PR-CC-2-v2 file:line manifest（§8）+ dispatch-subagent prompt skeleton（§9）
8. 验收准则（§10）+ 回滚计划（§11）

---

## 2. `Behavior.required_caps/0` callback（plugin 作者主要 API）

**新增 callback 的文件:** `apps/ezagent_core/lib/ezagent/behavior.ex`

**签名:**

```elixir
@doc """
Action atom 到所需 capability 的映射。由 `Invocation.dispatch/1` step 5.5
读取以 gate cap check 后的 action。

`actions/0` 返回的每个 action 必须在此处有条目。由 `:ezagent_plugin_check`
check 10（本 SPEC §7）编译期强制。

## Plugin 作者 UX

推荐的构造点使用 `Ezagent.Capability.cap/3` helper（本 SPEC §4）：

    @impl true
    def required_caps do
      %{
        send:    Capability.cap(:chat, __MODULE__, :send),
        receive: Capability.cap(:chat, __MODULE__, :receive),
        join:    Capability.cap(:chat, __MODULE__, :join)
      }
    end

直接构造 struct 也合法但冗长：

    %{
      send: %Capability{
        kind: :chat,
        behavior: Ezagent.Behavior.Chat,
        action: :send,
        instance: :any,
        workspace_uri: :any,
        granted_by: :plugin_declared,
        granted_at: :compile_time
      }
    }

helper 的 `:plugin_declared` / `:compile_time` 哨兵值（`granted_by` /
`granted_at`）文档化为 "此 cap 是声明性需求，不是已发授权" 约定。
"""
@callback required_caps() :: %{required(action :: atom()) => %Ezagent.Capability{}}
```

**可选行为:** `actions/0 == []` 的 Behavior（纯接收 Behavior 如 `Behavior.Echo` 的 `handle_kind_message/3`-only）可以返 `%{}` —— 编译期 check 在 `actions/0` 也是空时接受空 map。

**无宏。** Callback 是普通 `@callback`。Plugin 作者在实现里调 `Capability.cap/3`（普通函数）。

---

### 2b. `Behavior.workspace_scoped?/0` callback（step 5.6 workspace-iso 强制）

**同一文件:** `apps/ezagent_core/lib/ezagent/behavior.ex` —— `required_caps/0` 的姊妹 callback。

按父 SPEC r4 §0d.3："`Behavior.workspace_scoped?/0` callback：可选，default `true`。Step 5.6 通过此 gate 跨 workspace dispatch。"

**签名:**

```elixir
@doc """
本 Behavior 的 action 是否要求 caller 和 target 在同一 workspace？

由 `Invocation.dispatch/1` step 5.6（workspace iso 强制）读取。
当 `true`（默认）时，dispatch 拒绝跨 workspace target 除非 caller 持有
跨 workspace-explicit cap。当 `false` 时，workspace-iso 检查跳过
（例如真正 workspace-agnostic 的 Behavior 如 `Lifecycle` 管理操作或
只读列表 action）。

默认 `true` 这样 Behavior 作者忘记声明时获得更安全行为。
"""
@callback workspace_scoped?() :: boolean()
@optional_callbacks workspace_scoped?: 0
```

PR-CC-2-v2 的 dispatch step 5.6 调 `behavior.workspace_scoped?()`（带 `function_exported?` fallback 到 `true`）。本 callback 无需 invariant test 因为它是可选的 + 更安全的默认；`:false` 调用者的行为由它们现有的集成测试验证。

---

## 3. `Kind.holds_cap?/2` callback（dispatch-step-5.5 chokepoint）

**新增 callback 的文件:** `apps/ezagent_core/lib/ezagent/kind.ex`

**签名:**

```elixir
@doc """
位于 `entity_uri` 的实体（或 principal）是否持有授权 `needed` capability 的 cap？

由 `Invocation.dispatch/1` step 5.5 调用。仅当实体 `:identity` slice 包含至少
一个匹配 `needed` 的 `%Capability{}`（按 `Capability.matches?/2`）时返
`true`。

## Default 实现

```elixir
def holds_cap?(entity_uri, %Ezagent.Capability{} = needed) do
  case Ezagent.Identity.list_caps_for(entity_uri) do
    {:ok, held_caps} when is_list(held_caps) ->
      Enum.any?(held_caps, fn held -> Ezagent.Capability.matches?(held, needed) end)

    {:error, _} ->
      false

    :error ->
      false
  end
end
```

## Override 语义

Kind 可以 override `holds_cap?/2` 加 Kind-specific 逻辑（例如 `Kind.SystemPrincipal`
override 直接咨询 `SystemPrincipal.Catalog` 不绕回 `Identity.list_caps_for/1`）。
Default 实现是契约；override 必须保持 "任一持有 cap 匹配 needed" 语义。
"""
@callback holds_cap?(entity_uri :: URI.t() | String.t(), needed :: %Ezagent.Capability{}) :: boolean()
```

`@optional_callbacks holds_cap?: 2`，这样现有 Kind（不需要 override 的）通过 `Ezagent.Kind` 的宏系统继承 default 实现。

---

## 4. `Ezagent.Capability.cap/3`（和 `cap/5`）构造帮助函数

**扩展文件:** `apps/ezagent_core/lib/ezagent/capability.ex`

**Public API:**

```elixir
@doc """
构造声明性 capability，用于 `Behavior.required_caps/0` 或经 `Identity.grant_cap/3`
发授权。

3-arity 形态填 `instance` 和 `workspace_uri` 为 `:any`（匹配任意 target /
任意 workspace）—— `required_caps/0` 声明的常见形态。5-arity 形态显式接
`instance` 和 `workspace_uri` 用于需要收窄的授权点。

`granted_by` 默认 `:plugin_declared`（哨兵表 "这是声明性需求，不是已发授权"）。
授权时调用方覆盖 `granted_by` 为实际授权人 URI，经 `cap_granted_by/4` 或显式
传字段。

## 示例

    # required_caps/0 声明
    Capability.cap(:chat, __MODULE__, :send)
    # => %Capability{kind: :chat, behavior: __MODULE__, action: :send,
    #                instance: :any, workspace_uri: :any,
    #                granted_by: :plugin_declared,
    #                granted_at: :compile_time}

    # 收窄授权
    Capability.cap(:chat, Chat, :send, session_uri, workspace_uri)

    # 授权时含显式授权人（实际授权用 Identity.grant_cap/3 而非此 helper
    # —— 此 helper 只是构造器）
"""
@spec cap(atom(), module(), atom()) :: %__MODULE__{}
def cap(kind, behavior, action) when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,
    instance: :any,
    workspace_uri: :any,
    granted_by: :plugin_declared,
    granted_at: :compile_time
  }
end

@spec cap(atom(), module(), atom(), URI.t() | :any, URI.t() | :any) :: %__MODULE__{}
def cap(kind, behavior, action, instance, workspace_uri) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,
    instance: instance,
    workspace_uri: workspace_uri,
    granted_by: :plugin_declared,
    granted_at: :compile_time
  }
end
```

**为什么本 helper 是 plugin 作者 THE 主 API:** 父 SPEC §0d.8 提到 plugin 作者 UX 是 revert 后唯一存活的 string-cap 理由。本 helper 关闭那个缺口 —— `Capability.cap(:chat, Chat, :send)` 字符数跟 `"session.chat.send"` 相同，调用点同样易读。

**`@enforce_keys` 互动:** `%Capability{}` 当前 `@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]`。Helper 填全 6 个字段。测试或迁移脚本中的直接 struct 构造仍需要全 6 个。这保留 data-ownership-v2 SPEC 的结构性 bug 防御。

---

## 5. `SystemPrincipal.Catalog` cap-shape 转换（解决父 §0d.1b）

**修改文件:** `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`

**Before（当前 main，PR-CC-1 之后）:**

```elixir
@catalog %{
  "system://bootstrap"         => ["*"],
  "system://chat-router"       => ["session.chat.send", "session.chat.system_message"],
  # ... 12 个 [String.t()] 值条目
}
```

**After（PR-CC-2-v2）:**

```elixir
alias Ezagent.Capability

@catalog %{
  "system://bootstrap"         => [Capability.cap(:any, :any, :any)],
  "system://chat-router"       => [
    Capability.cap(:chat, Ezagent.Behavior.Chat, :send),
    Capability.cap(:chat, Ezagent.Behavior.Chat, :system_message)
  ],
  # ... 每条目逐 cap struct 构造
}
```

**`@type` 更新:**

```elixir
@type cap_list :: [%Ezagent.Capability{}]
@type catalog :: %{required(String.t()) => cap_list()}
```

**Bridge `SystemPrincipal.caps/1` 更新:**

当前 bridge 接 string list，按某隐含方式 parse（按 PR-CC-1 bridge 代码大约 138/151/174 行），返通配 cap。PR-CC-2-v2 后，bridge 变 pass-through：

```elixir
def caps(principal_uri) do
  Catalog.caps_for!(principal_uri)
end
```

—— 因为 catalog 现在直接持 `%Capability{}` 值，无需转换。

**Invariant test:** `apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs`：

```elixir
test "non-bootstrap system principals do not hold wildcard caps" do
  for {uri, caps} <- Ezagent.SystemPrincipal.Catalog.entries(), uri != "system://bootstrap" do
    refute Enum.any?(caps, fn %Capability{kind: k, behavior: b, instance: i, workspace_uri: w} ->
             k == :any and b == :any and i == :any and w == :any
           end),
           "principal #{uri} 携带完全通配 cap —— 仅 system://bootstrap 可以"
  end
end
```

**映射表（14 个 principal）:**

| Principal URI | 新 cap 列表（struct shape） |
|---|---|
| `system://bootstrap` | `[Capability.cap(:any, :any, :any)]` |
| `system://boot-reconciler` | `[Capability.cap(:any, ExternalMirror, :any, :any, :any)]` |
| `system://chat-router` | `[Capability.cap(:chat, Chat, :send), Capability.cap(:chat, Chat, :system_message)]` |
| `system://chat-reply` | `[Capability.cap(:chat, Chat, :send), Capability.cap(:chat, Chat, :reaction)]` |
| `system://worker-publish` | `[Capability.cap(:session, ExternalMirrorWorker, :publish)]` |
| `system://template-materialize` | `[Capability.cap(:workspace, Workspace, :template_invoke), Capability.cap(:session, :any, :any)]` |
| `system://orchestrator-tools` | `[Capability.cap(:session, :any, :any)]` |
| `system://session-internal` | `[Capability.cap(:chat, Chat, :any), Capability.cap(:workspace, Workspace, :read)]` |
| `system://agent-internal` | `[Capability.cap(:user, Identity, :grant_cap)]` |
| `system://workspace-loader` | `[Capability.cap(:workspace, Workspace, :any)]` |
| `system://mix-task` | `[Capability.cap(:any, :any, :any)]`（operator 驱动；按部署契约同 admin User 权限）|
| `system://feishu-binding-policy` | `[Capability.cap(:user, Identity, :grant_cap)]` |
| `system://lv-anon-mount` | `[]`（按设计空 —— 见父 §4.4） |
| `system://adapter-install` | `[Capability.cap(:session, :any, :bind)]` |

**关于 "mix-task" 通配:** `system://mix-task` 合法想要 admin 级权限因为操作 mix task 的 operator 已经有 shell 权限（in-VM 信任模型 §10.5）。invariant test 豁免它和 bootstrap。

**表格精炼 —— action atom 为 PROVISIONAL**（上引）：表中的 action atom（`:template_invoke`、`:publish` 等）是 SPEC 作者对原 string（`workspace.template.*`、`session.external_mirror.publish` 等）映射的读法。PR-CC-2-v2 dispatch subagent 必须在写 catalog 条目之前对照 main 上实际 `Behavior.<Module>.actions/0` callback 验证每个 atom。如果 `:template_invoke` 在 `Behavior.Template` 上实际是 `:materialize` 等，subagent 纠正表并在 PR body 记录纠正。SPEC 提供意图（哪个 Behavior 在做工作）；subagent 提供精度（哪个 action atom 名）。

**Hypothesis-level 依赖（PR-CC-2-v2 subagent 在实施前验证）:**
- `Identity.list_caps_for/1` 返回形态 —— §3 default 实现假设 `{:ok, [%Capability{}]} | {:error, _} | :error`。如果实际形态不同，§3 default 实现需要调整。
- `Capability.matches?/2` 通配语义 —— 假设它处理两侧 `:any` + instance/workspace_uri 上的 URI 相等 + 忽略 granted_by/granted_at。如果实际实现偏离，要么修 matches?/2 要么调整 §3 default 实现。
- §8 中的 19 个 Behavior 计数 —— 来自 PR-CC-2a（已 revert）subagent 报告。PR-CC-2-v2 subagent 应该重新 grep `apps/ -lr "@behaviour Ezagent.Behavior"` 并在 brainstorm Feishu 报告实际计数。

---

## 6. §9.2 12-probe invariant —— grep 目标重新指向 struct 构造点

**新增文件:** `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs`

父 SPEC §9.2 12 个 probe 原本瞄准 cap-string 文法 parse 点。Struct 保留后，每个 probe 重新指向 struct 构造等价：

| Probe | 守护的 Pathology | Grep 目标（struct 时代） | Chokepoint allowlist（豁免路径） |
|---|---|---|---|
| P1 | A — `User.admin_caps/0` 复活 | `\bUser\.admin_caps\(` | 仅 `test/support/` |
| P2 | A — 直接 `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}` ambient 构造 | `kind:\s*:any,.*behavior:\s*:any.*instance:\s*:any.*workspace_uri:\s*:any` | `apps/ezagent_core/lib/ezagent/capability.ex`（defstruct），`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`（bootstrap + mix-task） |
| P3 | B — chokepoint 外的 `Capability.matches?/2` | `Capability\.matches\?/` | `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex`，`apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex` |
| P4 | B — Behavior 契约外的 `cap_subjects/0` callback 声明 | `def\s+cap_subjects\b` | `apps/ezagent_core/lib/ezagent/behavior.ex`（callback 声明），每个 `apps/*/lib/.../behavior/*.ex`（impl） |
| P5 | B — dispatch 外的 `CapabilityRegistry.lookup` | `CapabilityRegistry\.(lookup\|fetch\|get)` | 仅 dispatch chokepoint 路径 |
| P6 | B — Identity 域 + Kind.holds_cap?/2 default impl 外的 `Identity.list_caps_for/1` | `Identity\.list_caps_for\b` | `apps/ezagent_domain_identity/`，`apps/ezagent_core/lib/ezagent/kind.ex`（default impl） |
| P7 | B — Identity Behavior + admin LV + mix tasks 外的 `Identity.grant_cap/3` | `Identity\.grant_cap\b` | `apps/ezagent_domain_identity/lib/ezagent/behavior/identity*.ex`，`apps/ezagent_plugin_liveview/lib/.../entity_caps_live.ex`，`apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex` |
| P8 | B — chokepoint 外针对 cap 形态的 `MapSet.member?` | `MapSet\.member\?\(.*caps` | 仅 Identity 域 |
| P9 | B — 手写 cap-shape predicate | `has_admin_cap\?\|is_admin_cap\?\|admin_cap_match` | 无 —— 所有实例必须删 |
| P10 | A — dispatch ctx 直接 `caller: <entity_uri>` + `caps: <list>` ambient 模式 | `caller:.*caps:` | `apps/ezagent_core/lib/ezagent/invocation.ex`（struct 定义） |
| P11 | B — Behavior callback 外的 workspace iso check | `caller_workspace.*==.*target_workspace\|cross_workspace` | 仅 dispatch step 5.6 |
| P12 | C — 宏声明的 `required_caps`（绕过编译期 gate）| `defmacro\s+required_caps\|@__cap__` | 无 —— 所有声明必须用普通 `def` |

**测试形态:**

```elixir
defmodule EzagentCore.Invariants.CapCheckOnlyAtChokepointTest do
  use ExUnit.Case, async: true

  @probes [
    %{id: :p1, pattern: ~r/\bUser\.admin_caps\(/, allowlist: ["test/support/"]},
    %{id: :p2, pattern: ~r/kind:\s*:any,.*behavior:\s*:any.*instance:\s*:any.*workspace_uri:\s*:any/m,
      allowlist: ["apps/ezagent_core/lib/ezagent/capability.ex",
                  "apps/ezagent_core/lib/ezagent/system_principal/catalog.ex"]},
    # ... 10 个更多
  ]

  test "每个 G2 Pathology probe 找到零意外出现" do
    offenders =
      for probe <- @probes,
          path <- Path.wildcard("apps/*/lib/**/*.ex"),
          allowed_path?(path, probe.allowlist) == false,
          File.read!(path) =~ probe.pattern,
          do: "#{probe.id} @ #{path}"

    assert offenders == [],
           "G2 泄漏: #{inspect(offenders)}\n" <>
           "见 SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §6。"
  end

  defp allowed_path?(path, allowlist) do
    Enum.any?(allowlist, fn allowed -> String.contains?(path, allowed) end)
  end
end
```

**为什么 12 个 probe**（从父 §9.2 沿用）：单个 regex 抓一种模式形态；一个用不同语法的 bypass 滑过去。12 个不同 probe 覆盖已知泄漏形态；第 13 种泄漏 → 第 13 个 probe + SPEC 修订是回归锁契约。

---

## 7. G3 编译期强制（`:ezagent_plugin_check`）

**修改文件:** `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`

**现有 check:** 1–9（cap-subject 注册、action/cap-subject 等价等 —— 早于本 SPEC）。

**新 check:**

### Check 10 — `required_caps/0` callback 存在 + key 等价

对每个实现 `@behaviour Ezagent.Behavior` 的模块：

**关于 cap-exempt action 的说明:** 如果 Behavior 有故意不 cap-gate 的 action（例如纯数据检视的只读 `:status` action），通过可选 `cap_exempt_actions/0` callback 返 `[atom()]` 声明。check 然后 assert `MapSet.new(actions/0) -- cap_exempt_actions/0 == MapSet.new(required_caps_keys)`。`cap_exempt_actions/0` default 实现返 `[]`（每个 action 都需要 cap）。


```elixir
defp check_required_caps_callback(behavior_module) do
  # (a) callback 已导出
  unless function_exported?(behavior_module, :required_caps, 0) do
    raise CompileError,
      "#{inspect(behavior_module)} 必须导出 required_caps/0，按 SPEC " <>
      "docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md G2 + r4-impl §2"
  end

  # (b) keys 等于 actions/0
  declared = behavior_module.actions()
  cap_keys = Map.keys(behavior_module.required_caps())

  unless MapSet.new(declared) == MapSet.new(cap_keys) do
    raise CompileError,
      "#{inspect(behavior_module)} required_caps/0 keys 必须严格等于 actions/0；" <>
      "expected #{inspect(MapSet.new(declared))}, got #{inspect(MapSet.new(cap_keys))}"
  end
end
```

### Check 11 — `required_caps/0` 值是有效 `%Capability{}` struct

对每个 Behavior：

```elixir
defp check_required_caps_values_struct_strict(behavior_module) do
  kind_of_module = derive_kind_from_behavior(behavior_module) # 经 Kind.behaviors/0 反查

  for {action_atom, cap_value} <- behavior_module.required_caps() do
    # (a) 值是 %Capability{}
    unless match?(%Ezagent.Capability{}, cap_value) do
      raise CompileError,
        "#{inspect(behavior_module)}.required_caps/0[#{inspect(action_atom)}] 必须是 " <>
        "%Ezagent.Capability{}；got #{inspect(cap_value)}"
    end

    # (b) kind 段匹配 Behavior 父 Kind 的 type_name/0
    #     （或 :any 对跨-Kind Behavior，按 Kind.behaviors/0 multi-registration）
    expected_kinds = MapSet.new([kind_of_module])
    unless cap_value.kind in expected_kinds or cap_value.kind == :any do
      raise CompileError,
        "#{inspect(behavior_module)}.required_caps/0[#{inspect(action_atom)}] kind 轴 " <>
        "必须匹配父 Kind 的 type_name/0 (#{inspect(kind_of_module)}) 或 :any；" <>
        "got #{inspect(cap_value.kind)}"
    end

    # (c) behavior 轴匹配 Behavior 模块引用（或 :any 用于 catch-all）
    unless cap_value.behavior == behavior_module or cap_value.behavior == :any do
      raise CompileError, ...
    end

    # (d) action 轴匹配 action atom（或 :any 用于 catch-all）
    unless cap_value.action == action_atom or cap_value.action == :any do
      raise CompileError, ...
    end
  end
end
```

父 SPEC r3-FINAL MED-1 修复的三键 dedupe 保留 —— 同一 Behavior 注册到多个 Kind 时，按 `{kind, behavior, action}` 三键去重，而非仅 `behavior`。

### 为什么无宏

Plugin 作者写普通 `%{action_atom => %Capability{}}` map。编译期 gate 是 Mix compiler pass，不是 `after_compile` hook 或 `use` 宏。按父 SPEC G3 + memory `feedback_let_it_crash_no_workarounds`。

---

## 8. PR-CC-2-v2 file:line manifest

PR-CC-2-v2 实施 subagent（主 agent 在本 SPEC 合并后 dispatch）必须 touch 以下文件。数量近似；subagent brainstorm 后第一条 Feishu 应该重新确认：

### 核心框架（~10 文件）
- `apps/ezagent_core/lib/ezagent/behavior.ex` —— 加 `required_caps/0` callback（§2）
- `apps/ezagent_core/lib/ezagent/kind.ex` —— 加 `holds_cap?/2` callback + default 实现（§3）
- `apps/ezagent_core/lib/ezagent/capability.ex` —— 加 `cap/3` + `cap/5` helper（§4）
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` —— 切 dispatch step 5.5 从基于 `CapabilityRegistry` 的 check 到 `behavior.required_caps()[action]` + `Kind.holds_cap?/2`
- `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` —— 转换 14 条目从 `[String.t()]` 到 `[%Capability{}]`（§5）
- `apps/ezagent_core/lib/ezagent/system_principal.ex` —— `caps/1` bridge 变 pass-through
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` —— 加 check 10 + 11（§7）
- `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs`（新）—— 12-probe invariant（§6）
- `apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs`（新）—— catalog wildcard gate（§5）
- `apps/ezagent_core/test/invariants/dispatch_uses_required_caps_struct_test.exs`（新）—— assert dispatch step 5.5 读 `required_caps/0` + 调 `Kind.holds_cap?/2`

### Behavior 注解（~19 文件）
每个实现 `@behaviour Ezagent.Behavior` 的模块加 `required_caps/0` 实现。同 PR-CC-2a（已 revert）列表 —— 用 struct 值重新加：

`Lifecycle`、`Notifications`、`Presence`、`Routing`、`Sandbox`、`Chat`、`Template`、`Publisher.SessionImpl`、`ExternalMirror`、`ExternalMirrorWorker`、`Identity`、`IdentityAdmin`、`ApiKeys`、`Pty`、`Workspace`、`Echo`、`CurlAgent`、`NpAgent`、`FeishuAllow`。

### 散落 cap-check 删除（Pathology B 清扫）
以下每个点当前在 chokepoint 外做 cap-shape 检查。每个**删除**（或重构调 `Kind.holds_cap?/2`）：

- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` —— `check_grant_authorized/2`（200+ LOC）；data-ownership 规则移到 `required_caps/0` 声明 + `data_owner/1` callback（data-ownership-v2 SPEC 不变）。
- `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` —— external-mirror-audit 的 facade Gates 1, 2, 3（~200 LOC）；cap 部分移到 `required_caps/0`；nonce + workspace-iso 部分保留（跟 cap-shape 正交）。
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/notification_subscriptions_*.ex` —— `has_admin_cap?/1` 和类似；替换为 `Kind.holds_cap?(current_entity_uri, Capability.cap(...))`。
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/member_panel.ex` —— `cc_agent_uri?/1` workspace-membership 行内 check；替换为 `Workspace.is_member?/2`（已存在，post-PR #344）。
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex` —— `Identity.list_caps_for(bound_uri)` 后接手写成员检查；替换为 `Kind.holds_cap?/2`。
- 各种 `_live` 模块 —— `MapSet.member?` 用于 cap 驱动 UI gating；替换为 chokepoint 或（只读显示）保留 `Identity.list_caps_for/1`（P6 allowlist）。

### 测试更新（~30 文件）
显式 field map 构造 `%Capability{}` 的测试保留（声明性测试 fixture）。调用已删散落 cap-check helper（如 `has_admin_cap?/1`）的测试更新为 `Kind.holds_cap?/2`。PR-CC-2-v2 subagent 的 mix test 运行应该显示 baseline (657/9) ± 新测试，无净新失败。

---

## 9. PR-CC-2-v2 dispatch-subagent prompt skeleton

主 agent dispatch PR-CC-2-v2 时应使用以下 prompt skeleton（dispatch 时填具体 commit hash + worktree 路径）：

```
按 SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md 实施 PR-CC-2-v2。

Repo: ezagent42/ezagent。Main 在 <commit>。从 main 切支到隔离 worktree。

REQUIRED SKILLS: Skill: ezagent-developer + Skill: elixir-phoenix-helper（按 feedback_subagent_must_load_project_skills 不可商量）。

Feishu chat_id 逐字: oc_d9b47511b085e9d5b66c4595b3ef9bb9。

Scope（SPEC §2–§7）:
1. 加 Behavior.required_caps/0 callback（§2）
2. 加 Kind.holds_cap?/2 callback + default 实现（§3）
3. 加 Capability.cap/3 + cap/5 helper（§4）
4. 转换 SystemPrincipal.Catalog 14 条目到 struct shape（§5）
5. 切 dispatch step 5.5 到 required_caps/0 + holds_cap?/2
6. 加 3 个新 invariant test（§5 wildcard gate + §6 12-probe + §7 dispatch-uses-required-caps）
7. 扩展 :ezagent_plugin_check 加 check 10 + 11（§7）
8. 清扫 ~19 个 Behavior 模块加 required_caps/0 实现
9. 删 §8 列表的散落 cap-check 点
10. 无 shim、无 dual-path、无迁移窗口。PR 是一次性协调改动（feedback_let_it_crash_no_workarounds）。

DO NOT:
- Touch caps_json DB 列（父 SPEC §0d.5 —— 无迁移）。
- 加宏（父 G3 + r4-impl §7 —— 仅普通函数）。
- 跑 destructive migration 对 live dev DB。
- 在 catalog bootstrap + mix-task 条目之外留任何 %Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any} 构造（§5 wildcard gate）。

Codex round 1 经 codex:codex-rescue 用逐字 no-mix 子句:
  "Do NOT run mix test, mix compile, mix deps.get, or any mix command. Static analysis only — read files and reason from source."

如 codex 529，回退到 self-static-review（12 个 adversarial 问题带 file:line 证据）。

Admin-merge: gh pr merge <N> --admin --squash --delete-branch。

通信标准（按前面有效的 PR-CC-1 / PR-CC-2a / PR-CC-2b dispatch 模式）：
- 按 `feedback_progress_percentage_in_replies` 每个 Feishu 消息前缀 [N% — PR-CC-2-v2]。
- 按 `feedback_explicit_stop_signal_after_feishu` 每个 Feishu 消息以显式 `继续` / `停` / `等你定` 结尾。
- 按 `feedback_feishu_notify_before_remote_ops` 在 `git push` / `gh pr create` / `gh pr merge --admin` 之前发 1-2 句 Feishu 头通知。
- 按 `feedback_no_paternalistic_stop_suggestions` 无家长式 "要停吗？" —— Allen 明确指示 "做决定，别烦我"。
- 按 `feedback_wake_but_dont_stop` 默认 wake-but-don't-stop：通知决策点 + 用推荐方案推进。
```

---

## 10. 验收准则

PR-CC-2-v2 仅当以下全部成立时合并：

- (a) `mix compile` 干净。
- (b) `:ezagent_plugin_check` check 10 + 11 对 main 上每个 Behavior 通过。
- (c) 新 invariant test 通过：
  - `cap_check_only_at_chokepoint_test.exs` —— 12 probe 返零 offender。
  - `no_wildcard_system_principals_test.exs` —— 无非 bootstrap principal 持通配 cap。
  - `dispatch_uses_required_caps_struct_test.exs` —— `Invocation.dispatch/1` 源代码引用 `required_caps/0` + `holds_cap?/2`。
- (d) baseline 失败不变：`ezagent_core` 657/9 ± 1（允许 incidental flaky clear）；`domain_instance_message` / `domain_external_mirror` / `domain_identity` / `domain_workspace` baseline 保留。
- (e) 无代码级对已删散落 cap-check helper 的新引用（§8 Pathology B 清扫完成）。
- (f) PR body 显式列 14 个 catalog 条目的 before-string → after-struct 转换表，标记跟原 string 语义的偏离。
- (g) Codex round 1 返干净通过或带 finding（subagent 在 r2 处理或 self-static-review 文档化，按 r3-FINAL codex 历史模式）。

---

## 11. 回滚计划

如 PR-CC-2-v2 合并后出现回归（例如某 Behavior `required_caps/0` 错误声明拒绝合法 dispatch）：

1. **先 —— 经 telemetry 浮现。** 新 dispatch step 5.5 应 emit `[:ezagent, :authz, :denied]` 带 `%{caller, needed, behavior_module}` 元数据。admin-authz-audit LV 实时显示。Operator 从 telemetry 找到坏声明。

2. **窄 hotfix。** 大部分回归是某 Behavior 缺 action atom 或 `required_caps/0` 声明过窄。1-LOC PR 修声明；广泛迁移保留。

3. **灾难 —— 完全 revert。** 如 dispatch step 5.5 切本身坏（例如 `Kind.holds_cap?/2` default impl 读 slice 形态错），`git revert` PR-CC-2-v2。PR diff 足够机械以单命令 revert。后续 forward 尝试修根因。

无需 DB 回滚（无 schema migration）。

---

## 12. 范围外（futures）

记在此处使 SPEC scope 不歧义；每条是未来 SPEC 的工作：

- **密码学 cap 验证。** 父 SPEC §0d.6 草拟 additive 字段集（`signature`、`nonce`、`issuer_pubkey_fingerprint`）。未来 SPEC 拥有完整威胁模型。
- **Cap 出处审计表。** 父 §0d.1 保留 `granted_by` / `granted_at` 在 struct；用于 grant-chain 重建的单独审计表是未来工作。
- **`Cap.Parser` 删除。** 字符串 parser 仍存在用于 legacy operator-CLI 输入路径（`mix ezagent.user.grant_cap --cap "session.chat.send"` 等）。是否删它是单独的 UX-level 决定；parser 在 PR-CC-2-v2 后不在 chokepoint 路径中。
- **`Identity.grant_cap/3` 人体工程。** 当前接 `%Capability{}`；可能加 keyword-arg 变体用于操作员便利。未来打磨 PR。
- **Workspace-suffix 文法。** 父 r2 的 `;ws=<workspace_uri>` instance-suffix 字符串 cap 语法永久撤销 —— struct 的 `workspace_uri` 字段原生处理。
- **`revoke_cap` CAS 原子性。** 父 SPEC r3 §5.3 step 8.5 引入 cap-snapshot CAS 契约（`Identity.cas_update_caps/2` 经 `:ets.select_replace/2`）以关闭并发 `grant_cap` 和 `revoke_cap` 调用间的 TOCTOU。r4 保持那个设计不变（跟 cap shape 正交 —— CAS 保护 revision 原子性，不是字段形态）。PR-CC-2-v2 不动它；如果未来压力测试浮现 race，修复作单独 PR。

---

## 13. Open questions

草稿时无。本 SPEC 的 Codex r1 review 会浮现任何问题。
