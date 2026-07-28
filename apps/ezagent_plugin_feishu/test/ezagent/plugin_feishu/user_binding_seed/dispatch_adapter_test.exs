defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapterTest do
  @moduledoc "Fail-closed configuration contract for the production seed adapter."

  use ExUnit.Case, async: false

  alias EzagentPluginFeishu.UserBindingSeed.DispatchAdapter

  setup do
    previous = Application.get_env(:ezagent_plugin_feishu, :seed_operator_uri)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ezagent_plugin_feishu, :seed_operator_uri)
      else
        Application.put_env(:ezagent_plugin_feishu, :seed_operator_uri, previous)
      end
    end)

    :ok
  end

  describe "bind/3" do
    test "fails closed when the runtime operator is absent" do
      workspace_uri = Ezagent.URI.new!("workspace://seed-adapter")
      user_uri = Ezagent.URI.new!("entity://seed-adapter/user/newcomer")

      Application.delete_env(:ezagent_plugin_feishu, :seed_operator_uri)

      assert {:error, :seed_operator_not_configured} =
               DispatchAdapter.bind(workspace_uri, "ou_adapter_bind", user_uri)
    end

    test "rejects a configured non-admin operator unsupported by the reviewed main seam" do
      workspace_uri = Ezagent.URI.new!("workspace://seed-adapter")
      user_uri = Ezagent.URI.new!("entity://seed-adapter/user/newcomer")

      Application.put_env(
        :ezagent_plugin_feishu,
        :seed_operator_uri,
        "entity://seed-adapter/user/operator"
      )

      assert {:error, :unsupported_seed_operator} =
               DispatchAdapter.bind(workspace_uri, "ou_adapter_bind", user_uri)
    end
  end

  describe "list_current/1" do
    test "rejects a malformed runtime operator without exposing its value" do
      workspace_uri = Ezagent.URI.new!("workspace://seed-adapter")

      Application.put_env(:ezagent_plugin_feishu, :seed_operator_uri, "not a principal URI")

      assert {:error, :invalid_seed_operator_uri} =
               DispatchAdapter.list_current(workspace_uri)
    end
  end
end
