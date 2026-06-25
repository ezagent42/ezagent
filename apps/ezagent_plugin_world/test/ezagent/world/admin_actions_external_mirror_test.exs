defmodule Ezagent.World.AdminActionsExternalMirrorTest do
  @moduledoc """
  F9 — operator UI to bind a Feishu chat → a session (chat→session binding).

  The world UI's External Mirror surface was READ-ONLY; the bind/unbind path
  existed only as the `mix ezagent.external_mirror.bind` CLI + the
  `Ezagent.ExternalMirror.bind/5` facade. F9 wires the world UI dispatch to
  that existing facade.

  This gate tests the WIRING SEAM (pure, injectable — mirrors
  `ConversationActions.create_session_result/5`): URI parsing + facade-result
  mapping + caller-context shape. The real feishu adapter bind (which makes a
  live Feishu API `target_ownership_check`) is the domain's responsibility and
  is proven end-to-end by the agent-browser demo, not re-tested here.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.AdminActions

  @session_uri "session://system/default/f9-probe"
  @adapter_id "feishu"
  @target_id "oc_test_chat"
  @ctx %{caller: Ezagent.Entity.User.admin_uri(), caps: MapSet.new()}

  describe "safe_session_uri/1" do
    test "parses a valid session URI" do
      assert {:ok, %URI{scheme: "session"}} = AdminActions.safe_session_uri(@session_uri)
    end

    test "rejects a non-session scheme" do
      assert :error = AdminActions.safe_session_uri("entity://system/user/admin")
    end

    test "rejects garbage" do
      assert :error = AdminActions.safe_session_uri("not a uri")
      assert :error = AdminActions.safe_session_uri("")
    end
  end

  describe "external_mirror_bind_result/6" do
    test "passes the parsed session URI + args + ctx to the bind fun and returns ok" do
      parent = self()

      bind_fun = fn session_uri, adapter_id, target_id, opts, ctx ->
        send(parent, {:bind_called, session_uri, adapter_id, target_id, opts, ctx})
        {:ok, %{ok: true, binding_id: "feishu/oc_test_chat", worker_uri: session_uri}}
      end

      assert {:ok, %URI{scheme: "session"} = session_uri, %{ok: true}} =
               AdminActions.external_mirror_bind_result(
                 @session_uri,
                 @adapter_id,
                 @target_id,
                 %{},
                 @ctx,
                 bind_fun
               )

      assert_received {:bind_called, ^session_uri, @adapter_id, @target_id, %{}, @ctx}
    end

    test "propagates a facade error WITH the session URI (so the surface can refresh)" do
      bind_fun = fn _s, _a, _t, _o, _c -> {:error, :unauthorized} end

      assert {:error, %URI{scheme: "session"}, :unauthorized} =
               AdminActions.external_mirror_bind_result(
                 @session_uri,
                 @adapter_id,
                 @target_id,
                 %{},
                 @ctx,
                 bind_fun
               )
    end

    test "returns :invalid_session_uri WITHOUT calling the bind fun" do
      bind_fun = fn _s, _a, _t, _o, _c -> flunk("bind fun must not run on a bad URI") end

      assert {:error, :invalid_session_uri} =
               AdminActions.external_mirror_bind_result(
                 "garbage",
                 @adapter_id,
                 @target_id,
                 %{},
                 @ctx,
                 bind_fun
               )
    end
  end

  describe "external_mirror_unbind_result/5" do
    test "passes the parsed session URI + args + ctx to the unbind fun and returns ok" do
      parent = self()

      unbind_fun = fn session_uri, adapter_id, target_id, ctx ->
        send(parent, {:unbind_called, session_uri, adapter_id, target_id, ctx})
        {:ok, %{ok: true, unbound: true}}
      end

      assert {:ok, %URI{scheme: "session"} = session_uri, %{unbound: true}} =
               AdminActions.external_mirror_unbind_result(
                 @session_uri,
                 @adapter_id,
                 @target_id,
                 @ctx,
                 unbind_fun
               )

      assert_received {:unbind_called, ^session_uri, @adapter_id, @target_id, @ctx}
    end

    test "propagates a facade error WITH the session URI" do
      unbind_fun = fn _s, _a, _t, _c -> {:error, :no_such_actor} end

      assert {:error, %URI{scheme: "session"}, :no_such_actor} =
               AdminActions.external_mirror_unbind_result(
                 @session_uri,
                 @adapter_id,
                 @target_id,
                 @ctx,
                 unbind_fun
               )
    end

    test "returns :invalid_session_uri WITHOUT calling the unbind fun" do
      unbind_fun = fn _s, _a, _t, _c -> flunk("unbind fun must not run on a bad URI") end

      assert {:error, :invalid_session_uri} =
               AdminActions.external_mirror_unbind_result(
                 "garbage",
                 @adapter_id,
                 @target_id,
                 @ctx,
                 unbind_fun
               )
    end
  end
end
