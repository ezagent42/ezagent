# SPEC — Caps cleanup v1 r4 implementation (PR-CC-2-v2)

**Status:** r1 (draft, awaiting codex review). 2026-05-25.
**Tier:** `apps/ezagent_core/` framework callbacks + sweep across every Behavior.
**Trigger:** parent SPEC `2026-05-25-caps-cleanup-v1.md` §0d.7 action item #2 — blocking dependency for PR-CC-2-v2 implementation. Resolves the SPEC-vs-code drift codex flagged in PR #350 r1 (HIGH-1, HIGH-2, MED-1).
**Companion:** `2026-05-25-caps-cleanup-v1-r4-impl.zh_cn.md`.

**Parent:**
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` r4 — the parent SPEC that this implementation SPEC pins down. r4 §0d documents the struct-kept decision (post-revert of PR-CC-2a/2b); §0d.7 action item #2 marks this sibling SPEC as ⛔ BLOCKING for PR-CC-2-v2.

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path, no migration window. The PR is one coordinated change.
- `feedback_completion_requires_invariant_test` — every deliverable has an invariant test. The PR's merge gate is the 12-probe §9.2 invariant + the new catalog cap-shape gate + the G3 compile-time check.
- `feedback_north_star_plugin_isolation` — every API surface added here must keep plugin authors out of `apps/ezagent_core/`. Behavior author writes ONE `required_caps/0` map + zero macros.
- `feedback_subagent_must_load_project_skills` — the PR-CC-2-v2 subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_companion_no_mix` — codex review on PR-CC-2-v2 includes the verbatim "no mix" clause.

---

## 1. Why this SPEC exists separately

The parent SPEC `2026-05-25-caps-cleanup-v1.md` r4 had to amend post-revert without losing the historical context (r1–r3 string-cap design + codex review history). The body sections §5–§9 were preserved as historical record with inline `> 🔄 r4 amend:` markers redirecting readers to §0d.

That preservation strategy created a gap: §0d is **comprehensive on the WHAT** (struct stays, structural goals survive, catalog gap exists) but **terse on the HOW** (no file:line, no signature precision, no test code). When the codex round 1 review of PR #350 (r4 SPEC amendment) ran, MED-1 flagged exactly this: "PR-CC-2-v2 is under-specified — §0d says keep `CapabilityRegistry`, `cap_subjects/0`, and struct caps, but §9.2 / §9.3 still define tests that delete registry/callback APIs and assert 'must be cap strings.'"

This SPEC closes that gap by writing the WHEN/WHERE/HOW of PR-CC-2-v2 explicitly. It does not re-litigate the WHY (parent §0d.2 owns that) or the WHAT (parent §0d.1 / §0d.3 / §0d.4 / §0d.5 own that). It pins down:

1. The exact `Behavior.required_caps/0` callback signature (§2)
2. The exact `Kind.holds_cap?/2` callback contract + default impl (§3)
3. The exact `Capability.cap/N` constructor helper for plugin-author UX (§4)
4. The exact `SystemPrincipal.Catalog` cap-shape conversion (§5; resolves §0d.1b's blocking gate)
5. The exact §9.2 12-probe invariant grep targets, re-pointed to struct construction sites (§6)
6. The exact §9.3 G3 compile-time check 10/11 struct-shape predicates (§7)
7. The PR-CC-2-v2 file:line manifest (§8) + dispatch-subagent prompt skeleton (§9)
8. The acceptance criteria (§10) + rollback plan (§11)

---

## 2. `Behavior.required_caps/0` callback (THE primary plugin-author API)

**File to add the callback to:** `apps/ezagent_core/lib/ezagent/behavior.ex`

**Signature:**

```elixir
@doc """
Map from action atom to the required capability. Read by
`Invocation.dispatch/1` step 5.5 to gate the action behind cap check.

Every action returned by `actions/0` MUST have an entry here. Compile-time
enforced by `:ezagent_plugin_check` check 10 (§7 of this SPEC).

## Plugin-author UX

The recommended construction site uses the `Ezagent.Capability.cap/3`
helper (§4 of this SPEC):

    @impl true
    def required_caps do
      %{
        send:    Capability.cap(:chat, __MODULE__, :send),
        receive: Capability.cap(:chat, __MODULE__, :receive),
        join:    Capability.cap(:chat, __MODULE__, :join)
      }
    end

Direct struct construction is also valid but verbose:

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

The helper's `:plugin_declared` / `:compile_time` sentinel values for
`granted_by` / `granted_at` are documented as the "this cap is a
declarative requirement, not an issued grant" convention.
"""
@callback required_caps() :: %{required(action :: atom()) => %Ezagent.Capability{}}
```

**Optional behavior:** Behaviors with `actions/0 == []` (purely receiving Behaviors like `Behavior.Echo.handle_kind_message/3`-only) MAY return `%{}` — the compile-time check accepts an empty map when `actions/0` is also empty.

**No macros.** The callback is a plain `@callback`. Plugin authors call `Capability.cap/3` (a regular function) inside the implementation.

---

### 2b. `Behavior.workspace_scoped?/0` callback (workspace-iso enforcement at step 5.6)

**Same file:** `apps/ezagent_core/lib/ezagent/behavior.ex` — sibling callback to `required_caps/0`.

Per parent SPEC r4 §0d.3: "`Behavior.workspace_scoped?/0` callback: optional, default `true`. Step 5.6 gates cross-workspace dispatches via this."

**Signature:**

```elixir
@doc """
Does this Behavior's actions require the caller and target to be in the
same workspace?

Read by `Invocation.dispatch/1` step 5.6 (workspace iso enforcement).
When `true` (the default), dispatch denies cross-workspace targets
unless the caller holds a cross-workspace-explicit cap. When `false`,
the workspace-iso check is skipped (e.g., for genuinely workspace-
agnostic Behaviors like `Lifecycle` admin operations or read-only
listing actions).

Defaults to `true` so a Behavior author who forgets to declare gets
the safer behavior.
"""
@callback workspace_scoped?() :: boolean()
@optional_callbacks workspace_scoped?: 0
```

The PR-CC-2-v2 dispatch step 5.6 calls `behavior.workspace_scoped?()` (with `function_exported?` fallback to `true`). No invariant test is required for this callback since it's optional + safer-default; the behavior of `:false` callers is verified by their existing integration tests.

---

## 3. `Kind.holds_cap?/2` callback (THE dispatch-step-5.5 chokepoint)

**File to add the callback to:** `apps/ezagent_core/lib/ezagent/kind.ex`

**Signature:**

```elixir
@doc """
Does the entity (or principal) at `entity_uri` hold a cap that authorizes
the `needed` capability?

Called by `Invocation.dispatch/1` step 5.5. Returns `true` only when the
entity's `:identity` slice contains at least one `%Capability{}` cap that
matches `needed` per `Capability.matches?/2`.

## Default implementation

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

## Override semantics

Kinds may override `holds_cap?/2` to add Kind-specific logic (e.g., a
`Kind.SystemPrincipal` override that consults `SystemPrincipal.Catalog`
directly without round-tripping through `Identity.list_caps_for/1`). The
default impl is the contract; overrides MUST preserve the "any held cap
matches needed" semantic.
"""
@callback holds_cap?(entity_uri :: URI.t() | String.t(), needed :: %Ezagent.Capability{}) :: boolean()
```

`@optional_callbacks holds_cap?: 2` so existing Kinds (those that don't need to override) inherit the default impl via the macro system in `Ezagent.Kind`.

---

## 4. `Ezagent.Capability.cap/3` (and `cap/5`) constructor helper

**File to extend:** `apps/ezagent_core/lib/ezagent/capability.ex`

**Public API:**

```elixir
@doc """
Construct a declarative capability for use in `Behavior.required_caps/0`
or for issuing a grant via `Identity.grant_cap/3`.

The 3-arity form fills `instance` and `workspace_uri` with `:any` (matches
any target / any workspace) — the common shape for `required_caps/0`
declarations. The 5-arity form takes explicit `instance` and
`workspace_uri` for grant sites that need narrowing.

`granted_by` defaults to `:plugin_declared` (sentinel meaning "this is a
declarative requirement, not an issued grant"). At grant time, callers
override `granted_by` to the actual granter URI via `cap_granted_by/4`
or by passing the field explicitly.

## Examples

    # required_caps/0 declaration
    Capability.cap(:chat, __MODULE__, :send)
    # => %Capability{kind: :chat, behavior: __MODULE__, action: :send,
    #                instance: :any, workspace_uri: :any,
    #                granted_by: :plugin_declared,
    #                granted_at: :compile_time}

    # narrow grant
    Capability.cap(:chat, Chat, :send, session_uri, workspace_uri)

    # grant-time with explicit granter (use Identity.grant_cap/3 instead
    # of this helper for actual grants — this is just the constructor)
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

**Why this helper is THE plugin-author API:** parent SPEC §0d.8 noted plugin-author UX is the one reason for string-caps that survives the revert. This helper closes that gap — `Capability.cap(:chat, Chat, :send)` is the same character count as `"session.chat.send"` and the call site is identically readable.

**`@enforce_keys` interaction:** `%Capability{}` currently `@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]`. The helper fills all six. Direct struct construction in tests or migration scripts still requires all six. This preserves the structural-bug-prevention from data-ownership-v2 SPEC.

---

## 5. `SystemPrincipal.Catalog` cap-shape conversion (resolves parent §0d.1b)

**File to modify:** `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`

**Before (current main, post-PR-CC-1):**

```elixir
@catalog %{
  "system://bootstrap"         => ["*"],
  "system://chat-router"       => ["session.chat.send", "session.chat.system_message"],
  # ... 12 more entries with [String.t()] values
}
```

**After (PR-CC-2-v2):**

```elixir
alias Ezagent.Capability

@catalog %{
  "system://bootstrap"         => [Capability.cap(:any, :any, :any)],
  "system://chat-router"       => [
    Capability.cap(:chat, Ezagent.Behavior.Chat, :send),
    Capability.cap(:chat, Ezagent.Behavior.Chat, :system_message)
  ],
  # ... per-entry per-cap struct construction
}
```

**`@type` update:**

```elixir
@type cap_list :: [%Ezagent.Capability{}]
@type catalog :: %{required(String.t()) => cap_list()}
```

**Bridge `SystemPrincipal.caps/1` update:**

Currently the bridge takes the string list, parses some implied way (per PR-CC-1's bridge code lines ~138/151/174), and returns wildcard caps. After PR-CC-2-v2, the bridge becomes a pass-through:

```elixir
def caps(principal_uri) do
  Catalog.caps_for!(principal_uri)
end
```

— since the catalog now holds `%Capability{}` values directly, no conversion needed.

**Invariant test:** `apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs`:

```elixir
test "non-bootstrap system principals do not hold wildcard caps" do
  for {uri, caps} <- Ezagent.SystemPrincipal.Catalog.entries(), uri != "system://bootstrap" do
    refute Enum.any?(caps, fn %Capability{kind: k, behavior: b, instance: i, workspace_uri: w} ->
             k == :any and b == :any and i == :any and w == :any
           end),
           "principal #{uri} carries a full wildcard cap — only system://bootstrap may"
  end
end
```

**Mapping table (the 14 principals):**

| Principal URI | New cap list (struct shape) |
|---|---|
| `system://bootstrap` | `[Capability.cap(:any, :any, :any)]` |
| `system://boot-reconciler` | `[Capability.cap(:any, ExternalMirror, :any, :any, :any)]` (session.external_mirror.* → kind=:session matches via :any kind segment of Behavior; refine if Behavior naming clarifies the kind axis) |
| `system://chat-router` | `[Capability.cap(:chat, Chat, :send), Capability.cap(:chat, Chat, :system_message)]` |
| `system://chat-reply` | `[Capability.cap(:chat, Chat, :send), Capability.cap(:chat, Chat, :reaction)]` |
| `system://worker-publish` | `[Capability.cap(:session, ExternalMirrorWorker, :publish)]` |
| `system://template-materialize` | `[Capability.cap(:workspace, Workspace, :template_invoke), Capability.cap(:session, :any, :any)]` |
| `system://orchestrator-tools` | `[Capability.cap(:session, :any, :any)]` |
| `system://session-internal` | `[Capability.cap(:chat, Chat, :any), Capability.cap(:workspace, Workspace, :read)]` |
| `system://agent-internal` | `[Capability.cap(:user, Identity, :grant_cap)]` |
| `system://workspace-loader` | `[Capability.cap(:workspace, Workspace, :any)]` |
| `system://mix-task` | `[Capability.cap(:any, :any, :any)]` (operator-driven; same authority as admin User by deployment contract) |
| `system://feishu-binding-policy` | `[Capability.cap(:user, Identity, :grant_cap)]` |
| `system://lv-anon-mount` | `[]` (empty by design — see parent §4.4) |
| `system://adapter-install` | `[Capability.cap(:session, :any, :bind)]` |

**Note on "mix-task" wildcard:** `system://mix-task` legitimately wants admin-level authority because operators driving mix tasks already have shell access (in-VM trust model §10.5). The invariant test exempts it AND bootstrap.

**Refinement for table — action atoms are PROVISIONAL** (cited above): the action atoms (`:template_invoke`, `:publish`, etc.) in this table are the SPEC author's reading of what the original strings (`workspace.template.*`, `session.external_mirror.publish`, etc.) likely map to. The PR-CC-2-v2 dispatch subagent MUST verify each atom against the actual `Behavior.<Module>.actions/0` callback on main BEFORE writing the catalog entry. If `:template_invoke` is actually `:materialize` on `Behavior.Template`, etc., the subagent corrects the table and records the correction in the PR body. The SPEC provides INTENT (which Behavior is doing the work); the subagent provides PRECISION (which action atom name).

**Hypothesis-level dependencies (PR-CC-2-v2 subagent verifies before implementing):**
- `Identity.list_caps_for/1` return shape — assumed `{:ok, [%Capability{}]} | {:error, _} | :error` in §3 default impl. If actual shape differs, §3's default impl needs adjustment.
- `Capability.matches?/2` wildcard semantics — assumed it handles `:any` on both sides + URI equality on instance/workspace_uri + ignores granted_by/granted_at. If actual implementation diverges, either fix matches?/2 OR adjust §3's default impl.
- The 19 Behavior count in §8 — derived from PR-CC-2a (reverted) subagent's report. The PR-CC-2-v2 subagent should re-grep `apps/ -lr "@behaviour Ezagent.Behavior"` and report the actual count in the brainstorm Feishu.

---

## 6. §9.2 12-probe invariant — grep targets re-pointed to struct construction sites

**File to add:** `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs`

The parent SPEC's §9.2 12 probes were originally targeted at cap-string grammar parse sites. With struct kept, each probe re-points to its struct-construction equivalent:

| Probe | Pathology guarded | Grep target (struct era) | Chokepoint allowlist (paths exempt) |
|---|---|---|---|
| P1 | A — `User.admin_caps/0` revival | `\bUser\.admin_caps\(` | `test/support/` only |
| P2 | A — direct `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}` ambient construction | `kind:\s*:any,.*behavior:\s*:any.*instance:\s*:any.*workspace_uri:\s*:any` | `apps/ezagent_core/lib/ezagent/capability.ex` (defstruct), `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` (bootstrap + mix-task) |
| P3 | B — `Capability.matches?/2` outside chokepoint | `Capability\.matches\?/` | `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex`, `apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex` |
| P4 | B — `cap_subjects/0` callback declaration outside Behavior contract | `def\s+cap_subjects\b` | `apps/ezagent_core/lib/ezagent/behavior.ex` (callback decl), every `apps/*/lib/.../behavior/*.ex` (impls) |
| P5 | B — `CapabilityRegistry.lookup` outside dispatch | `CapabilityRegistry\.(lookup\|fetch\|get)` | dispatch chokepoint paths only |
| P6 | B — `Identity.list_caps_for/1` outside Identity domain + Kind.holds_cap?/2 default impl | `Identity\.list_caps_for\b` | `apps/ezagent_domain_identity/`, `apps/ezagent_core/lib/ezagent/kind.ex` (default impl) |
| P7 | B — `Identity.grant_cap/3` outside Identity Behavior + admin LV + mix tasks | `Identity\.grant_cap\b` | `apps/ezagent_domain_identity/lib/ezagent/behavior/identity*.ex`, `apps/ezagent_plugin_liveview/lib/.../entity_caps_live.ex`, `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex` |
| P8 | B — `MapSet.member?` against cap shape outside chokepoint | `MapSet\.member\?\(.*caps` | Identity domain only |
| P9 | B — hand-written cap-shape predicates | `has_admin_cap\?\|is_admin_cap\?\|admin_cap_match` | none — all instances must be deleted |
| P10 | A — direct `caller: <entity_uri>` + `caps: <list>` ambient pattern in dispatch ctx | `caller:.*caps:` | `apps/ezagent_core/lib/ezagent/invocation.ex` (struct def) |
| P11 | B — workspace iso check outside Behavior callback | `caller_workspace.*==.*target_workspace\|cross_workspace` | dispatch step 5.6 only |
| P12 | C — macro-declared `required_caps` (defeats compile-time gate) | `defmacro\s+required_caps\|@__cap__` | none — all declarations must be plain `def` |

**Test shape:**

```elixir
defmodule EzagentCore.Invariants.CapCheckOnlyAtChokepointTest do
  use ExUnit.Case, async: true

  @probes [
    %{id: :p1, pattern: ~r/\bUser\.admin_caps\(/, allowlist: ["test/support/"]},
    %{id: :p2, pattern: ~r/kind:\s*:any,.*behavior:\s*:any.*instance:\s*:any.*workspace_uri:\s*:any/m,
      allowlist: ["apps/ezagent_core/lib/ezagent/capability.ex",
                  "apps/ezagent_core/lib/ezagent/system_principal/catalog.ex"]},
    # ... 10 more
  ]

  test "every G2 Pathology probe finds zero unexpected occurrences" do
    offenders =
      for probe <- @probes,
          path <- Path.wildcard("apps/*/lib/**/*.ex"),
          allowed_path?(path, probe.allowlist) == false,
          File.read!(path) =~ probe.pattern,
          do: "#{probe.id} @ #{path}"

    assert offenders == [],
           "G2 leakage: #{inspect(offenders)}\n" <>
           "See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §6."
  end

  defp allowed_path?(path, allowlist) do
    Enum.any?(allowlist, fn allowed -> String.contains?(path, allowed) end)
  end
end
```

**Why 12 probes** (carried over from parent §9.2): a single regex catches one pattern shape; a savvy bypass with different syntax slips through. 12 distinct probes cover the known leak shapes; a 13th leak → 13th probe + SPEC amendment is the regression-lock contract.

---

## 7. G3 compile-time enforcement (`:ezagent_plugin_check`)

**File to modify:** `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`

**Existing checks:** 1–9 (cap-subject registration, action/cap-subject parity, etc. — predate this SPEC).

**New checks:**

### Check 10 — `required_caps/0` callback presence + key parity

For every module implementing `@behaviour Ezagent.Behavior`:

**Note on cap-exempt actions:** if a Behavior has actions that are intentionally NOT cap-gated (e.g., a read-only `:status` action that's pure data inspection), declare them via an optional `cap_exempt_actions/0` callback returning `[atom()]`. The check then asserts `MapSet.new(actions/0) -- cap_exempt_actions/0 == MapSet.new(required_caps_keys)`. Default impl of `cap_exempt_actions/0` returns `[]` (every action needs a cap).


```elixir
defp check_required_caps_callback(behavior_module) do
  # (a) callback exported
  unless function_exported?(behavior_module, :required_caps, 0) do
    raise CompileError,
      "#{inspect(behavior_module)} must export required_caps/0 per SPEC " <>
      "docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md G2 + r4-impl §2"
  end

  # (b) keys equal actions/0
  declared = behavior_module.actions()
  cap_keys = Map.keys(behavior_module.required_caps())

  unless MapSet.new(declared) == MapSet.new(cap_keys) do
    raise CompileError,
      "#{inspect(behavior_module)} required_caps/0 keys must equal actions/0 exactly; " <>
      "expected #{inspect(MapSet.new(declared))}, got #{inspect(MapSet.new(cap_keys))}"
  end
end
```

### Check 11 — `required_caps/0` values are valid `%Capability{}` structs

For every Behavior:

```elixir
defp check_required_caps_values_struct_strict(behavior_module) do
  kind_of_module = derive_kind_from_behavior(behavior_module) # via Kind.behaviors/0 inversion

  for {action_atom, cap_value} <- behavior_module.required_caps() do
    # (a) value is %Capability{}
    unless match?(%Ezagent.Capability{}, cap_value) do
      raise CompileError,
        "#{inspect(behavior_module)}.required_caps/0[#{inspect(action_atom)}] must be " <>
        "a %Ezagent.Capability{}; got #{inspect(cap_value)}"
    end

    # (b) kind segment matches the Behavior's parent Kind's type_name/0
    #     (or :any for cross-Kind Behaviors per Kind.behaviors/0 multi-registration).
    #     Example — Behavior.Routing is on Workspace+Session+System; its
    #     required_caps/0 declares `kind: :any` per action because the
    #     single declaration must match all three host Kinds. The dispatch
    #     step 5.5 wildcard-substitution (parent SPEC §5.3 design) fills
    #     in the actual target Kind's type_name/0 at runtime before
    #     calling Kind.holds_cap?/2.
    expected_kinds = MapSet.new([kind_of_module])
    unless cap_value.kind in expected_kinds or cap_value.kind == :any do
      raise CompileError,
        "#{inspect(behavior_module)}.required_caps/0[#{inspect(action_atom)}] kind axis " <>
        "must match parent Kind's type_name/0 (#{inspect(kind_of_module)}) or :any; " <>
        "got #{inspect(cap_value.kind)}"
    end

    # (c) behavior axis matches the Behavior module ref (or :any for catch-all)
    unless cap_value.behavior == behavior_module or cap_value.behavior == :any do
      raise CompileError, ...
    end

    # (d) action axis matches the action atom (or :any for catch-all)
    unless cap_value.action == action_atom or cap_value.action == :any do
      raise CompileError, ...
    end
  end
end
```

The triple-keyed dedupe from parent SPEC r3-FINAL MED-1 fix stays — when the same Behavior is registered against multiple Kinds, dedupe via `{kind, behavior, action}` triple key, not just `behavior`.

### Why no macros

Plugin authors write a plain `%{action_atom => %Capability{}}` map. The compile-time gate is a Mix compiler pass, not an `after_compile` hook or a `use` macro. Per parent SPEC G3 + memory `feedback_let_it_crash_no_workarounds`.

---

## 8. PR-CC-2-v2 file:line manifest

The PR-CC-2-v2 implementation subagent (dispatched by main-agent after this SPEC merges) MUST touch the following files. Counts are approximate; the subagent's first Feishu after brainstorm SHOULD re-confirm:

### Core framework (~10 files)
- `apps/ezagent_core/lib/ezagent/behavior.ex` — add `required_caps/0` callback (§2)
- `apps/ezagent_core/lib/ezagent/kind.ex` — add `holds_cap?/2` callback + default impl (§3)
- `apps/ezagent_core/lib/ezagent/capability.ex` — add `cap/3` + `cap/5` helpers (§4)
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — switch dispatch step 5.5 from `CapabilityRegistry`-based check to `behavior.required_caps()[action]` + `Kind.holds_cap?/2`
- `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` — convert 14 entries from `[String.t()]` to `[%Capability{}]` (§5)
- `apps/ezagent_core/lib/ezagent/system_principal.ex` — `caps/1` bridge becomes a pass-through
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — add checks 10 + 11 (§7)
- `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs` (NEW) — 12-probe invariant (§6)
- `apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs` (NEW) — catalog wildcard gate (§5)
- `apps/ezagent_core/test/invariants/dispatch_uses_required_caps_struct_test.exs` (NEW) — assert dispatch step 5.5 reads `required_caps/0` + calls `Kind.holds_cap?/2`

### Behavior annotations (~19 files)
Every module implementing `@behaviour Ezagent.Behavior` gets a `required_caps/0` impl. Same list as PR-CC-2a (reverted) — re-add with struct values:

`Lifecycle`, `Notifications`, `Presence`, `Routing`, `Sandbox`, `Chat`, `Template`, `Publisher.SessionImpl`, `ExternalMirror`, `ExternalMirrorWorker`, `Identity`, `IdentityAdmin`, `ApiKeys`, `Pty`, `Workspace`, `Echo`, `CurlAgent`, `NpAgent`, `FeishuAllow`.

### Scattered cap-check deletion (Pathology B sweep)
Each of the following sites currently performs cap-shape inspection outside the chokepoint. Each gets DELETED (or refactored to call `Kind.holds_cap?/2`):

- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` — `check_grant_authorized/2` (200+ LOC); the data-ownership rule moves to `required_caps/0` declarations + `data_owner/1` callback (unchanged from data-ownership-v2 SPEC).
- `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` — facade Gates 1, 2, 3 from external-mirror-audit (~200 LOC); cap parts move to `required_caps/0`; nonce + workspace-iso parts STAY (orthogonal to cap-shape).
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/notification_subscriptions_*.ex` — `has_admin_cap?/1` and similar; replace with `Kind.holds_cap?(current_entity_uri, Capability.cap(...))`.
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/member_panel.ex` — `cc_agent_uri?/1` workspace-membership inline check; replace with `Workspace.is_member?/2` (already exists post-PR #344).
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex` — `Identity.list_caps_for(bound_uri)` followed by hand-written membership; replace with `Kind.holds_cap?/2`.
- Various `_live` modules — `MapSet.member?` checks for cap-driven UI gating; replace with the chokepoint OR (for read-only display) keep `Identity.list_caps_for/1` (allowlisted in P6).

### Test updates (~30 files)
Tests that constructed `%Capability{}` with explicit field maps STAY (they're declarative test fixtures). Tests that called the deleted scattered cap-check helpers (e.g., `has_admin_cap?/1`) get updated to use `Kind.holds_cap?/2`. The PR-CC-2-v2 subagent's mix test run should show baseline (657/9) ± new tests, no net new failures.

---

## 9. PR-CC-2-v2 dispatch-subagent prompt skeleton

Main-agent dispatching PR-CC-2-v2 SHOULD use the following prompt skeleton (filled with concrete commit hash + worktree path at dispatch time):

```
Implement PR-CC-2-v2 per SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md.

Repo: ezagent42/ezagent. Main at <commit>. Branch off main into isolated worktree.

REQUIRED SKILLS: Skill: ezagent-developer + Skill: elixir-phoenix-helper (non-negotiable per feedback_subagent_must_load_project_skills).

Feishu chat_id VERBATIM: oc_d9b47511b085e9d5b66c4595b3ef9bb9.

Scope (§2–§7 of the SPEC):
1. Add Behavior.required_caps/0 callback (§2)
2. Add Kind.holds_cap?/2 callback + default impl (§3)
3. Add Capability.cap/3 + cap/5 helpers (§4)
4. Convert SystemPrincipal.Catalog 14 entries to struct shape (§5)
5. Switch dispatch step 5.5 to required_caps/0 + holds_cap?/2
6. Add 3 new invariant tests (§5 wildcard gate + §6 12-probe + §7 dispatch-uses-required-caps)
7. Extend :ezagent_plugin_check with checks 10 + 11 (§7)
8. Sweep ~19 Behavior modules to add required_caps/0 impl
9. Delete scattered cap-check sites per §8 list
10. No shims, no dual-path, no migration window. The PR is one coordinated change (feedback_let_it_crash_no_workarounds).

DO NOT:
- Touch caps_json DB column (parent SPEC §0d.5 — no migration).
- Add macros (parent G3 + r4-impl §7 — plain functions only).
- Run destructive migrations against live dev DB.
- Leave any %Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any} construction outside the catalog's bootstrap + mix-task entries (§5 wildcard gate).

Codex round 1 via codex:codex-rescue with verbatim no-mix clause:
  "Do NOT run mix test, mix compile, mix deps.get, or any mix command. Static analysis only — read files and reason from source."

If codex 529s, fall back to self-static-review (12 adversarial questions with file:line evidence).

Admin-merge: gh pr merge <N> --admin --squash --delete-branch.

Communication standards (per the prior PR-CC-1 / PR-CC-2a / PR-CC-2b dispatch patterns that worked):
- Prefix every Feishu message with [N% — PR-CC-2-v2] per `feedback_progress_percentage_in_replies`.
- End every Feishu message with explicit `继续` / `停` / `等你定` per `feedback_explicit_stop_signal_after_feishu`.
- Send a 1-2 sentence heads-up Feishu BEFORE `git push` / `gh pr create` / `gh pr merge --admin` per `feedback_feishu_notify_before_remote_ops`.
- No paternalistic "want to stop?" — Allen explicitly directed "make calls, don't bother me" per `feedback_no_paternalistic_stop_suggestions`.
- Default to wake-but-don't-stop: notify decision points + proceed with recommendation per `feedback_wake_but_dont_stop`.
```

---

## 10. Acceptance criteria

PR-CC-2-v2 merges only when all of the following hold:

- (a) `mix compile` clean.
- (b) `:ezagent_plugin_check` checks 10 + 11 pass for every Behavior on main.
- (c) New invariant tests pass:
  - `cap_check_only_at_chokepoint_test.exs` — 12 probes return zero offenders.
  - `no_wildcard_system_principals_test.exs` — no non-bootstrap principal has wildcard caps.
  - `dispatch_uses_required_caps_struct_test.exs` — `Invocation.dispatch/1` source references `required_caps/0` + `holds_cap?/2`.
- (d) Baseline failures unchanged: `ezagent_core` 657/9 ± 1 (allowing for incidental flaky clears); `domain_instance_message` / `domain_external_mirror` / `domain_identity` / `domain_workspace` baseline preserved.
- (e) No new code-level reference to deleted scattered cap-check helpers (the §8 Pathology B sweep complete).
- (f) PR body explicitly enumerates the 14 catalog entries' before-string → after-struct conversion table, with any deviations from the original string semantics flagged.
- (g) Codex round 1 returns either clean-bill OR findings that the subagent addresses in round 2 OR self-static-review documents (per r3-FINAL codex history pattern).

---

## 11. Rollback plan

If PR-CC-2-v2 lands and a regression surfaces (e.g., a Behavior whose `required_caps/0` was incorrectly declared denies a legitimate dispatch):

1. **First — surface via telemetry.** The new dispatch step 5.5 should emit `[:ezagent, :authz, :denied]` with `%{caller, needed, behavior_module}` metadata. The admin-authz-audit LV displays these in real time. Operators identify the bad declaration from telemetry.

2. **Hotfix narrow.** Most regressions are a missing action atom or a too-narrow `required_caps/0` declaration in one Behavior. Fix the declaration in a 1-LOC PR; the broader migration stays in place.

3. **Catastrophic — full revert.** If the dispatch step 5.5 switch itself is broken (e.g., `Kind.holds_cap?/2` default impl misreads slice shape), `git revert` PR-CC-2-v2. The PR's diff is mechanical enough that revert is a single command. Subsequent forward attempt addresses the root cause.

No DB rollback needed (no schema migration).

---

## 12. Out-of-scope (futures)

Tracked here so the SPEC scope is unambiguous; each is a future SPEC's job:

- **Cryptographic cap verification.** Parent SPEC §0d.6 sketches the additive field set (`signature`, `nonce`, `issuer_pubkey_fingerprint`). Future SPEC owns the full threat model.
- **Cap provenance audit table.** Parent §0d.1 keeps `granted_by` / `granted_at` in the struct; a separate audit table for grant-chain reconstruction is future work.
- **`Cap.Parser` deletion.** The string parser still exists for legacy operator-CLI input paths (`mix ezagent.user.grant_cap --cap "session.chat.send"` etc.). Whether to delete it is a separate UX-level decision; the parser is not in the chokepoint path post-PR-CC-2-v2.
- **`Identity.grant_cap/3` ergonomics.** Currently takes a `%Capability{}`; could grow keyword-arg variant for operator convenience. Future polish PR.
- **Workspace-suffix grammar.** Parent r2's `;ws=<workspace_uri>` instance-suffix syntax for string caps is permanently withdrawn — struct's `workspace_uri` field handles this natively.
- **`revoke_cap` CAS atomicity.** Parent SPEC r3 §5.3 step 8.5 introduced the cap-snapshot CAS contract (`Identity.cas_update_caps/2` via `:ets.select_replace/2`) to close TOCTOU between concurrent `grant_cap` and `revoke_cap` calls. r4 keeps that design intact (orthogonal to cap shape — the CAS protects revision atomicity, not field shape). PR-CC-2-v2 does NOT touch it; if a future stress test surfaces a race, the fix lands as a separate PR.

---

## 13. Open questions

None at draft time. Codex r1 review of THIS SPEC will surface any.
