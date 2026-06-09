defmodule EzagentPluginFeishu.UserBindingTest do
  @moduledoc """
  Phase 6 PR 15 — bind / unbind / resolve / open_ids_for.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.UserBinding

  test "bind then resolve" do
    open_id = "ou_bind_test_#{System.unique_integer([:positive])}"
    {:ok, _row} = UserBinding.bind(open_id, "entity://team-alpha/user/alice", "entity://system/user/admin")

    assert {:ok, %URI{} = uri} = UserBinding.resolve(open_id)
    assert URI.to_string(uri) == "entity://team-alpha/user/alice"
  end

  test "resolve returns :error for unbound" do
    assert :error = UserBinding.resolve("ou_no_such_binding")
    assert :error = UserBinding.resolve(nil)
    assert :error = UserBinding.resolve("")
  end

  test "rebind replaces user_uri silently" do
    open_id = "ou_rebind_#{System.unique_integer([:positive])}"
    {:ok, _} = UserBinding.bind(open_id, "entity://team-alpha/user/alice", "entity://system/user/admin")
    {:ok, _} = UserBinding.bind(open_id, "entity://team-alpha/user/bob", "entity://system/user/admin")

    {:ok, uri} = UserBinding.resolve(open_id)
    assert URI.to_string(uri) == "entity://team-alpha/user/bob"
  end

  test "unbind removes the row" do
    open_id = "ou_unbind_#{System.unique_integer([:positive])}"
    {:ok, _} = UserBinding.bind(open_id, "entity://team-alpha/user/alice", "entity://system/user/admin")
    assert :ok = UserBinding.unbind(open_id)
    assert :error = UserBinding.resolve(open_id)
  end

  test "unbind on unknown returns :not_found" do
    assert {:error, :not_found} = UserBinding.unbind("ou_never_bound")
  end

  test "open_ids_for finds all bindings for a user" do
    user = "entity://team-alpha/user/multi_#{System.unique_integer([:positive])}"
    {:ok, _} = UserBinding.bind("ou_one_#{System.unique_integer([:positive])}", user, "entity://system/user/admin")
    {:ok, _} = UserBinding.bind("ou_two_#{System.unique_integer([:positive])}", user, "entity://system/user/admin")

    ids = UserBinding.open_ids_for(user)
    assert length(ids) == 2
  end
end
