defmodule EzagentDomainInstanceMessage.Integration.SendEchoDecoupleTest do
  @moduledoc """
  send-echo-decouple (2026-07-08) — a dead/slow session member must NEVER drag
  the sender's own message echo.

  Reproduces the nightly admin-walk symptom: a session with a cold np-flavor
  agent member (compute error) made EVERY message send appear in the feed only
  after a CONSTANT ~5s, because the Session Kind ran the per-recipient fan-out
  SYNCHRONOUSLY inside `handle_send` — including the blocking
  `Ezagent.SpawnRegistry.ensure_live/1` cold-member revival — BEFORE it returned
  the `{:notify, :chat_message}` feed-broadcast effect. The sender's own echo
  therefore waited on delivery to a member it does not depend on.

  The fix (`Delivery.deliver_async/5`) fans each recipient's delivery into an
  UNLINKED supervised Task, so `handle_send` returns immediately and the feed
  broadcast fires without waiting on any member.

  Injection point (advisor-confirmed): the ONLY synchronous slow call in the
  fan-out loop is `ensure_live` — the `:receive` dispatch itself is a `:cast`
  (`reply: :ignore`), non-blocking. So the stub is a COLD agent-scheme member
  whose spawn is made to sleep @slow_spawn_ms (simulating the np cold provision).

    * On UNMODIFIED main: the feed broadcast is delayed ~@slow_spawn_ms → the
      `< @fast_ms` assertions FAIL (documents the regression).
    * After the fix: the broadcast is fast; the slow spawn runs in a background
      Task and blocks nobody.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, SpawnRegistry}
  alias Ezagent.ActionSet.Session.Delivery
  alias Ezagent.Routing.Resolver
  alias Ezagent.RoutingRegistry

  @slow_spawn_ms 1_200
  @fast_ms 500

  defp u(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end

  setup do
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    # A single routing rule: {:always} → [$session_members], so every joined
    # member (incl. the cold slow agent) is a fan-out recipient.
    table = String.to_atom("send_echo_#{u("t")}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    :ok =
      RoutingRegistry.put(
        table,
        Ezagent.Routing.Matcher.always(),
        [Resolver.session_members_token()]
      )

    Application.put_env(:ezagent_core, :routing_tables, [table])
    :ok
  end

  defp spawn_session do
    session = Ezagent.URI.new!("session://team-alpha/default/#{u("se-sess")}")
    {:ok, _} = SpawnRegistry.spawn(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, Ezagent.URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session) end)
    session
  end

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(session)}?action=session.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  # Spawn a real echo agent member, join it, then make its spawn slow and
  # terminate it → a COLD-but-durable member whose `ensure_live` revival blocks
  # @slow_spawn_ms. Restores the original entity spawn fn on exit.
  defp join_cold_slow_member(session) do
    member = Ezagent.URI.new!("entity://team-alpha/agent/slow_np_#{u("m")}")
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(member, "echo")
    join(session, member)

    [{"entity", original_entity_fn}] = :ets.lookup(SpawnRegistry.table(), "entity")

    slow_fn = fn %URI{} = uri ->
      if URI.to_string(uri) == URI.to_string(member), do: Process.sleep(@slow_spawn_ms)
      original_entity_fn.(uri)
    end

    :ok = SpawnRegistry.register("entity", slow_fn)
    on_exit(fn -> SpawnRegistry.register("entity", original_entity_fn) end)

    # Go cold: kill the live member process (snapshot row survives → ensure_live
    # will attempt the now-slow re-spawn instead of :not_created).
    :ok = Ezagent.Kind.terminate(member)
    wait_until(fn -> Ezagent.KindRegistry.lookup(member) == :error end)

    member
  end

  defp subscribe(session) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Delivery.session_events_topic(session))
  end

  # Wait for every in-flight background delivery Task to finish BEFORE the test
  # returns, so the slow cold-member spawn (which reads/writes snapshots) does
  # not race the sandbox owner teardown. Test-hygiene only — it runs AFTER the
  # timing assertions have already captured the (fast) echo latency.
  defp drain_delivery_tasks do
    wait_until(
      fn -> Task.Supervisor.children(Ezagent.Session.DeliverySupervisor) == [] end,
      200
    )
  end

  # Dispatch a send (cast) and return {msg_id, elapsed_ms_until_feed_broadcast}.
  defp send_and_time(session, sender, text) do
    msg = Message.new(sender, %{text: text, attachments: []}, mentions: [])
    t0 = System.monotonic_time(:millisecond)

    :ok =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(session)}?action=session.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    id = msg.id
    assert_receive {:chat_message, _s, %Message{id: ^id}}, @fast_ms + 1_500
    {id, System.monotonic_time(:millisecond) - t0}
  end

  test "sender echo (feed broadcast) is fast despite a cold slow member; and the next send is not blocked behind it" do
    session = spawn_session()
    sender = Ezagent.URI.new!("entity://team-alpha/user/#{u("sender")}")
    {:ok, _} = SpawnRegistry.spawn(sender)
    join(session, sender)

    _slow = join_cold_slow_member(session)
    subscribe(session)

    # Prong A — the sender's own message hits the feed FAST, even though the
    # only other recipient is a cold member whose ensure_live spawn sleeps
    # @slow_spawn_ms (> @fast_ms). On unmodified main this arrives ~@slow_spawn_ms.
    {_id1, elapsed1} = send_and_time(session, sender, "prong A: fast echo")

    assert elapsed1 < @fast_ms,
           "feed broadcast took #{elapsed1}ms (>= #{@fast_ms}ms) — the sender echo is " <>
             "still coupled to the slow member's synchronous fan-out delivery"

    # Prong B — a SECOND rapid send must ALSO be fast: the slow member's delivery
    # must not have parked the Session Kind (on main, the pipeline would be busy
    # ~@slow_spawn_ms in the first send's fan-out, delaying this one too).
    {_id2, elapsed2} = send_and_time(session, sender, "prong B: pipeline not blocked")

    assert elapsed2 < @fast_ms,
           "second send took #{elapsed2}ms (>= #{@fast_ms}ms) — a slow member delivery " <>
             "is blocking the send pipeline / the next send"

    drain_delivery_tasks()
  end

  test "ordering — multiple rapid sends appear in the feed in send order" do
    session = spawn_session()
    sender = Ezagent.URI.new!("entity://team-alpha/user/#{u("sender")}")
    {:ok, _} = SpawnRegistry.spawn(sender)
    join(session, sender)

    _slow = join_cold_slow_member(session)
    subscribe(session)

    ids =
      for n <- 1..5 do
        msg = Message.new(sender, %{text: "ordered #{n}", attachments: []}, mentions: [])

        :ok =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.new!("#{URI.to_string(session)}?action=session.send"),
            mode: :cast,
            args: %{message: msg},
            ctx: %{
              caller: sender,
              caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
              reply: :ignore
            }
          })

        msg.id
      end

    received =
      for _ <- 1..5 do
        assert_receive {:chat_message, _s, %Message{id: id}}, @fast_ms + 1_500
        id
      end

    assert received == ids,
           "feed order #{inspect(received)} did not match send order #{inspect(ids)} — " <>
             "async fan-out must not reorder the sender-visible feed"

    drain_delivery_tasks()
  end
end
