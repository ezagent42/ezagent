defmodule EzagentDomainInstanceMessage.Integration.MentionGatedRoutingTest do
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

  Drives the production path: `SessionBehavior.invoke(:send, ...)` through
  `Invocation.dispatch` against the live Session GenServer, with the
  routing table set to the migrated `system_default` shape
  `{:always} → [$session_users, $mentions]`. `chat.receive`
  dispatches are observed via the `invocations` audit log — the
  authoritative cross-recipient observable.
  """

  use EzagentCore.DataCase, async: false
  import Ecto.Query

  alias Ezagent.{Invocation, Message, RoutingRegistry}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.User
  alias Ezagent.Routing.Resolver

  setup do
    # `chat.receive` dispatches are observed via the `invocations` audit
    # log (the moduledoc's "authoritative cross-recipient observable").
    # `Ezagent.Audit.Writer` is skipped from the test-env supervision tree
    # (2026-05-26 sandbox-isolation fix), so start it per-test and allow it
    # onto this test's sandbox connection — otherwise no rows are written
    # and every `receive_dispatch_count/1` stays 0.
    {:ok, writer} = start_supervised(Ezagent.Audit.Writer)
    Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), writer)

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

  # Spawn a real Session bound to workspace://team-alpha + return its URI.
  defp spawn_session do
    session = URI.new!("session://team-alpha/default/#{u("mg-sess")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session) end)
    session
  end

  defp join(session, member) do
    target = URI.new!("#{URI.to_string(session)}?action=session.join")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, member)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  defp dispatch_send(session, sender, text, mentions \\ []) do
    msg =
      Message.new(sender, %{text: text, attachments: []}, mentions: mentions)

    target = URI.new!("#{URI.to_string(session)}?action=session.send")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, sender)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      })

    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)
    Process.sleep(300)
    msg
  end

  defp receive_dispatch_count(target_uri) do
    # PR-2 (im/session/agent decomposition §OQ-4 / §3.3): the `:receive`
    # fan-out now spells the behavior prefix per recipient Kind —
    # `user.receive` for a user target, `agent.receive` for an agent. The
    # prefix is telemetry-only (routing keys on the `:receive` action atom
    # + Kind), but the audit `target` carries it, so this counter matches
    # the per-Kind spelling instead of the retired `session.receive`.
    behavior =
      case Ezagent.URI.type(target_uri) do
        {:ok, "user"} -> "user"
        _ -> "agent"
      end

    prefix = "#{URI.to_string(target_uri)}?action=#{behavior}.receive"

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

    sender = URI.new!("entity://team-alpha/user/#{u("sender")}")
    user_member = URI.new!("entity://team-alpha/user/#{u("usermem")}")
    agent_member = URI.new!("entity://team-alpha/agent/echo_#{u("a")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_member)
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_member, "echo")

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

    sender = URI.new!("entity://team-alpha/user/#{u("sender")}")
    user_member = URI.new!("entity://team-alpha/user/#{u("usermem")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_member)

    join(session, sender)
    join(session, user_member)

    :ok = Ezagent.Notifications.subscribe_slice_change(user_member)

    msg = dispatch_send(session, sender, "ping, no mention")

    # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25): the slice-change
    # broadcast envelope is security-minimal — `uri / slice_key /
    # cursor / event_at / result_summary`. Slice content is fetched
    # via `Kind.get_slice/2` per the new contract; see
    # `apps/ezagent_core/test/invariants/slice_change_event_carries_no_slice_content_test.exs`.
    assert_receive {:slice_changed, %{uri: ^user_member, slice_key: :session}}, 1_000
    {:ok, slice} = Ezagent.Kind.get_slice(user_member, :session)
    assert slice.last_received.message_id == msg.id
  end

  test "§6.8 — the session stream broadcast is unconditional (no mention)" do
    install_default_rule_table()
    session = spawn_session()
    sender = URI.new!("entity://team-alpha/user/#{u("sender")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    join(session, sender)

    :ok =
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, SessionBehavior.session_events_topic(session))

    msg = dispatch_send(session, sender, "stream shows everything")

    assert_receive {:chat_message, _s, %Message{id: rid}}, 1_000
    assert rid == msg.id
  end

  test "§6.3 — @mention one agent: exactly that agent gets chat.receive, others don't" do
    install_default_rule_table()
    session = spawn_session()

    sender = URI.new!("entity://team-alpha/user/#{u("sender")}")
    mentioned = URI.new!("entity://team-alpha/agent/echo_#{u("hit")}")
    other = URI.new!("entity://team-alpha/agent/echo_#{u("miss")}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(mentioned, "echo")
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(other, "echo")

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

    sender = URI.new!("entity://team-alpha/user/#{u("sender")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(sender)
    join(session, sender)

    agents =
      for _ <- 1..5 do
        a = URI.new!("entity://team-alpha/agent/echo_#{u("cascade")}")
        {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(a, "echo")
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
