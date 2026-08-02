defmodule Ezagent.ActionSet.IdentityMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1).

  Validates that the migrated `Ezagent.ActionSet.Identity` AND
  `Ezagent.ActionSet.IdentityAdmin` produce the same dispatch-visible
  outcomes via the new-contract path (`Kind.Runtime.handle_dispatch/4`
  → `handle_<action>/2` → `apply_effects/2`) as the legacy `invoke/4`
  did pre-migration.

  Both Behaviors share the `:identity` slice (and `state_slice/0 ==
  :identity` on both); the parity test exercises them on the same
  state to prove the shared-slice contract works end-to-end through
  the new dispatch.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper,
    only: [
      self_license_cap!: 2,
      signed_fixture_cap!: 5,
      signed_invocation!: 2,
      signed_required_cap!: 5
    ]

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.ActionSet.{Identity, IdentityAdmin}

  defmodule StubUserKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :identity_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin]
    @impl true
    def persistence, do: :ephemeral
  end

  @workspace_uri URI.new!("workspace://identity-parity")
  @granter Ezagent.URI.new!("entity://system/user/admin")

  setup do
    :ok = BehaviorRegistry.register(StubUserKind, :list_caps, Identity)
    :ok = BehaviorRegistry.register(StubUserKind, :has_cap?, Identity)
    :ok = BehaviorRegistry.register(StubUserKind, :grant_cap, IdentityAdmin)
    :ok = BehaviorRegistry.register(StubUserKind, :revoke_cap, IdentityAdmin)

    n = System.unique_integer([:positive])
    user_uri = Ezagent.URI.new!("entity://identity-parity/user/alice-#{n}")

    initial_caps = MapSet.new([self_license_cap!(user_uri, :user)])
    :ok = Ezagent.IdentityCaps.Store.persist(user_uri, initial_caps)
    state = %{identity: %{caps: initial_caps}}

    {:ok, user_uri: user_uri, state: state, initial_caps: initial_caps}
  end

  defp build_invocation(user_uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(user_uri)}?action=identity.#{action}")

    behavior =
      if action in [:list_caps, :has_cap?],
        do: Identity,
        else: IdentityAdmin

    auth_cap =
      signed_required_cap!(target, :identity_parity_stub, behavior, action, @granter)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: @granter, caps: MapSet.new([auth_cap]), reply: :sync}
    }
    |> signed_invocation!(:identity_parity_stub)
  end

  describe "Identity — Level 1 dispatch parity" do
    test "list_caps dispatch returns the slice cap list (no slice mutation)",
         %{user_uri: user_uri, state: state, initial_caps: initial_caps} do
      inv = build_invocation(user_uri, :list_caps, %{})

      assert {:ok, new_state, %{caps: caps_list}, nil, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      # No slice mutation — read-only action.
      assert new_state == state
      assert length(caps_list) == MapSet.size(initial_caps)
    end

    test "has_cap? dispatch returns true for admin all-cap match",
         %{user_uri: user_uri, state: state} do
      needed = %{
        kind: :user,
        behavior: Ezagent.ActionSet.Identity,
        action: :self_license,
        instance: user_uri,
        workspace_uri: @workspace_uri
      }

      inv = build_invocation(user_uri, :has_cap?, %{cap: needed})

      assert {:ok, _new_state, %{has: true}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)
    end

    test "has_cap? dispatch returns false when no caps match", %{user_uri: user_uri} do
      empty_state = %{identity: %{caps: MapSet.new()}}

      needed = %{
        kind: :session,
        behavior: Ezagent.ActionSet.Session,
        instance: URI.new!("session://system/default/main"),
        workspace_uri: @workspace_uri
      }

      inv = build_invocation(user_uri, :has_cap?, %{cap: needed})

      assert {:ok, _new_state, %{has: false}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, empty_state, StubUserKind, user_uri)
    end
  end

  describe "IdentityAdmin — Level 1 dispatch parity" do
    test "grant_cap dispatch adds cap to the shared :identity slice",
         %{user_uri: user_uri, initial_caps: initial_caps} do
      state = %{identity: %{caps: initial_caps}}

      new_cap =
        signed_fixture_cap!(
          Ezagent.URI.new!("session://identity-parity/default/grant-target"),
          :session,
          Ezagent.ActionSet.Session,
          :send,
          user_uri
        )

      inv = build_invocation(user_uri, :grant_cap, %{cap: new_cap})

      assert {:ok, new_state, %{caps: cap_list}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      # Slice gained one cap.
      assert MapSet.size(new_state.identity.caps) == MapSet.size(initial_caps) + 1
      assert new_cap in cap_list
    end

    test "revoke_cap dispatch removes a cap from the shared :identity slice",
         %{user_uri: user_uri, initial_caps: initial_caps} do
      cap =
        signed_fixture_cap!(
          Ezagent.URI.new!("session://identity-parity/default/revoke-target"),
          :session,
          Ezagent.ActionSet.Session,
          :send,
          user_uri
        )

      state = %{identity: %{caps: MapSet.put(initial_caps, cap)}}

      inv = build_invocation(user_uri, :revoke_cap, %{cap: cap})

      assert {:ok, new_state, %{caps: _cap_list}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      assert MapSet.size(new_state.identity.caps) == MapSet.size(initial_caps)
      refute cap in new_state.identity.caps
    end
  end
end
