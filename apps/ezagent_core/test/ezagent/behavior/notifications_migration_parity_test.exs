defmodule Ezagent.Behavior.NotificationsMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.Behavior.Notifications`
  per SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3
  Level 1 (dispatch parity).

  Notifications is a cap-only marker Behavior (`dispatchable?/0 ==
  false`, same shape as the per-adapter `*.Allow` markers). The
  migration moves it from legacy `@behaviour Ezagent.Behavior` to the
  new `use Ezagent.Behavior` + declarative `action/3` shape with a
  raising `handle_subscribe/2` (the handler must exist for the macro's
  @before_compile invariant but is never invoked because
  `dispatchable?/0 == false` prevents routing — defence in depth).

  ## Why no full `Kind.Runtime.handle_dispatch/4` path

  Cap-only Behaviors are intentionally unreachable via dispatch — the
  CapabilityRegistry records the cap subject but does NOT write to
  `BehaviorRegistry`, so the dispatch lookup returns `:error` and
  `Invocation.dispatch/1` returns `{:error, :no_behaviour}`. This test
  pins the contract markers + cap-axis preservation + raising-handler
  defence instead.

  ## #154 cleanup (2026-06-20)

  The dead `:notify` action was removed — notification push became
  VM-internal (`Ezagent.Notifications.notify/2` has no cap check), so
  nothing consumed the `:notify` cap. Only `:subscribe` remains: it is
  the live cap-only subject that `Ezagent.NotificationSubscriptions`
  authorizes cross-entity subscribe/admin against.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Notifications

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.Behavior.new_style?(Notifications)
    end

    test "__behavior__?/0 returns true" do
      assert Notifications.__behavior__?()
    end

    test "__action_names__/0 lists [:subscribe]" do
      assert Notifications.__action_names__() == [:subscribe]
    end

    test "__action_spec__(:subscribe) carries args/returns/caps/modes" do
      spec = Notifications.__action_spec__(:subscribe)
      assert spec.name == :subscribe
      assert spec.args == %{}
      assert :subscribe in spec.caps
      assert :call in spec.modes
    end

    test "handle_subscribe/2 is exported (macro invariant)" do
      assert function_exported?(Notifications, :handle_subscribe, 2)
    end
  end

  describe "cap-only marker preserved" do
    test "dispatchable?/0 returns false (cap-only marker)" do
      assert Notifications.dispatchable?() == false
    end

    test "required_caps/0 uses the :user axis (User Kind only registration)" do
      caps = Notifications.required_caps()

      assert %Ezagent.Capability{kind: :user, behavior: Notifications, action: :subscribe} =
               caps[:subscribe]
    end

    test "data_owner/1 — entity URI returns the canonical instance URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      assert %URI{} = Notifications.data_owner(uri)
    end

    test "data_owner/1 — :any class-wide returns :any" do
      assert Notifications.data_owner(:any) == :any
    end

    test "data_owner/1 — unknown shape returns :no_owner" do
      assert Notifications.data_owner(:something_else) == :no_owner
    end

    test "handle_subscribe/2 raises if ever invoked (defence in depth)" do
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        Notifications.handle_subscribe(%{}, %{})
      end
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Notifications.actions() == [:subscribe]
      # Cap-only Behaviors have an empty interface() since they're
      # never dispatched — this matches the pre-migration shape.
      assert Notifications.interface() == %{} or is_map(Notifications.interface())

      subjects = Notifications.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert subjects == [:subscribe]
    end

    test "state_slice/0 preserved + create/1 builds persistent state (Lifecycle migration)" do
      # Slice key still auto-derives to `:notifications`. Under `use
      # Ezagent.Lifecycle`, the persistent-state builder is `create/1`
      # (empty — cap-only Behavior); `init_slice/1` is the macro-emitted
      # two-container wrapper.
      assert Notifications.state_slice() == :notifications
      assert Notifications.create(%{}) == {:ok, %{}}
      assert Notifications.init_slice(%{}) == %{state: %{}, transients: %{}}
    end
  end
end
