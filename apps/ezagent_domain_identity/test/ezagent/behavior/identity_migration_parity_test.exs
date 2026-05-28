defmodule Ezagent.Behavior.IdentityMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1).

  Validates that the migrated `Ezagent.Behavior.Identity` AND
  `Ezagent.Behavior.IdentityAdmin` produce the same dispatch-visible
  outcomes via the new-contract path (`Kind.Runtime.handle_dispatch/4`
  → `handle_<action>/2` → `apply_effects/2`) as the legacy `invoke/4`
  did pre-migration.

  Both Behaviors share the `:identity` slice (and `state_slice/0 ==
  :identity` on both); the parity test exercises them on the same
  state to prove the shared-slice contract works end-to-end through
  the new dispatch.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.Behavior.{Identity, IdentityAdmin}
  alias Ezagent.Capability

  defmodule StubUserKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :identity_parity_stub
    @impl true
    def behaviors, do: [Ezagent.Behavior.Identity, Ezagent.Behavior.IdentityAdmin]
    @impl true
    def persistence, do: :ephemeral
  end

  @workspace_uri URI.new!("workspace://identity-parity")
  @granter URI.parse("entity://user/system/admin")

  setup do
    :ok = BehaviorRegistry.register(StubUserKind, :list_caps, Identity)
    :ok = BehaviorRegistry.register(StubUserKind, :has_cap?, Identity)
    :ok = BehaviorRegistry.register(StubUserKind, :grant_cap, IdentityAdmin)
    :ok = BehaviorRegistry.register(StubUserKind, :revoke_cap, IdentityAdmin)

    n = System.unique_integer([:positive])
    user_uri = URI.parse("entity://user/identity-parity/alice-#{n}")

    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
    state = %{identity: %{caps: admin_caps}}

    {:ok, user_uri: user_uri, state: state, admin_caps: admin_caps}
  end

  defp build_invocation(user_uri, action, args, caller_caps \\ MapSet.new()) do
    target =
      user_uri
      |> URI.to_string()
      |> Kernel.<>("?action=identity.#{action}")
      |> URI.parse()

    %Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: @granter, caps: caller_caps, reply: :sync}
    }
  end

  describe "Identity — Level 1 dispatch parity" do
    test "list_caps dispatch returns the slice cap list (no slice mutation)",
         %{user_uri: user_uri, state: state, admin_caps: admin_caps} do
      inv = build_invocation(user_uri, :list_caps, %{}, admin_caps)

      assert {:ok, new_state, %{caps: caps_list}, nil} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      # No slice mutation — read-only action.
      assert new_state == state
      assert length(caps_list) == MapSet.size(admin_caps)
    end

    test "has_cap? dispatch returns true for admin all-cap match",
         %{user_uri: user_uri, state: state, admin_caps: admin_caps} do
      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/system/main"),
        workspace_uri: @workspace_uri
      }

      inv = build_invocation(user_uri, :has_cap?, %{cap: needed}, admin_caps)

      assert {:ok, _new_state, %{has: true}, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)
    end

    test "has_cap? dispatch returns false when no caps match",
         %{user_uri: user_uri, admin_caps: admin_caps} do
      empty_state = %{identity: %{caps: MapSet.new()}}

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/system/main"),
        workspace_uri: @workspace_uri
      }

      inv = build_invocation(user_uri, :has_cap?, %{cap: needed}, admin_caps)

      assert {:ok, _new_state, %{has: false}, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, empty_state, StubUserKind, user_uri)
    end
  end

  describe "IdentityAdmin — Level 1 dispatch parity" do
    test "grant_cap dispatch adds cap to the shared :identity slice",
         %{user_uri: user_uri, admin_caps: admin_caps} do
      # Start with a slice that only has admin's cross-cutting caps.
      state = %{identity: %{caps: admin_caps}}

      new_cap = %Capability{
        kind: :echo,
        behavior: :any,
        instance: :any,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: DateTime.utc_now()
      }

      inv = build_invocation(user_uri, :grant_cap, %{cap: new_cap}, admin_caps)

      assert {:ok, new_state, %{caps: cap_list}, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      # Slice gained one cap.
      assert MapSet.size(new_state.identity.caps) == MapSet.size(admin_caps) + 1
      assert new_cap in cap_list
    end

    test "revoke_cap dispatch removes a cap from the shared :identity slice",
         %{user_uri: user_uri, admin_caps: admin_caps} do
      cap = %Capability{
        kind: :echo,
        behavior: :any,
        instance: :any,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: DateTime.utc_now()
      }

      state = %{identity: %{caps: MapSet.put(admin_caps, cap)}}

      inv = build_invocation(user_uri, :revoke_cap, %{cap: cap}, admin_caps)

      assert {:ok, new_state, %{caps: _cap_list}, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubUserKind, user_uri)

      assert MapSet.size(new_state.identity.caps) == MapSet.size(admin_caps)
      refute cap in new_state.identity.caps
    end
  end
end
