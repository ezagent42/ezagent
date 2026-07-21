defmodule EzagentWeb.LiveAuthCapsTest do
  @moduledoc """
  Regression coverage for the capability source used by authenticated LiveViews.

  Runtime grants are stored in the principal's live Identity slice. The legacy
  `users.caps_json` projection may therefore lag behind and must not authorize a
  LiveView mount.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentWeb.LiveAuth

  setup do
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, cap_config) end)
    :ok
  end

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

    ensure_agent_authority(agent_uri)

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        user_uri,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )

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

    assert Ezagent.Domain.Pty.Access.may_read?(
             user_uri,
             agent_uri,
             socket.assigns.current_caps
           )

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

    ensure_agent_authority(owned_uri)

    {:ok, cap} =
      Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, principal_uri, requested_cap)

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

    assert Ezagent.Domain.Pty.Access.may_read?(
             principal_uri,
             owned_uri,
             socket.assigns.current_caps
           )

    assert_signed_cap_for(socket.assigns.current_caps, requested_cap, principal_uri)
  end

  test "cold User and Agent principals load receiver-bound persisted capabilities" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-cold-#{unique}")
    user_uri = Ezagent.URI.user("live-auth-cold-#{unique}", "user")
    agent_uri = Ezagent.URI.agent("live-auth-cold-#{unique}", "agent")
    user_cap = issued_manage_cap(user_uri, workspace_uri, "user-target")
    agent_cap = issued_manage_cap(agent_uri, workspace_uri, "agent-target")

    assert {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [user_cap])

    assert {:ok, _snapshot} =
             Ezagent.SnapshotStore.write(
               agent_uri,
               %{identity: %{state: %{caps: MapSet.new([agent_cap])}}},
               kind_type: :agent
             )

    assert :error = Ezagent.KindRegistry.lookup(user_uri)
    assert :error = Ezagent.KindRegistry.lookup(agent_uri)
    assert_mount_has_cap(user_uri, workspace_uri, user_cap)
    assert_mount_has_cap(agent_uri, workspace_uri, agent_cap)
  end

  test "revoke remains absent after the principal stops and restarts" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-revoke-#{unique}")
    user_uri = Ezagent.URI.user("live-auth-revoke-#{unique}", "user")
    cap = issued_manage_cap(user_uri, workspace_uri, "target")

    assert {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [cap])
    assert_mount_has_cap(user_uri, workspace_uri, cap)
    assert :ok = Ezagent.EntityCaps.revoke(user_uri, cap)
    assert_mount_lacks_cap(user_uri, workspace_uri, cap)

    assert :ok = Ezagent.Kind.terminate(user_uri)
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(user_uri)
    assert_mount_lacks_cap(user_uri, workspace_uri, cap)
  end

  test "storage keeps receiver-bound opaque artifacts and excludes another receiver" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-invalid-#{unique}")
    user_uri = Ezagent.URI.user("live-auth-invalid-#{unique}", "user")
    other_uri = Ezagent.URI.user("live-auth-invalid-#{unique}", "other")
    valid = issued_manage_cap(user_uri, workspace_uri, "valid-target")
    invalid = %{issued_manage_cap(user_uri, workspace_uri, "invalid-target") | action: :send}
    wrong_receiver = issued_manage_cap(other_uri, workspace_uri, "wrong-target")

    assert {:ok, _row} =
             Ezagent.Users.create(user_uri, "test-password", [valid, invalid, wrong_receiver])

    {:cont, socket} = mount(user_uri, workspace_uri)
    assert_cap_present(socket.assigns.current_caps, valid)
    # Storage is deliberately structural: a receiver-bound signed-looking
    # artifact may remain opaque at rest. The target verifier rejects this
    # mutated signature when it is presented for authorization.
    assert_cap_present(socket.assigns.current_caps, invalid)
    refute_cap_present(socket.assigns.current_caps, wrong_receiver)
  end

  test "an empty EntityCaps store assigns an empty MapSet" do
    unique = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.workspace("live-auth-reader-failure-#{unique}")
    user_uri = Ezagent.URI.user("live-auth-reader-failure-#{unique}", "user")
    assert {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [])

    assert {:cont, socket} = mount(user_uri, workspace_uri)
    assert socket.assigns.current_caps == MapSet.new()
  end

  test "LiveAuth capability reads have no legacy user or snapshot fallback" do
    source = File.read!(Path.expand("../../lib/ezagent_web/live_auth.ex", __DIR__))
    [load_caps_source] = Regex.run(~r/defp load_caps\(%URI\{}.*?defp load_caps\(_\)/s, source)

    assert load_caps_source =~ "Ezagent.EntityCaps.load()"
    refute load_caps_source =~ "Users.get_by_uri"
    refute load_caps_source =~ "caps_json"
    refute load_caps_source =~ "SnapshotStore"
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

  defp issued_manage_cap(receiver_uri, workspace_uri, target_name) do
    target_uri =
      Ezagent.URI.agent(Ezagent.URI.workspace_name!(workspace_uri), target_name)

    ensure_agent_authority(target_uri)

    requested =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        target_uri,
        workspace_uri,
        receiver_uri
      )

    {:ok, cap} =
      Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, receiver_uri, requested)

    cap
  end

  defp ensure_agent_authority(agent_uri) do
    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri}) do
      {:ok, _pid} -> on_exit(fn -> Ezagent.Kind.terminate(agent_uri) end)
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end

    :ok
  end

  defp assert_mount_has_cap(principal_uri, workspace_uri, cap) do
    {:cont, socket} = mount(principal_uri, workspace_uri)
    assert_cap_present(socket.assigns.current_caps, cap)
  end

  defp assert_mount_lacks_cap(principal_uri, workspace_uri, cap) do
    {:cont, socket} = mount(principal_uri, workspace_uri)
    refute_cap_present(socket.assigns.current_caps, cap)
  end

  defp assert_cap_present(caps, cap) do
    assert Enum.any?(
             caps,
             &(Ezagent.Capability.identity_key(&1) == Ezagent.Capability.identity_key(cap))
           )
  end

  defp refute_cap_present(caps, cap) do
    refute Enum.any?(
             caps,
             &(Ezagent.Capability.identity_key(&1) == Ezagent.Capability.identity_key(cap))
           )
  end

  defp mount(principal_uri, workspace_uri) do
    LiveAuth.on_mount(
      :require_entity,
      %{},
      %{
        "current_entity_uri" => URI.to_string(principal_uri),
        "current_workspace_uri" => URI.to_string(workspace_uri)
      },
      build_socket()
    )
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
  end
end
