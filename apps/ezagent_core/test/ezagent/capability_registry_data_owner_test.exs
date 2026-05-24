defmodule Ezagent.CapabilityRegistry.DataOwnerTest do
  @moduledoc """
  PR-OWN-1 acceptance tests for `data_owner_of/2` +
  `default_grants_from_data_owner/2`.

  Uses test-only `Ezagent.TestSupport.OwnedBehavior` +
  `OwnedCapOnlyBehavior` + `OwnedKind` so no real Behavior is
  touched. PR-OWN-2..6 add per-Behavior data_owner declarations;
  this file stays as the contract test.

  Round-5 regression: assert the helper enumerates BOTH dispatchable
  AND cap-only Behaviors (codex round-4 caught the bug where the
  ETS pattern silently returned empty list).
  """
  use ExUnit.Case, async: false

  alias Ezagent.CapabilityRegistry
  alias Ezagent.TestSupport.{OwnedBehavior, OwnedCapOnlyBehavior, OwnedKind}

  setup do
    # Register the test Behaviors against the synthetic Kind once
    # per test (CapabilityRegistry.register is idempotent only for
    # same {kind, action, behavior} — we use unique synthetic atoms
    # to avoid conflicts).
    :ok = CapabilityRegistry.register(OwnedKind, :read, OwnedBehavior)
    :ok = CapabilityRegistry.register(OwnedKind, :write, OwnedBehavior)
    :ok = CapabilityRegistry.register(OwnedKind, :subscribe, OwnedCapOnlyBehavior)

    on_exit(fn ->
      # ETS table is :public (per EtsOwner pattern); delete the rows
      # so this test doesn't leak into other test files.
      :ets.delete(CapabilityRegistry.Subjects.table(), {OwnedKind, OwnedBehavior, :read})
      :ets.delete(CapabilityRegistry.Subjects.table(), {OwnedKind, OwnedBehavior, :write})
      :ets.delete(
        CapabilityRegistry.Subjects.table(),
        {OwnedKind, OwnedCapOnlyBehavior, :subscribe}
      )
    end)

    :ok
  end

  describe "data_owner_of/2" do
    test "calls Behavior's data_owner/1 when exported" do
      uri = URI.parse("entity://user/acme/alice")
      assert ^uri = CapabilityRegistry.data_owner_of(OwnedBehavior, uri)
    end

    test "returns :no_owner for non-URI input the Behavior doesn't handle" do
      assert :no_owner = CapabilityRegistry.data_owner_of(OwnedBehavior, :any)
    end

    test "returns :no_owner when Behavior does not export data_owner/1" do
      defmodule UnownedBehavior do
        @behaviour Ezagent.Behavior
        def actions, do: [:noop]
        def state_slice, do: :u
        def init_slice(_), do: %{}
        def invoke(_, s, _, _), do: {:ok, s}
        def cap_subjects, do: []
        def interface, do: %{noop: %{description: "no-op", args: %{}}}
      end

      uri = URI.parse("entity://user/acme/x")
      assert :no_owner = CapabilityRegistry.data_owner_of(UnownedBehavior, uri)
    end
  end

  describe "default_grants_from_data_owner/2 — basic contract (PR-OWN-1)" do
    test "returns tuple list [{grantee, %Capability{}}]" do
      target = URI.parse("entity://user/acme/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      # Each entry is a 2-tuple {URI.t, %Capability{}}
      Enum.each(grants, fn entry ->
        assert {%URI{} = _grantee, %Ezagent.Capability{} = _cap} = entry
      end)
    end

    test "grantee is the data owner (== target_uri for OwnedBehavior)" do
      target = URI.parse("entity://user/acme/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      Enum.each(grants, fn {grantee, _cap} ->
        assert grantee == target
      end)
    end

    test "%Capability{} has correct kind + behavior + instance + workspace_uri" do
      target = URI.parse("entity://user/acme/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      Enum.each(grants, fn {_grantee, cap} ->
        assert cap.kind == :owned_test_kind
        assert cap.behavior in [OwnedBehavior, OwnedCapOnlyBehavior]
        assert cap.instance == target
        assert match?(%URI{}, cap.workspace_uri) or cap.workspace_uri == :any
        assert match?(%URI{}, cap.granted_by)
        assert match?(%DateTime{}, cap.granted_at)
      end)
    end
  end

  describe "default_grants_from_data_owner/2 — round-5 regression (codex round-4 HIGH)" do
    test "enumerates dispatchable AND cap-only Behaviors (no silent skip)" do
      target = URI.parse("entity://user/acme/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      behaviors_seen =
        grants
        |> Enum.map(fn {_grantee, cap} -> cap.behavior end)
        |> Enum.uniq()
        |> Enum.sort()

      # BOTH must appear — the round-4 bug silently dropped
      # OwnedCapOnlyBehavior because the wrong ETS pattern matched
      # nothing.
      assert OwnedBehavior in behaviors_seen,
             "dispatchable Behavior missing — round-1 abstraction bug regression"

      assert OwnedCapOnlyBehavior in behaviors_seen,
             "cap-only Behavior missing — round-4 ETS-shape bug regression"
    end

    test "multi-action dispatchable Behavior appears ONCE (Enum.uniq on behavior)" do
      target = URI.parse("entity://user/acme/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      owned_behavior_count =
        Enum.count(grants, fn {_g, cap} -> cap.behavior == OwnedBehavior end)

      # OwnedBehavior is registered for 2 actions (:read + :write)
      # but should produce a single cap (the cap is behavior-scoped,
      # not action-scoped — SPEC §1).
      assert owned_behavior_count == 1,
             "behavior-scoped cap should appear once even with multiple actions"
    end
  end

  describe "default_grants_from_data_owner/2 — non-URI owner returns no entry" do
    test ":any / :no_owner / {:scope, _, _} produce empty list" do
      defmodule AnyOwnerBehavior do
        @behaviour Ezagent.Behavior
        def actions, do: [:do_thing]
        def state_slice, do: :any_o
        def init_slice(_), do: %{}
        def invoke(_, s, _, _), do: {:ok, s}
        def cap_subjects, do: [{:do_thing, "any-owner — do"}]
        def interface, do: %{do_thing: %{description: "do", args: %{}}}
        def data_owner(_), do: :any
      end

      :ok = CapabilityRegistry.register(OwnedKind, :do_thing, AnyOwnerBehavior)

      on_exit(fn ->
        :ets.delete(CapabilityRegistry.Subjects.table(), {OwnedKind, AnyOwnerBehavior, :do_thing})
      end)

      target = URI.parse("entity://user/acme/x")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      # AnyOwnerBehavior should NOT appear in grants (data_owner == :any).
      refute Enum.any?(grants, fn {_g, cap} -> cap.behavior == AnyOwnerBehavior end),
             ":any owner must produce no default grant — caller relies on explicit grant_cap"
    end
  end
end
