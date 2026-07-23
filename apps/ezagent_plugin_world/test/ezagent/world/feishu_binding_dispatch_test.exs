defmodule Ezagent.World.FeishuBindingDispatchTest do
  @moduledoc """
  B2 (handoff `feishu-binding-b2-world-dispatch`) — unit coverage for the
  thin World → formal `EzagentPluginFeishu.Behavior.UserBinding` dispatch
  adapter.

  This suite does NOT re-prove the Behavior's own workspace / anti-hijack /
  policy / rollback rules — those are covered exhaustively by
  `apps/ezagent_plugin_feishu/test/behavior/user_binding_test.exs`. It proves
  only the ADAPTER's job: real target/caller/caps wiring through
  `Ezagent.Invocation.dispatch/1`, workspace-scoped reads, and stable/redacted
  error normalization (never `inspect/1`, a raw tuple, or a leaked open_id).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Test.CapHelper
  alias Ezagent.Workspace
  alias Ezagent.World.FeishuBindingDispatch, as: Dispatch

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_plugin_feishu)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws_name, do: "fbd-#{uniq()}"

  defp new_ws! do
    name = new_ws_name()
    {:ok, _} = Workspace.create(name, %{})
    CapHelper.ensure_workspace_kind!(URI.new!("workspace://#{name}"))
    URI.new!("workspace://#{name}")
  end

  defp read_only_caller!(%URI{} = workspace_uri, caps) do
    uri = URI.new!("entity://#{Ezagent.URI.name!(workspace_uri)}/user/caller-#{uniq()}")

    {:ok, _} = Ezagent.Users.create_read_only(uri, caps)
    :ok = Ezagent.Entity.spawn_principal(uri)
    uri
  end

  defp cap_for(%URI{} = workspace_uri, action, %URI{} = grantee) do
    target = Ezagent.URI.with_action(workspace_uri, :feishu_user_bindings, action)
    CapHelper.signed_action_cap!(target, grantee)
  end

  describe "list/3" do
    test "returns only the target workspace's bindings, JSON-safe" do
      ws = new_ws!()

      # Real, non-canonical caller holding precise :bind + :list caps — the
      # ADAPTER's own wiring is under test here, not the admin auto-mint path
      # (that convenience is exercised at the World route layer instead).
      caller = read_only_caller!(ws, [])
      bind_cap = cap_for(ws, :bind, caller)
      list_cap = cap_for(ws, :list_feishu_bindings, caller)

      open_id = "ou_fbd_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/bound-#{uniq()}")

      assert {:ok, %{open_id: ^open_id}} =
               Dispatch.bind(ws, caller, MapSet.new([bind_cap]), open_id, URI.to_string(user_uri))

      assert {:ok, bindings} = Dispatch.list(ws, caller, MapSet.new([list_cap]))
      assert Enum.all?(bindings, &is_map/1)
      row = Enum.find(bindings, &(&1["open_id"] == open_id))
      assert row["user_uri"] == URI.to_string(user_uri)
      assert is_binary(row["bound_by"])
      assert is_binary(row["bound_at"])

      # Every value must already be JSON-primitive — no raw struct leaked.
      for {_k, v} <- row do
        assert is_binary(v) or is_nil(v) or is_boolean(v) or is_number(v)
      end
    end

    test "a foreign workspace's bindings never appear in this workspace's list" do
      ws_a = new_ws!()
      ws_b = new_ws!()

      caller_b = read_only_caller!(ws_b, [])
      bind_cap_b = cap_for(ws_b, :bind, caller_b)

      open_id_b = "ou_fbd_foreign_#{uniq()}"
      user_b = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/victim-#{uniq()}")

      assert {:ok, _} =
               Dispatch.bind(
                 ws_b,
                 caller_b,
                 MapSet.new([bind_cap_b]),
                 open_id_b,
                 URI.to_string(user_b)
               )

      caller_a = read_only_caller!(ws_a, [])
      list_cap_a = cap_for(ws_a, :list_feishu_bindings, caller_a)

      assert {:ok, bindings_a} = Dispatch.list(ws_a, caller_a, MapSet.new([list_cap_a]))
      refute Enum.any?(bindings_a, &(&1["open_id"] == open_id_b))
    end

    test "no list cap → {:error, :unauthorized}, never raises or leaks a raw reason" do
      ws = new_ws!()
      caller = read_only_caller!(ws, [])

      assert {:error, :unauthorized} = Dispatch.list(ws, caller, MapSet.new())
    end
  end

  describe "bind/5" do
    test "no bind cap → {:error, :unauthorized} and no row is created" do
      ws = new_ws!()
      caller = read_only_caller!(ws, [])
      open_id = "ou_fbd_nocap_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/nocap-#{uniq()}")

      assert {:error, :unauthorized} =
               Dispatch.bind(ws, caller, MapSet.new(), open_id, URI.to_string(user_uri))

      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "binding a user from a different workspace is denied as :cross_workspace_denied" do
      ws_a = new_ws!()
      ws_b = new_ws!()

      caller_a = read_only_caller!(ws_a, [])
      bind_cap_a = cap_for(ws_a, :bind, caller_a)

      open_id = "ou_fbd_xws_#{uniq()}"
      foreign_user = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/foreign-#{uniq()}")

      assert {:error, :cross_workspace_denied} =
               Dispatch.bind(
                 ws_a,
                 caller_a,
                 MapSet.new([bind_cap_a]),
                 open_id,
                 URI.to_string(foreign_user)
               )

      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "every error is a bare atom from the closed set — never a tuple or inspect-shaped string" do
      ws = new_ws!()
      caller = read_only_caller!(ws, [])

      assert {:error, code} =
               Dispatch.bind(
                 ws,
                 caller,
                 MapSet.new(),
                 "ou_fbd_shape_#{uniq()}",
                 "entity://x/user/y"
               )

      assert code in [
               :unauthorized,
               :cross_workspace_denied,
               :invalid_args,
               :binding_policy_failed,
               :binding_unavailable,
               :binding_operation_failed
             ]
    end
  end

  describe "unbind/4" do
    test "successful bind → unbind round trip" do
      ws = new_ws!()
      caller = read_only_caller!(ws, [])
      bind_cap = cap_for(ws, :bind, caller)
      unbind_cap = cap_for(ws, :unbind, caller)

      open_id = "ou_fbd_roundtrip_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/rt-#{uniq()}")

      assert {:ok, _} =
               Dispatch.bind(ws, caller, MapSet.new([bind_cap]), open_id, URI.to_string(user_uri))

      assert {:ok, ^open_id} = Dispatch.unbind(ws, caller, MapSet.new([unbind_cap]), open_id)
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "no unbind cap → {:error, :unauthorized} and the row survives" do
      ws = new_ws!()
      caller = read_only_caller!(ws, [])
      bind_cap = cap_for(ws, :bind, caller)

      open_id = "ou_fbd_unauth_unbind_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/uu-#{uniq()}")

      assert {:ok, _} =
               Dispatch.bind(ws, caller, MapSet.new([bind_cap]), open_id, URI.to_string(user_uri))

      assert {:error, :unauthorized} = Dispatch.unbind(ws, caller, MapSet.new(), open_id)
      assert {:ok, _} = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end
  end
end
