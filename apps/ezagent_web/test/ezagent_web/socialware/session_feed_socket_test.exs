defmodule EzagentWeb.Socialware.SessionFeedSocketTest do
  use EzagentWeb.ConnCase, async: false

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.Socialware.{AnonUser, ChatFeedAuth}
  alias EzagentWeb.Socialware.SessionFeedSocket
  alias EzagentWeb.TestSupport.SnapshotPullAdapter

  @session Ezagent.URI.session(:team_alpha, :default, "session-feed-socket")
  @caller Ezagent.URI.entity(:team_alpha, :user, "session-feed-socket-caller")
  @anon Ezagent.URI.entity(:team_alpha, :user, "#{AnonUser.prefix()}session-feed-socket")

  setup do
    adapters = :ets.tab2list(AdapterRegistry.table())
    bindings = :ets.tab2list(BindingRegistry.table())
    :ets.delete_all_objects(AdapterRegistry.table())
    :ets.delete_all_objects(BindingRegistry.table())

    :ok = AdapterRegistry.register(SnapshotPullAdapter)

    on_exit(fn ->
      :ets.delete_all_objects(AdapterRegistry.table())
      :ets.delete_all_objects(BindingRegistry.table())
      :ets.insert(AdapterRegistry.table(), adapters)
      :ets.insert(BindingRegistry.table(), bindings)
    end)

    :ok
  end

  test "connect resolves a signed-in caller and registered adapter into assigns" do
    token = ChatFeedAuth.issue_token(@caller, @session)

    assert {:ok, socket} =
             SessionFeedSocket.connect(
               %{
                 "adapter_id" => "web_snapshot",
                 "session_uri" => URI.to_string(@session),
                 "token" => token
               },
               %Phoenix.Socket{},
               %{}
             )

    assert socket.assigns.adapter_id == "web_snapshot"
    assert socket.assigns.adapter == SnapshotPullAdapter
    assert socket.assigns.session_uri == @session
    assert socket.assigns.caller == @caller
    assert socket.assigns.delivery_discipline == :snapshot_refresh
    assert socket.assigns.participation_profile == :read_only
  end

  test "connect accepts an anon-shaped caller minted by the existing ingress flow" do
    token = ChatFeedAuth.issue_token(@anon, @session)

    assert {:ok, socket} =
             SessionFeedSocket.connect(
               %{
                 "adapter_id" => "web_snapshot",
                 "session_uri" => URI.to_string(@session),
                 "token" => token
               },
               %Phoenix.Socket{},
               %{}
             )

    assert socket.assigns.caller == @anon
    assert AnonUser.anon_uri?(socket.assigns.caller)
  end

  test "connect rejects bad token and unknown adapter" do
    assert :error =
             SessionFeedSocket.connect(
               %{
                 "adapter_id" => "web_snapshot",
                 "session_uri" => URI.to_string(@session),
                 "token" => "bad"
               },
               %Phoenix.Socket{},
               %{}
             )

    token = ChatFeedAuth.issue_token(@caller, @session)

    assert :error =
             SessionFeedSocket.connect(
               %{
                 "adapter_id" => "missing",
                 "session_uri" => URI.to_string(@session),
                 "token" => token
               },
               %Phoenix.Socket{},
               %{}
             )
  end
end
