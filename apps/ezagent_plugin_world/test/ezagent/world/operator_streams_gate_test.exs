defmodule Ezagent.World.OperatorStreamsGateTest do
  @moduledoc """
  REGRESSION tests for task #187 — the global `audit` / `authz` / `cc_event`
  streams (the OPERATOR-OBSERVABILITY plane) were delivered to EVERY connected
  WorldLive: `subscribe_global_inbound/1` subscribed unconditionally at mount
  and the `handle_info` handlers pushed unconditionally, so any logged-in
  NON-operator received all-tenant audit + cc events via `world:inbound`.

  The gate REUSES `Ezagent.Identity.AdminAuthority.admin?/1` — the SAME
  operator predicate the `:require_admin` live_session and
  `Ezagent.Identity.OperatorReads` gate on — at BOTH exits:

    * subscribe-time (mount): a non-operator's LV process is never subscribed
      to `Ezagent.Audit.stream_topic()` / `Ezagent.CCEvents.topic()`;
    * delivery-time (handle_info): even a socket that somehow receives the
      envelope drops it unless the caller is an operator LIVE.

  Fail-closed on unknown/missing caller. Remove either gate and the
  corresponding test goes red.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginWorld.WorldLive

  @non_operator Ezagent.URI.new!("entity://team-alpha/user/plain-member")
  @operator Ezagent.URI.new!("entity://system/user/operator-187")

  @events [
    {:audit_event, %{"target" => "world"}},
    {:authz_event, :denied, %{"target" => "entity://team-alpha/agent/x"}, DateTime.utc_now()},
    {:cc_event, %{"event" => "stdout"}}
  ]

  defp socket_for(caller_uri) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_entity_uri: caller_uri,
        current_caps: MapSet.new(),
        current_workspace_uri: nil,
        world_state: %{"component" => "sessions_table"}
      }
    }
  end

  describe "delivery-time gate (handle_info)" do
    test "a non-operator receives NONE of the operator streams" do
      for event <- @events do
        input = socket_for(@non_operator)
        {:noreply, out} = WorldLive.handle_info(event, input)

        assert out == input,
               "a non-operator must not receive #{elem(event, 0)} — the event was pushed"
      end
    end

    test "fail-closed: a socket with NO caller receives NONE" do
      for event <- @events do
        input = socket_for(nil)
        {:noreply, out} = WorldLive.handle_info(event, input)

        assert out == input,
               "a caller-less socket must not receive #{elem(event, 0)} — fail closed"
      end
    end

    test "an operator still receives ALL operator streams" do
      for event <- @events do
        input = socket_for(@operator)
        {:noreply, out} = WorldLive.handle_info(event, input)

        refute out == input,
               "an operator must still receive #{elem(event, 0)}"
      end
    end
  end

  describe "subscribe-time gate (mount)" do
    defp connected_socket(caller_uri) do
      %Phoenix.LiveView.Socket{
        transport_pid: self(),
        assigns: %{
          __changed__: %{},
          current_entity_uri: caller_uri,
          current_caps: MapSet.new(),
          current_workspace_uri: nil,
          is_system_member?: false
        }
      }
    end

    test "connected mount defers the expensive world bootstrap" do
      {:ok, socket} = WorldLive.mount(%{}, %{}, connected_socket(@non_operator))

      assert socket.assigns.world_bootstrap_ready? == false
      assert_receive :load_world_state, 200
    end

    test "the first connected session route initializes the active session before bootstrap" do
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      {:ok, socket} = WorldLive.mount(%{}, %{}, connected_socket(@non_operator))

      {:noreply, socket} =
        WorldLive.handle_params(
          %{"session" => URI.encode_www_form(URI.to_string(session_uri))},
          "https://example.com/sessions",
          socket
        )

      assert socket.assigns.current_route.component == "conversation"
      assert socket.assigns.current_route.session_uri == session_uri
      refute socket.assigns.current_session_uri
      assert socket.assigns.world_component == "conversation"
      assert_receive :load_world_state, 200

      # The bootstrap task is now delivered via `start_async/3` +
      # `handle_async/3` (idiomatic LiveView async primitive, tracked and
      # awaitable via `Phoenix.LiveViewTest.render_async/1` in LiveViewTest
      # suites) rather than a hand-rolled `{:world_bootstrap_ready, ...}`
      # message — see `EzagentPluginWorld.WorldLive.do_load_world_state/1`.
      # This unit test drives the module's callbacks directly (no live
      # socket transport), so it invokes the new callback with the same
      # `{:ok, result}` shape `start_async` would deliver.
      {:noreply, socket} =
        WorldLive.handle_async(
          :load_world_state,
          {:ok,
           {socket.assigns.current_route, %{}, %{"component" => "conversation"}, %{}, []}},
          socket
        )

      assert socket.assigns.current_session_uri == session_uri
    end

    test "a non-operator mount subscribes to NEITHER operator topic" do
      {:ok, _socket} = WorldLive.mount(%{}, %{}, connected_socket(@non_operator))

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.Audit.stream_topic(),
        {:audit_event, %{"target" => "world"}}
      )

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.CCEvents.topic(),
        {:cc_event, %{"event" => "stdout"}}
      )

      refute_receive {:audit_event, _}, 200
      refute_receive {:cc_event, _}, 200
    end

    test "fail-closed: a caller-less mount subscribes to NEITHER operator topic" do
      {:ok, _socket} = WorldLive.mount(%{}, %{}, connected_socket(nil))

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.Audit.stream_topic(),
        {:audit_event, %{"target" => "world"}}
      )

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.CCEvents.topic(),
        {:cc_event, %{"event" => "stdout"}}
      )

      refute_receive {:audit_event, _}, 200
      refute_receive {:cc_event, _}, 200
    end

    test "an operator mount subscribes to BOTH operator topics" do
      {:ok, _socket} = WorldLive.mount(%{}, %{}, connected_socket(@operator))

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.Audit.stream_topic(),
        {:audit_event, %{"target" => "world"}}
      )

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.CCEvents.topic(),
        {:cc_event, %{"event" => "stdout"}}
      )

      assert_receive {:audit_event, _}, 500
      assert_receive {:cc_event, _}, 500
    end
  end
end
