# SPEC — `Ezagent.CapabilityRegistry` (core primitive)

**Status:** rev 4 · 2026-05-23 (codex round 3 fixes: action-aware registration + correct migration map + real admin gate + `__info__` API fix)
**Tier:** `apps/ezagent_core/`
**Trigger:** Allen 2026-05-23 — "现在 caps 有统一的注册入口吗？" + "registry 是唯一入口，不允许被绕过，避免后续出现 drift"
**Predecessors:** SKILL P15 (CapBAC shape), existing `Ezagent.Capability` + `Ezagent.BehaviorRegistry` + `Ezagent.Plugin.boot/1`
**Sequencing:** Lands BEFORE `2026-05-23-presence.md` (rev 3 rebases on this).

## Rev 4 changelog (vs rev 3)

Codex round 3 (verdict needs-attention, 1 CRITICAL + 2 HIGH + 1 MEDIUM):

- **CRITICAL: Behavior-wide registration over-registers actions.** Rev 3 had `register_against_kind(K, B)` (no per-action arg) — but Chat is bound to Session with 5 actions vs User/Agent with only `:receive`. **Rev 4 fix:** API is `register(kind, action, behavior)` — same 3-arity as `BehaviorRegistry.register/3` today. Mechanical s/BehaviorRegistry/CapabilityRegistry/ at every call site. Per-Kind action subsets are naturally preserved (one call per action per Kind, as today).
- **HIGH: Migration list inaccurate.** Rev 3 said Pty is registered from DomainPty.Application — actually from EzagentDomainInstanceMessage.Application; Workspace Routing from EzagentDomainWorkspace.Application (correct); Session Routing also from Chat (rev 3 wrong); rev 3 also missed Chat's User/Agent `:receive` registrations. **Rev 4 fix:** §5 migration table replaced with `rg`-derived exhaustive list.
- **HIGH: `/admin/caps` admin gate claim was false.** Current `/admin/*` routes are login-gated only; the existing `/admin/settings` LV does its OWN mount-time `@is_admin?` redirect — not a shared route-level gate. **Rev 4 fix:** §8.1 LV mirrors `settings_live.ex`'s `@is_admin?` mount pattern (redirect non-admin to `/sessions` with flash). Test mirrors `settings_live_admin_test`. The broader "make admin route-level shared gate" is filed as a separate concern (not in PR-CR).
- **MEDIUM: `behavior.__info__(:application)` doesn't exist.** Elixir's `__info__/1` accepts `:functions`, `:attributes`, `:module` — not `:application`. **Rev 4 fix:** §8.1 uses `:application.get_application(behavior)` instead.

## Rev 3 changelog (vs rev 2)

Two corrections from the rev-2 review cycle landed:

**Allen clarification:** "macro 只是举例，不一定要求使用 macro，请根据实际的需求考虑." Rev 2 reversed Decision #84 and adopted `use Ezagent.Behavior` macros. Reconsidered against the codebase's existing `@behaviour Ezagent.Behavior` + manual callback pattern — that pattern already enforces "every Behavior implements actions/0, state_slice/0, init_slice/1, invoke/4, interface/0" via Elixir's behaviour-callback warnings under `--warnings-as-errors`. Adding ONE more callback (`cap_subjects/0`) is the minimum-surface change and reuses the existing enforcement mechanism. No macros, no Decision #84 reversal.

**Codex round 2** (verdict needs-attention, 1 CRITICAL + 3 HIGH):
- **CRITICAL: core-only bootstrap** — `EzagentCore.Application.start/2` runs BEFORE plugin/domain Applications (umbrella dep direction). A core-side bootstrap walk via `:code.all_loaded` can't see plugin Behaviors at start, and lazy-loading in releases makes it worse. **Rev 3 fix:** registration moves INTO each Application's own `start/2` — `EzagentDomainInstanceMessage.Application` registers Chat/Template/Lifecycle, `EzagentDomainIdentity.Application` registers Identity/ApiKeys/default-grants for User, plugins do their own via `Ezagent.Plugin.boot/1` (which is updated to route through CapabilityRegistry).
- HIGH: macro option key mismatch (`:dispatchable` vs `:dispatchable?`) — moot in rev 3 (no macro).
- HIGH: `Ezagent.Plugin.boot/1` already centralizes plugin Behavior registration — missed in rev 2 migration scope. **Rev 3 fix:** `Plugin.boot/1` is now explicitly part of the migration list; its internal `BehaviorRegistry.register/3` call becomes `CapabilityRegistry.register_against_kind/2` (single change, covers ALL plugin Behaviors transparently).
- HIGH: `User.default_caps/1` has multiple production callers (Users.create, Feishu BindingPolicy, mix stress, tests) — rev 2 only named one. **Rev 3 fix:** `User.default_caps/1` is KEPT as the implementation; identity domain registers it with `CapabilityRegistry.register_default_grant/2` at boot. All existing callers continue working (no forced migration of every call site); new callers can use `CapabilityRegistry.default_grants_for/2` for discoverability.

---

## 1. Problem

(Unchanged.) The set of grantable capabilities today is implicit and scattered:

- `BehaviorRegistry.list_all/0` (mixes dispatch wiring with cap-subject identity)
- Per-Kind `default_caps/1` functions (only `Ezagent.Entity.User` has one)
- Per-entity caps slices serialized into per-Kind JSON columns

No `list_grantable/0` for admin/CLI; no machine-checkable cap-only declaration (Presence's `:online` would need to register as a Behavior with raising `invoke/4` — anti-pattern); `BehaviorRegistry.register/3` is a bare ETS insert any code can call (no single-entry enforcement → drift risk Allen called out).

## 2. Goal

Land `Ezagent.CapabilityRegistry` as the non-bypassable source of truth for cap subjects + default grants. Approach: **add one callback to `Ezagent.Behavior`** (`cap_subjects/0`) + **route all registrations through one module** (`CapabilityRegistry`) + **invariant test forbids direct `BehaviorRegistry.register/3` outside that module**.

Concretely:

- `Ezagent.Behavior` gains `@callback cap_subjects() :: [{atom(), String.t()}]` and an optional `@callback dispatchable?() :: boolean()` (defaulted via `__using__`-free pattern, see §3.1).
- Every existing Behavior adds one ~5-line function declaring its actions' descriptions. Compile-time warning via `@behaviour` enforcement catches misses; CI's `--warnings-as-errors` turns warning into failure.
- `Ezagent.CapabilityRegistry.register_against_kind(kind, behavior)` is the single entry point. It reads `Behavior.cap_subjects/0` + checks `Behavior.dispatchable?/0`, writes to its own subjects ETS, AND (for dispatchable behaviors) writes to `BehaviorRegistry`. Conflict-detected.
- `Ezagent.BehaviorRegistry.register/3` becomes `@doc false` + invariant test `single_capability_registration_entry_test.exs` scans production code; any call site outside `apps/ezagent_core/lib/ezagent/capability_registry.ex` = failure.
- Each domain/plugin Application's `start/2` calls `CapabilityRegistry.register_against_kind/2` instead of `BehaviorRegistry.register/3`. This is the registration locus — same place that always did the wiring, just goes through the new front door.
- `Ezagent.Plugin.boot/1`'s internal `BehaviorRegistry.register/3` call migrates to `CapabilityRegistry.register_against_kind/2` — one change covers all plugin Behaviors transparently.
- `Ezagent.Entity.User.default_caps/1` STAYS (don't break existing callers). `EzagentDomainIdentity.Application.start/2` registers it via `CapabilityRegistry.register_default_grant(User, &User.default_caps/1)`. `default_grants_for/2` returns the same caps; existing call sites continue working unchanged.

Non-goals:
- No macros (rev 2 backed out)
- No `Ezagent.Capability` struct shape change
- No forced migration of `default_caps/1` callers (Feishu BindingPolicy / stress / tests keep using `User.default_caps/1`; new code prefers the registry)

## 3. API surface

### 3.1 `Ezagent.Behavior` — two new callbacks

```elixir
defmodule Ezagent.Behavior do
  # ... existing @callback actions/0, state_slice/0, init_slice/1,
  # invoke/4, interface/0 unchanged ...

  @doc """
  List of `{action, description}` tuples — the cap subjects this
  Behavior gates. Every action returned from `actions/0` MUST appear
  here with a human-readable English description (used by admin UI,
  CLI, audit). Cap-only Behaviors (`dispatchable?/0 == false`) still
  list their actions here — that is HOW Presence-style auth gates get
  their cap shape into the registry.

  ## Compile-time enforcement

  `Ezagent.Behavior` is a behaviour; missing `cap_subjects/0` produces
  the standard Elixir `@behaviour` warning. CI runs with
  `--warnings-as-errors`, so a forgotten declaration breaks the
  build. This is the "non-bypassable" mechanism — no macros required.

  Example:
      def cap_subjects do
        [
          {:send,  "send a message to session members"},
          {:join,  "join a session as a member"},
          {:leave, "leave a session"}
        ]
      end
  """
  @callback cap_subjects() :: [{action(), String.t()}]

  @doc """
  Is this Behavior dispatchable? Default `true` — most Behaviors
  expose `invoke/4` for action dispatch. Set to `false` for cap-only
  Behaviors (the cap shape exists for auth, but there is no
  dispatchable action) — e.g. `Ezagent.Behavior.Presence`'s `:online`
  action is a subscription gate, not a dispatch target.

  When `dispatchable?/0 == false`, `CapabilityRegistry` records the
  cap subjects but does NOT write to `BehaviorRegistry`. The
  behaviour module SHOULD still provide an `invoke/4` that raises with
  a clear error — this catches accidental dispatch attempts at
  runtime instead of silent unknown-action errors.
  """
  @callback dispatchable?() :: boolean()

  @optional_callbacks [dispatchable?: 0]  # default-true via the registry
end
```

`@optional_callbacks` means an existing Behavior that doesn't yet define `dispatchable?/0` doesn't break compilation. `CapabilityRegistry.register_against_kind/2` treats the absence as `true` (dispatchable) — the common case — so migration only adds `dispatchable?/0` for cap-only Behaviors (currently zero; the future Presence is the first).

`cap_subjects/0` is NOT optional — every Behavior must declare it. The migration adds this function to every existing Behavior in a single PR.

### 3.2 `Ezagent.CapabilityRegistry`

```elixir
defmodule Ezagent.CapabilityRegistry do
  @moduledoc """
  Non-bypassable source of truth for cap subjects + default grants.

  ## Registration flow

  Each domain/plugin Application's `start/2` callback calls
  `register_against_kind/2` for every (Behavior, Kind) pair it wires —
  replacing the previous `BehaviorRegistry.register/3` calls. Plugin
  Behaviors registered via `Ezagent.Plugin.boot/1` flow through the
  same path (see §5).

  The registry runs early in `EzagentCore.Application.start/2` (after
  `EtsOwner`, before any domain/plugin Application starts) — its only
  job at core boot is to make the ETS tables exist. The actual subject
  registrations happen later as plugin/domain Applications come up.

  ## Single-entry guarantee

  `Ezagent.BehaviorRegistry.register/3` is `@doc false` and forbidden
  in production code outside this module (invariant test
  `single_capability_registration_entry_test.exs`). Boot-time conflict
  (same `{kind, action}` from two different Behaviors) raises during
  `register_against_kind/2` — caller sees a clear `RuntimeError` in
  the supervisor's startup log, which propagates to `Application.start`
  returning `{:error, reason}` — the standard let-it-crash path.
  """

  alias Ezagent.{BehaviorRegistry, Capability}

  @subjects_table :ezagent_capability_subjects
  @defaults_table :ezagent_capability_default_grants

  @typedoc "Internal subject record."
  @type subject :: %{
          kind: module(),
          behavior: module(),
          action: atom(),
          dispatchable?: boolean(),
          description: String.t()
        }

  # ----- Registration (called from domain/plugin Application.start/2) -----

  @doc """
  Register ONE `(kind, action, behavior)` triple — same shape as
  existing `Ezagent.BehaviorRegistry.register/3` (arg order
  preserved for mechanical migration).

  Behavior:
  - Reads `behavior.cap_subjects/0` (required); finds the entry where
    `elem(0) == action` to get the description. RAISES if `action`
    is not in `cap_subjects/0` — every exposed action must be
    declared (forces description discipline).
  - Reads `behavior.dispatchable?/0` (defaults to true if undefined
    via `function_exported?/3` probe — see §3.4).
  - Inserts subject keyed `{kind, behavior, action}` into the
    subjects ETS table with the discovered description.
  - If `dispatchable?/0` returns true, ALSO inserts `{kind, action}
    → behavior` into `BehaviorRegistry`.
  - RAISES if a different behavior is already registered for the
    same `{kind, action}` (conflict — caller bug).
  - Idempotent on repeat with the SAME `(kind, action, behavior)`
    (no-op, no raise).

  Per-Kind action subsets preserved: callers register the actions
  they want for each Kind (e.g. Chat:Session :send + :join + :leave;
  Chat:User :receive only — three separate calls per the existing
  pattern). This is the same per-call structure as today's
  `BehaviorRegistry.register/3` loops.

  Intended caller: domain/plugin Application `start/2` callbacks +
  `Ezagent.Plugin.boot/1`. Tests can call directly (test allowlist
  in the invariant scan).
  """
  @spec register(kind :: module(), action :: atom(), behavior :: module()) :: :ok
  def register(kind, action, behavior)

  @doc """
  Register a default-grant policy for new instances of a Kind. The fn
  receives the spawn-time `workspace_uri` (or `:any` for system-scoped
  Kinds) and returns the list of caps to grant.

  Called from each domain Application that owns Kinds with default
  grants — e.g. `EzagentDomainIdentity.Application.start/2` calls
  `register_default_grant(Ezagent.Entity.User,
  &Ezagent.Entity.User.default_caps/1)`. The Kind module's
  `default_caps/1` function STAYS (existing callers unchanged); this
  just makes the registry aware of it.
  """
  @spec register_default_grant(
          kind :: module(),
          grant_fn :: (URI.t() | :any -> [Capability.t()])
        ) :: :ok
  def register_default_grant(kind, grant_fn)

  # ----- Discovery / lookup -----

  @doc "All registered cap subjects, sorted by `{kind, behavior, action}`."
  @spec list_grantable() :: [subject()]
  def list_grantable()

  @doc "Subjects registered against a specific Kind."
  @spec subjects_for_kind(module()) :: [subject()]
  def subjects_for_kind(kind)

  @doc """
  Look up a single subject by `{kind, action}`. Returns `:error` if
  no subject registered. There can be at most one subject per
  `{kind, action}` (conflict-detected in `register_against_kind/2`).
  """
  @spec lookup_subject(module(), atom()) :: {:ok, subject()} | :error
  def lookup_subject(kind, action)

  @doc """
  Return the 4-field needed-cap MAP (NOT a `%Capability{}` struct) for
  authorization against `target_uri`. Same shape
  `Ezagent.Capability.cap_for_action/3` returns today — so callers
  (Presence, dispatch step 5.5, future cap consumers) feed it into
  `Capability.matches?/2` uniformly.

  RAISES `KeyError` if `{kind, action}` is not registered — caller bug,
  not a runtime condition (P2 let-it-crash).
  """
  @spec needed_for(kind :: module(), action :: atom(), target_uri :: URI.t()) :: map()
  def needed_for(kind, action, target_uri)

  @doc """
  Default caps a fresh instance of `kind` in `workspace_uri` would get.
  Returns `[]` if no default-grant registered for `kind`. After PR-CR
  registers `Ezagent.Entity.User.default_caps/1` via
  `register_default_grant/2`, this returns the actual User defaults.
  """
  @spec default_grants_for(module(), URI.t() | :any) :: [Capability.t()]
  def default_grants_for(kind, workspace_uri)
end
```

### 3.4 `dispatchable?/0` lookup mechanism (rev 4 explicit)

Inside `register/3`:

```elixir
defp dispatchable?(behavior_module) do
  if function_exported?(behavior_module, :dispatchable?, 0) do
    behavior_module.dispatchable?()
  else
    true
  end
end
```

`function_exported?/3` requires the module to be loaded — at boot time, the Behavior module is loaded by the calling Application (the call site is inside that Application's `start/2`, so its modules are loaded by then). For test-time mock Behaviors that may not be loaded at the moment of registration, callers can `Code.ensure_loaded!(behavior_module)` first; the registration helper does NOT do this automatically (P2 — let it crash if the module isn't loaded; that's a caller bug).

### 3.3 The relationship to `Capability.cap_for_action/3`

`needed_for/3` in CapabilityRegistry returns the SAME 4-field map shape that `Capability.cap_for_action/3` returns today. They differ in lookup source:

- `Capability.cap_for_action/3` reads `BehaviorRegistry.lookup(kind, action)` to find the behavior — works for dispatchable subjects only.
- `CapabilityRegistry.needed_for/3` reads `CapabilityRegistry.lookup_subject(kind, action)` — works for BOTH dispatchable AND cap-only subjects (Presence's `:online` is reachable through here but NOT through `cap_for_action/3`).

`Capability.cap_for_action/3` stays unchanged in this PR (it's a hot path called from `Invocation.dispatch/1` step 5.5; existing callers + invariants depend on its exact behavior). New code (Presence + future cap-only consumers) calls `CapabilityRegistry.needed_for/3` instead.

A future PR can consolidate by making `cap_for_action/3` delegate to `needed_for/3` — the lookup result is equivalent for dispatchable subjects. Out of scope for PR-CR.

## 4. Storage

Two ETS tables (owned by `EzagentCore.EtsOwner`, mirror `BehaviorRegistry` pattern):

- `:ezagent_capability_subjects` — keyed by `{kind, behavior, action}`, value `%{description, dispatchable?}`.
- `:ezagent_capability_default_grants` — keyed by `kind`, value `grant_fn`.

`BehaviorRegistry`'s table is unchanged. Subjects + dispatch entries are atomically inserted in `register_against_kind/2` (single function = single source of truth for ordering); a conflict raises before either insert commits, so neither table holds half a registration.

## 5. Migration plan — per-Application registration

(Reflects codex CRITICAL fix: NOT centralized in core; each Application registers its own.)

**`apps/ezagent_core/lib/ezagent/behavior.ex`** — add the two callbacks per §3.1.

**Each `@behaviour Ezagent.Behavior` module** (~10) adds `def cap_subjects, do: [{...}, ...]` per its existing actions. ~5 LOC per module, mechanical.

**Each Application that wires Behaviors** — switches `BehaviorRegistry.register/3` calls to `CapabilityRegistry.register_against_kind/2`:

Exhaustive `rg "BehaviorRegistry.register"` (production only — `apps/*/lib/`, code paths not comments):

| File:line | Current call | Migrates to |
|---|---|---|
| `apps/ezagent_core/lib/ezagent_core/application.ex:123` | `BehaviorRegistry.register(SK, action, RB)` (loop) | `CapabilityRegistry.register(SK, action, RB)` — System Routing actions |
| `apps/ezagent_core/lib/ezagent/plugin.ex:302` | `BehaviorRegistry.register(kind, action, behavior)` (Plugin.boot/1's inner loop over `plugin.behaviors()`) | `CapabilityRegistry.register(kind, action, behavior)` — covers ALL plugin Behaviors transparently |
| `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:444-446` | Session `:send`, `:join`, `:leave` → Chat | `CapabilityRegistry.register(Session, :send, Chat)` etc. |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:450` | Session `:set_working_copy` → Chat | direct migration |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:451-452` | User `:receive`, Agent `:receive` → Chat (post-hoc) | direct migration — **per-Kind action subset preserved** (Chat exposes only `:receive` on User/Agent vs full 5 actions on Session) |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:464` | Session Routing actions (loop) → RB | direct migration |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:478` | Agent Pty actions (loop) → PtyB (post-hoc) | direct migration |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:491-492` | AgentTemplate + SessionTemplate Template actions (loop) → TemplateB | direct migration |
| `apps/ezagent_domain_instance_message/lib/.../application.ex:508` | Agent Lifecycle actions (loop) → LifecycleB (post-hoc) | direct migration |
| `apps/ezagent_domain_identity/lib/.../application.ex:222` | User Identity actions (loop) | direct migration |
| `apps/ezagent_domain_identity/lib/.../application.ex:228` | Agent Identity actions (loop, post-hoc) | direct migration |
| `apps/ezagent_domain_identity/lib/.../application.ex:235` | User ApiKeys actions (loop) | direct migration |
| `apps/ezagent_domain_workspace/lib/.../application.ex:45` | Workspace own actions (loop) | direct migration |
| `apps/ezagent_domain_workspace/lib/.../application.ex:55` | Workspace Routing actions (loop) | direct migration |

**Migration is mechanical**: each call site does `s/Ezagent.BehaviorRegistry.register(/Ezagent.CapabilityRegistry.register(/`. Arg order unchanged (the new `register/3` has the same `(kind, action, behavior)` shape).

Total: **16 production call sites** to migrate. Two are LOOPS (`Plugin.boot/1` line 302 + the various per-action loops in domain Applications) — the loop body changes once per call site.

Existing `behaviors/0` callbacks on Plugin modules + `actions/0` callbacks on Behavior modules are NOT touched (they're the input data for the loops).

**`EzagentDomainIdentity.Application.start/2`** adds one new line:
```elixir
:ok = Ezagent.CapabilityRegistry.register_default_grant(
  Ezagent.Entity.User,
  &Ezagent.Entity.User.default_caps/1
)
```

**`Ezagent.BehaviorRegistry.register/3`** gets `@doc false` + a `# WARN` comment noting "direct calls forbidden — see Ezagent.CapabilityRegistry".

**No DB migration.** **No `Ezagent.Entity.User.default_caps/1` deletion.**

## 6. Invariant tests (single sole-entry enforcement)

`apps/ezagent_core/test/invariants/single_capability_registration_entry_test.exs`:

1. **No direct `BehaviorRegistry.register(` calls in production code outside CapabilityRegistry source.** AST scan over `apps/*/lib/**/*.ex` (excluding `test/`, mirroring `single_spawn_entry_test.exs` pattern). Allowlist: `apps/ezagent_core/lib/ezagent/capability_registry.ex` only. Tests can call directly (test files are excluded from the scan).

2. **Every `@behaviour Ezagent.Behavior` module defines `cap_subjects/0`.** Walks `:code.all_loaded`, filters to modules implementing the behaviour, asserts each defines `cap_subjects/0`. Catches Behaviors written without the new callback (caught at compile via `@behaviour` warning + `--warnings-as-errors`, but the test gives a faster CI signal and doesn't depend on warning configuration).

3. **No `{kind, action}` registered with two different behaviors.** Walks both `:ezagent_capability_subjects` and `BehaviorRegistry`'s table; asserts the dispatchable subjects in subjects-table match BehaviorRegistry entries 1:1.

`apps/ezagent_core/test/ezagent/capability_registry_test.exs` — 10 unit tests:

4. `register(K, :action, dispatchable_behavior)` → subjects table + BehaviorRegistry both updated; `lookup_subject(K, :action)` returns the subject; `BehaviorRegistry.lookup(K, :action)` returns `{:ok, behavior}`
5. `register(K, :action, cap_only_behavior)` (where `cap_only_behavior.dispatchable?() == false`) → subjects table updated, BehaviorRegistry untouched; `lookup_subject` returns subject; `BehaviorRegistry.lookup` returns `:error`
6. Same `(K, :action, behavior)` registered twice is idempotent (no-op, no raise)
7. Same `(K, :action)` registered with DIFFERENT behaviors RAISES `RuntimeError` (conflict)
8. `register(K, :action, behavior)` where `:action` is NOT in `behavior.cap_subjects/0` raises `RuntimeError` ("forces description discipline")
9. `register_default_grant(K, fn)` + `default_grants_for(K, ws_uri)` returns the fn's result
10. `default_grants_for(unknown_kind, ws)` returns `[]`
11. `needed_for(K, :action, uri)` returns 4-field map with the right keys
12. `needed_for(K, :unregistered_action, uri)` raises `KeyError`
13. `list_grantable/0` after registering 3 subjects returns 3 entries sorted by `{kind, behavior, action}`
14. `subjects_for_kind(K)` filters correctly
15. Chat-on-Session vs Chat-on-User action-subset preservation: `register(Session, :send, Chat)` + `register(User, :receive, Chat)` → `subjects_for_kind(Session)` includes `:send` but NOT `:receive`; `subjects_for_kind(User)` includes `:receive` but NOT `:send` (per-Kind action subset preservation — codex round-3 CRITICAL regression test)

## 7. Files

| File | Action | LOC est |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/capability_registry.ex` | new | ~250 |
| `apps/ezagent_core/lib/ezagent/behavior.ex` | edit (add `cap_subjects/0` + `dispatchable?/0` callbacks + @doc) | +40 |
| `apps/ezagent_core/lib/ezagent/behavior_registry.ex` | edit (mark `register/3` `@doc false` + warning comment) | +5 |
| `apps/ezagent_core/lib/ezagent_core/ets_owner.ex` | edit (add 2 ETS tables) | +6 |
| `apps/ezagent_core/lib/ezagent/plugin.ex` | edit (replace internal `BehaviorRegistry.register/3` with `CapabilityRegistry.register_against_kind/2`) | -5, +5 net |
| **All ~10 `@behaviour Ezagent.Behavior` modules** | edit (add `cap_subjects/0` function; ~5 LOC each) | +50 |
| **All ~6 Applications with `BehaviorRegistry.register/3` calls** | edit (replace with `CapabilityRegistry.register_against_kind/2`) | -15, +20 net |
| `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` | edit (add `register_default_grant` for User) | +5 |
| `apps/ezagent_core/test/ezagent/capability_registry_test.exs` | new | ~200 (10 tests) |
| `apps/ezagent_core/test/invariants/single_capability_registration_entry_test.exs` | new | ~80 (3 invariants) |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/admin_caps_live.ex` | new | ~180 (LV — see §8.1) |
| `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/admin/admin_caps_live_test.exs` | new | ~80 |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/router.ex` | edit (mount `/admin/caps`) | +1 |
| `docs/runbook/common-failures.md` | edit (cap-subject not registered + boot conflict symptoms) | +30 |
| `docs/superpowers/specs/2026-05-23-capability-registry.md` | new (this file) | — |

Total: ~960 net LOC (still smaller than rev 2's 1100 — no macros). Single PR including admin LV per Allen's directive.

## 8. Rollout / acceptance

### 8.1 `/admin/caps` LiveView (in PR-CR per Allen 2026-05-23)

The discovery primitive needs a discovery surface in the same PR — Allen's "我想知道现在有哪些 caps 可以注册和被 grant" is unmet if PR-CR ships the registry without the LV. Scope of the LV:

- Mounted at `/admin/caps` inside the existing `live_session :require_entity` (the route-level gate today only authenticates the user — see admin gate note below).
- **Admin gate (rev 4 fix)**: mirrors `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/settings_live.ex`'s mount-time pattern — `if Map.get(socket.assigns, :is_admin?) do ... else redirect to "/sessions" with flash` (the SAME defence the existing `/admin/settings` LV uses). Test mirrors `settings_live_admin_test.exs`. A broader "route-level admin gate via `live_session`" is a separate concern — filed for future cleanup, NOT in PR-CR scope (current LVs each carry their own mount-time gate; adding one shared gate is its own refactor).
- Renders one row per `CapabilityRegistry.list_grantable/0` entry: `kind | behavior | action | description | dispatchable?`
- Sortable by kind / behavior / action; filter input for free-text match across all fields
- Per-row "expand" reveals:
  - The needed-cap MAP shape: `needed_for(kind, action, sample_uri)` displayed JSON-pretty (sample URI is a hardcoded placeholder of the kind's URI scheme — e.g. `entity://user/example/example` for User-kind subjects)
  - The registering OTP application: `:application.get_application(behavior)` (NOT `__info__(:application)` — that field doesn't exist on Elixir modules; rev 4 fix)
- A "default grants" section at the top: for each Kind with a registered default-grant fn, show `default_grants_for(K, <admin-selected workspace>)` rendered as a Capability list. The workspace selector defaults to the admin's current workspace. Uses existing `EzagentPluginLiveview.UI` workspace-picker primitive (already used in `/admin/templates`).
- LiveView re-queries on every mount (V1) — registry mutations only happen at boot, so live-update is unnecessary. A future `esr:capability_registry:changes` PubSub topic for hot-reload support is out of scope.

The LV is small (~180 LOC) — uses existing `EzagentPluginLiveview.UI` primitives (table, badge, expandable rows).

### 8.2 PR-CR acceptance gates

**PR-CR (this SPEC):** ships everything (registry + invariants + admin LV). Acceptance gates:

1. `mix compile --warnings-as-errors` clean (proves all Behaviors implement `cap_subjects/0`)
2. `mix test` green (all 13+ new tests + existing test suite)
3. `CapabilityRegistry.list_grantable/0` returns ≥ N entries (N = sum of actions across all migrated Behaviors — known at PR time)
4. `CapabilityRegistry.default_grants_for(Ezagent.Entity.User, ws)` returns the same caps as `Ezagent.Entity.User.default_caps(ws)` (snapshot test)
5. Invariant tests #1-#3 pass (single-entry enforcement + no Behavior without cap_subjects + no drift between subjects and BehaviorRegistry)
6. **`mix precommit` passes on every existing app** — no plugin/domain Application broken by the migration
7. **`/admin/caps` LV renders ≥ N grantable subjects + ≥ 1 default-grant section** — admin can navigate to the page and see the cap surface from §8.1

After PR-CR merges:
- **PR-1 (separate SPEC `2026-05-23-presence.md` rev 3)** — Presence Behavior declares `cap_subjects [{:online, "..."}]` + `dispatchable?(), do: false`; registered via `EzagentCore.Application.start/2` calling `CapabilityRegistry.register_against_kind(Ezagent.Entity.User, Ezagent.Behavior.Presence)` (and Agent). Presence's `subscribe/1` calls `CapabilityRegistry.needed_for(User, :online, uri)` for cap shape. The `/admin/caps` LV automatically picks up the new subject (no LV change needed).
- Future cap-discovery surfaces (`mix ezagent.caps.list` CLI, `esr:capability_registry:changes` live-update topic) — separate small PRs. Not in PR-CR scope.

## 9. Open questions for Allen

- **Conflict policy** — `register_against_kind/2` RAISES on `{kind, action}` registered with two different behaviors. Stricter than the current `BehaviorRegistry.register/3`'s last-writer-wins. This is intentional (silent overwrite is the drift problem). Going strict; flagging because it could surface latent dup-registration bugs as boot failures rather than silent loss-of-fidelity. The fix is to find the dup and decide — both registrations were probably wrong.

- **`cap_subjects/0` returns `{atom, String.t()}` tuples — no priority / category / tags.** Future admin UI might want grouping ("messaging" / "lifecycle" / "auth"). Kept tuple shape minimal for V1; can extend to `{atom, String.t(), Keyword.t()}` later without breaking the shape (the macro-less callback contract lets us extend tuples by adding a 3rd optional element).

- **`Ezagent.Plugin.boot/1` migration breaks every plugin** that wires Behaviors at boot via the `behaviors/0` callback. The migration covers this via the single-site change inside `Plugin.boot/1` — but during the PR's review window, a plugin author writing AGAINST main could be confused. Documenting in PR description; not adding a back-compat shim per P2.
