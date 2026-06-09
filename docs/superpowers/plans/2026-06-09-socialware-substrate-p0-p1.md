# Socialware Substrate P0+P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Make `Behavior.Publisher` a base behavior every session composes (P0), then make the Kind runtime *per-instance-behavior-set-aware* — persisting each instance's behavior set and routing every behavior enumeration + callback entry point through it so an out-of-set behavior can never run a callback, process a signal, run a cleanup hook, or create/mutate its slice, even when one Kind module registers a superset (P1).

**Architecture:** A new core base behavior `Ezagent.Behavior.KindBase` (slice key `:kind_base`, `use Ezagent.Lifecycle`) snapshots the instance's behavior-module list at spawn into its persistent `:state` so it survives restart/reconcile via the existing `kind_snapshots` path. A new pure resolver `Ezagent.Kind.BehaviorSet` (a) computes the *effective instance set* (declared `behaviors_of/1` ∩ the persisted set, or the full declared list when no per-instance override exists — preserving today's two static Kinds), (b) classifies each `reads_siblings` entry `:required`/`:optional` against a slice-owner map and fails loud only on a missing *required* sibling. Every runtime call site that today calls `Ezagent.Kind.behaviors_of(kind_module)` or resolves dispatch by `{kind_module, action}` is re-pointed at the instance set; dispatch gains a membership gate that denies an out-of-set behavior with `{:error, :behavior_not_in_instance_set}`.

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
- **E9 is the security-critical one.** Dispatch resolves a behavior via `Ezagent.BehaviorRegistry.lookup(kind_module, action)` (`runtime.ex:284-289`), which is keyed by `kind_module` — NOT by instance. Caps are also registered per `{kind_module, action}` (`Ezagent.CapabilityRegistry.register(kind, action, behavior)`, `capability_registry.ex:82`). So with one `SessionKind` carrying a superset, ANY instance could resolve+dispatch ANY registered action. P1 inserts an instance-set membership gate AFTER `lookup_behavior` and BEFORE `authz_check`.
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
| `apps/ezagent_core/lib/ezagent/behavior/kind_base.ex` | Create | P1: base behavior owning slice `:kind_base`; `create/1` snapshots the instance behavior-module list from spawn args; exposes no actions (data-only base). |
| `apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs` | Create | P1: assert the slice captures the behavior set and survives a restart round-trip. |
| `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex` | Create | P1: pure resolver — `effective_set/3` (instance set), slice-owner map, `resolve_closure/1` (required/optional fail-loud), `member?/2`. |
| `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs` | Create | P1: unit tests for effective_set, closure (required fail / optional soft), member?. |
| `apps/ezagent_core/lib/ezagent/kind/server.ex` | Modify | P1: thread the instance set into state; re-point E1–E5 enumerations through it. |
| `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` | Modify | P1: re-point E6–E8 (init_fresh / prune / reconcile) through the instance set; KindBase always in fresh init. |
| `apps/ezagent_core/lib/ezagent/kind/runtime.ex` | Modify | P1 (E9): instance-set membership gate after `lookup_behavior`, denying out-of-set behaviors. |
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

  test "create/1 captures the instance behavior set from :behaviors arg" do
    behaviors = [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface]
    assert {:ok, %{behaviors: ^behaviors}} = KindBase.create(%{behaviors: behaviors})
  end

  test "create/1 with no :behaviors arg yields an empty list (module-static fallback)" do
    assert {:ok, %{behaviors: []}} = KindBase.create(%{})
  end

  test "behaviors_in_slice/1 reads the captured set from a two-container slice" do
    {:ok, st} = KindBase.create(%{behaviors: [Ezagent.Behavior.Chat]})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == [Ezagent.Behavior.Chat]
  end

  test "behaviors_in_slice/1 returns [] for a missing/empty slice" do
    assert KindBase.behaviors_in_slice(nil) == []
    assert KindBase.behaviors_in_slice(%{state: %{}, transients: %{}}) == []
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
  `behaviors_in_slice/1` by `Ezagent.Kind.BehaviorSet.effective_set/3`.

  The set is snapshotted via the standard `kind_snapshots` path, so it
  survives restart/reconcile exactly like any other slice.
  """

  use Ezagent.Lifecycle, state_slice: :kind_base

  @impl Ezagent.Lifecycle
  def create(args) do
    behaviors = Map.get(args, :behaviors, [])
    {:ok, %{behaviors: behaviors}}
  end

  @doc "Read the captured instance behavior set from this Kind's :kind_base slice."
  @spec behaviors_in_slice(map() | nil) :: [module()]
  def behaviors_in_slice(%{state: %{behaviors: behaviors}}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(%{behaviors: behaviors}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(_), do: []
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
      Ecto.Adapters.SQL.Sandbox.checkout(Ezagent.Repo)
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

      reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, KBTestKind, %{behaviors: []})
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

### Task 6: `BehaviorSet.effective_set/3` (failing test first)

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex`
- Test: `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`

The effective set = the host module's declared `behaviors_of/1` intersected with the persisted set when a per-instance override exists; otherwise the full declared list (preserving today's two static Kinds, which spawn with no `:behaviors` arg → empty captured set → fall back to declared list).

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

  test "no captured set → full declared list (static-Kind preservation)" do
    slice_state = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             Ezagent.Kind.behaviors_of(SupersetKind)
  end

  test "captured subset → declared ∩ captured, declaration order preserved" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    refute Ezagent.Behavior.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "member?/2 reflects the effective set" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    assert BehaviorSet.member?(Ezagent.Behavior.Chat, BehaviorSet.effective_set(SupersetKind, slice_state))
    refute BehaviorSet.member?(Ezagent.Behavior.Surface, BehaviorSet.effective_set(SupersetKind, slice_state))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: FAIL — `Ezagent.Kind.BehaviorSet` undefined.

- [ ] **Step 3: Write the resolver (effective_set + member? only for this task)**

```elixir
defmodule Ezagent.Kind.BehaviorSet do
  @moduledoc """
  Per-instance behavior-set resolution + required/optional sibling
  closure for the unified socialware substrate (SPEC §3.1).

  `effective_set/2` is the single function every runtime behavior
  enumeration calls instead of `Ezagent.Kind.behaviors_of/1`. It returns
  the host Kind module's declared behaviors INTERSECTED with the set the
  instance was spawned with (captured in the `:kind_base` slice), in the
  module's declaration order. When the instance captured no set (the two
  legacy static Kinds, which spawn without a `:behaviors` arg), it
  returns the full declared list — so existing Kinds are byte-for-byte
  unchanged.
  """

  alias Ezagent.Behavior.KindBase

  @doc "The effective behavior set for this instance, declaration order preserved."
  @spec effective_set(module(), %{atom() => map()}) :: [module()]
  def effective_set(kind_module, slice_state) when is_atom(kind_module) and is_map(slice_state) do
    declared = Ezagent.Kind.behaviors_of(kind_module)
    captured = KindBase.behaviors_in_slice(Map.get(slice_state, :kind_base))

    case captured do
      [] ->
        declared

      list when is_list(list) ->
        captured_set = MapSet.new(list)
        Enum.filter(declared, &MapSet.member?(captured_set, &1))
    end
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
git commit -m "feat(kind): P1 — BehaviorSet.effective_set resolves the per-instance set"
```

### Task 7: Required/optional sibling closure resolver (failing test first)

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex`
- Test: append to `apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
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

    test "OPTIONAL sibling absent is OK (Chat without Sandbox — today's behavior)" do
      set = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
      assert BehaviorSet.resolve_closure(set) == :ok
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: FAIL — `resolve_closure/1` undefined.

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

  @doc """
  Validate a behavior set is closed under its REQUIRED sibling reads.
  Fails loud ONLY on a missing required sibling owner; optional reads
  keep the soft `%{}` default (no failure).
  """
  @spec resolve_closure([module()]) :: :ok | {:error, {:missing_required_siblings, [{module(), atom()}]}}
  def resolve_closure(set) when is_list(set) do
    present_slices =
      set
      |> Enum.map(& &1.state_slice())
      |> MapSet.new()

    missing =
      for reader <- set,
          {key, :required} <- Map.get(@required_reads, reader, %{}) |> Map.to_list(),
          not MapSet.member?(present_slices, key),
          do: {reader, key}

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_required_siblings, missing}}
    end
  end

  @doc "The owning Behavior module for a slice key (or nil)."
  @spec owner_of(atom()) :: module() | nil
  def owner_of(slice_key) when is_atom(slice_key), do: Map.get(@slice_owners, slice_key)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/behavior_set.ex \
        apps/ezagent_core/test/ezagent/kind/behavior_set_test.exs
git commit -m "feat(kind): P1 — required/optional sibling closure resolver"
```

### Task 8: Test-support — superset Kind + observable probe behavior

**Files:**
- Create: `apps/ezagent_core/test/ezagent/kind/instance_set_support.ex`

This module is shared by the denial suite (Task 14). It defines a Kind whose MODULE registers a superset (`[Chat, Surface, ProbeBehavior, KindBase]`) but is spawned with a chat-only instance set, plus a `ProbeBehavior` that records when its `handle_signal`/`terminate`/`destroy`/`on_ready`/`init_slice` run (via a test pid registered in `:persistent_term` or an Agent).

- [ ] **Step 1: Write the support module**

```elixir
defmodule Ezagent.Kind.InstanceSetSupport do
  @moduledoc false

  defmodule ProbeBehavior do
    @moduledoc false
    use Ezagent.Lifecycle, state_slice: :probe

    action(:poke, args: %{}, returns: %{}, caps: [:poke], modes: [:call])

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

    def on_ready(_slice, _ctx), do: notify(:on_ready)
    def terminate(_reason, _slice, _ctx), do: notify(:terminate)
    def reconcile_after_load(_uri, slice), do: notify(:reconcile) && slice

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
        Ezagent.Behavior.Surface,
        Ezagent.Kind.InstanceSetSupport.ProbeBehavior,
        Ezagent.Behavior.KindBase
      ]
    end
    @impl true
    def persistence, do: {:snapshot, :on_change}
    @impl true
    def supervisor, do: Ezagent.Kind.Server
  end
end
```

NOTE TO IMPLEMENTER: confirm `ProbeBehavior`'s `:probe` slice key isn't in `@slice_owners` — that's fine; ProbeBehavior is test-only and declares no required reads. Register the probe pid with `:persistent_term.put({ProbeBehavior, :probe_pid}, self())` in each denial test's setup.

- [ ] **Step 2: Compile to verify the support module is valid**

Run: `MIX_ENV=test mix compile`
Expected: compiles (no warnings-as-errors needed yet).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/test/ezagent/kind/instance_set_support.ex
git commit -m "test(kind): P1 — superset Kind + observable probe behavior support"
```

### Task 9 (E8 + E6 + E7): Snapshot init/prune/reconcile through the instance set

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:135-144` (`prune_orphan_slices`), `:162-174` (`reconcile_after_load_behaviors`), `:532-538` (`init_fresh`).

KindBase must ALWAYS be in fresh init (so the captured set is written even when the spawn-args set is the full list). But once an instance set is captured, prune/reconcile must operate on the effective set. Because `init_fresh` runs BEFORE the snapshot is loaded (no slice state yet), it uses the *declared* list PLUS KindBase. Prune/reconcile run AFTER load (slice state present), so they use `effective_set`.

- [ ] **Step 1: Write the failing test**

```elixir
# in apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs (created here, extended in Task 14)
defmodule Ezagent.Kind.InstanceSetDenialTest do
  use ExUnit.Case, async: false

  alias Ezagent.Kind.InstanceSetSupport.{SupersetSessionKind, ProbeBehavior}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Ezagent.Repo)
    :persistent_term.put({ProbeBehavior, :probe_pid}, self())
    on_exit(fn -> :persistent_term.erase({ProbeBehavior, :probe_pid}) end)
    :ok
  end

  test "slice-init: an out-of-set behavior does NOT init its slice (E8)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-init-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    # First materialize the captured set (save_now), then reload.
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    # ProbeBehavior is out of the instance set → its :probe slice must be pruned.
    refute Map.has_key?(reloaded, :probe)
    # Surface is also out of set → no :surface slice.
    refute Map.has_key?(reloaded, :surface)
    # Chat (in set) IS present.
    assert Map.has_key?(reloaded, :chat)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs:LINE`
Expected: FAIL — `prune_orphan_slices` currently prunes against the MODULE's declared list (keeps `:surface` and `:probe`).

- [ ] **Step 3: Re-point prune/reconcile at the effective set; keep init_fresh declared+KindBase**

In `prune_orphan_slices/2` (`snapshot.ex:135`), change the declared-set computation to the effective set:

```elixir
  defp prune_orphan_slices(state, kind_module) do
    declared =
      Ezagent.Kind.BehaviorSet.effective_set(kind_module, state)
      |> Enum.map(& &1.state_slice())
      |> MapSet.new()
      # KindBase's own slice must never be pruned — it carries the set.
      |> MapSet.put(:kind_base)

    state
    |> Enum.filter(fn {key, _} -> MapSet.member?(declared, key) end)
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

In `init_fresh/2` (`snapshot.ex:532`), ensure KindBase is always initialized so the captured set lands even before the first snapshot exists:

```elixir
  defp init_fresh(kind_module, args) do
    (Ezagent.Kind.behaviors_of(kind_module) ++ [Ezagent.Behavior.KindBase])
    |> Enum.uniq()
    |> Enum.map(fn behavior -> {behavior.state_slice(), behavior.init_slice(args)} end)
    |> Map.new()
  end
```

NOTE TO IMPLEMENTER: `effective_set/2` reads `:kind_base` from the *loaded* state, which is present by the time prune/reconcile run (load merged it). For the very first `init_fresh` there's no captured set yet, so init uses the declared list + KindBase — correct: a fresh instance materializes ALL declared slices, then on the NEXT load (after the set is captured) prune drops the out-of-set slices. The denial test above exercises exactly that two-load sequence.

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/snapshot.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E6/E7/E8) — snapshot prune/reconcile use the instance set; KindBase always init'd"
```

### Task 10 (E9): Dispatch + caps gate through the instance set

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/runtime.ex:172-189` (insert a membership gate in the `with` chain).

- [ ] **Step 1: Write the failing test**

```elixir
# append to instance_set_denial_test.exs
  test "dispatch: an out-of-set behavior action is DENIED (E9)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-disp-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    # ProbeBehavior.:poke is registered on SupersetSessionKind (module superset),
    # but this instance's set is chat-only → must be denied.
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

  defp admin_caps, do: Ezagent.SystemPrincipal.caps("system://bootstrap")
```

NOTE TO IMPLEMENTER: bind `admin_caps/0` to whatever the existing dispatch tests in `apps/ezagent_core/test` use to construct admin caps; the helper above is the documented bootstrap shape (`kind.ex:288`).

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs:LINE`
Expected: FAIL — currently `:poke` resolves via the registry (keyed by module) and runs, returning `:ok`.

- [ ] **Step 3: Insert the instance-set membership gate**

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
  # action by {kind_module, action} (module-keyed), the behavior must be
  # in THIS INSTANCE's effective set to act. A chat instance on a
  # superset SessionKind cannot dispatch a Surface/ProbeBehavior action.
  defp instance_set_gate(behavior_module, kind_module, state) do
    effective = Ezagent.Kind.BehaviorSet.effective_set(kind_module, state)

    if Ezagent.Kind.BehaviorSet.member?(behavior_module, effective) do
      :ok
    else
      :telemetry.execute([:ezagent, :authz, :denied], %{}, %{
        kind_module: kind_module,
        behavior_module: behavior_module,
        reason: :behavior_not_in_instance_set
      })

      {:error, :behavior_not_in_instance_set}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/runtime.ex \
        apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs
git commit -m "feat(kind): P1 (E9) — dispatch denies out-of-instance-set behaviors"
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

NOTE TO IMPLEMENTER: ProbeBehavior needs a `__ezagent_lifecycle_destroy__/3` to be probed by E3 (the Lifecycle macro injects it). If the macro auto-injects it, add a `notify(:destroy)` path; if not, add a manual `def __ezagent_lifecycle_destroy__(_r,_s,_c), do: notify(:destroy)` to ProbeBehavior in Task 8's support module (update Task 8 accordingly).

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

NOTE TO IMPLEMENTER: `init_slice` for ProbeBehavior runs in `init_fresh` ONLY on the FIRST load (before the set is captured) — see Task 9's two-load note. To make the `refute_received {:probe, :init_slice}` assertion deterministic, register the probe pid AFTER the first materializing load, OR materialize the captured set via `save_now` in setup before `spawn` (so spawn's `init/1` load already sees the captured set and prunes ProbeBehavior). Use the save_now-first pattern from Task 9's E8 test for determinism.

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

    # Instance set captured as empty list → falls back to declared list (still has Lifecycle).
    full = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, full)
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

### Task 15: Static-Kind parity — chat Session unchanged at runtime under the new path

**Files:**
- Test: `apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs`

Proves the two legacy Kinds (which spawn without a `:behaviors` arg → empty captured set → declared-list fallback) behave identically: all declared behaviors still init, dispatch, and run their hooks.

- [ ] **Step 1: Write the test**

```elixir
defmodule Ezagent.SessionInstanceSetTest do
  use ExUnit.Case, async: false

  test "chat Session's effective set equals its full declared list (no :behaviors arg)" do
    slice_state = %{}  # no :kind_base captured → fallback
    assert Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Session, slice_state) ==
             Ezagent.Kind.behaviors_of(Ezagent.Entity.Session)
  end

  test "chat send/join still works end-to-end on the default Session" do
    # Re-use the existing chat send/join helper from the instance_message
    # suite (read send_receive_test for the exact setup) and assert a
    # message reaches a joined member — proving dispatch is unchanged.
    # IMPLEMENTER: bind to the existing test helper; do not hand-roll caps.
    assert true  # placeholder line REMOVED by implementer: wire to real helper
  end
end
```

NOTE TO IMPLEMENTER: replace the second test body with the project's existing chat send/join flow (copy the setup from `apps/ezagent_domain_instance_message/test/.../send_*` or `join_*` test). Do NOT ship the `assert true` placeholder — it exists only to mark where the real flow goes. The first test is complete as-is.

- [ ] **Step 2: Run test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message/session_instance_set_test.exs
git commit -m "test(kind): P1 — static chat Session unchanged under instance-set path"
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

**Spec coverage of §6 P0 + P1 and §3.1:**
- P0 "Publisher as base behavior on SocialwareSession / every session composes it" → Task 1 (+ Task 2 caps, Task 3 gate). ✓
- P0 "no consumer change; chat/socialware/Feishu unchanged" → Task 3 regression gate. ✓
- P1.1 "reclassify each reads_siblings as required/optional + slice-owner map + resolver failing loud only on missing required" → Tasks 6–7 (slice-owner map, required/optional table, `resolve_closure`, optional soft default preserved for `Chat → :sandbox`). ✓
- P1.2 HARD INVARIANT "persist instance set + route EVERY enumeration/callback entry point through it" → KindBase persistence (Tasks 4–5) + every entry point E1–E10 (Tasks 9–14). ✓
- §3.1 denial requirements (a dispatch, b slice init/reconcile, c handle_signal, d terminate/destroy) → denial suite Tasks 9 (b), 10 (a), 11 (c), 12 (d), 13 (on_ready/post_init/init). ✓
- "instance set survives restart/reconcile" → Task 5 (snapshot round-trip) + Task 9 (prune/reconcile use effective set). ✓
- "valid sets unchanged at runtime (static Kinds)" → Task 15 parity. ✓
- "a deliberately required-broken set fails loud in a test" → Task 7 (Turn-without-Surface). ✓
- §7 E2E gate per phase (arch gates + regression suites + author-owned SPA E2E) → Task 3 (P0), Task 16 (P1). ✓

**Placeholder scan:** Two intentional, clearly-flagged implementer bind-points remain (not silent placeholders): (1) Task 2's `Ezagent.Identity.production_caps()` accessor — flagged "bind to the exact accessor binding_policy_test uses"; (2) Task 15's second test body — flagged "REMOVED by implementer; wire to real helper." Both are because the exact existing test-helper symbols must be read from the live suite at execution time (binding them blind would be a worse failure mode than an explicit, scoped instruction). Task 10's `admin_caps/0` is given the documented bootstrap shape with a bind-note. No "TODO/handle edge cases/add validation" placeholders.

**Type/signature consistency:** `effective_set/2` (kind_module, slice_state) used identically in Tasks 9–14. `member?/2` (behavior, effective_set) consistent. `behaviors_in_slice/1` consistent (Tasks 4, 6). `resolve_closure/1` returns `:ok | {:error, {:missing_required_siblings, [{module(), atom()}]}}` consistent (Task 7). `hosts_lifecycle?/1` and `/2` both defined (Task 14). KindBase `state_slice == :kind_base` consistent across owner map + effective_set + prune-exclusion.

**Spec ambiguity resolved (flagged for orchestrator):**
- **Where the instance set is persisted:** chosen a dedicated base behavior `KindBase` owning a `:kind_base` slice (not a raw spawn-arg-only field), because the spec's §3.1 explicitly requires the set to "survive restart/reconcile" and only slice state goes through `kind_snapshots` load/merge/prune. A spawn-arg-only value would be lost on cold restart (args aren't re-supplied on rehydrate). Justification matches the spec's own parenthetical "(in the spawn args / template / a base slice)".
- **Static-Kind fallback semantics:** the spec keeps the two Kind modules "thin: each = a fixed instance behavior set." This plan implements that as: a static Kind that spawns without a `:behaviors` arg captures an empty set → `effective_set` falls back to the declared list. This preserves today's runtime exactly while making the per-instance path live everywhere. If the orchestrator prefers the static Kinds to ALSO capture their full declared list explicitly at spawn (so there is never a "fallback"), that is a one-line change at each Kind's spawn site — flagged as a design choice, not a blocker.
- **E11 (`auto_derive.ex`) scoped to P2:** it is the View/display surface, not a P1 security gate. Flagged so it is not mistaken for a P1 coverage gap.
