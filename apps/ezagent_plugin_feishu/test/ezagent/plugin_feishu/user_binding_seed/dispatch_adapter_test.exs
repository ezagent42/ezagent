defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapterTest do
  @moduledoc """
  Current fail-closed contract for the deferred B-layer executor.

  Future runtime-authorization acceptance requirements remain in
  `BootDispatchFeasibilityTest`, which is explicitly deferred. These active
  tests prove this placeholder cannot become a production authority early.
  """

  use ExUnit.Case, async: true

  alias EzagentPluginFeishu.UserBindingSeed.DispatchAdapter

  describe "bind/3" do
    test "raises until runtime boot authorization is integrated" do
      workspace_uri = Ezagent.URI.new!("workspace://seed-adapter")
      user_uri = Ezagent.URI.new!("entity://seed-adapter/user/newcomer")

      assert_raise RuntimeError, ~r/seed executor\/boot authorization is not configured/, fn ->
        DispatchAdapter.bind(workspace_uri, "ou_adapter_bind", user_uri)
      end
    end
  end

  describe "list_current/1" do
    test "raises until runtime boot authorization is integrated" do
      workspace_uri = Ezagent.URI.new!("workspace://seed-adapter")

      assert_raise RuntimeError, ~r/seed executor\/boot authorization is not configured/, fn ->
        DispatchAdapter.list_current(workspace_uri)
      end
    end
  end
end
