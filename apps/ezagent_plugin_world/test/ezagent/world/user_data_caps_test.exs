defmodule Ezagent.World.UserDataCapsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.UserData

  test "list_users counts verified live capabilities instead of the stale row projection" do
    {workspace, user} = identities("runtime")
    runtime_cap = issued_cap(user, workspace, "runtime")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [])
    assert :ok = declare_workspace_member(workspace, user)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user, initial_caps: [runtime_cap]})

    on_exit(fn -> Ezagent.Kind.terminate(user) end)

    assert row_for(user, workspace)["cap_count"] ==
             MapSet.size(Ezagent.EntityCaps.verified_set(Ezagent.EntityCaps.load(user), user))

    assert row_for(user, workspace)["cap_count"] > 0
    durable_caps = Ezagent.Users.get_by_uri(user).caps

    assert MapSet.new(durable_caps) == MapSet.new(Ezagent.EntityCaps.load(user))
    assert durable_caps != []
  end

  test "unsigned artifacts left in serialized data do not determine the count" do
    {workspace, user} = identities("revoked")
    stale_one = unsigned_cap(user, workspace, "stale-one")
    stale_two = unsigned_cap(user, workspace, "stale-two")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [stale_one, stale_two])
    assert :ok = declare_workspace_member(workspace, user)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user, initial_caps: []})

    on_exit(fn -> Ezagent.Kind.terminate(user) end)

    expected = length(Ezagent.EntityCaps.load(user))
    assert expected != length(Ezagent.Users.get_by_uri(user).caps)
    assert row_for(user, workspace)["cap_count"] == expected
  end

  test "an unsigned serialized artifact is ignored while the current self-license remains" do
    {workspace, user} = identities("failure")
    cap = unsigned_cap(user, workspace, "target")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [cap])
    assert :ok = declare_workspace_member(workspace, user)
    assert :ok = Ezagent.Entity.spawn_principal(user)

    verified = Ezagent.EntityCaps.verified_set(Ezagent.EntityCaps.load(user), user)

    assert row_for(user, workspace)["cap_count"] == MapSet.size(verified)
    assert MapSet.size(verified) == 1
    refute cap in verified
  end

  test "World capability counts have no raw-store fallback" do
    source = File.read!(Path.expand("../../../lib/ezagent/world/user_data.ex", __DIR__))

    refute source =~ "length(user.caps)"
    assert source =~ "Ezagent.EntityCaps.load"
  end

  # The users-table roster is caller-authorized (read-plane PR-4 rework):
  # the caller must be a declared member of the workspace it lists. The
  # rows these tests read are the caller's OWN (self-view always reveals
  # its own metadata), so declare the user a member of its workspace.
  defp row_for(user, workspace) do
    UserData.list_users(user, workspace)
    |> Enum.find(&(&1["uri"] == URI.to_string(user)))
  end

  defp declare_workspace_member(%URI{host: ws_name}, %URI{} = user) do
    {:ok, _pid} = Ezagent.Workspace.create(ws_name, %{})
    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [user])
    :ok
  end

  defp identities(suffix) do
    unique = System.unique_integer([:positive])
    workspace_name = "world-cap-count-#{suffix}-#{unique}"
    {Ezagent.URI.workspace(workspace_name), Ezagent.URI.user(workspace_name, "user")}
  end

  defp issued_cap(receiver, workspace, target_name) do
    requested =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        Ezagent.URI.agent(Ezagent.URI.workspace_name!(workspace), target_name),
        workspace,
        receiver
      )

    Ezagent.Test.CapHelper.with_test_authority(requested.instance, :agent, fn authority ->
      Ezagent.Test.CapHelper.authority_signed_cap!(authority, receiver, requested)
    end)
  end

  defp unsigned_cap(receiver, workspace, target_name) do
    Ezagent.CreatorGrant.manage_cap(
      :agent,
      Ezagent.URI.agent(Ezagent.URI.workspace_name!(workspace), target_name),
      workspace,
      receiver
    )
  end
end
