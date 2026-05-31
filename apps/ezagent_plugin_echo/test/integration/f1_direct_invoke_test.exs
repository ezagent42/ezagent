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

  # AuditCase starts + allow-lists `Ezagent.Audit.Writer` on the
  # per-test sandbox connection so its 100ms batch flush hits the
  # invocations table during this test. Without it, the F1 row-query
  # step (read-back via Repo) sees `[]` because the writer's INSERT ran
  # under a different (or torn-down) ownership.
  use Ezagent.Test.AuditCase, writers: [:audit]

  alias Ezagent.Invocation
  alias EzagentPluginEcho.Application, as: EchoApp

  setup do
    # Subscribe to the audit stream before invocation so we see the
    # event the dispatch will emit. (Sandbox checkout + shared mode is
    # handled by Ezagent.Test.AuditCase's `using` block above.)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())

    # Echo agent (boot-spawned at `EzagentPluginEcho.Application` start)
    # can be missing if a prior test rolled back the sandbox or its
    # Kind.Server crashed. Re-spawn idempotently so each test starts
    # with a live `entity://agent/system/echo_default`. SpawnRegistry
    # tolerates an already-running instance (returns the existing pid).
    _ = Ezagent.SpawnRegistry.spawn(EchoApp.default_uri())
    :ok
  end

  test "F1: dispatch :say to entity://agent/system/echo_default, get reply, see audit event + SQLite row" do
    target = Ezagent.URI.new!("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{msg: "hello"},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    }

    # Step 1: dispatch returns the echoed result synchronously.
    assert {:ok, %{echo: "hello"}} = Invocation.dispatch(inv)

    # Step 2: audit handler broadcasts to esr:audit:stream.
    # Phase 3d: dispatch emits two audit events — :authz :granted first
    # (when cap check passes) then :invoke :stop (when invoke succeeds).
    # Both arrive; we care about the :stop event whose target is
    # echo.say specifically (the echo agent's broadcast path also
    # fires a chat.receive :stop event — drain until we get the
    # one we asked for).
    assert_receive {:audit_event, %{event: [:ezagent, :authz, :granted]}}, 500
    stop_event = drain_stop_event_for_target!("entity://agent/system/echo_default?action=echo.say")
    assert stop_event.metadata.target == "entity://agent/system/echo_default?action=echo.say"
    assert stop_event.metadata.action == :say

    # Step 3: wait for Audit.Writer batch flush (100ms) + 50ms slack,
    # then query invocations table.
    Process.sleep(200)

    rows =
      EzagentCore.Repo.query!(
        "SELECT target, action, authz, duration_us FROM invocations " <>
          "WHERE target LIKE 'entity://agent/system/echo_default%' ORDER BY id DESC LIMIT 1"
      ).rows

    assert [[target_col, action_col, authz_col, duration_col]] = rows
    assert target_col == "entity://agent/system/echo_default?action=echo.say"
    assert action_col == "say"
    # Phase 3d: hard flip removed :stub_grant in favor of real "granted"
    # from cap check. invocations.authz column is "granted" for the
    # success path (caller had matching cap).
    assert authz_col == "granted"
    assert is_integer(duration_col) and duration_col > 0
  end

  test "F1 via :cast — reply lands in caller_inbox" do
    target = Ezagent.URI.new!("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :cast,
      args: %{msg: "via-cast"},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    }

    assert :ok = Invocation.dispatch(inv)
    assert_receive {:ezagent_reply, {:ok, %{echo: "via-cast"}}}, 500
    assert_receive {:audit_event, %{event: [:ezagent, :invoke, :stop]}}, 500
  end

  test "PR-J regression: echo :receive replies via chat.send back to originating session" do
    # The bug Allen flagged 2026-05-20: Echo agent in session://default/system/main
    # never replied. Root cause: `:receive` was not registered in
    # BehaviorRegistry — `chat.send` fan-out dispatched `chat.receive`
    # to the Echo Kind and got `:not_registered`.
    #
    # This test joins the default Echo agent into session://default/system/main,
    # subscribes to the session's chat-stream PubSub topic, dispatches
    # `chat.send` from admin, and asserts an "echo: <text>" reply
    # message lands within 500ms.
    session_uri = URI.new!("session://default/system/main")
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
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
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
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      })

    # First broadcast: the original message. Body may carry atom OR
    # string `:text` key depending on whether it round-tripped through
    # the message store's `Jason` encode/decode — the assertion tolerates
    # both. (Switched from `Access.key!` to `Access.key` so the missing
    # atom key returns `nil` instead of raising.)
    assert_receive {:chat_message, ^session_uri, %Ezagent.Message{} = first}, 1000
    assert get_in(first.body, [Access.key(:text)]) == text or
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

    # Compare via to_string/1 — the message round-trips through
    # `Ezagent.Message.normalize_sender/1` which uses `URI.new!/1` whose
    # output URI struct lacks the `:authority` field set by
    # `URI.parse/1` (the constructor used for `EchoApp.default_uri/0`).
    # The two structs are byte-different but URI-string-equal, which is
    # the canonical equality we care about.
    assert URI.to_string(reply.sender) == URI.to_string(echo_agent_uri),
           "expected reply.sender == echo agent URI, got #{inspect(reply.sender)}"
  end

  test "F1 invalid args fail-stop at validator (does not reach Echo slice)" do
    target = Ezagent.URI.new!("#{URI.to_string(EchoApp.default_uri())}?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      # `:msg` should be a string per @interface; pass int to fail.
      args: %{msg: 42},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    }

    assert {:error, {:invalid_args, violations}} = Invocation.dispatch(inv)
    assert [{[:msg], {:type_mismatch, _}}] = violations
  end

  # Drain :invoke :stop events from the mailbox until one with the
  # matching target arrives, then return it. The echo agent's broadcast
  # path now fires its own `chat.receive` :stop event, which can land in
  # the mailbox before the echo.say one; ignore them.
  defp drain_stop_event_for_target!(target_str) do
    receive do
      {:audit_event, %{event: [:ezagent, :invoke, :stop], metadata: %{target: ^target_str}} = ev} ->
        ev

      {:audit_event, %{event: [:ezagent, :invoke, :stop]}} ->
        drain_stop_event_for_target!(target_str)
    after
      500 ->
        flunk("no :invoke :stop audit event for target=#{target_str} within 500ms")
    end
  end
end
