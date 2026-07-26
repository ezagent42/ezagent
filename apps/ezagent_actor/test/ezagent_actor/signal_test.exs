defmodule EzagentActor.SignalTest do
  @moduledoc """
  V5 use-side B1 — the `EzagentActor.Signal` transport: every delivery path
  (`signal/2`, `broadcast/2`, `monitor/1`, `send_after/2`) produces the
  sanctioned envelope struct, never a raw tuple / `{:DOWN, ...}` / timer
  atom. Nothing is sealed or migrated here — these tests pin the TRANSPORT
  shape only.
  """
  use ExUnit.Case, async: false

  alias Ezagent.KindRegistry
  alias EzagentActor.Signal

  defp unique_uri(tag),
    do: "entity://test/agent/signal-#{tag}-#{System.unique_integer([:positive])}"

  describe "signal/2" do
    test "delivers the payload as the sanctioned envelope to a registered Kind URI" do
      uri = unique_uri("signal")
      :ok = KindRegistry.put_new(uri)

      assert :ok = Signal.signal(uri, {:hello, 42})
      assert_receive %Signal{kind: :signal, from: nil, payload: {:hello, 42}}
    end

    test "accepts a %URI{} target too" do
      uri = unique_uri("signal-uri")
      :ok = KindRegistry.put_new(uri)

      assert :ok = Signal.signal(URI.parse(uri), :ping)
      assert_receive %Signal{kind: :signal, payload: :ping}
    end

    test ":not_found for an unregistered target" do
      assert :not_found = Signal.signal(unique_uri("absent"), :ping)
    end
  end

  describe "broadcast/2 + subscribe/1" do
    setup do
      name = :"signal_test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: name})
      Application.put_env(:ezagent_actor, :pubsub, name)
      on_exit(fn -> Application.delete_env(:ezagent_actor, :pubsub) end)
      :ok
    end

    test "a subscriber receives the envelope struct, not a raw tuple" do
      topic = "signal:test:#{System.unique_integer([:positive])}"

      assert :ok = Signal.subscribe(topic)
      assert :ok = Signal.broadcast(topic, {:slice_changed, :fake})

      assert_receive %Signal{kind: :broadcast, from: ^topic, payload: {:slice_changed, :fake}}
      refute_received {:slice_changed, :fake}
    end

    test "unsubscribe/1 stops delivery" do
      topic = "signal:test:#{System.unique_integer([:positive])}"

      :ok = Signal.subscribe(topic)
      :ok = Signal.unsubscribe(topic)
      :ok = Signal.broadcast(topic, :gone)

      refute_receive %Signal{kind: :broadcast, payload: :gone}, 100
    end
  end

  describe "monitor/1" do
    test "the death notice arrives as a %Signal{kind: :down} envelope" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, ref} = Signal.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive %Signal{
        kind: :down,
        from: ^pid,
        payload: %{ref: ^ref, pid: ^pid, reason: :killed}
      }

      refute_received {:DOWN, _, :process, _, _}
    end

    test "monitoring an already-dead pid delivers the envelope with :noproc (BEAM semantics)" do
      pid = spawn(fn -> :ok end)
      raw = Process.monitor(pid)
      assert_receive {:DOWN, ^raw, :process, ^pid, _}

      assert {:ok, ref} = Signal.monitor(pid)
      assert_receive %Signal{kind: :down, payload: %{ref: ^ref, pid: ^pid, reason: :noproc}}
    end

    test "distinct monitors get distinct refs, each delivered once" do
      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, ref_a} = Signal.monitor(pid_a)
      {:ok, ref_b} = Signal.monitor(pid_b)
      refute ref_a == ref_b

      Process.exit(pid_a, :kill)
      assert_receive %Signal{kind: :down, payload: %{ref: ^ref_a}}
      refute_receive %Signal{kind: :down, payload: %{ref: ^ref_b}}, 100

      Process.exit(pid_b, :kill)
      assert_receive %Signal{kind: :down, payload: %{ref: ^ref_b}}
    end
  end

  describe "send_after/2" do
    test "the timer message arrives as a %Signal{kind: :timer} envelope" do
      timer = Signal.send_after({:reconcile, 1}, 10)
      assert is_reference(timer)

      assert_receive %Signal{kind: :timer, payload: {:reconcile, 1}}, 500
    end

    test "cancellable via Process.cancel_timer/1 (no message, no crash)" do
      timer = Signal.send_after(:never, 60_000)
      assert is_integer(Process.cancel_timer(timer))
      refute_receive %Signal{kind: :timer, payload: :never}, 100
    end
  end

  describe "effective_message/1 (B2 — the Kind.Server envelope unwrap)" do
    test "a :down envelope reconstructs the exact raw {:DOWN, ref, :process, pid, reason} tuple" do
      ref = make_ref()
      pid = self()

      envelope = %Signal{kind: :down, from: pid, payload: %{ref: ref, pid: pid, reason: :killed}}

      assert Signal.effective_message(envelope) == {:DOWN, ref, :process, pid, :killed}
    end

    test "every other envelope kind unwraps to the payload verbatim" do
      assert Signal.effective_message(%Signal{kind: :signal, payload: :snapshot_tick}) ==
               :snapshot_tick

      assert Signal.effective_message(%Signal{kind: :timer, payload: {:tick, 1}}) == {:tick, 1}

      assert Signal.effective_message(%Signal{kind: :broadcast, from: "t", payload: {:ev, 2}}) ==
               {:ev, 2}
    end

    test "the :down reconstruction is a plain tuple, never an envelope (no re-dispatch loop)" do
      ref = make_ref()

      message =
        Signal.effective_message(%Signal{
          kind: :down,
          payload: %{ref: ref, pid: self(), reason: :normal}
        })

      refute match?(%Signal{}, message)
      assert {:DOWN, ^ref, :process, _pid, :normal} = message
    end
  end
end
