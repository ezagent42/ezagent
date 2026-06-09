# Socialware Substrate P0+P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Make `Behavior.Publisher` a base behavior every session composes (P0), then make the Kind runtime *per-instance-behavior-set-aware* — persisting each instance's behavior set and routing every behavior enumeration + callback entry point through it so an out-of-set behavior can never run a callback, process a signal, run a cleanup hook, or create/mutate its slice, even when one Kind module registers a superset (P1).

**Architecture:** A new core base behavior `Ezagent.Behavior.KindBase` (slice key `:kind_base`, `use Ezagent.Lifecycle`) snapshots the instance's behavior-module list at spawn into its persistent `:state` so it survives restart/reconcile via the existing `kind_snapshots` path. The captured value uses an explicit **legacy sentinel** (`nil`) to distinguish a Kind spawned with NO `:behaviors` arg (legacy static Kind → expand to the full declared list) from a Kind spawned with a PRESENT list (including the empty list `[]` → exactly that list, never the declared superset) — so an explicit `%{behaviors: []}` can never be confused with omitted args and re-open the §3.1 hole under empty/malformed args. A new pure resolver `Ezagent.Kind.BehaviorSet` exposes (a) `init_set/2` — the FIRST-spawn set from spawn args: when `:behaviors` is ABSENT → the full declared list (legacy), when PRESENT (even `[]`) → `(list ∩ declared)`, in both cases PLUS the always-on base behaviors (`KindBase` + `Ezagent.UniversalBehaviors.all()`), consumed by `init_fresh_first_spawn` (the `:not_found` branch of the fetched-first `load_with_fallback/3`) so an out-of-set behavior NEVER runs `create`/`init_slice` nor persists a slice even on the very first spawn; (b) `effective_set/2` — the post-load set from the persisted `:kind_base` slice: legacy sentinel (`nil`) → full declared list (preserving today's two static Kinds), an explicit captured list (even `[]`) → `(list ∩ declared)`, in both cases + base behaviors; (c) a required/optional `reads_siblings` closure against a slice-owner map (fails loud only on a missing *required* sibling). `init_set` and `effective_set` are symmetric: absent-at-spawn ⇒ sentinel-at-reload ⇒ declared; present-list-at-spawn ⇒ same-list-at-reload ⇒ that list. Every runtime call site that today calls `Ezagent.Kind.behaviors_of(kind_module)` or resolves dispatch by `{kind_module, action}` is re-pointed at the instance set; dispatch gains a membership gate that denies an out-of-set behavior with `{:error, :behavior_not_in_instance_set}` while EXEMPTING universal behaviors (e.g. `Manage`), which are always reachable and gated only by the normal cap check.

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_core`, `apps/ezagent_domain_instance_message`, `apps/ezagent_domain_socialware`, `apps/ezagent_domain_external_mirror`), `use Ezagent.Lifecycle` behavior contract, `Ezagent.Kind.Server` (single GenServer host), `Ezagent.Kind.Snapshot` persistence, ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

---

## Background — grounded entry-point inventory (the P1 surface)

P1's HARD INVARIANT is "every behavior enumeration + every callback entry point uses the persisted INSTANCE set, never the module's static list." The full inventory of sites that today enumerate behaviors by *module* (or resolve dispatch by `{kind_module, action}` independent of the instance) — each becomes a P1 task:

| # | Site | File:line | Kind of entry point | Denial-test class |
|---|---|---|---|---|
| E1 | `collect_post_init_queue/3` | `apps/ezagent_core/lib/ezagent/kind/server.ex:266` | `create`/`post_init` enumeration | yes (slice-init / post_init) |
| E2 | `run_on_ready_hooks/3` | `apps/ezagent_core/lib/ezagent/kind/server.ex:517` | `on_ready` enumeration | yes (on_ready) |
| E3 | `handle_call({:ezagent_lifecycle_destroy, …})` | `apps/ezagent_core/lib/ezagent/kind/server.ex:581` | `destroy` enumeration | yes (destroy) |
| E4 | `handle_info/2` mailbox → `forward_to_behavior` | `apps/ezagent_core/lib/ezagent/kind/server.ex:742` | `handle_signal`/`handle_kind_message` mailbox | yes (signal) |
| E5 | `drain_behavior_terminates/4` | `apps/ezagent_core/lib/ezagent/kind/server.ex:896` | `terminate`/`deactivate` enumeration | yes (terminate) |
| E6 | `prune_orphan_slices/2` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:137` | slice prune (declared-key set) | covered by E8 denial |
| E7 | `reconcile_after_load_behaviors/3` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:163` | `reconcile_after_load` enumeration | yes (reconcile) |
| E8 | `init_fresh/2` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:533` | slice init (`init_slice`) | yes (slice-init) |
| E9 | `lookup_behavior/2` + `invoke_behavior/5` dispatch resolution | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:172`, `:188`, `:284` | dispatch + caps | yes (dispatch) |
| E10 | `hosts_lifecycle?/1` | `apps/ezagent_core/lib/ezagent/lifecycle.ex:397` | metadata classification (create/activate marker) | parity assertion (not security) |
| E11 | `build_detail/3` (operator UI introspection) | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex:107` | display only | DEFERRED to P2 (see note) |

Notes:
- **E8 + E9 are the two security-critical sites.** **E8 (slice init)** is the load path's first-spawn slice-creation point. In the CURRENT source, `load_with_fallback` runs `fresh = init_fresh(args)` at its START (`snapshot.ex:70`) BEFORE `fetch_snapshot` reads the persisted row, and on `:not_found` that fresh result is returned + persisted on first spawn (`snapshot.ex:111` → `Kind.Server.persist_initial_snapshot`), BEFORE any restart. P1 RESTRUCTURES this (Task 9): fetch the persisted row FIRST, then branch — `:not_found` → `init_fresh_first_spawn/2` (scoped to `BehaviorSet.init_set/2` + closure-validated) so an out-of-set behavior's `create`/`init_slice` never runs and its slice never persists on first spawn; reload → SEED the legacy sentinel `nil` into `:kind_base` when the loaded snapshot lacks it (pre-P1 row, codex CRITICAL data-loss fix — INDEPENDENT of reload args), then derive the set from the PERSISTED `:kind_base` (`effective_set/2`, NOT spawn args) so a closed-but-wrong or unclosed spawn-args fallback can't create out-of-set slices, crash a valid persisted instance, or let reload args re-drive a legacy instance and prune its persisted declared slices (codex CRITICAL). **E9 (dispatch)** resolves a behavior via `Ezagent.BehaviorRegistry.lookup(kind_module, action)` (`runtime.ex:284-289`), keyed by `kind_module` — NOT by instance — and FALLS BACK to `Ezagent.UniversalBehaviors.behavior_for_action/1` (`behavior_registry.ex:58`) for actions with no per-Kind registration (today: `Manage`'s `:delete`/`:reconfigure`). Caps are also registered per `{kind_module, action}` (`Ezagent.CapabilityRegistry.register(kind, action, behavior)`, `capability_registry.ex:82`). So with one `SessionKind` carrying a superset, ANY instance could resolve+dispatch ANY registered action. P1 inserts an instance-set membership gate AFTER `lookup_behavior` and BEFORE `authz_check` — gating NON-universal behaviors by instance-set membership while EXEMPTING `UniversalBehaviors.all()` (still cap-checked) so universal `Manage` is never wrongly denied (codex HIGH).
- **E10** (`hosts_lifecycle?/1`) decides the create/activate marker semantics from the module's behavior list. It is metadata, not a callback gate. We re-point it at the instance set for correctness (a superset Kind would otherwise mark every instance as Lifecycle-hosting even when its instance set has no Lifecycle behavior). Verified by a parity assertion, not a security-denial test.
- **E11** (`auto_derive.ex`) is operator-AdminLive *display* of a Kind's behaviors. It is the View surface, owned by **P2 (Unified View contract)**, not P1. Left untouched here; flagged so the orchestrator does not treat it as a P1 gap.

### `reads_siblings` slice-owner map (the P1 closure input)

Every `reads_siblings` / `reads_sibling_slices` declaration in the tree, with its owning behavior and required/optional classification:

| Reader behavior | Declared key(s) | Owning behavior (slice) | Classification | Rationale |
|---|---|---|---|---|
| `Ezagent.Behavior.Chat` (`:chat`) | `[:sandbox]` | `Ezagent.Behavior.Sandbox` (`:sandbox`) | **OPTIONAL** | Both current session Kinds run WITHOUT `Sandbox`; runtime injects `%{}` today (`context.ex:47`). Must stay soft. |
| `Ezagent.Behavior.Turn` (`:turns`) | `[:surface]` | `Ezagent.Behavior.Surface` (`:surface`) | **REQUIRED** | Turn cannot compute versions without Surface. |
| `Ezagent.Behavior.ConfigUpdate` (`:config_updates`) | `[:turns, :chat]` | `Turn` (`:turns`), `Chat` (`:chat`) | **REQUIRED** | ConfigUpdate reads both to apply config across the turn machine. |
| `Ezagent.Behavior.ExternalMirror` (`:external_mirror`) | `[:publisher]` | `Ezagent.Behavior.Publisher.SessionImpl` (`:publisher`) | **REQUIRED** | The mirror reads the publisher cursor/ring. (P0 makes `:publisher` present on every session.) |
| `Ezagent.Behavior.CurlAgent` (`:curl_agent`) | `[:api_keys]` | `Ezagent.Behavior.ApiKeys` (`:api_keys`) | **OPTIONAL** | Agent-tier (not a session); ApiKeys may be absent. Keep soft to avoid breaking agent Kinds. |

The slice-owner map lives as a single source of truth in `Ezagent.Kind.BehaviorSet` (Task 6). Classification is encoded per-reader-per-key (Task 7).

---

## File Structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `apps/ezagent_domain_socialware/lib/ezagent/entity/socialware_session.ex` | Modify | P0: add `Publisher.SessionImpl` to `behaviors/0`; add `@behaviour Ezagent.Behavior.Publisher` + the 4 façade callbacks (mirroring `Ezagent.Entity.Session`). |
| `apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs` | Create | P0: assert `SocialwareSession` composes `:publisher`, subscribe_from works, slice changes emit publisher events. |
| `apps/ezagent_core/lib/ezagent/behavior/kind_base.ex` | Create | P1: base behavior owning slice `:kind_base`; `create/1` snapshots the instance behavior-module list from spawn args, persisting the legacy sentinel `nil` when `:behaviors` is ABSENT and the exact list (even `[]`) when PRESENT; exposes no actions (data-only base). |
| `apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs` | Create | P1: assert the slice captures the behavior set and survives a restart round-trip. |
| `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex` | Create | P1: pure resolver — `base_behaviors/0` (KindBase + UniversalBehaviors.all), `init_set/2` (first-spawn set from args), `effective_set/2` (post-load instance set), slice-owner map, `resolve_closure/1` (required/optional fail-loud), `member?/2`. |
| `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs` | Create | P1: unit tests for init_set (first-spawn scoping + universal base), effective_set, closure (required fail / optional soft), member?. |
| `apps/ezagent_core/lib/ezagent/kind/server.ex` | Modify | P1: thread the instance set into state; re-point E1–E5 enumerations through it. |
| `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` | Modify | P1: RESTRUCTURE `load_with_fallback/3` — fetch persisted snapshot FIRST, then branch: `:not_found` → `init_fresh_first_spawn/2` (init_set from args + validate_closure! — first-spawn §3.1 guard, no out-of-set create/slice); reload → `seed_legacy_kind_base/1` (pre-P1 row with NO `:kind_base` → seed legacy sentinel `nil` INDEPENDENT of args, no data loss) then `effective_set/2` from persisted `:kind_base` + validate + `init_fresh_for_set/2` (spawn args never re-drive reload slice creation). prune/reconcile re-pointed through `effective_set/2`; KindBase always present via base behaviors. |
| `apps/ezagent_core/lib/ezagent/kind/runtime.ex` | Modify | P1 (E9): instance-set membership gate after `lookup_behavior`, denying out-of-set behaviors; EXEMPTS `UniversalBehaviors.all()` (still cap-checked). |
| `apps/ezagent_core/lib/ezagent/lifecycle.ex` | Modify | P1 (E10): `hosts_lifecycle?/2` instance-aware variant; keep `/1` for static callers. |
| `apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs` | Create | P1: the cross-entry-point denial suite (dispatch / slice-init / signal / terminate-destroy / on_ready / reconcile). |
| `apps/ezagent_core/test/ezagent/kind/instance_set_support.ex` | Create | P1: a test-support `SupersetSessionKind` whose module registers `[Chat, Surface, …]` but is spawned with a chat-only instance set, plus a probe behavior with observable signal/terminate. |
| `apps/ezagent_domain_instance_message/test/.../session_instance_set_test.exs` | Create | P1: assert chat `Session` (static set) is unchanged at runtime under the new instance-set path. |

---

## P0 — Publisher as a base behavior on every session

### Task 1: SocialwareSession composes the Publisher slice (failing test first)

**Files:**
- Test: `apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/entity/socialware_session.ex:15-22`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Entity.SocialwareSessionPublisherTest do
  use ExUnit.Case, async: false

  alias Ezagent.Entity.SocialwareSession

  test "SocialwareSession composes Publisher.SessionImpl (owns the :publisher slice)" do
    behaviors = Ezagent.Kind.behaviors_of(SocialwareSession)
    assert Ezagent.Behavior.Publisher.SessionImpl in behaviors

    slice_keys = Enum.map(behaviors, & &1.state_slice())
    assert :publisher in slice_keys
  end

  test "SocialwareSession declares the Publisher behaviour contract" do
    assert Ezagent.Behavior.Publisher in (SocialwareSession.module_info(:attributes)[:behaviour] || [])
    assert function_exported?(SocialwareSession, :subscribe_from, 4)
    assert function_exported?(SocialwareSession, :snapshot, 2)
    assert function_exported?(SocialwareSession, :history, 4)
    assert SocialwareSession.history_retention() == 100
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs`
Expected: FAIL — `Ezagent.Behavior.Publisher.SessionImpl` not in behaviors; `subscribe_from/4` not exported.

- [ ] **Step 3: Add Publisher.SessionImpl to behaviors/0 and the façade callbacks**

Replace `behaviors/0` (`socialware_session.ex:15-22`) with:

```elixir
  @behaviour Ezagent.Behavior.Publisher

  @impl Ezagent.Kind
  def behaviors do
    [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Turn,
      Ezagent.Behavior.Surface,
      Ezagent.Behavior.ConfigUpdate,
      # P0 (socialware substrate) — every session composes the Publisher
      # trunk. SessionImpl owns the `:publisher` slice + the 3 publisher
      # actions. No consumer change: the slice simply exists now.
      Ezagent.Behavior.Publisher.SessionImpl
    ]
  end
```

Then add the Publisher façade callbacks. Re-use the proven implementation in `Ezagent.Entity.Session` (`session.ex:83-225`): the 4 `@impl Ezagent.Behavior.Publisher` callbacks (`history_retention/0`, the 3-ary `subscribe_from`/`snapshot`/`history` that raise `raise_no_ambient_caps!`), the 4-ary/2-ary public variants that route through `dispatch_publisher_action/4`, and the private `dispatch_publisher_action`/`unwrap_cursor`/`unwrap_events`/`raise_no_ambient_caps!`. Add to `socialware_session.ex`:

```elixir
  @impl Ezagent.Behavior.Publisher
  def history_retention, do: 100

  @impl Ezagent.Behavior.Publisher
  def subscribe_from(%URI{} = _publisher_uri, subscriber_pid, _cursor)
      when is_pid(subscriber_pid),
      do: raise_no_ambient_caps!(:subscribe_from, 4)

  @impl Ezagent.Behavior.Publisher
  def snapshot(%URI{} = _publisher_uri), do: raise_no_ambient_caps!(:snapshot, 2)

  @impl Ezagent.Behavior.Publisher
  def history(%URI{} = _publisher_uri, _from, _to), do: raise_no_ambient_caps!(:history, 4)

  @spec subscribe_from(URI.t(), pid(), Ezagent.Behavior.Publisher.cursor(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def subscribe_from(%URI{} = publisher_uri, subscriber_pid, cursor, ctx)
      when is_pid(subscriber_pid) and is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(
      :subscribe_from,
      %{subscriber_pid: subscriber_pid, cursor: cursor},
      ctx
    )
    |> unwrap_cursor()
  end

  @spec snapshot(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def snapshot(%URI{} = publisher_uri, ctx) when is_map(ctx),
    do: dispatch_publisher_action(publisher_uri, :snapshot, %{}, ctx)

  @spec history(URI.t(), Ezagent.Behavior.Publisher.cursor(), Ezagent.Behavior.Publisher.cursor(), map()) ::
          {:ok, [Ezagent.Publisher.Event.t()]} | {:error, term()}
  def history(%URI{} = publisher_uri, from, to, ctx) when is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(:history, %{from: from, to: to}, ctx)
    |> unwrap_events()
  end

  defp dispatch_publisher_action(%URI{} = publisher_uri, action, args, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(publisher_uri)}?action=publisher.#{action}")
    normalised_ctx = Map.put_new(ctx, :reply, :ignore)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: normalised_ctx
    })
  end

  defp unwrap_cursor({:ok, %{cursor: cursor}}), do: {:ok, cursor}
  defp unwrap_cursor({:error, _} = err), do: err
  defp unwrap_events({:ok, %{events: events}}), do: {:ok, events}
  defp unwrap_events({:error, _} = err), do: err

  defp raise_no_ambient_caps!(action, arity) do
    raise ArgumentError,
          "Ezagent.Entity.SocialwareSession.#{action}/#{arity - 1} requires an explicit " <>
            "caller ctx — use #{action}/#{arity} with `ctx: %{caller: %URI{...}, " <>
            "caps: MapSet.new([...])}`. The V1 codebase has no ambient-caps mechanism."
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/entity/socialware_session.ex \
        apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs
git commit -m "feat(socialware): P0 — Publisher base behavior on SocialwareSession"
```

### Task 2: Publisher caps registered for SocialwareSession (failing test first)

The publisher actions are cap-gated per `{kind_module, action}`. Adding `Publisher.SessionImpl` to a NEW Kind module requires the cap catalog to grant the 3 publisher actions on `SocialwareSession` too, or `subscribe_from/4` denies with `:unauthorized`.

**Files:**
- Test: append to `apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs`
- Modify: the production cap catalog that registers publisher caps (locate with the grep in Step 1).

- [ ] **Step 1: Locate the cap catalog + write the failing test**

Run `rg -n "Publisher.SessionImpl" apps/*/lib` to find where the publisher cap grant is declared for `Ezagent.Entity.Session` (the catalog that `apps/ezagent_plugin_feishu/test/binding_policy_test.exs` asserts against). Add a test asserting the same 3 actions are granted on `SocialwareSession`:

```elixir
  test "publisher caps cover SocialwareSession's 3 publisher actions" do
    caps = Ezagent.Identity.production_caps()  # use the same accessor binding_policy_test uses

    sw_pub_caps =
      Enum.filter(caps, fn c ->
        c.behavior == Ezagent.Behavior.Publisher.SessionImpl and
          c.kind == :session
      end)

    actions = sw_pub_caps |> Enum.map(& &1.action) |> MapSet.new()
    assert MapSet.subset?(MapSet.new([:subscribe_from, :snapshot, :history]), actions)
  end
```

NOTE TO IMPLEMENTER: `Ezagent.Identity.production_caps()` is a placeholder — bind it to the exact accessor `binding_policy_test.exs` uses (read that test first). If the catalog already keys publisher caps by `kind: :session` (both Kinds share `type_name :session`), this test may pass immediately — in which case keep it as a regression guard and skip Step 3.

- [ ] **Step 2: Run test to verify it fails (or passes — see note)**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs:LINE`
Expected: FAIL with the publisher actions missing for SocialwareSession — UNLESS caps are `kind: :session`-keyed (then PASS; record that finding in the commit message and proceed to Task 3).

- [ ] **Step 3: Grant the publisher caps for SocialwareSession (only if Step 2 failed)**

Add `SocialwareSession` to the catalog entry that grants `subscribe_from`/`snapshot`/`history` on the publisher behavior, mirroring the existing `Ezagent.Entity.Session` grant. Follow the catalog's existing shape exactly (read the neighbouring `Ezagent.Entity.Session` grant block).

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/entity/socialware_session_publisher_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware apps/ezagent_core apps/ezagent_plugin_feishu
git commit -m "feat(socialware): P0 — publisher caps for SocialwareSession's publisher slice"
```

### Task 3: P0 acceptance gate (arch fitness + regression suites)

**Files:** none (verification task).

- [ ] **Step 1: Run the arch fitness gates**

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix ezagent.arch.scan
MIX_ENV=test mix ezagent.check_invariants
MIX_ENV=test mix ezagent.check_invariants.lifecycle
```
Expected: all exit 0.

- [ ] **Step 2: Run the regression suites that touch sessions/publisher/Feishu**

```bash
MIX_ENV=test mix test apps/ezagent_domain_instance_message/test
MIX_ENV=test mix test apps/ezagent_domain_socialware/test
MIX_ENV=test mix test apps/ezagent_domain_external_mirror/test
MIX_ENV=test mix test apps/ezagent_plugin_feishu/test
```
Expected: all green. Behavior-preserving — adding a slice must not change chat/socialware/Feishu outcomes. NOTE: the customer-SPA agent-browser visual E2E (§7) is author-owned and runs on the isolated disposable seeded stack (own ports, Tailscale `100.64.0.27`); it is NOT part of this `mix test` gate but MUST be green before the phase is declared done — flag this to the orchestrator as a human/author-driven step.

- [ ] **Step 3: Commit (only if any test-support tweaks were needed)**

```bash
git commit -am "test(socialware): P0 acceptance — arch gates + session/publisher/Feishu suites green"
```

---

## P1 — Per-instance behavior set + required-closure resolver + instance-set runtime enforcement

### Task 4: `KindBase` base behavior persists the instance set (failing test first)

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/behavior/kind_base.ex`
- Test: `apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Behavior.KindBaseTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.KindBase

  test "state_slice is :kind_base" do
    assert KindBase.state_slice() == :kind_base
  end

  test "create/1 captures the instance behavior set from a PRESENT :behaviors arg" do
    behaviors = [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface]
    assert {:ok, %{behaviors: ^behaviors}} = KindBase.create(%{behaviors: behaviors})
  end

  test "create/1 with NO :behaviors arg yields the legacy sentinel nil (NOT [])" do
    # ABSENT key → legacy static Kind → sentinel nil, so effective_set later
    # expands to the FULL declared list. It must NOT be persisted as [] (which
    # is a PRESENT empty list = base-behaviors-only).
    assert {:ok, %{behaviors: nil}} = KindBase.create(%{})
  end

  test "create/1 with an EXPLICIT empty list persists [] (distinct from the absent/nil case)" do
    # PRESENT empty list → the instance deliberately carries ONLY base behaviors.
    # This MUST be distinguishable from the absent case above (codex CRITICAL).
    assert {:ok, %{behaviors: []}} = KindBase.create(%{behaviors: []})
  end

  test "behaviors_in_slice/1 reads the captured PRESENT set from a two-container slice" do
    {:ok, st} = KindBase.create(%{behaviors: [Ezagent.Behavior.Chat]})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == [Ezagent.Behavior.Chat]
  end

  test "behaviors_in_slice/1 reads back the EXPLICIT empty list as [] (present, not sentinel)" do
    {:ok, st} = KindBase.create(%{behaviors: []})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == []
  end

  test "behaviors_in_slice/1 returns the legacy sentinel nil for the absent-args slice and missing slices" do
    # The legacy sentinel survives the round-trip: an absent-args Kind reads
    # back nil so effective_set falls back to the declared list.
    {:ok, st} = KindBase.create(%{})
    assert KindBase.behaviors_in_slice(%{state: st, transients: %{}}) == nil
    assert KindBase.behaviors_in_slice(nil) == nil
    assert KindBase.behaviors_in_slice(%{state: %{}, transients: %{}}) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`
Expected: FAIL — `Ezagent.Behavior.KindBase` undefined.

- [ ] **Step 3: Write the base behavior**

```elixir
defmodule Ezagent.Behavior.KindBase do
  @moduledoc """
  Base behavior present on every session instance under the unified
  socialware substrate. Its persistent `:kind_base` slice records the
  list of Behavior modules THIS INSTANCE was spawned with, so the runtime
  can scope every behavior enumeration + callback entry point to the
  instance's set (not the host Kind module's static superset).

  Data-only: it declares no actions. The captured set is read via
  `behaviors_in_slice/1` by `Ezagent.Kind.BehaviorSet.effective_set/2`.

  ## Legacy sentinel (codex CRITICAL)

  The captured value distinguishes two cases that MUST NOT collapse:

    * `:behaviors` ABSENT from spawn args → a legacy static Kind. We persist
      the sentinel `nil`, which `effective_set/2` expands to the FULL declared
      list (today's two static Kinds, unchanged).
    * `:behaviors` PRESENT (a list, INCLUDING the empty list `[]`) → the
      instance deliberately carries exactly that subset. We persist the list
      verbatim. An explicit `%{behaviors: []}` therefore yields ONLY the base
      behaviors — never the declared superset.

  Persisting `[]` for the absent case (the old behavior) would make an
  empty/malformed `%{behaviors: []}` indistinguishable from omitted args and,
  on a superset Kind, expand back to the full declared list — re-opening the
  §3.1 hole on first spawn AND on every reload. The `nil` sentinel closes it.

  The set is snapshotted via the standard `kind_snapshots` path, so it
  survives restart/reconcile exactly like any other slice.
  """

  use Ezagent.Lifecycle, state_slice: :kind_base

  @impl Ezagent.Lifecycle
  def create(args) do
    # ABSENT key → legacy sentinel nil (full-declared expansion downstream).
    # PRESENT list (even []) → persist it exactly.
    behaviors =
      case Map.fetch(args, :behaviors) do
        :error -> nil
        {:ok, list} when is_list(list) -> list
      end

    {:ok, %{behaviors: behaviors}}
  end

  @doc """
  Read the captured instance behavior set from this Kind's :kind_base slice.
  Returns the captured list (possibly `[]`) for an instance spawned with a
  PRESENT `:behaviors` arg, or the legacy sentinel `nil` for an absent-args
  (legacy static) instance and for missing/empty slices.
  """
  @spec behaviors_in_slice(map() | nil) :: [module()] | nil
  def behaviors_in_slice(%{state: %{behaviors: behaviors}}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(%{state: %{behaviors: nil}}), do: nil
  def behaviors_in_slice(%{behaviors: behaviors}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(%{behaviors: nil}), do: nil
  def behaviors_in_slice(_), do: nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/behavior/kind_base.ex \
        apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs
git commit -m "feat(kind): P1 — KindBase behavior persists the per-instance behavior set"
```

### Task 5: KindBase survives a snapshot round-trip (failing integration test)

**Files:**
- Test: append to `apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`

- [ ] **Step 1: Write the failing test**

This proves the set persists via `kind_snapshots`. Re-use the existing snapshot round-trip helper pattern (read `apps/ezagent_core/test/.../snapshot*test.exs` for the exact `save_now`/`load_or_init` helpers). Minimal version using the Snapshot API directly:

```elixir
  describe "snapshot round-trip" do
    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    end

    test "kind_base slice survives load_or_init after save_now" do
      uri = Ezagent.URI.session(:system, :default, :"kbtest-#{System.unique_integer([:positive])}")
      behaviors = [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface]

      # A throwaway Kind module composing only KindBase, on_change persistence.
      defmodule KBTestKind do
        @behaviour Ezagent.Kind
        @impl true
        def type_name, do: :session
        @impl true
        def behaviors, do: [Ezagent.Behavior.KindBase]
        @impl true
        def persistence, do: {:snapshot, :on_change}
        @impl true
        def supervisor, do: Ezagent.Kind.Server
      end

      fresh = Ezagent.Kind.Snapshot.load_or_init(uri, KBTestKind, %{behaviors: behaviors})
      :ok = Ezagent.Kind.Snapshot.save_now(uri, KBTestKind, fresh)

      # The persisted snapshot wins on reload; the args here are the unused
      # cold-init fallback (a snapshot already exists for this uri).
      reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, KBTestKind, %{behaviors: behaviors})
      assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == behaviors
    end
  end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`
Expected: PASS if `init_fresh` already calls `create/1` for Lifecycle behaviors and `save_now` strips transients (it does — `snapshot.ex:355`). If FAIL, the failure pinpoints the persistence wiring to fix before proceeding. (This task is a guard, not a code-change task; if green on first run, record that and continue.)

- [ ] **Step 3: (only if Step 2 failed) Fix the persistence path** per the failure, then re-run.

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs
git commit -m "test(kind): P1 — KindBase instance set survives snapshot round-trip"
```

### Task 6: `BehaviorSet.init_set/2` + `effective_set/2` + `member?/2` (failing test first)

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex`
- Test: `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`

This task introduces THREE pure functions plus a `base_behaviors/0` helper:

- `init_set/2` — computes the FIRST-spawn set from the SPAWN ARGS, PLUS the always-on `base_behaviors/0`. It distinguishes ABSENT `:behaviors` from a PRESENT list via the same legacy sentinel rule `KindBase.create/1` uses: when `:behaviors` is ABSENT → the FULL declared list (legacy static Kind); when PRESENT (even `[]`) → `(list ∩ declared)`. So `%{behaviors: []}` on a superset Kind yields ONLY `base_behaviors`, never the declared superset. Used by `init_fresh_first_spawn/2` (Task 9, the `:not_found` branch) so an out-of-set behavior's `create`/`init_slice` never runs and its slice is never created/persisted at first spawn (SPEC §3.1, codex CRITICAL finding 1).
- `effective_set/2` — computes the POST-load set from the persisted `:kind_base` slice, PLUS `base_behaviors/0`. It reads the captured value back via `KindBase.behaviors_in_slice/1`: the legacy sentinel `nil` → the FULL declared list; a PRESENT captured list (even `[]`) → `(list ∩ declared)`. Used by every runtime enumeration after load (Tasks 9–14). Symmetric with `init_set`: absent-at-spawn ⇒ sentinel `nil`-at-reload ⇒ declared; present-list-at-spawn ⇒ same-list-at-reload ⇒ that list.
- `member?/2` — set membership for the dispatch gate (Task 10).
- `base_behaviors/0` — `KindBase` + every `Ezagent.UniversalBehaviors.all/0` entry (today `Manage`); these are ALWAYS in the set so the universal `Manage` actions (`delete`/`reconfigure`) stay reachable on every instance even though `Manage` is not in any Kind's `behaviors/0` (SPEC §3.1 universal-behavior fallback policy, codex HIGH finding 2).

`init_set` and `effective_set` are kept consistent by (a) appending the same `base_behaviors/0` at both ends and (b) treating ABSENT-args (sentinel `nil`) identically as "full declared list" — so whatever `init_set` materializes at spawn is exactly what `effective_set` re-derives after reload. **Crucially, an explicit empty list `%{behaviors: []}` is NOT treated as "absent": it is a PRESENT list that intersects to nothing declared, yielding base behaviors only.** When the instance carries no `:behaviors` arg at all (today's two static Kinds), both fall back to the full declared list (+ base behaviors), preserving current runtime exactly.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Kind.BehaviorSetTest do
  use ExUnit.Case, async: true

  alias Ezagent.Kind.BehaviorSet

  defmodule SupersetKind do
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors, do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface, Ezagent.Behavior.KindBase]
    @impl true
    def persistence, do: :ephemeral
    @impl true
    def supervisor, do: Ezagent.Kind.Server
  end

  test "LEGACY sentinel (nil captured) → full declared list + base behaviors (static-Kind preservation)" do
    # ABSENT-args instance: KindBase persisted the sentinel nil.
    slice_state = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}

    # Sentinel nil → every declared behavior stays, in declaration order, then
    # the always-on base behaviors (Manage from UniversalBehaviors; KindBase
    # already declared so deduped).
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             Ezagent.Kind.behaviors_of(SupersetKind) ++ [Ezagent.Behavior.Manage]
  end

  test "EXPLICIT empty captured list ([]) → base behaviors ONLY, NOT the declared superset (codex CRITICAL)" do
    # A PRESENT empty list is NOT the legacy sentinel: it intersects to nothing
    # declared, so the effective set is exactly base_behaviors — Chat/Surface
    # (declared) must be absent.
    slice_state = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}

    assert BehaviorSet.effective_set(SupersetKind, slice_state) == BehaviorSet.base_behaviors()
    refute Ezagent.Behavior.Chat in BehaviorSet.effective_set(SupersetKind, slice_state)
    refute Ezagent.Behavior.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.Behavior.KindBase in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.Behavior.Manage in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "captured subset → (declared ∩ captured) + base behaviors, declaration order preserved" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    # Surface is dropped (out of captured set); Chat + KindBase kept in
    # declaration order; Manage appended as a universal base behavior.
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase, Ezagent.Behavior.Manage]

    refute Ezagent.Behavior.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "member?/2 reflects the effective set" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    assert BehaviorSet.member?(Ezagent.Behavior.Chat, BehaviorSet.effective_set(SupersetKind, slice_state))
    refute BehaviorSet.member?(Ezagent.Behavior.Surface, BehaviorSet.effective_set(SupersetKind, slice_state))
  end

  describe "init_set/2 (first-spawn scoping, BEFORE any slice exists)" do
    test "args :behaviors subset → declared ∩ subset, PLUS the base behaviors" do
      # A chat-only spawn on the superset Kind. init_set is what
      # `init_fresh_first_spawn` enumerates on FIRST spawn (no :kind_base slice
      # yet), so Surface's
      # create/init_slice must NEVER appear here.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.Behavior.Chat]})

      assert Ezagent.Behavior.Chat in set
      # base behaviors are always present so KindBase can persist the set and
      # Manage stays reachable (universal-by-construction).
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
      # out-of-set declared behavior is EXCLUDED — its create/init_slice must
      # not run on first spawn.
      refute Ezagent.Behavior.Surface in set
    end

    test "ABSENT :behaviors arg → full declared list, PLUS base behaviors (legacy static-Kind preservation)" do
      # No :behaviors KEY at all → legacy path → full declared list.
      set = BehaviorSet.init_set(SupersetKind, %{})
      declared = Ezagent.Kind.behaviors_of(SupersetKind)

      assert Enum.all?(declared, &(&1 in set))
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
    end

    test "EXPLICIT empty list on a SUPERSET Kind → base behaviors ONLY, never the declared superset (codex CRITICAL)" do
      # %{behaviors: []} is PRESENT-but-empty. It must NOT expand to the declared
      # superset (the bug the sentinel fixes). On first spawn this guarantees
      # Chat/Surface's create/init_slice never run.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: []})

      assert set == BehaviorSet.base_behaviors()
      refute Ezagent.Behavior.Chat in set
      refute Ezagent.Behavior.Surface in set
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
    end

    test "args :behaviors are intersected with declared (an undeclared module is ignored)" do
      set =
        BehaviorSet.init_set(SupersetKind, %{
          behaviors: [Ezagent.Behavior.Chat, Ezagent.Behavior.ApiKeys]
        })

      assert Ezagent.Behavior.Chat in set
      # ApiKeys is NOT declared by SupersetKind → must not be admitted.
      refute Ezagent.Behavior.ApiKeys in set
    end

    test "base behaviors with their own slice are NOT double-counted" do
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.Behavior.KindBase]})
      assert Enum.count(set, &(&1 == Ezagent.Behavior.KindBase)) == 1
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: FAIL — `Ezagent.Kind.BehaviorSet` undefined.

- [ ] **Step 3: Write the resolver (base_behaviors + init_set + effective_set + member? for this task)**

```elixir
defmodule Ezagent.Kind.BehaviorSet do
  @moduledoc """
  Per-instance behavior-set resolution + required/optional sibling
  closure for the unified socialware substrate (SPEC §3.1).

  Two entry points compute the instance set at different lifecycle moments:

  * `init_set/2` is called by `Snapshot.init_fresh_first_spawn/2` at FIRST
    spawn (the `:not_found` branch of `load_with_fallback/3`, fetched-first),
    BEFORE any slice (and thus any `:kind_base` slice) exists. It derives
    the set from the SPAWN ARGS, PLUS the always-on base behaviors
    (`base_behaviors/0`), using the SAME legacy-sentinel rule as
    `KindBase.create/1`: when `:behaviors` is ABSENT → the full declared
    list (legacy static Kind); when PRESENT (even the empty list `[]`) →
    `(list ∩ declared)`. So `%{behaviors: []}` on a superset Kind admits
    ONLY base behaviors, never the declared superset. `init_fresh_first_spawn`
    enumerates ONLY this set, so an out-of-set behavior's `create`/
    `init_slice` NEVER runs and its slice is NEVER created or persisted on
    first spawn (SPEC §3.1 — no "prune on next load" reliance for the
    security property).
  * `effective_set/2` is the single function every POST-LOAD runtime
    behavior enumeration calls instead of `Ezagent.Kind.behaviors_of/1`. It
    reads the captured value back from the persisted `:kind_base` slice via
    `KindBase.behaviors_in_slice/1`: the legacy sentinel `nil` (an absent-
    args instance, i.e. the two legacy static Kinds) → the FULL declared
    list (so existing Kinds are byte-for-byte unchanged); a PRESENT captured
    list (even `[]`) → the host Kind's declared behaviors INTERSECTED with
    that list, in declaration order.

  Both entry points include `base_behaviors/0` AND apply the identical
  absent-vs-present-empty distinction, so the two are symmetric: whatever
  `init_set` materializes at spawn is exactly what `effective_set` re-derives
  after reload. **An explicit `%{behaviors: []}` is NOT "absent" — it is a
  present empty list, so it can never be confused with omitted args and
  expand to the declared superset (codex CRITICAL).**
  """

  alias Ezagent.Behavior.KindBase

  # SPEC §3.1 "universal-behavior fallback policy" — behaviors that are
  # ALWAYS in the instance set regardless of the spawn-args subset:
  #
  #   * `KindBase` — owns the `:kind_base` slice that PERSISTS the set; the
  #     instance cannot record its own set without it.
  #   * every `Ezagent.UniversalBehaviors.all/0` entry (today: `Manage`) —
  #     these resolve for EVERY Kind by construction (`BehaviorRegistry`
  #     falls back to them on a per-Kind miss) and are intentionally NOT in
  #     any Kind's `behaviors/0`. They must stay reachable on every instance
  #     so `manage.delete`/`manage.reconfigure` are never denied as
  #     out-of-set (E9 finding). They are exempt from the membership gate
  #     (Task 10) AND always part of the init/effective set here.
  @doc "Behaviors always present on every instance (KindBase + UniversalBehaviors.all/0)."
  @spec base_behaviors() :: [module()]
  def base_behaviors do
    Enum.uniq([KindBase | Ezagent.UniversalBehaviors.all()])
  end

  @doc """
  The set `init_fresh_first_spawn/2` enumerates at FIRST spawn, computed from
  spawn args (no slice state yet). Declaration order preserved; base behaviors
  appended (deduped).

  Legacy-sentinel rule (codex CRITICAL): an ABSENT `:behaviors` key →
  full declared list; a PRESENT list (even `[]`) → `(list ∩ declared)`. So
  an explicit `%{behaviors: []}` is NEVER expanded to the declared superset.
  """
  @spec init_set(module(), map()) :: [module()]
  def init_set(kind_module, args) when is_atom(kind_module) and is_map(args) do
    declared = Ezagent.Kind.behaviors_of(kind_module)

    chosen =
      case Map.fetch(args, :behaviors) do
        # ABSENT key → legacy static Kind → full declared list.
        :error ->
          declared

        # PRESENT list (INCLUDING []) → intersect with declared, order-preserved.
        {:ok, list} when is_list(list) ->
          requested = MapSet.new(list)
          Enum.filter(declared, &MapSet.member?(requested, &1))
      end

    Enum.uniq(chosen ++ base_behaviors())
  end

  @doc """
  The effective behavior set for this instance, declaration order preserved.

  Legacy-sentinel rule (codex CRITICAL), symmetric with `init_set/2`: the
  captured value read back from `:kind_base` is the sentinel `nil` for an
  absent-args (legacy static) instance → full declared list; a PRESENT
  captured list (even `[]`) → `(list ∩ declared)`. An explicit captured `[]`
  is NEVER expanded to the declared superset.
  """
  @spec effective_set(module(), %{atom() => map()}) :: [module()]
  def effective_set(kind_module, slice_state) when is_atom(kind_module) and is_map(slice_state) do
    declared = Ezagent.Kind.behaviors_of(kind_module)
    captured = KindBase.behaviors_in_slice(Map.get(slice_state, :kind_base))

    chosen =
      case captured do
        # Legacy sentinel (absent-args instance, or missing slice) → declared.
        nil ->
          declared

        # PRESENT captured list (INCLUDING []) → intersect with declared.
        list when is_list(list) ->
          captured_set = MapSet.new(list)
          Enum.filter(declared, &MapSet.member?(captured_set, &1))
      end

    Enum.uniq(chosen ++ base_behaviors())
  end

  @doc "Is `behavior` a member of `effective_set`?"
  @spec member?(module(), [module()]) :: boolean()
  def member?(behavior, effective_set) when is_atom(behavior) and is_list(effective_set) do
    behavior in effective_set
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/behavior_set.ex \
        apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs
git commit -m "feat(kind): P1 — BehaviorSet.init_set/effective_set/member? resolve the per-instance set (+ universal base behaviors)"
```

### Task 7: Required/optional sibling closure resolver (failing test first)

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex`
- Test: append to `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  # A behavior that DECLARES the `:surface` slice key but is NOT the
  # registered owner (`Ezagent.Behavior.Surface`). Used to prove closure
  # is owner-MODULE based, not slice-key-presence based: a key collision
  # must NOT falsely satisfy Turn's required `:surface` dependency.
  defmodule FakeSurfaceOwner do
    use Ezagent.Lifecycle, state_slice: :surface
  end

  describe "resolve_closure/1 (required/optional siblings)" do
    test "passes when every required sibling owner is present" do
      set = [
        Ezagent.Behavior.Chat,
        Ezagent.Behavior.Turn,
        Ezagent.Behavior.Surface,
        Ezagent.Behavior.ConfigUpdate,
        Ezagent.Behavior.KindBase
      ]
      assert BehaviorSet.resolve_closure(set) == :ok
    end

    test "fails loud when a REQUIRED sibling owner is missing (Turn without Surface)" do
      set = [Ezagent.Behavior.Chat, Ezagent.Behavior.Turn, Ezagent.Behavior.KindBase]

      assert {:error, {:missing_required_siblings, missing}} = BehaviorSet.resolve_closure(set)
      assert {Ezagent.Behavior.Turn, :surface} in missing
    end

    test "a slice-key COLLISION does NOT close the set (owner-module check, not key presence)" do
      # FakeSurfaceOwner declares state_slice :surface but is NOT
      # Ezagent.Behavior.Surface — Turn's required :surface owner is still
      # ABSENT, so closure must FAIL. (Pre-fix this passed because the set
      # contributed a behavior whose state_slice/0 == :surface.)
      set = [Ezagent.Behavior.Turn, FakeSurfaceOwner, Ezagent.Behavior.KindBase]

      assert {:error, {:missing_required_siblings, missing}} = BehaviorSet.resolve_closure(set)
      assert {Ezagent.Behavior.Turn, :surface} in missing
      # The REAL owner closes it.
      ok_set = [Ezagent.Behavior.Turn, Ezagent.Behavior.Surface, Ezagent.Behavior.KindBase]
      assert BehaviorSet.resolve_closure(ok_set) == :ok
    end

    test "OPTIONAL sibling absent is OK (Chat without Sandbox — today's behavior)" do
      set = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
      assert BehaviorSet.resolve_closure(set) == :ok
    end
  end

  describe "validate_closure!/1 (raising wrapper used on the init path)" do
    test "returns the set unchanged when closed (passthrough for piping)" do
      set = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
      assert BehaviorSet.validate_closure!(set) == set
    end

    test "RAISES UnclosedSetError when a required sibling OWNER is missing" do
      set = [Ezagent.Behavior.Chat, Ezagent.Behavior.Turn, Ezagent.Behavior.KindBase]

      err =
        assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                     ~r/missing required sibling/,
                     fn -> BehaviorSet.validate_closure!(set) end

      assert {Ezagent.Behavior.Turn, :surface} in err.missing
    end

    test "RAISES UnclosedSetError on a slice-key collision (FakeSurfaceOwner ≠ Surface)" do
      set = [Ezagent.Behavior.Turn, FakeSurfaceOwner, Ezagent.Behavior.KindBase]

      err =
        assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                     ~r/missing required sibling/,
                     fn -> BehaviorSet.validate_closure!(set) end

      assert err.missing == [{Ezagent.Behavior.Turn, :surface}]
    end
  end

  describe "resolve_closure/1 (unknown required slice owner — fail loud)" do
    test "a REQUIRED key with no @slice_owners entry fails loud (resolve_closure)" do
      # Drive an unknown required key through a reader registered in
      # @required_reads with a required key absent from @slice_owners. We
      # synthesize this via a local reader so the test is independent of
      # the production maps: assert the contract on the resolver directly.
      assert {:error, {:unknown_required_slice_owner, :nonexistent_slice}} =
               BehaviorSet.resolve_closure_for(
                 [UnknownKeyReader],
                 %{UnknownKeyReader => %{nonexistent_slice: :required}},
                 %{}
               )
    end

    test "validate_closure! RAISES on an unknown required slice owner" do
      assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                   ~r/no owner module registered/,
                   fn ->
                     BehaviorSet.validate_closure_for!(
                       [UnknownKeyReader],
                       %{UnknownKeyReader => %{nonexistent_slice: :required}},
                       %{}
                     )
                   end
    end
  end

  defmodule UnknownKeyReader do
    use Ezagent.Lifecycle, state_slice: :unknown_key_reader
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: FAIL — `resolve_closure/1` / `resolve_closure_for/3` / `validate_closure!/1` / `validate_closure_for!/3` undefined (and the slice-key-collision + unknown-required-key tests cannot resolve the new owner-module rule yet).

- [ ] **Step 3: Add the slice-owner map + closure resolver**

Append to `Ezagent.Kind.BehaviorSet`:

```elixir
  # Slice-owner map: which Behavior module OWNS each slice key. Single
  # source of truth for the closure resolver. Derived from each
  # session-relevant Behavior's `state_slice/0`.
  @slice_owners %{
    chat: Ezagent.Behavior.Chat,
    turns: Ezagent.Behavior.Turn,
    surface: Ezagent.Behavior.Surface,
    config_updates: Ezagent.Behavior.ConfigUpdate,
    publisher: Ezagent.Behavior.Publisher.SessionImpl,
    sandbox: Ezagent.Behavior.Sandbox,
    api_keys: Ezagent.Behavior.ApiKeys,
    external_mirror: Ezagent.Behavior.ExternalMirror,
    kind_base: Ezagent.Behavior.KindBase
  }

  # Per-reader required-vs-optional classification of each `reads_siblings`
  # key. A key absent from a reader's entry defaults to :optional (preserves
  # the soft `%{}` default the runtime injects today — `context.ex`).
  @required_reads %{
    Ezagent.Behavior.Turn => %{surface: :required},
    Ezagent.Behavior.ConfigUpdate => %{turns: :required, chat: :required},
    Ezagent.Behavior.ExternalMirror => %{publisher: :required},
    Ezagent.Behavior.Chat => %{sandbox: :optional},
    Ezagent.Behavior.CurlAgent => %{api_keys: :optional}
  }

  @type closure_error ::
          {:missing_required_siblings, [{module(), atom()}]}
          | {:unknown_required_slice_owner, atom()}

  @doc """
  Validate a behavior set is closed under its REQUIRED sibling reads.

  Closure is checked by OWNER MODULE, not by slice-key presence: for each
  reader's REQUIRED `reads_siblings` key we look up the key's OWNING
  behavior module in `@slice_owners` and require THAT EXACT MODULE to be a
  member of the set. A different behavior that merely happens to declare
  the same `state_slice/0` key does NOT satisfy the dependency — a
  slice-key collision must never falsely close the set (otherwise a reader
  like `Turn` could initialize/dispatch against a fake/incompatible
  `:surface` owner, defeating the dependency-closed invariant).

  Fails loud ONLY on a missing required sibling OWNER; optional reads keep
  the soft `%{}` default (no failure). A required key with NO entry in
  `@slice_owners` is a programming error (a new required dep added without
  registering its owner) and fails loud with
  `{:error, {:unknown_required_slice_owner, key}}` so it can never silently
  pass closure.

  Returns `:ok` on success, or
  `{:error, {:missing_required_siblings, [{reader, key}]}}` /
  `{:error, {:unknown_required_slice_owner, key}}` on failure.
  """
  @spec resolve_closure([module()]) :: :ok | {:error, closure_error()}
  def resolve_closure(set) when is_list(set),
    do: resolve_closure_for(set, @required_reads, @slice_owners)

  @doc """
  Map-injectable core of `resolve_closure/1`. The production call passes the
  module's `@required_reads` and `@slice_owners`; tests pass synthetic maps
  to exercise the unknown-required-key branch deterministically without
  mutating the production maps. Closure is OWNER-MODULE based: a required
  key's owner module (per `slice_owners`) MUST be a set member — a mere
  slice-key collision never closes it.
  """
  @spec resolve_closure_for([module()], map(), map()) :: :ok | {:error, closure_error()}
  def resolve_closure_for(set, required_reads, slice_owners)
      when is_list(set) and is_map(required_reads) and is_map(slice_owners) do
    members = MapSet.new(set)

    required_pairs =
      for reader <- set,
          {key, :required} <- Map.to_list(Map.get(required_reads, reader, %{})),
          do: {reader, key}

    # Fail loud on a required key whose owner module is not registered in
    # slice_owners — a new required dep must declare its owner.
    unknown =
      Enum.find(required_pairs, fn {_reader, key} ->
        not Map.has_key?(slice_owners, key)
      end)

    cond do
      unknown != nil ->
        {_reader, key} = unknown
        {:error, {:unknown_required_slice_owner, key}}

      true ->
        missing =
          for {reader, key} <- required_pairs,
              owner = Map.fetch!(slice_owners, key),
              not MapSet.member?(members, owner),
              do: {reader, key}

        case missing do
          [] -> :ok
          _ -> {:error, {:missing_required_siblings, missing}}
        end
    end
  end

  @doc """
  Raising form of `resolve_closure/1`, returning the set unchanged on
  success so it can sit inline in a pipe at the init chokepoint
  (`Snapshot.init_fresh_first_spawn/2` at first spawn; also on the persisted
  effective set in the reload branch of `load_with_fallback/3`). RAISES
  `UnclosedSetError` (which aborts the spawn before any `create`/`init_slice`
  runs) when a required sibling owner is missing.

  This is the load-bearing enforcement of P1.1 (codex CRITICAL finding 1):
  the closure is checked at the SAME point the slices are about to be
  materialized, so an unclosed set NEVER reaches `init_slice` and NEVER
  persists a partial snapshot.
  """
  @spec validate_closure!([module()]) :: [module()]
  def validate_closure!(set) when is_list(set),
    do: validate_closure_for!(set, @required_reads, @slice_owners)

  @doc """
  Map-injectable raising form (production passes the module's
  `@required_reads`/`@slice_owners`; tests inject synthetic maps to drive
  the unknown-required-key branch). Raises `UnclosedSetError` on a missing
  required sibling OWNER or an unknown required slice key.
  """
  @spec validate_closure_for!([module()], map(), map()) :: [module()]
  def validate_closure_for!(set, required_reads, slice_owners)
      when is_list(set) and is_map(required_reads) and is_map(slice_owners) do
    case resolve_closure_for(set, required_reads, slice_owners) do
      :ok ->
        set

      {:error, {:missing_required_siblings, missing}} ->
        raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
          message:
            "behavior set is not closed under required sibling reads — " <>
              "missing required sibling owner(s): " <>
              Enum.map_join(missing, ", ", fn {reader, key} ->
                owner = Map.fetch!(slice_owners, key)
                "#{inspect(reader)} requires slice :#{key} (owner #{inspect(owner)})"
              end),
          missing: missing

      {:error, {:unknown_required_slice_owner, key}} ->
        # A REQUIRED reads_siblings key with no slice_owners entry is a
        # programming error (new required dep added without registering its
        # owner module). Fail loud so it can never silently pass closure.
        raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
          message:
            "behavior set closure cannot be resolved — required slice " <>
              ":#{key} has no owner module registered in @slice_owners",
          missing: [{:unknown_required_slice_owner, key}]
    end
  end

  @doc "The owning Behavior module for a slice key (or nil)."
  @spec owner_of(atom()) :: module() | nil
  def owner_of(slice_key) when is_atom(slice_key), do: Map.get(@slice_owners, slice_key)
```

Define the exception at the top of `Ezagent.Kind.BehaviorSet` (or as a sibling module in the same file). Place it ABOVE the `defmodule Ezagent.Kind.BehaviorSet do` opening so the alias `Ezagent.Kind.BehaviorSet.UnclosedSetError` resolves:

```elixir
defmodule Ezagent.Kind.BehaviorSet.UnclosedSetError do
  @moduledoc """
  Raised at `Snapshot.init_fresh_first_spawn/2` (first spawn) — and on the
  persisted effective set in the reload branch of `load_with_fallback/3` — when
  a requested/persisted instance behavior set is NOT closed under its required
  sibling reads (P1.1). Carries the `:missing` list of
  `{reader_module, missing_slice_key}` tuples. Because it is raised at the init
  chokepoint BEFORE any `init_slice`/`create` runs, the spawn aborts and NO
  partial slice is persisted.
  """
  defexception [:message, missing: []]
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/behavior_set.ex \
        apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs
git commit -m "feat(kind): P1 — required/optional sibling closure resolver + validate_closure! raising wrapper"
```

### Task 8: Test-support — superset Kind + observable probe behavior

**Files:**
- Create: `apps/ezagent_core/test/ezagent/kind/instance_set_support.ex`

This module is shared by the denial suite (Task 14). It defines a Kind whose MODULE registers a superset (`[Chat, Turn, Surface, ProbeBehavior, KindBase]`) but is spawned with a chat-only instance set, plus a `ProbeBehavior` that records when its lifecycle moments run (via a test pid registered in `:persistent_term`). **Each observable moment is hooked through the REAL overridable developer hook the `use Ezagent.Lifecycle` macro exposes — `create/1` (init/slice), `handle_signal/2` (signal), `activated/2` (on-ready), `deactivate/2` (graceful terminate), `destroy/2` (destroy) — NOT through the macro-EMITTED engine callbacks (`on_ready/2`, `terminate/3`, `__ezagent_lifecycle_destroy__/3`, …), which are not overridable and would not compile if redefined (codex HIGH finding 2; verified against lifecycle.ex:288-302 — the `defoverridable` list is exactly `create:1, activate:2, deactivate:2, destroy:2, activated:2, handle_signal:2`).**

**Why the superset declares `Turn` (codex HIGH finding — closure-denial fixture).** The closure-denial test in Task 9 requests an UNCLOSED set (`Turn` without `Surface`). Because `init_set/2` intersects the requested list with the Kind's DECLARED list (`Enum.filter(declared, …)`), the requested `Turn` is dropped BEFORE `validate_closure!/1` runs unless the host Kind ALSO declares `Turn`. If `Turn` is dropped, the residual set (`[Chat, KindBase]`) is trivially closed (`Chat → :sandbox` is OPTIONAL), so `UnclosedSetError` would NEVER be raised and the closure path would never be exercised (the `refute_received {:probe, :init_slice}` would be vacuous). Declaring `Turn` here makes the requested `Turn` survive the ∩-declared intersection so the closure genuinely fails on Turn's REQUIRED `:surface` sibling. We use the REAL `Ezagent.Behavior.Turn` (`use Ezagent.Lifecycle, state_slice: :turns`; `reads_siblings, do: [:surface]` — verified at `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex:11,80`), and `@required_reads` (Task 7) already classifies `Turn => %{surface: :required}`.

- [ ] **Step 1: Write the support module**

```elixir
defmodule Ezagent.Kind.InstanceSetSupport do
  @moduledoc false

  defmodule ProbeBehavior do
    @moduledoc false
    use Ezagent.Lifecycle, state_slice: :probe

    # `description:` is REQUIRED for clean cap-subject registration:
    # `CapabilityRegistry.register/3` reads `cap_subjects/0` (auto-derived
    # from each action's `:description`) — see behavior.ex:753. Without a
    # description the auto-derived subject carries `""`, which registers
    # but is undocumented; give it a real string.
    action(:poke,
      args: %{},
      returns: %{},
      caps: [:poke],
      modes: [:call],
      description: "test-only probe action that records when it is dispatched"
    )

    # IMPORTANT (codex HIGH finding 2): `use Ezagent.Lifecycle` EMITS the
    # engine callbacks `on_ready/2`, `terminate/3`, `post_init/2`,
    # `handle_continue/3`, `handle_kind_message/3` and
    # `__ezagent_lifecycle_destroy__/3` — these are NOT in the macro's
    # `defoverridable` list (verified lifecycle.ex:288-302), so DEFINING
    # them directly is a compile error ("def ... already defined") and the
    # probe would never wire. The ONLY overridable developer hooks are
    # `create/1`, `activate/2`, `deactivate/2`, `destroy/2`, `activated/2`,
    # `handle_signal/2` (lifecycle.ex:290-302). We therefore observe each
    # lifecycle moment through its REAL developer hook, which the macro
    # routes to the corresponding engine callback (mapping table,
    # lifecycle.ex:24-33):
    #
    #   * on-ready observation → `activated/2`  (→ engine `on_ready/2`)
    #   * terminate observation → `deactivate/2` (→ engine graceful `terminate/3`)
    #   * destroy observation  → `destroy/2`    (→ engine `__ezagent_lifecycle_destroy__/3`)
    #   * signal observation   → `handle_signal/2` (→ engine `handle_kind_message/3`)
    #   * init/create observation → `create/1`   (→ engine `init_slice/1`)

    @impl Ezagent.Lifecycle
    def create(_args) do
      notify(:init_slice)
      {:ok, %{poked: false}}
    end

    def handle_poke(_args, _ctx) do
      notify(:handle_poke)
      {:ok, %{}, [{:set, :poked, true}]}
    end

    @impl Ezagent.Lifecycle
    def handle_signal(_msg, _ctx) do
      notify(:handle_signal)
      :ignore
    end

    # on_ready observation via the OVERRIDABLE `activated/2` developer hook
    # (the macro emits engine `on_ready/2`, which calls this — lifecycle.ex:31,284).
    @impl Ezagent.Lifecycle
    def activated(_state, _ctx) do
      notify(:on_ready)
      :ok
    end

    # terminate observation via the OVERRIDABLE `deactivate/2` developer hook
    # (the macro emits engine `terminate/3`, which calls this on the graceful
    # path — lifecycle.ex:29,258).
    @impl Ezagent.Lifecycle
    def deactivate(_reason, _ctx) do
      notify(:terminate)
      :ok
    end

    # destroy observation via the OVERRIDABLE `destroy/2` developer hook
    # (the macro emits engine `__ezagent_lifecycle_destroy__/3`, which calls
    # this on the explicit-destroy path — lifecycle.ex:30,267).
    @impl Ezagent.Lifecycle
    def destroy(_reason, _ctx) do
      notify(:destroy)
      :ok
    end

    defp notify(event) do
      case :persistent_term.get({__MODULE__, :probe_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:probe, event})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule SupersetSessionKind do
    @moduledoc false
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors do
      [
        Ezagent.Behavior.Chat,
        # Turn is DECLARED (but NOT spawned into the chat-only instance set)
        # so the closure-denial test (Task 9) can REQUEST `Turn` and have it
        # survive `init_set/2`'s ∩-declared intersection — otherwise Turn is
        # dropped before `validate_closure!/1` and `UnclosedSetError` is never
        # raised (codex HIGH). Turn `reads_siblings :surface :required`.
        Ezagent.Behavior.Turn,
        Ezagent.Behavior.Surface,
        Ezagent.Kind.InstanceSetSupport.ProbeBehavior,
        Ezagent.Behavior.KindBase
      ]
    end
    @impl true
    def persistence, do: {:snapshot, :on_change}

    # CRITICAL (codex HIGH finding 3): `supervisor/0` must return a RUNNING
    # DynamicSupervisor, because `Ezagent.Kind.spawn/2` passes
    # `kind_module.supervisor()` straight into
    # `DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, ...})`
    # (verified kind.ex:300-301 + resolve_supervisor/1 kind.ex:635-641).
    # Returning `Ezagent.Kind.Server` here (the CHILD module, not a
    # supervisor) makes EVERY `Kind.spawn(SupersetSessionKind, ...)` in
    # Tasks 10-13 fail before the gate is ever exercised. Reuse the existing
    # dedicated test DynamicSupervisor `Ezagent.LifecycleCase.gate_supervisor()`
    # (a named singleton started idempotently by
    # `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`, verified
    # lifecycle_case.ex:47-48,117-151) — the SAME opt-in pattern the
    # cold-restart GATE Kinds use. The denial suite calls
    # `ensure_gate_supervisor!/0` in its setup (Task 9) before any spawn.
    @impl true
    def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
  end
end
```

NOTE TO IMPLEMENTER: confirm `ProbeBehavior`'s `:probe` slice key isn't in `@slice_owners` — that's fine; ProbeBehavior is test-only and declares no required reads. Register the probe pid with `:persistent_term.put({ProbeBehavior, :probe_pid}, self())` in each denial test's setup.

**Dispatch registration is NOT automatic for a test-only Kind.** Dispatch resolves the behavior for `{kind_module, action}` via `Ezagent.BehaviorRegistry.lookup/2` (behavior_registry.ex:48) — it does NOT scan `SupersetSessionKind.behaviors/0`. Production Kinds register at app boot via their plugin/domain `Application.start/2`; a test-only Kind has no such hook, so the E9 dispatch test (Task 10) MUST register `{SupersetSessionKind, :poke} → ProbeBehavior` itself, through the SINGLE canonical chokepoint `Ezagent.CapabilityRegistry.register/3` (capability_registry.ex:82 — `BehaviorRegistry.register/3` is `@doc false` and forbidden in production code outside that module; the `single_capability_registration_entry_test.exs` invariant covers production, but tests should still use the canonical entry to exercise the real wiring). `register/3` reads `ProbeBehavior.cap_subjects/0` (auto-derived from the `:poke` action above) and inserts into BOTH the subjects table AND `BehaviorRegistry` (because `ProbeBehavior` is dispatchable). The exact setup calls live in Task 10. `Manage` needs NO such registration — it is universal-by-construction and resolves via `BehaviorRegistry.lookup/2`'s fallback to `UniversalBehaviors.behavior_for_action/1` (behavior_registry.ex:58).

- [ ] **Step 2: Compile to verify the support module is valid**

Run: `MIX_ENV=test mix compile`
Expected: compiles (no warnings-as-errors needed yet).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/test/ezagent/kind/instance_set_support.ex
git commit -m "test(kind): P1 — superset Kind + observable probe behavior support"
```

### Task 9 (E8 + E6 + E7 + P1.1 closure): Snapshot init/prune/reconcile through the instance set — FIRST-spawn scoped + closure-enforced

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:52-66` (`load_or_init` `:ephemeral`/`:external` arms → `init_fresh_first_spawn`), `:68-127` (`load_with_fallback` — RESTRUCTURE: fetch FIRST, branch first-spawn vs reload, SEED legacy `:kind_base` on reload), `:135-144` (`prune_orphan_slices`), `:162-174` (`reconcile_after_load_behaviors`), `:532-538` (`init_fresh` → `init_fresh_first_spawn` + new `init_fresh_for_set` + new `seed_legacy_kind_base`).

**The deploy-safety fix (codex CRITICAL — legacy-snapshot data loss).** A snapshot WRITTEN BEFORE P1 has NO `:kind_base` slice (KindBase did not exist), but DOES carry real persisted declared slices (e.g. `:chat`, `:surface`). On reload, the effective-set derivation reads `:kind_base` back — for a legacy row that key is ABSENT. If the reload branch let the args-driven `init_fresh_for_set(effective, args)` create a `:kind_base` recording the CURRENT reload `args[:behaviors]` (which it could whenever `ever_created?(args)` resolves false for the supplied args — e.g. args lacking or carrying a mismatched `:uri`), a narrower reload (`%{behaviors: []}` or a subset) would persist that subset as the captured set; the very NEXT reload would read it back and `prune_orphan_slices/2` would DROP every previously-persisted declared slice not in those args — silent data loss / version skew for live prod sessions. The fix SEEDS `:kind_base` with the LEGACY SENTINEL `nil`, INDEPENDENT of reload args, the instant a `:kind_base`-less (pre-P1) snapshot is loaded — so a legacy instance behaves exactly like a legacy static Kind (sentinel nil → full DECLARED list, nothing pruned), and reload args can NEVER re-drive it. Only a snapshot that ALREADY has `:kind_base` (post-P1) lets its persisted captured set drive the effective set.

**The security-critical fix (codex CRITICAL finding 1) — TWO coupled defects, one structural cause.** In the REAL source `load_with_fallback/3` computes `fresh = init_fresh(kind_module, args)` at its FIRST line (`snapshot.ex:70`), BEFORE `fetch_snapshot/2` reads the persisted row (`snapshot.ex:72`). Putting `init_set/2` + `validate_closure!/1` + slice creation inside `init_fresh/2` would therefore run the SPAWN-ARGS set's closure + `init_slice`/`create` on EVERY restart of an already-persisted instance, BEFORE the persisted `:kind_base` is ever read:

1. **First-spawn defect:** on a `:not_found` first spawn `init_fresh`'s result is returned directly (`snapshot.ex:111`) and persisted by `Kind.Server.persist_initial_snapshot/3` BEFORE any restart. If `init_fresh` enumerated the module's *declared superset*, a first spawn of a chat-only instance on a superset Kind would run Surface/Probe `create`/`init_slice` AND persist `:surface`/`:probe` slices — violating SPEC §3.1. The "materialize all, prune on NEXT load" approach is WRONG for the security property.
2. **Reload defect:** even with `init_fresh` scoped to `init_set/2`, running it UP FRONT means a fallback-args set drives slice creation/validation on reload before the persisted set is read — a closed-but-wrong fallback set can `init_slice`/create an out-of-set behavior, and an unclosed fallback set can crash a valid persisted instance with `UnclosedSetError`. Violates SPEC §3.1 across restart/reconcile.

The fix is structural (see Step 3): **fetch the persisted snapshot FIRST, then branch.** First-spawn (`:not_found`) → `init_fresh_first_spawn/2` runs `init_set/2` + `validate_closure!/1` + `init_slice` from SPAWN ARGS (the §3.1 first-spawn guard) — for a PRESENT `:behaviors` list the spawn-args subset (∩ declared), for an ABSENT key the full declared list (legacy), in both cases PLUS the always-on base behaviors; a requested set like `[Turn]` without `Surface` (Turn `reads_siblings :surface :required`) raises `UnclosedSetError` and aborts the spawn before a single `init_slice`/`create` runs and strictly before `persist_initial_snapshot/3` — no partial slice ever lands. Reload (`{:ok, loaded}`) → the effective set is derived from the PERSISTED `:kind_base` slice (`effective_set/2`, NOT spawn args), THAT set is closure-validated, and its members are init'd as the `fresh` baseline via `init_fresh_for_set/2` (persisted slices' fresh values are immediately overwritten by the loaded-state merge; only newly-added behaviors keep their fresh value — the Q5 contract); spawn args never re-drive creation of an out-of-set behavior's slice, and a bogus reload `args` can never crash a valid persisted instance. KindBase is in `base_behaviors/0`, so the captured set is always written; the universal `Manage` is always present; out-of-set behaviors NEVER appear at first spawn OR on reload. Critically, the sentinel rule means an explicit `%{behaviors: []}` on a superset Kind admits ONLY base behaviors at first spawn — it is NOT mistaken for omitted args and expanded to the declared superset (codex CRITICAL); the same holds after reload because `KindBase.create/1` persisted `[]` (a present list), not the legacy `nil`.

`prune_orphan_slices` and `reconcile_after_load_behaviors` run AFTER the reload branch merged the loaded `:kind_base` into state, so they use `effective_set/2` (which reads the persisted set back). They are a defense-in-depth + cross-version-migration layer (drop a slice whose behavior left the set between two boots), NOT the primary first-spawn guard — which is `init_fresh_first_spawn` in the `:not_found` branch.

- [ ] **Step 1: Write the failing tests (first-spawn denial + reload prune + reload-scoping + unclosed-fails-loud + bogus-reload-survives)**

```elixir
# in apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs (created here, extended in Task 14)
defmodule Ezagent.Kind.InstanceSetDenialTest do
  use ExUnit.Case, async: false

  alias Ezagent.Kind.InstanceSetSupport.{SupersetSessionKind, ProbeBehavior}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    # codex HIGH finding 3: SupersetSessionKind.supervisor/0 returns the
    # dedicated test DynamicSupervisor `Ezagent.LifecycleCase.gate_supervisor()`.
    # It must be RUNNING before any `Ezagent.Kind.spawn(SupersetSessionKind, …)`
    # in Tasks 10-13 (spawn does `DynamicSupervisor.start_child(supervisor, …)`
    # — kind.ex:300-301). `ensure_gate_supervisor!/0` is idempotent: it starts
    # the named singleton once per BEAM and is a no-op thereafter
    # (lifecycle_case.ex:117-151).
    Ezagent.LifecycleCase.ensure_gate_supervisor!()

    :persistent_term.put({ProbeBehavior, :probe_pid}, self())
    on_exit(fn -> :persistent_term.erase({ProbeBehavior, :probe_pid}) end)
    :ok
  end

  test "FIRST spawn: out-of-set behavior NEVER runs create/init_slice and NEVER creates its slice (E8, no prior snapshot)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-firstinit-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    # No save_now first — this is the cold, never-before-seen instance.
    # The :not_found branch runs init_fresh_first_spawn (scoped to
    # init_set(args)) so ProbeBehavior is absent from the materialized state
    # BEFORE any restart/prune.
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    # ProbeBehavior's create/init_slice must NOT have run (no :probe slice,
    # and its `notify(:init_slice)` never fired).
    refute Map.has_key?(fresh, :probe)
    refute_received {:probe, :init_slice}
    # Surface is out of set → no :surface slice on first spawn.
    refute Map.has_key?(fresh, :surface)
    # Chat (in set) IS present; KindBase (base behavior) carries the set.
    assert Map.has_key?(fresh, :chat)
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(fresh[:kind_base]) == chat_only
  end

  test "reload prune: a slice for a now-out-of-set behavior is dropped on load (E6/E7 defense-in-depth)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-init-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    # Materialize the captured set (save_now), then reload.
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    # NOTE: the captured set persisted by save_now wins on reload; the args
    # here are only the cold-init fallback (unused because a snapshot exists).
    reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
  end

  test "RELOAD derives the set from the PERSISTED :kind_base, NOT spawn args: out-of-set behavior never init/created; only missing persisted-set slices re-materialize (E8 reload, codex CRITICAL finding 1)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-reload-scope-#{System.unique_integer([:positive])}")

    # Persist a chat-only instance (the persisted :kind_base captures [Chat, KindBase]).
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    # Drain any probe signals from the first spawn, then reload with a WRONG,
    # broader spawn-args fallback that includes ProbeBehavior + Surface. Because
    # the load path now fetches the persisted row FIRST and derives the set from
    # the persisted :kind_base (NOT these args), the out-of-set ProbeBehavior /
    # Surface must NEVER run create/init_slice and must NEVER appear in state.
    receive do
      {:probe, _} -> :ok
    after
      0 -> :ok
    end

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [
          Ezagent.Behavior.Chat,
          Ezagent.Behavior.Surface,
          ProbeBehavior,
          Ezagent.Behavior.KindBase
        ]
      })

    # Spawn-args did NOT re-drive slice creation: no out-of-set slices, no probe init.
    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    refute_received {:probe, :init_slice}
    # The persisted set's slices ARE present; the effective set re-derived from
    # the persisted :kind_base is exactly chat-only + base behaviors.
    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only

    assert Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded) ==
             Enum.uniq(chat_only ++ Ezagent.Kind.BehaviorSet.base_behaviors())
  end

  test "RELOAD with BOGUS/unclosed spawn args does NOT crash a VALID persisted instance (E8 reload, codex CRITICAL finding 1)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-reload-bogus-#{System.unique_integer([:positive])}")

    # Persist a VALID, closed chat-only instance.
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    # Reload supplying a BOGUS, UNCLOSED args set (Turn without Surface). The
    # OLD (buggy) load order would run init_set/validate_closure! on THESE args
    # BEFORE reading the persisted :kind_base and crash with UnclosedSetError.
    # The fixed order validates the PERSISTED effective set (closed), so the
    # reload SUCCEEDS and the instance stays chat-only.
    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.Behavior.Turn]
      })

    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    refute Map.has_key?(reloaded, :turns)
    refute Map.has_key?(reloaded, :surface)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only
  end

  test "LEGACY (pre-P1) snapshot reload: a :kind_base-less row keeps ALL declared slices; reload args do NOT prune; :kind_base seeded as legacy sentinel (codex CRITICAL — data-loss hole)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-legacy-#{System.unique_integer([:positive])}")

    # Hand-write a LEGACY snapshot row: real declared slices (chat + surface),
    # NO :kind_base slice — exactly the shape a snapshot written BEFORE P1 has
    # (KindBase did not exist then). save_now persists this state verbatim
    # (after stripping transients); mark_ever_created mirrors a real legacy row.
    legacy_state = %{
      chat: %{state: %{members: %{}, last_message_id: nil}, transients: %{}},
      surface: %{state: %{versions: []}, transients: %{}}
    }

    :ok =
      Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, legacy_state,
        mark_ever_created: true
      )

    # Reload with a NARROWER present arg (%{behaviors: [Chat]}). The OLD (buggy)
    # path could let these args drive a :kind_base recording [Chat], so the NEXT
    # reload would prune :surface — silent data loss. The fix seeds :kind_base
    # with the legacy sentinel nil INDEPENDENT of args → effective_set = full
    # declared list → nothing pruned.
    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.Behavior.Chat]
      })

    # BOTH legacy declared slices survive (NOT pruned by the narrower arg).
    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :surface)

    # :kind_base was seeded as the LEGACY sentinel (nil), so the effective set
    # is the FULL declared list (+ base behaviors), NOT the [Chat] arg subset.
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == nil

    declared = Ezagent.Kind.behaviors_of(SupersetSessionKind)
    effective = Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded)
    assert Enum.take(effective, length(declared)) == declared

    # Re-persist (the legacy row now carries the seeded sentinel :kind_base) and
    # reload AGAIN — the declared slices STILL survive and :kind_base reads back
    # as sentinel nil (the migration is durable, never re-drives off args).
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, reloaded)

    reloaded2 =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    assert Map.has_key?(reloaded2, :chat)
    assert Map.has_key?(reloaded2, :surface)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded2[:kind_base]) == nil
  end

  test "FIRST spawn with EXPLICIT empty list: NO declared behavior runs create/init_slice, ONLY base slices materialize (E8, codex CRITICAL)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-emptyinit-#{System.unique_integer([:positive])}")

    # %{behaviors: []} is PRESENT-but-empty. The sentinel rule means init_set
    # must NOT expand it to the declared superset — so Chat/Surface/Probe
    # create/init_slice must NEVER run, and ONLY base behaviors (KindBase +
    # Manage) materialize. This is the exact hole codex flagged.
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    refute Map.has_key?(fresh, :probe)
    refute Map.has_key?(fresh, :surface)
    refute Map.has_key?(fresh, :chat)
    refute_received {:probe, :init_slice}
    # KindBase (base behavior) is always present and captured the explicit [].
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(fresh[:kind_base]) == []
  end

  test "RELOAD with EXPLICIT empty list: the captured [] is read back as base-only, NOT re-expanded to declared (E8 reload, codex CRITICAL)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-emptyreload-#{System.unique_integer([:positive])}")

    # First spawn with %{behaviors: []}, persist, then reload — the round-trip
    # must keep the instance at base-only. KindBase persisted [] (a PRESENT
    # list), NOT the legacy nil sentinel, so effective_set re-derives base-only,
    # never the declared superset.
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    refute Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == []
    # The effective set re-derived after reload is exactly base behaviors.
    assert Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded) ==
             Ezagent.Kind.BehaviorSet.base_behaviors()
  end

  test "FIRST spawn with an UNCLOSED set (Turn without Surface) FAILS LOUD and persists NO partial slice (P1.1, codex CRITICAL/HIGH)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-unclosed-#{System.unique_integer([:positive])}")

    uri_str = URI.to_string(uri)

    # Turn `reads_siblings :surface :required` (verified turn.ex:80). The
    # requested set DECLARES Turn but OMITS Surface → an unclosed set.
    #
    # CRITICAL FIXTURE POINT (codex HIGH): Turn is also in
    # `SupersetSessionKind.behaviors/0` (Task 8), so `init_set/2`'s
    # ∩-declared intersection KEEPS the requested Turn — it is NOT dropped
    # before `validate_closure!/1`. (If the host Kind did NOT declare Turn,
    # the intersection would strip Turn, the residual set would be trivially
    # closed, and this test would be VACUOUS.) Surface is deliberately
    # NEITHER requested NOR — for the purpose of this set — relied on, so
    # Turn's REQUIRED `:surface` sibling owner is missing and the closure
    # MUST fail.
    #
    # ProbeBehavior is included as the OBSERVABLE requested behavior: its
    # `create`/`init_slice` calls `notify(:init_slice)`. The assertion
    # `refute_received {:probe, :init_slice}` is therefore NON-vacuous —
    # it proves `validate_closure!/1` raised BEFORE ANY requested behavior's
    # `init_slice`/`create` ran. (Surface is intentionally excluded from the
    # requested list to keep the set unclosed.)
    unclosed = [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Turn,
      ProbeBehavior,
      Ezagent.Behavior.KindBase
    ]

    err =
      assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError, fn ->
        Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: unclosed})
      end

    # The error names the EXACT unmet closure edge — Turn's required :surface
    # — proving the failure exercised the closure path, not some other guard.
    assert err.missing == [{Ezagent.Behavior.Turn, :surface}]
    assert err.message =~ "Turn"
    assert err.message =~ "surface"

    # No init_slice ran for ANY requested behavior — the observable probe
    # never fired (non-vacuous: ProbeBehavior IS in the requested set above).
    refute_received {:probe, :init_slice}

    # NO partial snapshot row was persisted (the raise aborts before any
    # DB write). `kind_snapshots`' primary key IS the URI string
    # (`@primary_key {:uri, :string}` — kind_snapshot.ex:24), so a direct
    # `Repo.get/2` by URI must return nil.
    assert is_nil(EzagentCore.Repo.get(Ezagent.Ecto.KindSnapshot, uri_str))
  end

  test "FIRST spawn with an OPTIONAL read missing still SUCCEEDS (Chat without Sandbox → soft %{})" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-optclosed-#{System.unique_integer([:positive])}")

    # Chat `reads_siblings :sandbox :optional` — a missing OPTIONAL sibling
    # must NOT fail the closure; init proceeds with the soft `%{}` default.
    set = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: set})

    assert Map.has_key?(fresh, :chat)
    assert Map.has_key?(fresh, :kind_base)
  end
end
```

NOTE TO IMPLEMENTER: the no-partial-persist assertion is written against `KindSnapshot`'s primary key `:uri` (`@primary_key {:uri, :string}`, kind_snapshot.ex:24), which is what `fetch_snapshot/2` (snapshot.ex:191) queries by. If the schema's keying changes, update the `Repo.get/2` call accordingly — the PROPERTY under test is "no `kind_snapshots` row exists for this URI after the failed spawn." Use `Ezagent.Kind.Snapshot.load_or_init/3` (NOT `Ezagent.Kind.spawn/2`) for this closure test so the raise surfaces synchronously in the test process; a full `spawn` would surface it as a `{:stop, ...}` GenServer crash (also acceptable, but harder to assert the no-row property against without `Process.flag(:trap_exit, true)`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: FAIL — the first-spawn test fails because today's `init_fresh` enumerates the declared superset, so `:probe`/`:surface` slices are created and `notify(:init_slice)` fires. The reload-prune test fails because `prune_orphan_slices` prunes against the MODULE's declared list (keeps `:surface`/`:probe`). The reload-scoping test (derive set from persisted `:kind_base`, not args) fails because today's load path materializes `fresh` from spawn-args up front. The bogus-reload-survives test fails (or never gets a chance to assert) because the up-front `init_fresh` would run `validate_closure!` on the bogus `[Turn]` args and crash a valid persisted instance. The LEGACY-snapshot migration test fails because today there is no `seed_legacy_kind_base/1` (and no `BehaviorSet`/`KindBase` at all) — the `:kind_base`-less legacy row has nowhere to read the set from, and once P1's resolver exists without the seeding, the narrower reload arg drives a captured set that prunes `:surface` on the second reload. The unclosed-set FIRST-spawn test fails because today's `init_fresh` never calls `validate_closure!/1` — so a `[Turn]`-without-`Surface` set is materialized (no raise) and a partial snapshot persists. The optional-read test currently passes trivially (no closure gate yet) and locks the "optional missing is OK" property once the gate exists.

- [ ] **Step 3: Restructure the load path — fetch the persisted set FIRST; scope first-spawn vs reload; re-point prune/reconcile at the effective set**

**The load-order bug (codex CRITICAL finding 1).** In the REAL source, `load_with_fallback/3` computes `fresh = init_fresh(kind_module, args)` at its VERY FIRST line (`snapshot.ex:70`), BEFORE `fetch_snapshot/2` reads the existing row (`snapshot.ex:72`). If we put `init_set/2` + `validate_closure!/1` + `init_slice` INSIDE `init_fresh/2`, then on EVERY restart of an already-persisted instance the load would (a) re-derive the set from the SPAWN-ARGS fallback (NOT the persisted `:kind_base`), (b) validate THAT spawn-args set, and (c) run `init_slice`/`create` for it — ALL before the persisted `:kind_base` slice is read. Two concrete failures:
- A closed-but-WRONG fallback-args set (e.g. a reload supplying `%{behaviors: [Chat, Surface]}` for an instance that persisted chat-only) would run Surface's `create`/`init_slice` (an out-of-set behavior) before the persisted set is consulted — violating SPEC §3.1 across restart/reconcile.
- An UNCLOSED fallback-args set (e.g. a reconcile path re-spawning with stale `%{behaviors: [Turn]}`) would raise `UnclosedSetError` and CRASH a perfectly valid persisted instance whose stored set was closed.

So the fix is structural: **fetch the persisted snapshot FIRST, then branch on its presence.** The first-spawn closure + scoping live in the `:not_found` branch (true first spawn, driven by spawn args); the reload branch derives the set from the PERSISTED `:kind_base` slice (`effective_set/2`), validates THAT set, and materializes ONLY the missing slices belonging to it — spawn args never re-drive slice creation on reload.

Rewrite `load_with_fallback/3` (`snapshot.ex:68-127`) so the fetch is FIRST and `init_fresh` is gated to the `:not_found` branch. `init_fresh/2` is renamed `init_fresh_first_spawn/2` to make the gating explicit (it is now reachable ONLY from `:not_found` and from the no-DB `:ephemeral`/`:external` paths in `load_or_init/3`, which are first-spawn-every-time by definition):

```elixir
  defp load_with_fallback(uri, kind_module, args) do
    uri_str = uri_to_str(uri)

    # CRITICAL (codex finding 1): fetch the persisted row FIRST. We do NOT
    # compute init_fresh up-front any more — running init_set/validate_closure!
    # /init_slice from SPAWN ARGS before the persisted :kind_base is read would
    # let a fallback-args set create out-of-set slices (or crash a valid
    # persisted instance with an unclosed fallback set) on every restart.
    case fetch_snapshot(uri_str, kind_module) do
      :not_found ->
        # TRUE first spawn — no persisted row. The set is driven by spawn args
        # (init_set/2), closure-validated, and ONLY that set's slices are
        # created. This is the §3.1 first-spawn guard.
        init_fresh_first_spawn(kind_module, args)

      {:ok, loaded_state} ->
        emit_restored(uri_str, loaded_state)
        # SPEC 2026-05-27-uri-canonicalization §9.2.1 (OQ-4 option b) —
        # canonicalize embedded %URI{} structs BEFORE the merge.
        canonicalized = canonicalize_uris(loaded_state)

        # LEGACY-SNAPSHOT MIGRATION (codex CRITICAL — data-loss hole). A
        # snapshot WRITTEN BEFORE P1 has NO `:kind_base` slice (KindBase did
        # not exist). We MUST seed `:kind_base` with the LEGACY SENTINEL `nil`
        # — INDEPENDENT of the reload args — BEFORE deriving the effective set,
        # so a pre-P1 instance behaves exactly like a legacy static Kind
        # (sentinel nil → full DECLARED list) and the reload args can NEVER
        # re-drive its set. Without this seeding, the args-driven
        # `init_fresh_for_set(effective, args)` below could (depending on
        # whether `ever_created?(args)` resolves false for the supplied args —
        # e.g. args without/with a mismatched `:uri`) run `KindBase.create/1`
        # against the CURRENT reload args and persist a `:kind_base` recording
        # `args[:behaviors]`; the very NEXT reload would then read that
        # captured set back and `prune_orphan_slices/2` would DROP every
        # previously-persisted declared slice not in those args — silent
        # data loss / version skew for existing prod sessions. Seeding the
        # sentinel here makes the legacy path deterministic and arg-free.
        canonicalized = seed_legacy_kind_base(canonicalized)

        # Reload scoping (codex finding 1): the effective set is derived from
        # the PERSISTED :kind_base slice (now ALWAYS present — either the real
        # post-P1 captured value, or the legacy sentinel seeded just above),
        # NOT the spawn args. Validate THAT set (a persisted set that was
        # closed at first spawn stays closed; a legacy sentinel → full declared
        # list, which is closed by construction since the Kind compiled — if a
        # code deploy made a previously-closed persisted set unclosed, failing
        # loud here is correct, operator must fix the Kind), then build the
        # `fresh` baseline by init_slice'ing ONLY that set's members (NOT the
        # module superset, NOT a spawn-args set). For members the snapshot
        # already owns, the fresh value is immediately overwritten by the
        # Map.merge(loaded) below (loaded wins — same as the original code);
        # for newly-added behaviors the fresh value is kept (the Q5 contract).
        # `init_fresh_for_set/2` does NOT validate closure again (validated just
        # above on `effective`) and is scoped to the persisted effective set, so
        # an out-of-set behavior's init_slice/create NEVER runs on reload.
        effective = Ezagent.Kind.BehaviorSet.effective_set(kind_module, canonicalized)
        _ = Ezagent.Kind.BehaviorSet.validate_closure!(effective)
        fresh = init_fresh_for_set(effective, args)

        fresh
        |> Map.merge(coerce_loaded_to_fresh_shape(fresh, canonicalized))
        |> prune_orphan_slices(kind_module)
        |> reconcile_after_load_behaviors(uri, kind_module)

      {:error, reason} ->
        # A row EXISTS but is unloadable (version mismatch / decode failure).
        # Fail loud — never reset to fresh over a good-but-unreadable row
        # (blocker #2 cold-restart wipe). UNCHANGED from the existing source.
        raise "Ezagent.Kind.Snapshot: refusing to initialize #{uri_str} as fresh " <>
                "over an EXISTING but unloadable snapshot (#{inspect(reason)}) — " <>
                "this would wipe durable state on the initial persist (blocker #2)"
    end
  end
```

Replace `init_fresh/2` (`snapshot.ex:532`) with the renamed first-spawn function PLUS a shared set-scoped initializer. `init_fresh_first_spawn/2` carries the §3.1 first-spawn guard (init_set + validate_closure! + init_slice from spawn args); `init_fresh_for_set/2` is the closure-already-validated worker that init_slice's exactly the given set (used by both the first-spawn path after validation and the reload path on the persisted effective set):

```elixir
  # FIRST-spawn slice materialization. Reachable ONLY from load_with_fallback/3's
  # :not_found branch and from load_or_init/3's no-DB :ephemeral/:external paths
  # (first-spawn-every-time by construction). Enumerates ONLY
  # BehaviorSet.init_set/2 (spawn-args subset ∩ declared, + base behaviors)
  # and FAILS LOUD on an unclosed set BEFORE any init_slice/create runs or any
  # slice is persisted (P1.1, codex CRITICAL). validate_closure!/1 returns the
  # (unchanged) set on success so the pipe continues; on a missing REQUIRED
  # sibling it raises UnclosedSetError → load_or_init → Kind.Server.init/1
  # returns {:stop, ...} → persist_initial_snapshot/3 is NEVER reached → no
  # partial slice row lands.
  defp init_fresh_first_spawn(kind_module, args) do
    kind_module
    |> Ezagent.Kind.BehaviorSet.init_set(args)
    |> Ezagent.Kind.BehaviorSet.validate_closure!()
    |> init_fresh_for_set(args)
  end

  # Init_slice exactly `set` (already closure-validated by the caller). Used on
  # BOTH the first-spawn path (after init_set + validate) AND the reload path
  # (on the PERSISTED effective set). On reload, members the snapshot already
  # owns get a fresh value here that the caller's Map.merge(loaded) immediately
  # overwrites (loaded wins — identical to the original merge semantics);
  # newly-added behaviors keep their fresh value (the Q5 contract). An
  # out-of-set behavior is never in `set`, so its init_slice/create NEVER runs
  # — at first spawn OR on reload.
  defp init_fresh_for_set(set, args) do
    set
    |> Enum.map(fn behavior -> {behavior.state_slice(), behavior.init_slice(args)} end)
    |> Map.new()
  end

  # LEGACY-SNAPSHOT MIGRATION (codex CRITICAL — data-loss hole). Called on the
  # reload branch BEFORE deriving the effective set. A snapshot WRITTEN BEFORE
  # P1 has NO `:kind_base` slice (KindBase did not exist). Seed it with the
  # LEGACY SENTINEL `nil` — INDEPENDENT of the reload args — so:
  #
  #   * `effective_set/2` reads the seeded slice back via
  #     `KindBase.behaviors_in_slice/1` as the sentinel `nil` (the
  #     `%{state: %{behaviors: nil}}` clause, kind_base.ex), → the FULL
  #     DECLARED list, so NO previously-persisted declared slice is pruned;
  #   * the seeded slice carries the two-container shape KindBase persists, so
  #     the next `:on_change` save (`save_now` strips transients) writes
  #     `%{behaviors: nil}` back, and every future reload re-reads sentinel nil
  #     — the legacy instance stays "full declared", arg-free, forever.
  #
  # A snapshot that ALREADY has `:kind_base` (written post-P1) is returned
  # UNCHANGED — its real captured value (a present list, including `[]`, or a
  # sentinel nil) drives the effective set. This is the deploy-safety guarantee
  # for existing prod sessions: reload args can NEVER re-drive a legacy
  # instance's behavior set.
  defp seed_legacy_kind_base(loaded_state) do
    kind_base_key = Ezagent.Behavior.KindBase.state_slice()

    if Map.has_key?(loaded_state, kind_base_key) do
      loaded_state
    else
      Map.put(loaded_state, kind_base_key, %{state: %{behaviors: nil}, transients: %{}})
    end
  end
```

Update `load_or_init/3`'s `:ephemeral` and `:external` arms (`snapshot.ex:54,58`) to call `init_fresh_first_spawn/2` (the rename — these paths have no persistence and are first-spawn-every-time, so the spawn-args set + closure is correct):

```elixir
      :ephemeral ->
        init_fresh_first_spawn(kind_module, args)

      :external ->
        # Plugin author's init_slice/1 reads from foreign system; don't touch DB.
        init_fresh_first_spawn(kind_module, args)
```

**Why this is correct (verified against the real code):** the persisted-set-on-reload contract from SPEC §3.1 is now realized in the LOAD ORDER itself. (1) On a `:not_found` first spawn (`fetch_snapshot` → `:not_found`), `init_fresh_first_spawn/2`'s result is returned directly and is what `Kind.Server.init/1` (`server.ex:110`) persists via `persist_initial_snapshot/3` (`server.ex:156`) — the closure + scoping ran on the SPAWN-ARGS set before any slice or DB write. (2) On a `{:ok, loaded}` reload, the effective set is derived from the PERSISTED `:kind_base` slice (`effective_set/2`), closure-validated, and only its MISSING slices are initialized; spawn args never re-drive creation of an out-of-set or already-persisted slice, and a bogus reload `args` cannot crash a valid persisted instance (closure runs on the persisted effective set, not on args). (3) The `{:error, _}` blocker-#2 fail-loud path is UNCHANGED.

In `prune_orphan_slices/2` (`snapshot.ex:135`), change the kept-set computation to the effective set (defense-in-depth on reload):

```elixir
  defp prune_orphan_slices(state, kind_module) do
    kept =
      Ezagent.Kind.BehaviorSet.effective_set(kind_module, state)
      |> Enum.map(& &1.state_slice())
      |> MapSet.new()
      # KindBase's own slice must never be pruned — it carries the set.
      |> MapSet.put(:kind_base)

    state
    |> Enum.filter(fn {key, _} -> MapSet.member?(kept, key) end)
    |> Map.new()
  end
```

In `reconcile_after_load_behaviors/3` (`snapshot.ex:163`), iterate the effective set instead of `behaviors_of`:

```elixir
  defp reconcile_after_load_behaviors(state, %URI{} = uri, kind_module) do
    Enum.reduce(Ezagent.Kind.BehaviorSet.effective_set(kind_module, state), state, fn behavior, acc ->
      slice_key = behavior.state_slice()
      slice_value = Map.get(acc, slice_key)

      if function_exported?(behavior, :reconcile_after_load, 2) and not is_nil(slice_value) do
        Map.put(acc, slice_key, behavior.reconcile_after_load(uri, slice_value))
      else
        acc
      end
    end)
  end
```

NOTE TO IMPLEMENTER: `init_set/2` works at FIRST spawn with NO slice state (it reads `args[:behaviors]`, not `:kind_base`) and is called ONLY from `init_fresh_first_spawn/2` in the `:not_found` (+ `:ephemeral`/`:external`) paths. `effective_set/2` works after load (it reads the persisted `:kind_base`) and drives the ENTIRE reload branch: effective-set derivation, closure re-validation, `init_fresh_for_set/2`, prune, and reconcile. Both append the same `base_behaviors/0`, so for a given spawn-args subset the first-spawn materialized set and the post-reload effective set are identical — the prune step is therefore a no-op on the happy path and only drops slices when the persisted set shrinks (e.g. a code deploy removed a declared behavior — a real orphan). KindBase is always present in both, so `:kind_base` is never pruned and the captured set always survives. CRITICAL: do NOT reintroduce an up-front `fresh = init_fresh(args)` at the top of `load_with_fallback/3` — the fetch MUST come first so spawn-args never drive slice creation/validation on reload (codex finding 1). EQUALLY CRITICAL (codex CRITICAL legacy-data-loss): `seed_legacy_kind_base/1` MUST run on the reload branch BEFORE `effective_set/2`, so a pre-P1 snapshot (no `:kind_base`) gets the legacy sentinel `nil` seeded INDEPENDENT of reload args — otherwise the args-driven `init_fresh_for_set` could materialize a `:kind_base` from `args[:behaviors]` (whenever `ever_created?(args)` is false for the supplied args) and the next reload would prune the legacy declared slices. The seed runs on the ALREADY-canonicalized loaded state; a snapshot that already has `:kind_base` (post-P1) is returned unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS (both the first-spawn denial test and the reload-prune test).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/snapshot.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E6/E7/E8 + closure) — init_fresh scopes to init_set AND validate_closure! at FIRST spawn (no out-of-set create/slice, unclosed set fails loud with no partial persist); reload seeds legacy :kind_base sentinel (no data loss for pre-P1 snapshots); prune/reconcile use the effective set"
```

### Task 10 (E9): Dispatch + caps gate through the instance set — with universal-behavior exemption

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/runtime.ex:172-189` (insert a membership gate in the `with` chain).

**The exemption (codex HIGH finding 2).** `lookup_behavior/2` falls back to `Ezagent.UniversalBehaviors.behavior_for_action/1` (`behavior_registry.ex:58`) for any `{kind, action}` with no per-Kind registration. `UniversalBehaviors.all/0` = `[Ezagent.Behavior.Manage]` — intentionally NOT in any Kind's `behaviors/0` (it resolves for every Kind by construction, #533 §3.4). So `manage.delete`/`manage.reconfigure` resolve to `Manage`, which would NOT be a member of any per-Kind instance set — and a naive membership gate would wrongly deny them as `:behavior_not_in_instance_set`. The gate must therefore **exempt every `UniversalBehaviors.all/0` entry from the membership check** (they are always reachable on every instance) while STILL leaving the normal cap check (`authz_check`) to gate them. Only NON-universal behaviors are subject to instance-set membership.

NOTE: `base_behaviors/0` already folds `UniversalBehaviors.all()` into `effective_set/2`, so membership alone would pass for `Manage` today. The explicit exemption below is the load-bearing contract per SPEC §3.1's "universal-behavior fallback policy" — it makes the policy robust independent of whether `base_behaviors/0` happens to include them, and self-documents WHY `Manage` bypasses the gate. Do NOT rely on the implicit `base_behaviors/0` inclusion alone.

- [ ] **Step 1: Write the failing tests (deny non-universal, allow universal)**

First, add a `setup_all` to `instance_set_denial_test.exs` that registers `ProbeBehavior.:poke` against `SupersetSessionKind` through the SINGLE canonical chokepoint. This is the REAL dispatch wiring — without it, `BehaviorRegistry.lookup(SupersetSessionKind, :poke)` returns `:error` (dispatch resolves by registry, NOT by scanning `behaviors/0`), and the denial test would fail with `{:error, :unknown_action}` / unroutable BEFORE ever reaching the new instance-set gate (codex MEDIUM finding 2). Place this `setup_all` once at the top of the module (Task 9 created the file; this block is added here):

```elixir
  # append near the top of Ezagent.Kind.InstanceSetDenialTest (module-level
  # setup_all — registers the test-only Kind's dispatch entry through the
  # canonical chokepoint exactly as production does at app boot).
  setup_all do
    Code.ensure_loaded!(SupersetSessionKind)
    Code.ensure_loaded!(ProbeBehavior)

    # SupersetSessionKind is test-only and not registered at app boot.
    # Register {SupersetSessionKind, :poke} → ProbeBehavior via the SINGLE
    # canonical entry (CapabilityRegistry.register/3, capability_registry.ex:82),
    # which reads ProbeBehavior.cap_subjects/0 and inserts into BOTH the
    # subjects table AND BehaviorRegistry (ProbeBehavior is dispatchable).
    # Idempotent — guarded so repeated runs don't conflict.
    if Ezagent.BehaviorRegistry.lookup(SupersetSessionKind, :poke) == :error do
      :ok = Ezagent.CapabilityRegistry.register(SupersetSessionKind, :poke, ProbeBehavior)
    end

    # Sanity: the canonical registration actually wired the dispatch lookup.
    assert {:ok, ProbeBehavior} = Ezagent.BehaviorRegistry.lookup(SupersetSessionKind, :poke)
    :ok
  end
```

```elixir
# append to instance_set_denial_test.exs

  # STEP (a) — BEFORE relying on the gate: prove the registry wiring is REAL by
  # dispatching :poke on an instance whose set INCLUDES ProbeBehavior; it must
  # REACH the handler. This guards against a false-green denial test that would
  # "pass" only because :poke was never registered (codex MEDIUM finding 2).
  test "dispatch wiring is real: :poke REACHES the handler on a full-set instance (E9 control)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-probe-ok-#{System.unique_integer([:positive])}")
    # Instance set INCLUDES ProbeBehavior → it IS a member → gate must pass.
    full = [Ezagent.Behavior.Chat, ProbeBehavior, Ezagent.Behavior.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: full})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=probe.poke")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: Ezagent.Entity.User.admin_uri(), caps: admin_caps(), reply: :ignore}
    })

    # The handler MUST have run — proving {SupersetSessionKind, :poke} resolves
    # via the real registry, so a later denial is the GATE, not a missing entry.
    assert_received {:probe, :handle_poke}
  end

  # STEP (b) — the actual gate: same registered :poke, but on a chat-only
  # instance (ProbeBehavior NOT in the set, and NOT universal) → DENIED.
  test "dispatch: a NON-universal out-of-set behavior action is DENIED (E9)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-disp-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    # ProbeBehavior.:poke is REGISTERED on SupersetSessionKind (setup_all above,
    # via the canonical path), and the control test proved it reaches the
    # handler when in-set. Here the instance set is chat-only and ProbeBehavior
    # is NOT universal → the membership gate denies it.
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=probe.poke")

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{},
        ctx: %{caller: Ezagent.Entity.User.admin_uri(), caps: admin_caps(), reply: :ignore}
      })

    assert {:error, :behavior_not_in_instance_set} = result
    # The handler must NOT have run.
    refute_received {:probe, :handle_poke}
  end

  test "dispatch: the UNIVERSAL Manage behavior still dispatches on a subset instance (E9 exemption)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-mng-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    # Manage is universal-by-construction (NOT in any Kind's behaviors/0, and
    # NOT registered per-Kind). It resolves via BehaviorRegistry.lookup/2's
    # fallback to UniversalBehaviors.behavior_for_action/1 (behavior_registry.ex:58)
    # — that real universal registration is what makes it reachable here, NOT a
    # per-Kind entry. The membership gate must EXEMPT it, so dispatch reaches
    # authz_check, NOT the :behavior_not_in_instance_set denial.
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=manage.delete")

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{},
        ctx: %{caller: Ezagent.Entity.User.admin_uri(), caps: admin_caps(), reply: :ignore}
      })

    # The exact success/error shape is owned by Manage + authz; the ONLY thing
    # this test asserts is that the instance-set gate did NOT short-circuit it.
    refute match?({:error, :behavior_not_in_instance_set}, result)
  end

  defp admin_caps, do: Ezagent.SystemPrincipal.caps("system://bootstrap")
```

NOTE TO IMPLEMENTER:
- **Registry wiring is the load-bearing fix here (codex MEDIUM).** The `setup_all` above registers `{SupersetSessionKind, :poke} → ProbeBehavior` through the real canonical path `Ezagent.CapabilityRegistry.register/3` (verified signature `register(kind, action, behavior)` — capability_registry.ex:82), guarded by `BehaviorRegistry.lookup/2 == :error` exactly like `lifecycle_test.exs:36-39` does. The control test (step a) dispatches `:poke` on a FULL-set instance and asserts `{:probe, :handle_poke}` is received — proving the entry is real, so the denial (step b) is unambiguously the GATE, not a missing registration. Do NOT hand-insert into `BehaviorRegistry` directly; use the canonical entry.
- **Manage uses its REAL universal registration**, not an assumed per-Kind entry. `manage.delete` resolves via `BehaviorRegistry.lookup/2`'s fallback to `UniversalBehaviors.behavior_for_action/1` (verified: `UniversalBehaviors.all/0 == [Ezagent.Behavior.Manage]`, universal_behaviors.ex:26-39). No setup registration is needed for it — that fallback IS the wiring under test.
- **`admin_caps/0`**: bind to whatever the existing dispatch tests in `apps/ezagent_core/test` use to construct admin caps; the helper above is the documented bootstrap shape (`kind.ex:288`). For the Manage test, `admin_caps()` must be a principal that holds the `Manage`/`:delete` cap for this instance — read an existing `manage.delete` dispatch test (e.g. `apps/ezagent_domain_instance_message/test/integration/manage_behavior_test.exs`) for the exact cap shape; if the bootstrap caps don't cover `manage.delete`, the `refute match?({:error, :behavior_not_in_instance_set}, result)` assertion still holds (an `:unauthorized` from authz proves the gate let it through, which is the property under test). For the probe control test (step a), `admin_caps()` must cover `probe.poke` so dispatch reaches the handler; if the bootstrap caps don't, register a per-instance grant for `{ProbeBehavior, :poke}` in that test's setup using the same cap helper the dispatch tests use.

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: with `setup_all` now registering `{SupersetSessionKind, :poke}` through the canonical path, the control test (step a) PASSES today — `:poke` resolves via the real registry and reaches the handler (this proves the wiring before the gate exists). The NON-universal denial test (step b) FAILS — currently `:poke` resolves and runs, returning `:ok` instead of `{:error, :behavior_not_in_instance_set}` (no gate yet). The Manage exemption test passes trivially today (no gate), but is the regression that locks the exemption once the gate exists.

- [ ] **Step 3: Insert the instance-set membership gate (with universal exemption)**

In `handle_dispatch/4` (`runtime.ex:172`), add a gate immediately after `lookup_behavior` and before `authz_check`. The `with` chain becomes:

```elixir
    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <- lookup_behavior(kind_module, action),
         :ok <- instance_set_gate(behavior_module, kind_module, state),
         :ok <- authz_check(kind_module, behavior_module, action, target, enriched_ctx),
         # ... rest unchanged
```

Add the private gate:

```elixir
  # P1 (SPEC §3.1, E9) — even though the BehaviorRegistry resolves an
  # action by {kind_module, action} (module-keyed), a NON-universal behavior
  # must be in THIS INSTANCE's effective set to act. A chat instance on a
  # superset SessionKind cannot dispatch a Surface/ProbeBehavior action.
  #
  # Universal-behavior fallback policy (SPEC §3.1): behaviors in
  # `Ezagent.UniversalBehaviors.all/0` (today `Ezagent.Behavior.Manage`)
  # resolve for EVERY Kind by construction and are intentionally NOT in any
  # Kind's `behaviors/0`. They are ALWAYS reachable, so the membership gate
  # EXEMPTS them — the subsequent `authz_check` still cap-gates them.
  defp instance_set_gate(behavior_module, kind_module, state) do
    cond do
      behavior_module in Ezagent.UniversalBehaviors.all() ->
        :ok

      Ezagent.Kind.BehaviorSet.member?(
        behavior_module,
        Ezagent.Kind.BehaviorSet.effective_set(kind_module, state)
      ) ->
        :ok

      true ->
        :telemetry.execute([:ezagent, :authz, :denied], %{}, %{
          kind_module: kind_module,
          behavior_module: behavior_module,
          reason: :behavior_not_in_instance_set
        })

        {:error, :behavior_not_in_instance_set}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS — the non-universal `:poke` is denied; `manage.delete` is NOT denied by the gate (reaches authz).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/runtime.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E9) — dispatch denies out-of-set behaviors; exempts universal Manage"
```

### Task 11 (E4): Mailbox `handle_signal` path through the instance set

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex:740-772` (`handle_info/2` → `forward_to_behavior`).

- [ ] **Step 1: Write the failing test**

```elixir
# append to instance_set_denial_test.exs
  test "signal: an out-of-set behavior does NOT run handle_signal/handle_kind_message (E4)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-sig-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    # Send a raw mailbox message that ProbeBehavior.handle_signal would react to.
    send(pid, {:some_signal, :payload})
    # Allow the message to be processed.
    _ = :sys.get_state(pid)

    refute_received {:probe, :handle_signal}
  end
```

NOTE TO IMPLEMENTER: `ProbeBehavior` exposes `handle_signal/2` (Lifecycle) which is routed through `forward_to_behavior` via the macro-injected `handle_kind_message/3`. Confirm against `lifecycle.ex` how `handle_signal` is wired to `handle_kind_message` — if the macro names it differently, assert on the actual injected callback. The behavior-set gate must wrap whichever callback `forward_to_behavior` probes.

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs:LINE`
Expected: FAIL — `handle_info/2` iterates `behaviors_of(kind_module)` (the superset), so ProbeBehavior runs.

- [ ] **Step 3: Re-point handle_info at the effective set**

In `handle_info/2` (the catch-all clause, `server.ex:740`), change the enumeration:

```elixir
  def handle_info(message, %{kind: kind_module, uri: self_uri, state: slice_state} = wrapper) do
    new_slice_state =
      Ezagent.Kind.BehaviorSet.effective_set(kind_module, slice_state)
      |> Enum.reduce(slice_state, fn behavior, acc_state ->
        forward_to_behavior(behavior, message, acc_state, kind_module, self_uri)
      end)

    _ = persist_handle_info_mutation(self_uri, kind_module, slice_state, new_slice_state)
    {:noreply, %{wrapper | state: new_slice_state}}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/server.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E4) — mailbox handle_signal path uses the instance set"
```

### Task 12 (E5 + E3): terminate + lifecycle-destroy through the instance set

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex:893-923` (`drain_behavior_terminates`), `:577-610` (`handle_call({:ezagent_lifecycle_destroy, …})`).

- [ ] **Step 1: Write the failing test**

```elixir
# append to instance_set_denial_test.exs
  test "terminate: an out-of-set behavior does NOT run its terminate hook (E5)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-term-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    refute_received {:probe, :terminate}
  end

  test "destroy: an out-of-set behavior does NOT run its destroy hook (E3)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-dstr-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    :ok = GenServer.call(pid, {:ezagent_lifecycle_destroy, :test})

    refute_received {:probe, :destroy}
  end
```

NOTE TO IMPLEMENTER (codex HIGH finding 2): do NOT define the macro-emitted engine callbacks (`terminate/3`, `__ezagent_lifecycle_destroy__/3`) on ProbeBehavior — they are emitted by `use Ezagent.Lifecycle` and are NOT overridable (lifecycle.ex:288-302), so redefining them fails to compile. ProbeBehavior already observes both moments through its OVERRIDABLE developer hooks (Task 8): the E5 graceful-stop path (`GenServer.stop(pid, :normal)` → engine `terminate/3` → `__run_deactivate__` → `deactivate/2`, lifecycle.ex:258-260) fires `notify(:terminate)` from `deactivate/2`; the E3 explicit-destroy path (`{:ezagent_lifecycle_destroy, :test}` → engine `__ezagent_lifecycle_destroy__/3` → `__run_destroy__` → `destroy/2`, lifecycle.ex:267-269) fires `notify(:destroy)` from `destroy/2`. The denial assertions `refute_received {:probe, :terminate}` / `{:probe, :destroy}` therefore observe through the real hooks, no extra wiring in Task 8 needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs:LINE`
Expected: FAIL — both hooks iterate `behaviors_of(kind_module)`.

- [ ] **Step 3: Re-point both at the effective set**

In `drain_behavior_terminates/4` (`server.ex:893`), change `Enum.each(Ezagent.Kind.behaviors_of(kind_module), …)` to `Enum.each(Ezagent.Kind.BehaviorSet.effective_set(kind_module, slice_state), …)`.

In `handle_call({:ezagent_lifecycle_destroy, reason}, _from, state)` (`server.ex:577`), change `Enum.each(Ezagent.Kind.behaviors_of(kind_module), …)` to `Enum.each(Ezagent.Kind.BehaviorSet.effective_set(kind_module, slice_state), …)` (`slice_state` is already destructured in that clause).

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/server.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs \
        apps/ezagent_core/test/ezagent/kind/instance_set_support.ex
git commit -m "feat(kind): P1 (E3/E5) — terminate + destroy hooks use the instance set"
```

### Task 13 (E1 + E2 + E7-runtime): post_init, on_ready, reconcile-at-boot through the instance set

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex:265-280` (`collect_post_init_queue`), `:514-544` (`run_on_ready_hooks`).

`collect_post_init_queue/3` runs at `init/1` time and receives `slice_state` (already loaded), so `effective_set` works. `run_on_ready_hooks/3` receives `slice_state` too. (E7 reconcile already done in Task 9; the boot-time call path goes through Snapshot.load_or_init, covered there.)

- [ ] **Step 1: Write the failing test**

```elixir
# append to instance_set_denial_test.exs
  test "on_ready: an out-of-set behavior does NOT run on_ready (E2)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-ready-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    _ = :sys.get_state(pid)

    refute_received {:probe, :on_ready}
    # init_slice ran for in-set behaviors only — ProbeBehavior must not have init'd.
    refute_received {:probe, :init_slice}
  end
```

NOTE TO IMPLEMENTER: after the Task 9 fix, the `:not_found` branch runs `init_fresh_first_spawn/2` which enumerates ONLY `BehaviorSet.init_set/2` (the spawn-args subset + base behaviors), so ProbeBehavior's `init_slice`/`create` NEVER runs — even on this FIRST spawn with no prior snapshot. The `refute_received {:probe, :init_slice}` assertion is therefore deterministic with no save_now-first dance: the probe pid is registered in `setup` (before `spawn`) and the in-line spawn here is the instance's only load. (This is the runtime counterpart of Task 9's first-spawn denial test — same guarantee, exercised through the live `Kind.spawn` → `Kind.Server.init/1` path.)

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs:LINE`
Expected: FAIL — `run_on_ready_hooks` and `collect_post_init_queue` iterate the superset.

- [ ] **Step 3: Re-point both at the effective set**

In `collect_post_init_queue/3` (`server.ex:265`): change `Ezagent.Kind.behaviors_of(kind_module)` to `Ezagent.Kind.BehaviorSet.effective_set(kind_module, slice_state)` (`slice_state` is the 3rd arg).

In `run_on_ready_hooks/3` (`server.ex:514`): change `Enum.each(Ezagent.Kind.behaviors_of(kind_module), …)` to `Enum.each(Ezagent.Kind.BehaviorSet.effective_set(kind_module, slice_state), …)` (`slice_state` is the 3rd arg).

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/server.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E1/E2) — post_init + on_ready use the instance set"
```

### Task 14 (E10): `hosts_lifecycle?` instance-aware + static-Kind parity

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/lifecycle.ex:394-402`.
- Read first: `apps/ezagent_core/lib/ezagent/kind/server.ex:148-154` (the `init/1` caller of `hosts_lifecycle?/1`).

`init/1` calls `hosts_lifecycle?(kind_module)` to set `create_freshness`. With a superset Kind, an instance whose set has no Lifecycle behavior would be mis-classified. Add an arity-2 variant taking the slice_state; keep `/1` for callers without slice context.

NOTE ON BASE BEHAVIORS: `effective_set/2` always appends `base_behaviors/0` = `KindBase` + `UniversalBehaviors.all()` (`Manage`). BOTH `use Ezagent.Lifecycle`, so they export `__ezagent_lifecycle_destroy__/3`. Therefore `hosts_lifecycle?/2` returns `true` for ANY composed instance — which is correct: every instance carries KindBase (a Lifecycle behavior), so every instance genuinely hosts a Lifecycle and has the create/activate marker semantics. This is not a mis-classification; it is the consequence of KindBase being a universal base. The arity-2 variant exists so the metadata is computed from the instance set (not the raw module list) for symmetry with every other E1–E9 entry point, not because a real instance could ever be non-Lifecycle.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ezagent_core/test/ezagent/lifecycle_hosts_test.exs
defmodule Ezagent.LifecycleHostsTest do
  use ExUnit.Case, async: true
  alias Ezagent.Kind.InstanceSetSupport.SupersetSessionKind

  test "hosts_lifecycle?/2 reflects the instance set, not the module superset" do
    # Instance set = only a NON-lifecycle behavior would be false; here use a
    # set with KindBase (a Lifecycle behavior) → true.
    lc_set = %{kind_base: %{state: %{behaviors: [Ezagent.Behavior.KindBase]}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, lc_set)

    # Legacy sentinel (nil captured) → falls back to declared list (still has Lifecycle).
    full = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, full)

    # Explicit empty list → base-only, but KindBase (base) is a Lifecycle
    # behavior, so hosts_lifecycle? is STILL true (correct, not a fallback).
    base_only = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, base_only)
  end

  test "hosts_lifecycle?/1 unchanged for static callers" do
    assert Ezagent.Lifecycle.hosts_lifecycle?(Ezagent.Entity.Session) ==
             Ezagent.Lifecycle.hosts_lifecycle?(Ezagent.Entity.Session)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/lifecycle_hosts_test.exs`
Expected: FAIL — `hosts_lifecycle?/2` undefined.

- [ ] **Step 3: Add the arity-2 variant**

```elixir
  @spec hosts_lifecycle?(module()) :: boolean()
  def hosts_lifecycle?(kind_module) when is_atom(kind_module) do
    kind_module
    |> Ezagent.Kind.behaviors_of()
    |> any_lifecycle?()
  end

  @spec hosts_lifecycle?(module(), %{atom() => map()}) :: boolean()
  def hosts_lifecycle?(kind_module, slice_state) when is_atom(kind_module) and is_map(slice_state) do
    kind_module
    |> Ezagent.Kind.BehaviorSet.effective_set(slice_state)
    |> any_lifecycle?()
  end

  defp any_lifecycle?(behaviors) do
    Enum.any?(behaviors, fn behaviour ->
      Code.ensure_loaded?(behaviour) and
        function_exported?(behaviour, :__ezagent_lifecycle_destroy__, 3)
    end)
  end
```

Then in `Kind.Server.init/1` (`server.ex:149`), change `Ezagent.Lifecycle.hosts_lifecycle?(kind_module)` to `Ezagent.Lifecycle.hosts_lifecycle?(kind_module, slice_state)` (`slice_state` is bound at `server.ex:110`).

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/lifecycle_hosts_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/lifecycle.ex apps/ezagent_core/lib/ezagent/kind/server.ex \
        apps/ezagent_core/test/ezagent/lifecycle_hosts_test.exs
git commit -m "feat(kind): P1 (E10) — hosts_lifecycle? is instance-set-aware"
```

### Task 15: Static-Kind parity — chat Session unchanged at runtime under the new path (REAL chat send + join)

**Files:**
- Test: `apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs`
- Read first: `apps/ezagent_domain_instance_message/test/integration/chat_routing_test.exs` — this task's chat send + join flow is copied/adapted from it (the live-dispatch path through the boot-time `session://system/default/main` Session).

Proves the two legacy Kinds (which spawn without a `:behaviors` arg → legacy sentinel `nil` captured → declared-list fallback) behave identically: the effective set is the full declared list (+ universal base behaviors), and a REAL `chat.send` + `chat.join` round-trip through `Ezagent.Invocation.dispatch` (the same path the new instance-set gate sits on) is unchanged. This is the behavior-preservation gate for the static Kind — it must EXERCISE chat, not assert a placeholder.

- [ ] **Step 1: Write the test (real dispatch flow — no placeholders)**

The second test is adapted directly from `chat_routing_test.exs` (`use EzagentCore.DataCase`, the idempotent `SessionCreator.create_session` setup, the bootstrap caps, the `chat.join` then `chat.send` dispatch, and the `:chat_message` broadcast + `MessageStore` assertions). It joins a transient member, sends a message, and asserts BOTH the session-level broadcast and the slice mutation landed — proving dispatch + join are unchanged under the instance-set path.

```elixir
defmodule Ezagent.SessionInstanceSetTest do
  # Non-async + EzagentCore.DataCase: shares the live boot-time Session
  # GenServer + EzagentCore.Repo (the P6 drain-live-kinds teardown applies),
  # mirroring chat_routing_test.exs which drives the same Session.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.{Session, User}

  setup do
    # session://system/default/main is a DynamicSupervisor child spawned once
    # at chat-app boot; ensure it via the idempotent facade (adopts the live
    # Session if already running) — same pattern as chat_routing_test.exs.
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "main",
        User.admin_uri(),
        template_name: "default"
      )

    :ok
  end

  test "chat Session's effective set = full declared list + universal base behaviors (no :behaviors arg)" do
    slice_state = %{}  # no :kind_base captured → fallback to declared (+ base)
    declared = Ezagent.Kind.behaviors_of(Ezagent.Entity.Session)

    effective = Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Session, slice_state)

    # Every declared behavior is preserved, in declaration order.
    assert Enum.take(effective, length(declared)) == declared
    # The universal Manage (not in behaviors/0) is appended as a base behavior.
    assert Ezagent.Behavior.Manage in effective
  end

  test "REAL chat join + send round-trips through dispatch on the default Session (unchanged)" do
    session_uri = Session.default_uri()
    sender = User.admin_uri()
    bootstrap_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    # --- chat.join: add a transient member through dispatch ---
    member_uri =
      URI.new!("entity://team-alpha/user/parity-#{System.unique_integer([:positive])}")

    {:ok, member_pid} = GenServer.start(__MODULE__.NoopMember, member_uri)
    on_exit(fn -> if Process.alive?(member_pid), do: GenServer.stop(member_pid) end)

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: bootstrap_caps, reply: :ignore}
      })

    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: joined_slice}}} = :sys.get_state(session_pid)
    assert joined_slice.members[member_uri].online == true

    # --- chat.send: broadcast + store + slice mutation ---
    session_topic = Chat.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    msg =
      Message.new(sender, %{text: "parity-send #{System.unique_integer()}", attachments: []})

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{caller: sender, caps: bootstrap_caps, reply: :ignore}
      })

    # Session-level broadcast fired (LV chat stream path).
    assert_receive {:chat_message, _session_uri, %Message{id: received_id}}, 500
    assert received_id == msg.id

    # Message landed in the store.
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.session_uri == session_uri

    # Slice mutation persisted (serialize through the GenServer to drain the commit).
    %{state: %{chat: %{state: post_send_slice}}} = :sys.get_state(session_pid)
    assert post_send_slice.last_message_id == msg.id

    # Cleanup — leave the transient member.
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.leave"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: bootstrap_caps, reply: :ignore}
      })
  end

  defmodule NoopMember do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      # Self-register so KindRegistry.lookup returns OUR pid (Registry registers
      # the calling process as owner) — mirrors chat_routing_test.exs's NoopServer.
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end
  end
end
```

ACCEPTANCE: reject any `assert true` / placeholder in this file. The second test MUST drive `chat.join` + `chat.send` (+ `chat.leave` cleanup) through `Ezagent.Invocation.dispatch` and assert the `:chat_message` broadcast, the `MessageStore` row, and the slice `last_message_id` — exactly as `chat_routing_test.exs` does. If any symbol drifted (`session_events_topic/1`, `MessageStore.by_id/1`, `SessionCreator.create_session/3`), bind to the live name read from `chat_routing_test.exs` rather than inventing one.

- [ ] **Step 2: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs`
Expected: PASS (both tests).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs
git commit -m "test(kind): P1 — static chat Session unchanged under instance-set path (real chat send+join)"
```

### Task 16: P1 acceptance gate (arch fitness + full regression suites + denial suite)

**Files:** none (verification task).

- [ ] **Step 1: Run the arch fitness gates**

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix ezagent.arch.scan
MIX_ENV=test mix ezagent.check_invariants
MIX_ENV=test mix ezagent.check_invariants.lifecycle
```
Expected: all exit 0. (Watch invariant 18 — sibling reads are still opt-in; the new required/optional layer is additive, not an `:all_slices` escape hatch.)

- [ ] **Step 2: Run the denial suite + the regression suites**

```bash
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
MIX_ENV=test mix test apps/ezagent_core/test
MIX_ENV=test mix test apps/ezagent_domain_instance_message/test
MIX_ENV=test mix test apps/ezagent_domain_socialware/test
MIX_ENV=test mix test apps/ezagent_domain_external_mirror/test
MIX_ENV=test mix test apps/ezagent_plugin_feishu/test
```
Expected: all green. The regression set covers chat send/receive/join (`ezagent_domain_instance_message`), the socialware three-phase + surface/settlement/customer-visibility suites, external_mirror/Feishu, and the cold-restart respawn round-trip — all MUST stay green (behavior-preserving). The denial suite proves an instance WITHOUT `Surface` cannot (a) dispatch a Surface action, (b) init/prune a `:surface` slice, (c) run a Surface signal hook, (d) run a Surface terminate/destroy hook — per SPEC §3.1.

- [ ] **Step 3: Run the customer-SPA E2E (author-owned, disposable stack)**

This is the agent-browser visual E2E + the leak / wake-up-loss / parent-commit-rollback acceptance tests from §7 — owned by the plan author on the isolated disposable seeded stack (own ports, Tailscale `100.64.0.27`, never shared dev `:10042`/prod). NOTE: this is a HUMAN/AUTHOR-driven step, not a `mix test` line. Flag to the orchestrator: P1 cannot be declared done until the customer-SPA E2E is green on the disposable stack. (P1 changes no customer-feed code, so this is a regression check that the instance-set rework did not perturb the existing SPA path.)

- [ ] **Step 4: Commit any test-support adjustments**

```bash
git commit -am "test(kind): P1 acceptance — arch gates + denial suite + full regression green"
```

---

## What is NOT in this plan (separate plans, one per phase)

- **P2 — Unified View contract** (includes E11 `auto_derive.ex` re-pointing at the instance set for the operator display).
- **P2.5 — Wire-schema regularization + durable committed customer-delivery outbox** (subsumes #44; MUST precede P3).
- **P3 — ExternalAdapter (generalize ExternalMirror + fold CustomerFeed).**
- **P4 — chat external SPA view.**
- **P5 — collapse to one session Kind.** Explicitly DEPENDS on P1's instance-set runtime enforcement — the collapse is only safe because dispatch/lifecycle/caps are instance-set-driven (this plan). **P1 must land before any of P2/P2.5/P3/P4/P5.**

Each is its own plan doc under `docs/superpowers/plans/`.

---

## Self-review (per writing-plans skill)

**Spec coverage of §6 P0 + P1 and §3.1 (rev8 — covers first-spawn + universal behaviors + absent-vs-present-empty sentinel + closure ENFORCED on init path + LOAD-ORDER fix (fetch persisted set before init on reload) + closure fixture DECLARES Turn + real E9 registry setup + LEGACY-snapshot reload migration (no data loss) + ProbeBehavior real Lifecycle developer hooks + real test DynamicSupervisor):**
- P0 "Publisher as base behavior on SocialwareSession / every session composes it" → Task 1 (+ Task 2 caps, Task 3 gate). ✓
- P0 "no consumer change; chat/socialware/Feishu unchanged" → Task 3 regression gate. ✓
- P1.1 "reclassify each reads_siblings as required/optional + slice-owner map + resolver failing loud only on missing required" → Tasks 6–7 (slice-owner map, required/optional table, `resolve_closure`, optional soft default preserved for `Chat → :sandbox`). **Closure is OWNER-MODULE based (codex HIGH): each required `reads_siblings` key resolves its OWNING behavior module via `@slice_owners` and requires THAT EXACT module to be a set member — a slice-key collision (a non-owner behavior declaring the same `state_slice/0` key) does NOT falsely close the set; a required key with no `@slice_owners` entry fails loud (`{:error, {:unknown_required_slice_owner, key}}`) so a new required dep can never silently pass.** ✓
- P1.1 "the closure is ENFORCED on the spawn/init path, not just a pure helper" → **Task 7 adds `validate_closure!/1` (raising passthrough) + `UnclosedSetError`; Task 9 wires it INTO `init_fresh_first_spawn/2` (the `:not_found` branch) BEFORE any `init_slice`/`create` runs and strictly before `persist_initial_snapshot/3`, and validates the PERSISTED effective set on reload** — so a requested set like `[Turn]` without `Surface` (Turn `reads_siblings :surface :required`) FAILS LOUD at first spawn and persists NO partial slice, while a valid persisted instance is never crashed by bogus reload args. **The closure-denial FIXTURE (Task 8) now DECLARES `Turn` in `SupersetSessionKind.behaviors/0`** so the requested `Turn` survives `init_set/2`'s ∩-declared intersection and the closure path is genuinely exercised (codex HIGH — previously Turn was dropped by the intersection and the test was vacuous). Integration denial test in Task 9 asserts the raise, `err.missing == [{Turn, :surface}]`, the observable `refute_received {:probe, :init_slice}` (ProbeBehavior is IN the requested set), AND `is_nil(Repo.get(KindSnapshot, uri_str))` (no row), plus an optional-read positive test (`Chat` without `Sandbox` succeeds, soft `%{}`). ✓ (codex CRITICAL finding 1 — closure now wired + load-order fixed; codex HIGH finding — fixture declares Turn so the test exercises closure)
- P1.2 HARD INVARIANT "persist instance set + route EVERY enumeration/callback entry point through it" → KindBase persistence (Tasks 4–5) + every entry point E1–E10 (Tasks 9–14). ✓
- §3.1 "an out-of-set behavior must NEVER run a callback nor create its slice — even on FIRST spawn before any restart, AND across restart/reconcile" → **Task 9 RESTRUCTURES `load_with_fallback/3` to fetch the persisted snapshot FIRST, then branch: `:not_found` → `init_fresh_first_spawn/2` (init_set from spawn args + validate_closure! + init_slice); `{:ok, loaded}` → effective set from the PERSISTED `:kind_base` (`effective_set/2`, NOT spawn args), closure-validate THAT set, init only its members (`init_fresh_for_set/2`).** So out-of-set `create`/`init_slice` never run and out-of-set slices are never created or persisted — at first spawn OR on reload — and a closed-but-wrong / unclosed SPAWN-ARGS fallback can no longer drive slice creation or crash a valid persisted instance. Proven by the first-spawn denial test (no prior snapshot), the reload-scoping test (set derived from persisted `:kind_base`, not broader args), and the bogus-reload-survives test (unclosed `[Turn]` args don't crash a valid chat-only persisted instance). No "prune on next load" reliance for the security property. ✓ (codex CRITICAL finding 1 — was a load-ORDER defect: `init_fresh` ran from spawn args before `fetch_snapshot` read the persisted set)
- **Deploy safety: LEGACY (pre-P1) snapshot reload must not lose data (codex CRITICAL)** → **Task 9 `seed_legacy_kind_base/1`**: on the reload branch, a snapshot WRITTEN BEFORE P1 has NO `:kind_base` slice; we seed it with the legacy sentinel `nil` INDEPENDENT of reload args BEFORE `effective_set/2`, so the instance resolves to the FULL DECLARED list (nothing pruned) and reload args can NEVER re-drive its set. Without this, the args-driven `init_fresh_for_set` could (when `ever_created?(args)` is false for the supplied args — e.g. no/mismatched `:uri`) persist a `:kind_base` recording `args[:behaviors]`, and the next reload's `prune_orphan_slices/2` would drop the legacy declared slices. Migration regression test (Task 9): hand-write a `:kind_base`-less legacy row with real `:chat` + `:surface` slices, reload with a NARROWER `%{behaviors: [Chat]}` arg, assert BOTH slices survive, `:kind_base` reads back as sentinel `nil`, the effective set is the full declared list, and the re-persisted+re-reloaded row STILL keeps them. ✓ (codex CRITICAL — legacy-snapshot data-loss hole)
- §3.1 "empty/malformed args must not re-open the hole" → **legacy sentinel** (`nil`): `KindBase.create/1` persists `nil` ONLY when `:behaviors` is ABSENT, and the exact list (including `[]`) when PRESENT; `init_set/2` + `effective_set/2` map sentinel `nil` → full declared list but a PRESENT `[]` → base-behaviors-only. So an explicit `%{behaviors: []}` on a superset Kind can NEVER be confused with omitted args and expand to the declared superset — at first spawn OR on reload (KindBase persisted `[]`, a present list, not `nil`). Tests: Task 4 (`create(%{})` → `nil`, `create(%{behaviors: []})` → `[]`); Task 6 (`init_set`/`effective_set` of `%{behaviors: []}`/captured `[]` on SupersetKind == `base_behaviors` only); Task 9 (first-spawn AND reload of `%{behaviors: []}` on the superset → NO `:surface`/`:probe` slice, `create`/`init_slice` never fire); Task 15 (absent-args static Session still → full declared list). ✓ (codex CRITICAL re-review)
- §3.1 "universal-behavior fallback policy" → **`base_behaviors/0` (KindBase + `UniversalBehaviors.all()`) is always in init_set/effective_set, AND the E9 dispatch gate explicitly EXEMPTS `UniversalBehaviors.all()` from the membership check while still cap-checking them** (Tasks 6 + 10). Tests: `manage.delete` dispatches on a chat-only instance; a non-universal `probe.poke` is denied. ✓ (codex HIGH finding 2)
- E9 test wiring is REAL, not assumed → **Task 8 + Task 10 register `{SupersetSessionKind, :poke} → ProbeBehavior` via the canonical chokepoint `Ezagent.CapabilityRegistry.register/3` in a `setup_all` (guarded by `BehaviorRegistry.lookup/2 == :error`, modeled on `lifecycle_test.exs:36-39`); the E9 suite is two-step — (a) a CONTROL test dispatches `:poke` on a FULL-set instance and asserts it REACHES the handler (proving registration), (b) the denial test on a chat-only instance asserts `:behavior_not_in_instance_set`. `manage.delete` uses its REAL universal registration (`BehaviorRegistry.lookup/2` fallback to `UniversalBehaviors.behavior_for_action/1`), not an assumed per-Kind entry.** ✓ (codex MEDIUM finding 2 — dispatch resolves by registry, NOT by scanning `behaviors/0`)
- §3.1 denial requirements (a dispatch, b slice init/reconcile, c handle_signal, d terminate/destroy) → denial suite Tasks 9 (b + first-spawn), 10 (a + universal exemption), 11 (c), 12 (d), 13 (on_ready/post_init/init). ✓
- "instance set survives restart/reconcile" → Task 5 (snapshot round-trip) + Task 9 (prune/reconcile use effective set). ✓
- "valid sets unchanged at runtime (static Kinds)" → Task 15 parity — now a REAL `chat.join` + `chat.send` + `chat.leave` round-trip through `Invocation.dispatch` (copied from `chat_routing_test.exs`), no placeholder. ✓ (codex MEDIUM finding 3)
- "a deliberately required-broken set fails loud in a test" → Task 7 (Turn-without-Surface). ✓
- §7 E2E gate per phase (arch gates + regression suites + author-owned SPA E2E) → Task 3 (P0), Task 16 (P1). ✓

**Placeholder scan (rev8 — full re-scan):** the intentional, clearly-flagged implementer bind-points remain (none are silent placeholders): Task 2's `Ezagent.Identity.production_caps()` accessor — flagged "bind to the exact accessor `binding_policy_test` uses" — because that exact catalog-accessor symbol must be read from the live suite at execution time (binding it blind is a worse failure mode); Task 9's no-partial-persist assertion is bound to the VERIFIED `KindSnapshot` primary key `:uri` (kind_snapshot.ex:24) with a one-line "update if schema keying changes" note; Task 10's `admin_caps/0` is given the documented bootstrap shape with a bind-note + an explicit "assert NOT `:behavior_not_in_instance_set`" fallback so the test is robust to the exact cap shape, and a bind-note for the probe-control test's cap coverage. The Task 8/10 E9 registration uses the VERIFIED canonical signature `Ezagent.CapabilityRegistry.register/3` (capability_registry.ex:82) — no assumption. **Task 15's `assert true` placeholder is GONE** — replaced with the full real chat send/join dispatch flow + an explicit "reject any `assert true` / placeholder" acceptance clause. No "TODO / implement later / handle edge cases / add validation / similar to Task N / write tests for the above" anywhere in the plan.

**Type/signature consistency (rev8):** `seed_legacy_kind_base/1` (Task 9) takes the canonicalized loaded-state map and returns it with `:kind_base` (= `Ezagent.Behavior.KindBase.state_slice()`) present — either unchanged (post-P1 row) or seeded `%{state: %{behaviors: nil}, transients: %{}}` (legacy row); its output feeds `effective_set/2`, whose `behaviors_in_slice/1` reads the seeded value back as the sentinel `nil` (the `%{state: %{behaviors: nil}}` clause, Task 4) → declared list, consistent with the absent-args path. The denial suite's `setup` (Task 9) calls `Ezagent.LifecycleCase.ensure_gate_supervisor!/0` and `SupersetSessionKind.supervisor/0` (Task 8) returns `Ezagent.LifecycleCase.gate_supervisor()` — the same named singleton, consistent across def + setup. `ProbeBehavior` (Task 8) defines ONLY the overridable developer hooks `create/1`, `handle_signal/2`, `activated/2`, `deactivate/2`, `destroy/2` (verified against the `defoverridable` list lifecycle.ex:288-302) — never the macro-emitted `on_ready/2`/`terminate/3`/`__ezagent_lifecycle_destroy__/3`; the denial-test probe symbols (`:probe, :on_ready` / `:terminate` / `:destroy` / `:handle_signal` / `:init_slice`) are produced by those hooks and consumed by `refute_received`/`assert_received` in Tasks 9-13 — names consistent across the support module + tests. `init_set/2` (kind_module, args) used in Task 6 def + Task 9 `init_fresh_first_spawn/2` (called as `kind_module |> BehaviorSet.init_set(args)`); both use the legacy-sentinel rule via `Map.fetch(args, :behaviors)` (`:error` → declared, `{:ok, list}` → ∩). `init_fresh_first_spawn/2` (Task 9) is reachable ONLY from `load_with_fallback/3`'s `:not_found` branch and `load_or_init/3`'s `:ephemeral`/`:external` arms; `init_fresh_for_set/2` (Task 9) is the closure-already-validated worker shared by the first-spawn path (after `validate_closure!`) and the reload branch (on the persisted effective set). The legacy `init_fresh/2` name is fully removed (renamed) — no caller references it. `effective_set/2` (kind_module, slice_state) used identically in the reload branch (Task 9) + Tasks 10–14; reads back via `behaviors_in_slice/1` and maps `nil` → declared, present-list → ∩. The reload branch of `load_with_fallback/3` calls `effective_set/2` on the canonicalized loaded state, then `validate_closure!/1` on the result, then `init_fresh_for_set/2`, then `coerce_loaded_to_fresh_shape/2`, `prune_orphan_slices/2`, `reconcile_after_load_behaviors/3` — all consistent with their Task 6/7/9 signatures. `behaviors_in_slice/1` returns `[module()] | nil` (sentinel `nil`, NOT `[]`) — consistent across Task 4 def + Task 6 effective_set + Task 9 assertions + Task 14 test slices (all use `behaviors: nil` for the legacy/declared case and `behaviors: []` for the base-only case). `base_behaviors/0` defined in Task 6, referenced by init_set/effective_set + the `%{behaviors: []}` tests (Tasks 6, 9) + Task 10 exemption note + Task 14 note. `member?/2` (behavior, effective_set) consistent (Tasks 6, 10). `resolve_closure/1` returns `:ok | {:error, {:missing_required_siblings, [{module(), atom()}]}} | {:error, {:unknown_required_slice_owner, atom()}}` consistent (Task 7); it delegates to the map-injectable `resolve_closure_for/3` (set, required_reads, slice_owners) — the production arity-1 passes `@required_reads`/`@slice_owners`, and the Task 7 unknown-required-key tests pass synthetic maps to drive the `:unknown_required_slice_owner` branch deterministically without mutating the production maps. Closure is OWNER-MODULE based: each required key resolves its owner via `@slice_owners` and that exact owner module must be a `MapSet.member?` of the set (a slice-key collision does NOT close it). `validate_closure!/1` (Task 7) delegates to `validate_closure_for!/3` and is the raising passthrough returning `[module()]` (the unchanged set) on success and raising `Ezagent.Kind.BehaviorSet.UnclosedSetError` (exception carries `:missing`) on a missing required OWNER OR an unknown required key — called in `init_fresh_first_spawn/2` (first-spawn) AND on the persisted effective set in the reload branch (Task 9), and asserted via `assert_raise UnclosedSetError` + `err.missing == [{Turn, :surface}]` in both Task 7 unit tests and the Task 9 first-spawn integration test (consistent module name across def + tests). The Task 9 closure fixture relies on `SupersetSessionKind` DECLARING `Turn` (Task 8) so the requested `Turn` survives `init_set/2`'s ∩-declared intersection. `instance_set_gate/3` (Task 10) uses `UniversalBehaviors.all/0` (verified to exist + contain `Manage`) and `effective_set/2`/`member?/2`. `hosts_lifecycle?/1` and `/2` both defined (Task 14). KindBase `state_slice == :kind_base` consistent across owner map + init_set/effective_set + prune-exclusion.

**Spec ambiguity resolved (flagged for orchestrator):**
- **Where the instance set is persisted:** chosen a dedicated base behavior `KindBase` owning a `:kind_base` slice (not a raw spawn-arg-only field), because the spec's §3.1 explicitly requires the set to "survive restart/reconcile" and only slice state goes through `kind_snapshots` load/merge/prune. A spawn-arg-only value would be lost on cold restart (args aren't re-supplied on rehydrate). Justification matches the spec's own parenthetical "(in the spawn args / template / a base slice)".
- **Static-Kind fallback semantics:** the spec keeps the two Kind modules "thin: each = a fixed instance behavior set." This plan implements that as: a static Kind that spawns without a `:behaviors` arg captures the legacy sentinel `nil` → `init_set`/`effective_set` fall back to the declared list (+ base behaviors). This preserves today's runtime exactly while making the per-instance path live everywhere. The sentinel is `nil` (NOT `[]`) precisely so that an explicit `%{behaviors: []}` — a deliberately base-only instance — is never confused with the absent-args legacy case (codex CRITICAL re-review). If the orchestrator prefers the static Kinds to ALSO capture their full declared list explicitly at spawn (so there is never a "fallback"), that is a one-line change at each Kind's spawn site — flagged as a design choice, not a blocker.
- **Universal-behavior policy (rev2, codex finding 2):** `base_behaviors/0` = `KindBase` + `UniversalBehaviors.all()` (today `Manage`). These are ALWAYS in the instance set AND the E9 dispatch gate explicitly exempts `UniversalBehaviors.all()` from the membership check (still cap-checked by `authz_check`). Implemented entirely in the plan (Tasks 6 + 10) — NO spec change needed: SPEC §3.1 already names "any universal-behavior fallback policy" as part of the HARD INVARIANT; this plan makes that policy concrete. KindBase being a universal base also means `hosts_lifecycle?/2` is always true for any composed instance (KindBase + Manage both `use Ezagent.Lifecycle`); this is correct, not a mis-classification (Task 14 note).
- **Load-order restructure (rev5, codex CRITICAL finding 1):** the §3.1 security guard could NOT live in an up-front `init_fresh` because the REAL `load_with_fallback/3` runs `fresh = init_fresh(args)` BEFORE `fetch_snapshot/2` reads the persisted row (snapshot.ex:70 then :72). Putting init_set + validate_closure! + init_slice inside `init_fresh` would run the SPAWN-ARGS closure + slice creation on every reload BEFORE the persisted `:kind_base` is read — a closed-but-wrong fallback set could create an out-of-set slice, an unclosed fallback set could crash a valid persisted instance. FIXED by RESTRUCTURING the load: fetch FIRST, then branch — `:not_found` runs `init_fresh_first_spawn/2` (spawn-args set, validated, the §3.1 first-spawn guard); `{:ok, loaded}` derives the set from the PERSISTED `:kind_base` via `effective_set/2`, validates THAT set, and init's only its members via `init_fresh_for_set/2`; spawn args never re-drive slice creation/validation on reload. Defense-in-depth prune/reconcile retained on reload over the persisted effective set. NO spec change needed — this realizes the existing §3.1 persisted-set-on-reload contract in the load ORDER.
- **Closure enforcement on the (first-spawn) init path (rev5, codex CRITICAL finding 1):** `resolve_closure/1` was previously a pure helper with unit tests but NEVER called from the spawn/init path — so an unclosed set (e.g. `[Turn]` without `Surface`) would still materialize and run `Turn.init_slice` with a missing required sibling. FIXED by adding `validate_closure!/1` (raising passthrough) + `UnclosedSetError` (Task 7) and calling it INSIDE `init_fresh_first_spawn/2` (the `:not_found` branch, Task 9) BEFORE any `init_slice`/`create` and strictly before `persist_initial_snapshot/3`; on reload, closure is validated on the PERSISTED effective set (a persisted set closed at first spawn stays closed; a bogus reload-args set can NOT crash a valid persisted instance). The first-spawn raise propagates `init_fresh_first_spawn → load_with_fallback → load_or_init → Kind.Server.init/1` → `{:stop, ...}`, so no partial snapshot lands. Integration denial test asserts the raise + `is_nil(Repo.get(KindSnapshot, uri_str))`; the bogus-reload test asserts a valid persisted instance survives. NO spec change needed — this enforces the existing §3.1/P1.1 invariant at the real chokepoints. Verified call sites: first-spawn slice creation = the `:not_found` branch of `load_with_fallback/3` (snapshot.ex:68-127) + the no-DB `:ephemeral`/`:external` arms of `load_or_init/3`; persist on first spawn = server.ex:110,156.
- **E9 registry setup is real (rev4, codex MEDIUM finding 2):** dispatch resolves `{kind, action}` via `BehaviorRegistry.lookup/2` (behavior_registry.ex:48), NOT by scanning `behaviors/0`. The prior E9 test assumed `{SupersetSessionKind, :poke}` was registered but the support module only defined `behaviors/0` — so the denial test could have failed as unroutable before reaching the gate. FIXED: a `setup_all` registers it through the canonical `CapabilityRegistry.register/3` (verified signature, capability_registry.ex:82), and the suite is two-step (control test proves `:poke` reaches the handler in-set; denial test proves out-of-set is gated). `Manage` uses its real universal-fallback registration. NO spec change needed.
- **Absent-vs-present-empty sentinel (rev3, codex CRITICAL re-review):** the resolver no longer treats `[]` as the "no subset" marker. `KindBase.create/1` persists the legacy sentinel `nil` for ABSENT `:behaviors` and the exact list (including `[]`) for PRESENT; `init_set/2` uses `Map.fetch` and `effective_set/2` reads back `nil`-vs-list, so an explicit `%{behaviors: []}` admits ONLY base behaviors and is never expanded to the declared superset (at first spawn or on reload). NO spec change needed — this hardens the existing §3.1 invariant against empty/malformed args; the sentinel is an implementation detail of "the per-instance set persists across restart." If the orchestrator wants a named atom (e.g. `:legacy_static`) instead of `nil`, that is a mechanical rename across `KindBase` + `BehaviorSet` + the tests — flagged as a cosmetic choice, not a blocker.
- **Legacy-snapshot reload migration (rev8, codex CRITICAL — data loss):** a snapshot written BEFORE P1 has NO `:kind_base` slice but carries real persisted declared slices. The reload branch derives the effective set from `:kind_base`; for a legacy row that key is absent. If the args-driven `init_fresh_for_set(effective, args)` were allowed to create a `:kind_base` from `args[:behaviors]` (it can whenever `ever_created?(args)` resolves false for the supplied args — e.g. args without/with a mismatched `:uri`, verified `ever_created?/1` reads `args[:uri]`, lifecycle.ex:404-407), a narrower reload would persist that subset and the next reload's `prune_orphan_slices/2` would DROP the legacy declared slices — silent data loss for prod sessions. FIXED by `seed_legacy_kind_base/1` (Task 9): on reload, if the loaded snapshot lacks `:kind_base`, seed it with the legacy sentinel `nil` (two-container shape `%{state: %{behaviors: nil}, transients: %{}}`) INDEPENDENT of args, BEFORE `effective_set/2` — so a legacy instance resolves to the full declared list (nothing pruned) and the seeded slice persists going forward as legacy-nil. A snapshot that already has `:kind_base` (post-P1) is returned unchanged. Migration regression test added (Task 9). NO spec change needed — this realizes §3.1's "set survives restart/reconcile" for snapshots that predate the set's existence (the deploy-safety case the spec implies but did not enumerate).
- **ProbeBehavior uses OVERRIDABLE developer hooks, not macro-emitted engine callbacks (rev8, codex HIGH):** the prior support module defined `on_ready/2` + `terminate/3` directly, but `use Ezagent.Lifecycle` EMITS those engine callbacks and they are NOT in the macro's `defoverridable` list (verified lifecycle.ex:288-302: the overridable set is exactly `create:1, activate:2, deactivate:2, destroy:2, activated:2, handle_signal:2`), so redefining them is a compile error and the destroy probe was unwired. FIXED (Task 8): observe each lifecycle moment through its REAL developer hook per the macro's mapping table (lifecycle.ex:24-33) — on-ready via `activated/2`, terminate via `deactivate/2`, destroy via `destroy/2`, signal via `handle_signal/2`, init via `create/1`. The E2/E3/E5 denial tests (Tasks 11-13) assert through those entry points (graceful `GenServer.stop` → `deactivate`; explicit `{:ezagent_lifecycle_destroy, …}` → `destroy`; mailbox signal → `handle_signal`). NO spec change needed.
- **SupersetSessionKind.supervisor/0 returns a RUNNING test DynamicSupervisor (rev8, codex HIGH):** the prior support Kind returned `Ezagent.Kind.Server` (the CHILD module) from `supervisor/0`, but `Ezagent.Kind.spawn/2` passes `kind_module.supervisor()` straight into `DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, …})` (verified kind.ex:300-301 + `resolve_supervisor/1` kind.ex:635-641) — so every `Kind.spawn(SupersetSessionKind, …)` in Tasks 10-13 would crash before the gate ran. FIXED (Task 8): `supervisor/0` returns the existing dedicated test supervisor `Ezagent.LifecycleCase.gate_supervisor()` (a named singleton started idempotently by `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`, verified lifecycle_case.ex:47-48,117-151 — the same opt-in pattern the cold-restart GATE Kinds use, kind_provenance_test.exs:97-103). The denial suite's `setup` (Task 9) calls `ensure_gate_supervisor!/0` before any spawn. NO spec change needed.
- **E11 (`auto_derive.ex`) scoped to P2:** it is the View/display surface, not a P1 security gate. Flagged so it is not mistaken for a P1 coverage gap.
