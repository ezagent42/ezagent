defmodule EzagentDomainInstanceMessage.Integration.SessionSendTest do
  @moduledoc """
  PR-1 (im/session/agent decomposition) — `session.send` is the SINGLE
  public Session entry verb; `chat.send` is demoted to a session-INTERNAL
  fan-out verb.

  This test proves the BEHAVIORAL equivalence the decomposition requires:
  dispatching `?action=session.send` persists + routes + fans out EXACTLY
  like `?action=chat.send` did — same recipient receives `chat.receive`,
  same message lands in `MessageStore` — for BOTH a `:call` and a `:cast`
  mode (Decision #134 / Invariant #9: `mode` is the transport choice the
  inbound surface makes; cap-denial must surface for `:call`).

  Drives the FULL production path (`Ezagent.Invocation.dispatch/1` →
  `Ezagent.Behavior.Session.handle_send/2` → delegated `Chat` fan-out →
  Resolver → `chat.receive` on the receiver User Kind), per the
  how-to-recipes invariant-test pattern (observable side-effects, not
  internal slice state alone).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, MessageStore, RoutingRegistry}
  alias Ezagent.Routing.Resolver

  setup do
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    install_default_rule_table()
    :ok
  end

  defp u(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # `{:always} → [$session_users, $mentions]` fans `chat.receive` out to
  # every session member (the migrated `system_default` rule shape). Same
  # fixture `chat_receive_user_slice_change_test.exs` uses.
  defp install_default_rule_table do
    table = String.to_atom("session_send_routing_#{u("t")}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    :ok =
      RoutingRegistry.put(
        table,
        Ezagent.Routing.Matcher.always(),
        [Resolver.session_users_token(), Resolver.mentions_token()]
      )

    Application.put_env(:ezagent_core, :routing_tables, [table])
    table
  end

  defp spawn_session do
    session = URI.new!("session://system/default/#{u("session-send")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, URI.new!("workspace://system"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session) end)
    session
  end

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=chat.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  # Dispatch via the NEW public verb `?action=session.send`.
  defp session_send(session, sender, text, mode) do
    msg = Message.new(sender, %{text: text, attachments: []})

    reply = if mode == :call, do: :sync, else: :ignore

    result =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=session.send"),
        mode: mode,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: reply
        }
      })

    {msg, result}
  end

  describe "session.send is the public first-class action" do
    test "{Session, :send} dispatches to Ezagent.Behavior.Session (NOT Chat directly)" do
      assert Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, :send) ==
               {:ok, Ezagent.Behavior.Session}
    end

    test "{SocialwareSession, :send} dispatches to Ezagent.Behavior.Session too" do
      assert Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.SocialwareSession, :send) ==
               {:ok, Ezagent.Behavior.Session}
    end

    test "the needed cap for session.send keeps behavior: Chat (cap parity, Invariant #19)" do
      # Existing IM grants are keyed on Ezagent.Behavior.Chat. session.send
      # MUST keep that cap subject so no grant has to be re-minted.
      assert %Ezagent.Capability{behavior: Ezagent.Behavior.Chat, action: :send} =
               Ezagent.Behavior.Session.required_caps()[:send]
    end
  end

  for dispatch_mode <- [:call, :cast] do
    test "session.send (#{dispatch_mode}) persists + fans out chat.receive exactly like chat.send did" do
      mode = unquote(dispatch_mode)
      session = spawn_session()

      sender = URI.new!("entity://system/user/#{u("sender")}")
      receiver = URI.new!("entity://system/user/#{u("receiver")}")

      {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(receiver)

      join(session, sender)
      join(session, receiver)

      {msg, result} = session_send(session, sender, "session.send #{mode} proof", mode)

      # Mode is preserved end-to-end: a :call returns {:ok, %{stored: true}}
      # (cap-denial would surface here); a :cast returns :ok.
      assert_mode_result(mode, result)

      # 1. Persist — the message landed in MessageStore stamped with the
      # session URI (the Chat fan-out's first step). For :cast the whole
      # chain is async to this process, so poll.
      loaded =
        wait_until(fn ->
          case MessageStore.by_id(msg.id) do
            {:ok, m} -> m
            _ -> nil
          end
        end)

      assert loaded.session_uri == session

      # 2. Fan-out — the receiver's `chat.receive` ran (User-branch sets
      # :last_received on its :chat slice). Poll: the cast fan-out + the
      # receiver's own commit are async to this process.
      slice =
        wait_until(fn ->
          case Ezagent.Kind.get_slice(receiver, :chat) do
            {:ok, %{last_received: %{message_id: id}} = s} when id == msg.id -> s
            _ -> nil
          end
        end)

      assert slice.last_received.message_id == msg.id
      assert %DateTime{} = slice.last_received.at
    end
  end

  describe "Ezagent.Entity.Session.send/3 convenience entry" do
    test "dispatches session.send and fans out, honoring ctx[:mode]" do
      session = spawn_session()
      sender = URI.new!("entity://system/user/#{u("conv-sender")}")
      receiver = URI.new!("entity://system/user/#{u("conv-receiver")}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(receiver)
      join(session, sender)
      join(session, receiver)

      msg = Message.new(sender, %{text: "via Session.send/3", attachments: []})

      assert {:ok, %{stored: true}} =
               Ezagent.Entity.Session.send(session, msg, %{
                 caller: sender,
                 caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                 mode: :call,
                 reply: :sync
               })

      slice =
        wait_until(fn ->
          case Ezagent.Kind.get_slice(receiver, :chat) do
            {:ok, %{last_received: %{message_id: id}} = s} when id == msg.id -> s
            _ -> nil
          end
        end)

      assert slice.last_received.message_id == msg.id
    end
  end

  defp assert_mode_result(:call, result), do: assert({:ok, %{stored: true}} = result)
  defp assert_mode_result(:cast, result), do: assert(result == :ok)

  defp wait_until(fun, retries \\ 100) do
    case fun.() do
      nil when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      nil ->
        flunk("wait_until timed out")

      value ->
        value
    end
  end
end
