defmodule Ezagent.Behavior.PresenceMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.Behavior.Presence` per
  SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3 Level 1
  (dispatch parity).

  Presence is a cap-only marker Behavior (`dispatchable?/0 == false`,
  same shape as `Ezagent.Behavior.Notifications` + the per-adapter
  `*.Allow` markers). The migration moves it from legacy
  `@behaviour Ezagent.Behavior` to the new `use Ezagent.Behavior` +
  declarative `action/3` shape with a raising `handle_online/2` (the
  handler must exist for the macro's @before_compile invariant but
  is never invoked because `dispatchable?/0 == false` prevents
  routing — defence in depth).

  ## Why no full `Kind.Runtime.handle_dispatch/4` path

  Cap-only Behaviors are intentionally unreachable via dispatch — the
  CapabilityRegistry records the cap subject but does NOT write to
  `BehaviorRegistry`, so the lookup at dispatch step 5 returns
  `:error` and `Invocation.dispatch/1` returns `{:error, :no_behaviour}`.
  The "full dispatch path" parity criterion (codex r3 P2-g) does not
  apply to cap-only Behaviors; instead this test pins:

  1. The new-contract introspection markers (`__behavior__?/0`,
     `__action_names__/0`).
  2. The `dispatchable?/0 == false` invariant.
  3. The cap-axis preservation (`:any` to match the multi-Kind
     registration on User + Agent).
  4. The raising handler defence (any future regression that flipped
     `dispatchable?` to true without re-architecting the cap-shape
     would surface as a raise on the test's direct handler call).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Presence

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.Behavior.new_style?(Presence)
    end

    test "__behavior__?/0 returns true" do
      assert Presence.__behavior__?()
    end

    test "__action_names__/0 lists [:online]" do
      assert Presence.__action_names__() == [:online]
    end

    test "__action_spec__(:online) carries args/returns/caps/modes" do
      spec = Presence.__action_spec__(:online)
      assert spec.name == :online
      assert spec.args == %{}
      assert :online in spec.caps
      assert :call in spec.modes
    end

    test "handle_online/2 is exported (required by macro invariant)" do
      assert function_exported?(Presence, :handle_online, 2)
    end
  end

  describe "cap-only marker preserved" do
    test "dispatchable?/0 returns false (cap-only marker)" do
      assert Presence.dispatchable?() == false
    end

    test "required_caps/0 uses the :any axis (multi-Kind registration)" do
      # Presence is registered on BOTH User + Agent (User has online
      # presence, Agent does too); the cap kind axis is `:any` per
      # check 11(b)'s multi-Kind escape (dispatch substitutes the
      # actual target's type_name/0 at step 5.5 runtime).
      caps = Presence.required_caps()

      assert %Ezagent.Capability{kind: :any, behavior: Presence, action: :online} =
               caps[:online]
    end

    test "data_owner/1 — entity URI returns the canonical instance URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      assert %URI{} = Presence.data_owner(uri)
    end

    test "data_owner/1 — :any class-wide returns :any" do
      assert Presence.data_owner(:any) == :any
    end

    test "data_owner/1 — unknown shape returns :no_owner" do
      assert Presence.data_owner(:something_else) == :no_owner
    end

    test "handle_online/2 raises if ever invoked (defence in depth)" do
      # Cap-only Behaviors must never be reached at dispatch time —
      # `dispatchable?/0 == false` prevents routing. If a regression
      # ever exposes this handler, the raise stops the dispatch with
      # a clear message instead of silently mis-behaving.
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        Presence.handle_online(%{}, %{})
      end
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Presence.actions() == [:online]
      assert Map.has_key?(Presence.interface(), :online)
      assert [{:online, desc}] = Presence.cap_subjects()
      assert is_binary(desc) and desc != ""
    end

    test "state_slice/0 preserved + create/1 builds persistent state (Lifecycle migration)" do
      # Slice key still auto-derives to `:presence`. Under `use
      # Ezagent.Lifecycle`, the persistent-state builder is `create/1`
      # (empty — cap-only Behavior); `init_slice/1` is the macro-emitted
      # two-container wrapper.
      assert Presence.state_slice() == :presence
      assert Presence.create(%{}) == {:ok, %{}}
      assert Presence.init_slice(%{}) == %{state: %{}, transients: %{}}
    end
  end
end
