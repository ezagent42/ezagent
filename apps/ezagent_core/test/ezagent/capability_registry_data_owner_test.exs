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
      uri = Ezagent.URI.new!("entity://acme/user/alice")
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

      uri = Ezagent.URI.new!("entity://acme/user/x")
      assert :no_owner = CapabilityRegistry.data_owner_of(UnownedBehavior, uri)
    end
  end

  describe "default_grants_from_data_owner/2 — basic contract (PR-OWN-1)" do
    test "returns tuple list [{grantee, %Capability{}}]" do
      target = Ezagent.URI.new!("entity://acme/user/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      # Each entry is a 2-tuple {URI.t, %Capability{}}
      Enum.each(grants, fn entry ->
        assert {%URI{} = _grantee, %Ezagent.Capability{} = _cap} = entry
      end)
    end

    test "grantee is the data owner (== target_uri for OwnedBehavior)" do
      target = Ezagent.URI.new!("entity://acme/user/alice")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      Enum.each(grants, fn {grantee, _cap} ->
        assert grantee == target
      end)
    end

    test "%Capability{} has correct kind + behavior + instance + workspace_uri" do
      target = Ezagent.URI.new!("entity://acme/user/alice")
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
      target = Ezagent.URI.new!("entity://acme/user/alice")
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
      target = Ezagent.URI.new!("entity://acme/user/alice")
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

  describe "default_grants_from_data_owner/2 — URI canonicalization (codex PR-OWN-1 HIGH)" do
    # Codex PR-OWN-1 HIGH: round-1 stored the raw target_uri in
    # the cap's `:instance` field, so an action-query URI like
    # `entity://acme/user/alice?action=identity.list_caps` would
    # mint a cap that never matches dispatch's canonical instance
    # (dispatch canonicalizes via `Ezagent.URI.instance/1`).
    # Round-2 fix canonicalizes upfront in the helper.
    test "action-query target URI yields a cap on the canonical bare instance" do
      action_target = Ezagent.URI.new!("entity://acme/user/alice?action=read")
      bare_target = Ezagent.URI.new!("entity://acme/user/alice")

      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, action_target)

      # Filter for OwnedBehavior (skip OwnedCapOnlyBehavior etc).
      [{grantee, cap}] = Enum.filter(grants, fn {_g, c} -> c.behavior == OwnedBehavior end)

      # grantee was computed from the CANONICAL bare URI (the test
      # OwnedBehavior returns target as its own owner).
      assert grantee == bare_target,
             "owner-lookup must use canonical instance, not raw URI with query"

      # cap.instance is the canonical bare URI — dispatch-side
      # `Capability.matches?/2` will succeed.
      assert cap.instance == bare_target,
             "cap.instance must be canonical (no query) so it matches dispatch"

      # And the canonical instance is NOT the raw action-query URI.
      refute cap.instance == action_target
    end

    test "reserved entity subresource target URI is rejected" do
      assert_raise ArgumentError, ~r/entity URI sub-resource positions are reserved/, fn ->
        Ezagent.URI.new!("entity://acme/user/alice/sessions/foo?action=write")
      end
    end

    test "match-level regression: generated cap matches dispatch's needed cap (codex round-2 MED)" do
      # Round-2 fix: derive `workspace_uri` from RAW target_uri so
      # the helper mirrors `Capability.cap_for_action/3` exactly.
      # This test asserts the END contract — round-1 + round-2 unit
      # tests only verified URI fields piecewise; this asserts that
      # `Capability.matches?/2` actually succeeds, the real authz gate.
      target = Ezagent.URI.new!("entity://acme/user/alice?action=read")

      [{_grantee, granted_cap}] =
        CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)
        |> Enum.filter(fn {_g, c} -> c.behavior == OwnedBehavior end)

      # Build dispatch's needed-cap shape directly (mirrors what
      # `Ezagent.Kind.Runtime.handle_dispatch` step 5.5 does).
      needed = %{
        kind: :owned_test_kind,
        behavior: OwnedBehavior,
        # SPEC 2026-05-27 capability-action-axis — the target URI's
        # query is `action=read`; mirror it in the needed shape.
        action: :read,
        instance: Ezagent.URI.instance(target),
        workspace_uri: Ezagent.Capability.workspace_of(target)
      }

      assert Ezagent.Capability.matches?(granted_cap, needed),
             "owner default grant must authorize dispatch on the same target — " <>
               "round-2 workspace_uri derivation matters"
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

      target = Ezagent.URI.new!("entity://acme/user/x")
      grants = CapabilityRegistry.default_grants_from_data_owner(OwnedKind, target)

      # AnyOwnerBehavior should NOT appear in grants (data_owner == :any).
      refute Enum.any?(grants, fn {_g, cap} -> cap.behavior == AnyOwnerBehavior end),
             ":any owner must produce no default grant — caller relies on explicit grant_cap"
    end
  end
end
