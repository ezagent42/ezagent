defmodule EzagentWeb.Socialware.SessionFeedChannelTest do
  use EzagentWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias EzagentWeb.Socialware.SessionFeedChannel

  alias EzagentWeb.TestSupport.{
    CursorPullAdapter,
    ParticipatoryPullAdapter,
    SessionFeedAdapterState,
    SnapshotPullAdapter
  }

  @endpoint EzagentWeb.Endpoint
  @session Ezagent.URI.session(:team_alpha, :default, "session-feed-channel")
  @caller Ezagent.URI.entity(:team_alpha, :user, "session-feed-caller")

  setup do
    adapters = :ets.tab2list(AdapterRegistry.table())
    bindings = :ets.tab2list(BindingRegistry.table())
    :ets.delete_all_objects(AdapterRegistry.table())
    :ets.delete_all_objects(BindingRegistry.table())
    SessionFeedAdapterState.reset!()

    :ok = AdapterRegistry.register(SnapshotPullAdapter)
    :ok = AdapterRegistry.register(CursorPullAdapter)
    :ok = AdapterRegistry.register(ParticipatoryPullAdapter)

    on_exit(fn ->
      :ets.delete_all_objects(AdapterRegistry.table())
      :ets.delete_all_objects(BindingRegistry.table())
      :ets.insert(AdapterRegistry.table(), adapters)
      :ets.insert(BindingRegistry.table(), bindings)
    end)

    :ok
  end

  test "snapshot-refresh join stores no cursor and advisory re-reads current snapshot" do
    assert {:ok, reply, socket} = join_feed("web_snapshot")
    assert reply.snapshot.page.props.label == "snapshot-1"
    refute Map.has_key?(socket.assigns, :feed_cursor)

    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "web_snapshot:#{URI.to_string(@session)}", :wake)

    assert_push("snapshot", %{page: %{props: %{label: "snapshot-2"}}}, 1000)
  end

  test "cursor-replay join stores cursor and advisory replays from that cursor" do
    assert {:ok, reply, socket} = join_feed("web_cursor")
    assert reply.snapshot.page.props.label == "join"
    assert socket.assigns.feed_cursor == 41

    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "web_cursor:#{URI.to_string(@session)}", :wake)

    assert_push("snapshot", %{page: %{props: %{label: "replay-from-41"}}}, 1000)
    assert SessionFeedAdapterState.get({CursorPullAdapter, :last_replay_cursor}) == 41
  end

  test "live revocation pushes unauthorized and stops the channel" do
    assert {:ok, _reply, _socket} = join_feed("web_snapshot")
    SessionFeedAdapterState.put({SnapshotPullAdapter, :unauthorized}, true)
    Process.flag(:trap_exit, true)

    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "web_snapshot:#{URI.to_string(@session)}", :wake)

    assert_push("unauthorized", %{reason: "membership_revoked"}, 1000)
    assert_receive {:EXIT, _channel_pid, :shutdown}, 1000
  end

  test "join subscribes before the first content read" do
    SessionFeedAdapterState.put({SnapshotPullAdapter, :broadcast_during_render}, true)

    assert {:ok, reply, _socket} = join_feed("web_snapshot")
    assert reply.snapshot.page.props.label == "snapshot-1"
    assert_push("snapshot", %{page: %{props: %{label: "snapshot-2"}}}, 1000)
  end

  test "read-only adapters reject post while participatory adapters accept it" do
    assert {:ok, _reply, snapshot_socket} = join_feed("web_snapshot")
    ref = Phoenix.ChannelTest.push(snapshot_socket, "post", %{"text" => "hello"})
    assert_reply(ref, :error, %{reason: "read_only"})

    assert {:ok, _reply, participatory_socket} = join_feed("web_participatory")
    ref = Phoenix.ChannelTest.push(participatory_socket, "post", %{"text" => "hello"})
    assert_reply(ref, :ok)

    assert SessionFeedAdapterState.get({ParticipatoryPullAdapter, :last_post}) ==
             {@session, @caller, "hello"}
  end

  test "the generic post fallback does not inject a retired Hello front-desk mention" do
    source =
      File.read!(
        Path.expand(
          "../../../lib/ezagent_web/socialware/session_feed_channel.ex",
          __DIR__
        )
      )

    refute source =~ "front-desk"
    refute source =~ "EzagentPluginHello.Members.role_uri"
  end

  defp join_feed(adapter_id) do
    @endpoint
    |> socket("session_feed:#{adapter_id}", %{session_uri: @session, caller: @caller})
    |> subscribe_and_join(
      SessionFeedChannel,
      "socialware:feed:#{adapter_id}:#{URI.to_string(@session)}",
      %{}
    )
  end
end
