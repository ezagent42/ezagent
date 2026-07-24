defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapterTest do
  @moduledoc """
  B-layer (DEFERRED): the DispatchAdapter's canonical-admin auto-elevation
  is not yet integrated. These tests are skipped until boot-auth lands.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :skip

  alias EzagentPluginFeishu.UserBinding, as: UB
  alias EzagentPluginFeishu.UserBindingSeed.DispatchAdapter

  defp workspace!(ws_name) do
    {:ok, _pid} = Ezagent.Workspace.create(ws_name)
    Ezagent.URI.new!("workspace://#{ws_name}")
  end

  describe "bind/3" do
    test "binds a fresh open_id through real dispatch, bound_by is the real admin" do
      ws_name = "seed-adapter-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)
      user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
      open_id = "ou_adapter_bind_#{System.unique_integer([:positive])}"

      assert {:ok, %{open_id: ^open_id, user_uri: user_uri_str}} =
               DispatchAdapter.bind(ws_uri, open_id, user_uri)

      assert user_uri_str == URI.to_string(user_uri)

      row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)
      assert row.bound_by == URI.to_string(Ezagent.Entity.User.admin_uri())
    end

    test "cross-workspace hijack attempt is refused by the real handler" do
      ws_name = "seed-adapter-hijack-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)
      other_ws_name = "seed-adapter-other-#{System.unique_integer([:positive])}"
      _other_ws_uri = workspace!(other_ws_name)

      open_id = "ou_adapter_hijack_#{System.unique_integer([:positive])}"
      # First bind it to the OTHER workspace's user via the SAME adapter.
      foreign_user = Ezagent.URI.new!("entity://#{other_ws_name}/user/eve")

      {:ok, _} =
        DispatchAdapter.bind(
          Ezagent.URI.new!("workspace://#{other_ws_name}"),
          open_id,
          foreign_user
        )

      # Now attempt to rebind it under THIS workspace — must be refused.
      user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
      assert {:error, _} = DispatchAdapter.bind(ws_uri, open_id, user_uri)

      # Original binding survives.
      {:ok, resolved} = UB.resolve(open_id)
      assert URI.to_string(resolved) == URI.to_string(foreign_user)
    end
  end

  describe "list_current/1" do
    test "returns bindings scoped to the target workspace" do
      ws_name = "seed-adapter-list-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)
      user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
      open_id = "ou_adapter_list_#{System.unique_integer([:positive])}"

      {:ok, _} = DispatchAdapter.bind(ws_uri, open_id, user_uri)

      assert {:ok, bindings} = DispatchAdapter.list_current(ws_uri)
      assert Enum.any?(bindings, fn b -> b.open_id == open_id end)
    end

    test "returns an empty list for a workspace with no bindings yet" do
      ws_name = "seed-adapter-empty-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)

      assert {:ok, []} = DispatchAdapter.list_current(ws_uri)
    end
  end
end
