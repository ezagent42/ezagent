defmodule EzagentPluginEcho.Integration.F1DirectInvokeTest do
  @moduledoc """
  PLAN-internal checkpoint per docs/phase-specs/phase1/PLAN.md §1a-step 4.

  Verifies F1 (text round-trip via Echo) works through the full
  dispatch path WITHOUT LiveView:

  - URI parsed
  - KindRegistry → Echo instance pid
  - GenServer.call routes to Kind.Runtime.handle_dispatch
  - BehaviorRegistry lookup finds Ezagent.Behavior.Echo
  - authz stub grants (emits :stub_grant)
  - args validated against @interface
  - Behavior.invoke runs, slice updated
  - telemetry [:ezagent, :invoke, :stop] emitted
  - Audit handler broadcasts to PubSub
  - Audit.Writer flushes batch to SQLite
  - SELECT FROM invocations finds the row

  This integration test must pass before moving on to step 5
  (LiveView). If it's red, the LiveView path will also be red because
  the dispatch backbone isn't working.
  """

  use ExUnit.Case

  alias Ezagent.Invocation
  alias EzagentPluginEcho.Application, as: EchoApp

  setup do
    # Subscribe to the audit stream before invocation so we see the
    # event the dispatch will emit.
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())

    # Sandbox checkout — Audit.Writer is a long-lived GenServer that
    # needs to be allowed on this connection for SQLite writes to
    # succeed during the test. Wait for ready before we proceed.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    :ok
  end

  test "F1: dispatch :say to entity://agent/default/echo_default, get reply, see audit event + SQLite row" do
    target = URI.parse("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{msg: "hello"},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.Entity.User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    }

    # Step 1: dispatch returns the echoed result synchronously.
    assert {:ok, %{echo: "hello"}} = Invocation.dispatch(inv)

    # Step 2: audit handler broadcasts to esr:audit:stream.
    # Phase 3d: dispatch emits two audit events — :authz :granted first
    # (when cap check passes) then :invoke :stop (when invoke succeeds).
    # Both arrive; we care about the :stop event's metadata.
    assert_receive {:audit_event, %{event: [:ezagent, :authz, :granted]}}, 500
    assert_receive {:audit_event, %{event: [:ezagent, :invoke, :stop]} = stop_event}, 500
    assert stop_event.metadata.target == "entity://agent/default/echo_default?action=echo.say"
    assert stop_event.metadata.action == :say

    # Step 3: wait for Audit.Writer batch flush (100ms) + 50ms slack,
    # then query invocations table.
    Process.sleep(200)

    rows =
      EzagentCore.Repo.query!(
        "SELECT target, action, authz, duration_us FROM invocations " <>
          "WHERE target LIKE 'entity://agent/default/echo_default%' ORDER BY id DESC LIMIT 1"
      ).rows

    assert [[target_col, action_col, authz_col, duration_col]] = rows
    assert target_col == "entity://agent/default/echo_default?action=echo.say"
    assert action_col == "say"
    # Phase 3d: hard flip removed :stub_grant in favor of real "granted"
    # from cap check. invocations.authz column is "granted" for the
    # success path (caller had matching cap).
    assert authz_col == "granted"
    assert is_integer(duration_col) and duration_col > 0
  end

  test "F1 via :cast — reply lands in caller_inbox" do
    target = URI.parse("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :cast,
      args: %{msg: "via-cast"},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.Entity.User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    }

    assert :ok = Invocation.dispatch(inv)
    assert_receive {:ezagent_reply, {:ok, %{echo: "via-cast"}}}, 500
    assert_receive {:audit_event, %{event: [:ezagent, :invoke, :stop]}}, 500
  end

  test "PR-J regression: echo :receive replies via chat.send back to originating session" do
    # The bug Allen flagged 2026-05-20: Echo agent in session://default/default/main
    # never replied. Root cause: `:receive` was not registered in
    # BehaviorRegistry — `chat.send` fan-out dispatched `chat.receive`
    # to the Echo Kind and got `:not_registered`.
    #
    # This test joins the default Echo agent into session://default/default/main,
    # subscribes to the session's chat-stream PubSub topic, dispatches
    # `chat.send` from admin, and asserts an "echo: <text>" reply
    # message lands within 500ms.
    session_uri = URI.new!("session://default/default/main")
    echo_agent_uri = EchoApp.default_uri()
    admin_uri = Ezagent.Entity.User.admin_uri()

    # Ensure echo agent is in the session.
    join_target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: join_target,
        mode: :call,
        args: %{member: echo_agent_uri},
        ctx: %{
          caller: admin_uri,
          caps: Ezagent.Entity.User.admin_caps(),
          reply: {:caller_inbox, self()}
        }
      })

    # Subscribe BEFORE sending so we don't miss the broadcast.
    session_topic = Ezagent.Behavior.Chat.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    text = "ping-#{System.unique_integer([:positive])}"

    msg =
      Ezagent.Message.new(admin_uri, %{text: text, attachments: []},
        mentions: [echo_agent_uri]
      )

    send_target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    :ok =
      Invocation.dispatch(%Invocation{
        target: send_target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: admin_uri,
          caps: Ezagent.Entity.User.admin_caps(),
          reply: :ignore
        }
      })

    # First broadcast: the original message.
    assert_receive {:chat_message, ^session_uri, %Ezagent.Message{} = first}, 1000
    assert get_in(first.body, [Access.key!(:text)]) == text or
             get_in(first.body, ["text"]) == text

    # Second broadcast: echo's reply ("echo: ping-XXX") from the echo
    # agent's URI. Match on text prefix to avoid coupling to id.
    assert_receive {:chat_message, ^session_uri, %Ezagent.Message{} = reply}, 1000

    reply_text =
      case reply.body do
        %{text: t} -> t
        %{"text" => t} -> t
      end

    assert reply_text == "echo: #{text}",
           "expected echo reply 'echo: #{text}', got #{inspect(reply_text)}"

    assert reply.sender == echo_agent_uri,
           "expected reply.sender == echo agent URI, got #{inspect(reply.sender)}"
  end

  test "F1 invalid args fail-stop at validator (does not reach Echo slice)" do
    target = URI.parse("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      # `:msg` should be a string per @interface; pass int to fail.
      args: %{msg: 42},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.Entity.User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    }

    assert {:error, {:invalid_args, violations}} = Invocation.dispatch(inv)
    assert [{[:msg], {:type_mismatch, _}}] = violations
  end
end
