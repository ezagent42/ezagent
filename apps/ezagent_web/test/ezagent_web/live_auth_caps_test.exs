defmodule EzagentWeb.LiveAuthCapsTest do
  @moduledoc """
  Regression coverage for the capability source used by authenticated LiveViews.

  Runtime grants are stored in the principal's live Identity slice. The legacy
  `users.caps_json` projection may therefore lag behind and must not authorize a
  LiveView mount.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentWeb.LiveAuth

  test "mount loads a runtime-granted creator capability from Identity" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-#{unique}")
    user_uri = Ezagent.URI.user("live-auth-#{unique}", "creator")
    agent_uri = Ezagent.URI.agent("live-auth-#{unique}", "owned-agent")

    {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(user_uri)
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)

    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent_uri,
        workspace_uri,
        user_uri
      )

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        user_uri,
        cap,
        {:genesis, user_uri},
        :sync
      )

    assert Ezagent.Users.get_by_uri(user_uri).caps == []

    assert Enum.any?(Ezagent.Identity.list_caps_for(user_uri), fn held ->
             Ezagent.Capability.identity_key(held) == Ezagent.Capability.identity_key(cap)
           end)

    assert {:cont, socket} =
             LiveAuth.on_mount(
               :require_entity,
               %{},
               %{
                 "current_entity_uri" => URI.to_string(user_uri),
                 "current_workspace_uri" => URI.to_string(workspace_uri)
               },
               build_socket()
             )

    assert Ezagent.Domain.Pty.Access.may_read?(agent_uri, socket.assigns.current_caps)
    assert Enum.all?(socket.assigns.current_caps, &Ezagent.Cap.verify/1)

    assert_signed_cap_for(socket.assigns.current_caps, cap, user_uri)
  end

  test "mount loads an Agent principal's Identity capabilities" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-agent-#{unique}")
    principal_uri = Ezagent.URI.agent("live-auth-agent-#{unique}", "principal")
    owned_uri = Ezagent.URI.agent("live-auth-agent-#{unique}", "owned-agent")

    requested_cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        owned_uri,
        workspace_uri,
        principal_uri
      )

    {:ok, cap} = Ezagent.Cap.issue({:genesis, principal_uri}, principal_uri, requested_cap)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: principal_uri,
        initial_caps: MapSet.new([cap])
      })

    on_exit(fn -> Ezagent.Kind.terminate(principal_uri) end)

    assert {:cont, socket} =
             LiveAuth.on_mount(
               :require_entity,
               %{},
               %{
                 "current_entity_uri" => URI.to_string(principal_uri),
                 "current_workspace_uri" => URI.to_string(workspace_uri)
               },
               build_socket()
             )

    assert Ezagent.Domain.Pty.Access.may_read?(owned_uri, socket.assigns.current_caps)
    assert Enum.all?(socket.assigns.current_caps, &Ezagent.Cap.verify/1)

    assert_signed_cap_for(socket.assigns.current_caps, requested_cap, principal_uri)
  end

  defp assert_signed_cap_for(caps, requested_cap, receiver_uri) do
    assert %Ezagent.Capability{
             signature: signature,
             key_id: key_id,
             grantee_uri: ^receiver_uri
           } =
             Enum.find(caps, fn held ->
               Ezagent.Capability.identity_key(held) ==
                 Ezagent.Capability.identity_key(requested_cap)
             end)

    assert is_binary(signature) and byte_size(signature) > 0
    assert is_binary(key_id) and key_id != ""
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
  end
end
