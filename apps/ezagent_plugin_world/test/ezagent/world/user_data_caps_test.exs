defmodule Ezagent.World.UserDataCapsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.UserData

  setup do
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, cap_config) end)
    :ok
  end

  test "list_users counts verified live capabilities instead of the stale row projection" do
    {workspace, user} = identities("runtime")
    runtime_cap = issued_cap(user, workspace, "runtime")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [])

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user, initial_caps: [runtime_cap]})

    on_exit(fn -> Ezagent.Kind.terminate(user) end)

    assert row_for(user)["cap_count"] ==
             MapSet.size(Ezagent.EntityCaps.verified_set(Ezagent.EntityCaps.load(user), user))

    assert row_for(user)["cap_count"] > 0
    assert Ezagent.Users.get_by_uri(user).caps == []
  end

  test "revoked artifacts left in serialized data do not determine the count" do
    {workspace, user} = identities("revoked")
    stale_one = issued_cap(user, workspace, "stale-one")
    stale_two = issued_cap(user, workspace, "stale-two")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [stale_one, stale_two])

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user, initial_caps: []})

    on_exit(fn -> Ezagent.Kind.terminate(user) end)

    expected = length(Ezagent.EntityCaps.load(user))
    assert expected != length(Ezagent.Users.get_by_uri(user).caps)
    assert row_for(user)["cap_count"] == expected
  end

  test "reader failure preserves the user row and reports zero capabilities" do
    {workspace, user} = identities("failure")
    cap = issued_cap(user, workspace, "target")
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [cap])

    config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
    signing = Keyword.fetch!(config, :signing)

    failing_signing =
      Keyword.put(signing, :seed_provider, fn _version -> {:error, :unavailable} end)

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(config, :signing, failing_signing)
    )

    assert row_for(user)["cap_count"] == 0
  end

  test "World capability counts have no raw-store fallback" do
    source = File.read!(Path.expand("../../../lib/ezagent/world/user_data.ex", __DIR__))

    refute source =~ "length(user.caps)"
    assert source =~ "Ezagent.EntityCaps.load"
  end

  defp row_for(user) do
    UserData.list_users(nil)
    |> Enum.find(&(&1["uri"] == URI.to_string(user)))
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

    {:ok, cap} = Ezagent.Cap.issue({:genesis, receiver}, receiver, requested)
    cap
  end
end
