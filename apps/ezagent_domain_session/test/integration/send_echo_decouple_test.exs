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
  # Echo-latency bound: RELATIVE to the injected spawn delay (codex MED-3 —
  # wall-clock assertions flake on a loaded runner; what we actually assert is
  # echo_time << slow_spawn_ms, i.e. the echo did NOT wait for the slow spawn).
  @fast_ms div(@slow_spawn_ms, 2)

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
    target = Ezagent.URI.new!("#{URI.to_string(session)}?action=session.join")
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

  # Spawn a real echo agent member, join it, then make its spawn slow and
  # terminate it → a COLD-but-durable member whose `ensure_live` revival blocks
  # @slow_spawn_ms. Restores the original entity spawn fn on exit.
  #
  # `mode:`
  #   * `:every` — every spawn of the member sleeps (dead-member simulation).
  #   * `:once`  — ONLY the first spawn call sleeps (and it messages
  #     `notify_pid` `:slow_spawn_entered` BEFORE sleeping). Used by the
  #     recipient-ordering test: delivery job #1 is slow, job #2 fast — the
  #     exact interleave codex HIGH-1 proved reorders per-recipient delivery
  #     without a per-recipient serialized queue.
  defp join_cold_slow_member(session, mode \\ :every, notify_pid \\ nil) do
    member = Ezagent.URI.new!("entity://team-alpha/agent/slow_np_#{u("m")}")
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(member, "echo")
    join(session, member)

    [{"entity", original_entity_fn}] = :ets.lookup(SpawnRegistry.table(), "entity")
    once_guard = :atomics.new(1, [])

    slow_fn = fn %URI{} = uri, opts ->
      if URI.to_string(uri) == URI.to_string(member) do
        case mode do
          :every ->
            Process.sleep(@slow_spawn_ms)

          :once ->
            if :atomics.add_get(once_guard, 1, 1) == 1 do
              if is_pid(notify_pid), do: send(notify_pid, :slow_spawn_entered)
              Process.sleep(@slow_spawn_ms)
            end
        end
      end

      original_entity_fn.(uri, opts)
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

  # Wait for every queued + in-flight background delivery to finish BEFORE the
  # test returns, so the slow cold-member spawn (which reads/writes snapshots)
  # does not race the sandbox owner teardown. Test-hygiene only — it runs AFTER
  # the timing assertions have already captured the (fast) echo latency.
  defp drain_delivery_tasks do
    wait_until(
      fn ->
        Ezagent.Session.DeliveryQueue.idle?() and
          Task.Supervisor.children(Ezagent.Session.DeliverySupervisor) == []
      end,
      200
    )
  end

  # Dispatch a send (cast) and return {msg_id, elapsed_ms_until_feed_broadcast}.
  defp send_and_time(session, sender, text) do
    msg = Message.new(sender, %{text: text, attachments: []}, mentions: [])
    t0 = System.monotonic_time(:millisecond)

    target = Ezagent.URI.new!("#{URI.to_string(session)}?action=session.send")
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

        target = Ezagent.URI.new!("#{URI.to_string(session)}?action=session.send")
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

  # ── codex HIGH-1 regression — PER-RECIPIENT delivery order ──────────────
  #
  # One unserialized Task per delivery gives NO cross-task ordering: two rapid
  # sends to the SAME recipient race, and if msg2's task wins, the recipient
  # observes [msg2, msg1] (wrong `last_received` / `recent_messages` order,
  # ReadMarker's monotonic cursor records "delivered up to msg2" and DISCARDS
  # msg1's later marker as stale). The fix: `Delivery.deliver_async/5` enqueues
  # into `Ezagent.Session.DeliveryQueue` — per-recipient-key FIFO, ONE in-flight
  # job per key — so a recipient always observes messages in send order while a
  # dead member still only ever blocks its OWN key (Prong B intact).
  #
  # Determinism: the slow spawn (`:once` mode) signals `:slow_spawn_entered`
  # BEFORE sleeping; the test sends msg2 only after that signal, so on the
  # unserialized code msg2's delivery ALWAYS overtakes msg1's (task 1 is
  # provably parked in the spawn sleep when msg2's job starts).
  #
  # Observation channel: `{Entity.Agent, :receive}` is swapped to the REAL
  # `Ezagent.ActionSet.User.Receive` (production behavior, same cap-exempt +
  # in-handler member-cap authorization contract) purely because it records
  # arrivals observably — `last_received` + the newest-first `recent_messages`
  # ring on the recipient's `:session` slice (exactly codex's harm (a)).
  test "per-recipient delivery order — a slow first delivery must not let a later send overtake it" do
    session = spawn_session()
    sender = Ezagent.URI.new!("entity://team-alpha/user/#{u("sender")}")
    {:ok, _} = SpawnRegistry.spawn(sender)
    join(session, sender)

    member = join_cold_slow_member(session, :once, self())

    # Swap the agent-Kind receive behavior for the observable production
    # User.Receive; restore the original on exit.
    {:ok, original_receive} = Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive)

    :ok =
      Ezagent.BehaviorRegistry.register(
        Ezagent.Entity.Agent,
        :receive,
        Ezagent.ActionSet.User.Receive
      )

    on_exit(fn ->
      Ezagent.BehaviorRegistry.register(Ezagent.Entity.Agent, :receive, original_receive)
    end)

    subscribe(session)

    # msg1 — its delivery job enters the slow cold-member spawn.
    {id1, _} = send_and_time(session, sender, "recipient-order msg1")
    assert_receive :slow_spawn_entered, @slow_spawn_ms

    # msg2 — sent while msg1's delivery is provably parked in the spawn sleep.
    {id2, _} = send_and_time(session, sender, "recipient-order msg2")

    drain_delivery_tasks()

    {:ok, slice} = Ezagent.Kind.get_slice(member, :session)
    state = Map.get(slice, :state, slice)

    ring_ids =
      state
      |> Map.get(:recent_messages, [])
      |> Enum.map(fn {_cursor, msg_id} -> msg_id end)

    assert ring_ids == [id2, id1],
           "recipient ring (newest-first) is #{inspect(ring_ids)}, expected " <>
             "#{inspect([id2, id1])} — msg2's delivery overtook msg1's (per-recipient " <>
             "delivery is not serialized in send order)"

    assert %{message_id: ^id2} = Map.get(state, :last_received),
           "recipient last_received is #{inspect(Map.get(state, :last_received))}, " <>
             "expected msg2 (#{id2}) as the LAST arrival — arrival order was inverted"
  end
end
