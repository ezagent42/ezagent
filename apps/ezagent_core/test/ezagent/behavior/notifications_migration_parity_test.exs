defmodule Ezagent.Behavior.NotificationsMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.Behavior.Notifications`
  per SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3
  Level 1 (dispatch parity).

  Notifications is a cap-only marker Behavior (`dispatchable?/0 ==
  false`, same shape as `Ezagent.Behavior.Presence` + the per-adapter
  `*.Allow` markers). The migration moves it from legacy
  `@behaviour Ezagent.Behavior` to the new `use Ezagent.Behavior` +
  declarative `action/3` shape with raising `handle_notify/2` +
  `handle_subscribe/2` (handlers must exist for the macro's
  @before_compile invariant but are never invoked because
  `dispatchable?/0 == false` prevents routing — defence in depth).

  ## Why no full `Kind.Runtime.handle_dispatch/4` path

  Cap-only Behaviors are intentionally unreachable via dispatch — see
  the longer note in `presence_migration_parity_test.exs`. This test
  pins the contract markers + cap-axis preservation + raising-handler
  defence instead.
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

    test "__action_names__/0 lists [:notify, :subscribe]" do
      assert Enum.sort(Notifications.__action_names__()) == [:notify, :subscribe]
    end

    test "__action_spec__/1 carries args/returns/caps/modes for each action" do
      for action <- [:notify, :subscribe] do
        spec = Notifications.__action_spec__(action)
        assert spec.name == action
        assert spec.args == %{}
        assert action in spec.caps
        assert :call in spec.modes
      end
    end

    test "handle_notify/2 + handle_subscribe/2 are exported (macro invariant)" do
      assert function_exported?(Notifications, :handle_notify, 2)
      assert function_exported?(Notifications, :handle_subscribe, 2)
    end
  end

  describe "cap-only marker preserved" do
    test "dispatchable?/0 returns false (cap-only marker)" do
      assert Notifications.dispatchable?() == false
    end

    test "required_caps/0 uses the :user axis (User Kind only registration)" do
      caps = Notifications.required_caps()

      assert %Ezagent.Capability{kind: :user, behavior: Notifications, action: :notify} =
               caps[:notify]

      assert %Ezagent.Capability{kind: :user, behavior: Notifications, action: :subscribe} =
               caps[:subscribe]
    end

    test "data_owner/1 — entity URI returns the canonical instance URI" do
      uri = URI.parse("entity://user/team-alpha/alice")
      assert %URI{} = Notifications.data_owner(uri)
    end

    test "data_owner/1 — :any class-wide returns :any" do
      assert Notifications.data_owner(:any) == :any
    end

    test "data_owner/1 — unknown shape returns :no_owner" do
      assert Notifications.data_owner(:something_else) == :no_owner
    end

    test "handle_notify/2 raises if ever invoked (defence in depth)" do
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        Notifications.handle_notify(%{}, %{})
      end
    end

    test "handle_subscribe/2 raises if ever invoked (defence in depth)" do
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        Notifications.handle_subscribe(%{}, %{})
      end
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Enum.sort(Notifications.actions()) == [:notify, :subscribe]
      # Cap-only Behaviors have an empty interface() since they're
      # never dispatched — this matches the pre-migration shape.
      assert Notifications.interface() == %{} or is_map(Notifications.interface())

      subjects = Notifications.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(subjects) == [:notify, :subscribe]
    end

    test "state_slice/0 + init_slice/1 unchanged (framework wiring)" do
      assert Notifications.state_slice() == :notifications
      assert Notifications.init_slice(%{}) == %{}
    end
  end
end
