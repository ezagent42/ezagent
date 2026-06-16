defmodule EzagentPluginLoom.Integration.SessionSubscriptionTest do
  @moduledoc """
  务实版 wiring 技术前提验证:plugin 进程能否订阅 session 事件 topic 并收到进 session 的消息。

  进 session 的每条消息(`session.send`)经 `Behavior.Session.handle_send` 广播
  `{:chat_message, session_uri, msg}` 到 `esr:session:<uri>:events`(`session_events_topic/1`)。
  loom 编排进程将订阅它来感知 customer 消息 → 触发编排。本测试只验证订阅机制可达。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, Workspace}
  alias Ezagent.Entity.User
  alias Ezagent.Behavior.Session, as: SessionBehavior
  alias EzagentPluginLoom.Template.LoomSession

  test "a process can subscribe to session events and receive in-session messages" do
    workspace_name = "loom-sub-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], _} =
             LoomSession.instantiate(
               "loom-main",
               %{
                 "class" => "session.loom",
                 "session_name" => session_name,
                 "operator_uri" => URI.to_string(User.admin_uri())
               },
               workspace_uri
             )

    # 编排进程将这样订阅
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, SessionBehavior.session_events_topic(session_uri))

    # 模拟一条消息进 session
    msg = Message.new(User.admin_uri(), %{text: "帮我做个落地页"})

    assert :ok =
             Invocation.dispatch(%Invocation{
               target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
               mode: :cast,
               args: %{message: msg},
               ctx: %{
                 caller: User.admin_uri(),
                 caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                 reply: :ignore
               }
             })

    # 订阅者收到广播 → 务实版编排进程能据此触发
    assert_receive {:chat_message, received_session_uri, received_msg}, 3000
    assert URI.to_string(received_session_uri) == URI.to_string(session_uri)
    assert received_msg.body["text"] == "帮我做个落地页"
    assert received_msg.id == msg.id
  end
end
