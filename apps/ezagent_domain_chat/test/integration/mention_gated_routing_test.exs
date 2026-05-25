defmodule EzagentDomainChat.Integration.MentionGatedRoutingTest do
  @moduledoc """
  Mention-gated agent dispatch — end-to-end integration.

  Implements `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  §6.2, §6.3, §6.5, §6.8:

  - §6.2 — a message with NO `@mention`: every User member still
    gets `chat.receive` + the `esr:user:<uri>:events` notification;
    every Agent member gets nothing; the `esr:session:` stream
    broadcast still fires.
  - §6.3 — a message `@`-mentioning one agent: exactly that agent
    gets `chat.receive`; other member agents do not.
  - §6.5 — cascade: N echo agents, a seed with no mention → zero
    agent dispatches; the cascade ends structurally.
  - §6.8 — the session stream broadcast is unconditional regardless
    of mentions.

  Drives the production path: `Chat.invoke(:send, ...)` through
  `Invocation.dispatch` against the live Session GenServer, with the
  routing table set to the migrated `system_default` shape
  `{:always} → [$session_users, $mentions]`. `chat.receive`
  dispatches are observed via the `invocations` audit log — the
  authoritative cross-recipient observable.
  """

  use EzagentCore.DataCase, async: false
  import Ecto.Query

  alias Ezagent.{Invocation, Message, RoutingRegistry}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.User
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

    :ok
  end

  defp u(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Install a routing table holding ONLY the migrated system_default
  # rule shape: {:always} → [$session_users, $mentions].
  defp install_default_rule_table do
    table = String.to_atom("mg_routing_#{u("t")}")
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

  # Spawn a real Session bound to workspace://default + return its URI.
  defp spawn_session do
    session = URI.new!("session://default/default/#{u("mg-sess")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, URI.new!("workspace://default"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session) end)
    session
  end

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=chat.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{caller: member, caps: User.admin_caps(), reply: :ignore}
      })

    Process.sleep(50)
  end

  defp dispatch_send(session, sender, text, mentions \\ []) do
    msg =
      Message.new(sender, %{text: text, attachments: []}, mentions: mentions)

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=chat.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{caller: sender, caps: User.admin_caps(), reply: :ignore}
      })

    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)
    Process.sleep(300)
    msg
  end

  defp receive_dispatch_count(target_uri) do
    prefix = "#{URI.to_string(target_uri)}?action=chat.receive"

    EzagentCore.Repo.aggregate(
      from(i in "invocations",
        where:
          fragment("? LIKE ?", i.target, ^"#{prefix}%") and
            i.authz == "granted"
      ),
      :count
    )
  end

  test "§6.2 — no mention: User member gets chat.receive, Agent member gets none" do
    install_default_rule_table()
    session = spawn_session()

    sender = URI.new!("entity://user/default/#{u("sender")}")
    user_member = URI.new!("entity://user/default/#{u("usermem")}")
    agent_member = URI.new!("entity://agent/default/echo_#{u("a")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_member)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(agent_member)

    join(session, sender)
    join(session, user_member)
    join(session, agent_member)

    user_before = receive_dispatch_count(user_member)
    agent_before = receive_dispatch_count(agent_member)

    _ = dispatch_send(session, sender, "hello everyone, no mention here")

    assert receive_dispatch_count(user_member) > user_before,
           "an un-mentioned User member must still get chat.receive (per-user notification)"

    assert receive_dispatch_count(agent_member) == agent_before,
           "an un-mentioned Agent member must get NO chat.receive (mention-gated)"
  end

  test "§6.2 — no mention: the User member's slice-change notification still fires" do
    # PR-N3 (SPEC v2 notification-architecture-v2, Allen 2026-05-25) —
    # the legacy `esr:user:<uri>:events` topic + `{:message_received, _}`
    # envelope were replaced by the slice-change auto-hook
    # (`esr:entity:<uri>:slice_changed` + `{:slice_changed, event_map}`).
    # The §6.2 invariant ("un-mentioned User still gets a per-user
    # notification") is preserved structurally: the Chat User-branch
    # now mutates the User's `:chat` slice on every receive, and the
    # hook emits the slice-change event to the user's stream.
    install_default_rule_table()
    session = spawn_session()

    sender = URI.new!("entity://user/default/#{u("sender")}")
    user_member = URI.new!("entity://user/default/#{u("usermem")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_member)

    join(session, sender)
    join(session, user_member)

    :ok = Ezagent.Notifications.subscribe_slice_change(user_member)

    msg = dispatch_send(session, sender, "ping, no mention")

    assert_receive {:slice_changed, %{action: :receive, new_slice: new_slice}}, 1_000
    assert new_slice.last_received.message_id == msg.id
  end

  test "§6.8 — the session stream broadcast is unconditional (no mention)" do
    install_default_rule_table()
    session = spawn_session()
    sender = URI.new!("entity://user/default/#{u("sender")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    join(session, sender)

    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session))

    msg = dispatch_send(session, sender, "stream shows everything")

    assert_receive {:chat_message, _s, %Message{id: rid}}, 1_000
    assert rid == msg.id
  end

  test "§6.3 — @mention one agent: exactly that agent gets chat.receive, others don't" do
    install_default_rule_table()
    session = spawn_session()

    sender = URI.new!("entity://user/default/#{u("sender")}")
    mentioned = URI.new!("entity://agent/default/echo_#{u("hit")}")
    other = URI.new!("entity://agent/default/echo_#{u("miss")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(mentioned)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(other)

    join(session, sender)
    join(session, mentioned)
    join(session, other)

    mentioned_before = receive_dispatch_count(mentioned)
    other_before = receive_dispatch_count(other)

    _ = dispatch_send(session, sender, "hey @agent", [mentioned])

    assert receive_dispatch_count(mentioned) > mentioned_before,
           "the @-mentioned agent must get chat.receive"

    assert receive_dispatch_count(other) == other_before,
           "an un-mentioned member agent must get NO chat.receive"
  end

  test "§6.5 — cascade: N echo agents, no-mention seed → zero agent dispatches" do
    install_default_rule_table()
    session = spawn_session()

    sender = URI.new!("entity://user/default/#{u("sender")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    join(session, sender)

    agents =
      for _ <- 1..5 do
        a = URI.new!("entity://agent/default/echo_#{u("cascade")}")
        {:ok, _} = Ezagent.SpawnRegistry.spawn(a)
        join(session, a)
        a
      end

    before = Enum.map(agents, &receive_dispatch_count/1)

    _ = dispatch_send(session, sender, "seed message with NO mention — should not actuate anyone")

    after_counts = Enum.map(agents, &receive_dispatch_count/1)

    assert before == after_counts,
           "a no-mention seed must produce ZERO agent dispatches — " <>
             "the {:always} default no longer actuates every agent (cascade storm fix)"
  end
end
