defmodule EzagentCore.Invariants.ProducerEnumeratorWorklistTest do
  @moduledoc """
  V5 pid-closure, Track B (use side), B1/D2 — the producer enumerator's
  HAS-TEETH self-test (**report-only** — nothing here gates on a
  violation).

  Two jobs:

    1. prove the enumerator is not blinded: it MUST surface every known
       producer FLOOR site below (the B1 task's has-teeth floor — the
       known raw producers into Kind mailboxes), INCLUDING sites inside
       the actor app (which the FORWARD boundary gate excludes). If the
       enumerator misses any, the ENUMERATOR is wrong — fix the
       enumerator, not this test.
    2. regenerate the committed producer worklist
       `docs/notes/v5-use-side-producer-worklist.md` (full emit) — the B2
       migration worklist authority.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ProducerEnumerator

  @worklist_path "docs/notes/v5-use-side-producer-worklist.md"

  # The has-teeth floor ({path, target, shape}) — every entry MUST be
  # surfaced. Shapes are the statically-visible message literals (module
  # attributes resolved: `:ezagent_ce_reconcile` arrives via
  # `@ce_reconcile_signal` in config_evolve.ex).
  @floor [
    # PubSub fan-out a Kind subscribes to
    {"apps/ezagent_domain_pty/lib/ezagent_domain_pty/phase_broadcast.ex",
     "Phoenix.PubSub.broadcast/3", {:pty_phase, 4}},
    {"apps/ezagent_actor/lib/ezagent/slice_change.ex", "Phoenix.PubSub.broadcast/3",
     {:slice_changed, 2}},
    {"apps/ezagent_core/lib/ezagent/publisher_lifecycle.ex", "Phoenix.PubSub.broadcast/3",
     {:publisher_alive, 2}},
    # Raw cross-process sends into a Kind mailbox
    {"apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex",
     "Kernel.send/2", {:publisher_event, 2}},
    {"apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex",
     "Kernel.send/2", {:ezagent_worker_subscribe_result, 2}},
    {"apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex",
     "Kernel.send/2", {:ezagent_worker_resubscribe_result, 3}},
    {"apps/ezagent_actor/lib/ezagent/kind/ready_transition.ex", "Kernel.send/2",
     {:ezagent_external_ready_gate, 3}},
    # Raw SELF-sends (incl. deferred dispatch + Lifecycle activate loops)
    {"apps/ezagent_actor/lib/ezagent/kind/deferred_dispatch.ex", "Kernel.send/2",
     {:ezagent_run_deferred, 2}},
    {"apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex", "Kernel.send/2",
     {:ezagent_recover_settlements, 1}},
    {"apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex", "Kernel.send/2",
     :ezagent_ce_reconcile},
    {"apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex",
     "Kernel.send/2", {:ezagent_em_reconcile, 2}}
  ]

  test "has-teeth: surfaces every producer floor site (path + primitive + shape)" do
    found = MapSet.new(ProducerEnumerator.sites(), &{&1.path, &1.target, &1.shape})

    for {path, target, shape} <- @floor do
      assert MapSet.member?(found, {path, target, shape}),
             "enumerator MISSED floor site #{target} #{inspect(shape)} at #{path} — blinded"
    end
  end

  test "has-teeth: BOTH publisher_event fan-out sites surface (replay + live)" do
    count =
      Enum.count(ProducerEnumerator.sites(), fn s ->
        s.path == "apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex" and
          s.target == "Kernel.send/2" and s.shape == {:publisher_event, 2}
      end)

    assert count == 2,
           "expected 2 {:publisher_event} send sites in session_impl.ex, got #{count}"
  end

  test "has-teeth: the B1 transport's own envelope sends are enumerated (empty allowlist)" do
    paths = MapSet.new(ProducerEnumerator.sites(), & &1.path)

    assert MapSet.member?(paths, "apps/ezagent_actor/lib/ezagent_actor/signal.ex")
    assert MapSet.member?(paths, "apps/ezagent_actor/lib/ezagent_actor/signal/monitor.ex")
  end

  test "synthetic: bare send/2 is flagged unless the file defines a local send" do
    flagged = """
    defmodule SynthBareSend do
      def poke(pid, msg), do: send(pid, {:raw, msg})
    end
    """

    assert [%{target: "Kernel.send/2", shape: {:raw, 2}}] =
             ProducerEnumerator.sites_in_source(flagged, "synth/bare_send.ex")

    local = """
    defmodule SynthLocalSend do
      def send(pid, msg), do: Kernel.send(pid, msg)
      def poke(pid, msg), do: send(pid, {:raw, msg})
    end
    """

    # The bare call is a LOCAL call (not flagged); the qualified Kernel.send
    # inside the local definition still is (its msg is a variable → :dynamic).
    assert [%{target: "Kernel.send/2", line: 2, shape: :dynamic}] =
             ProducerEnumerator.sites_in_source(local, "synth/local_send.ex")
  end

  test "synthetic: timers, Process.send, local_broadcast, and send_envelope are flagged" do
    source = """
    defmodule SynthProducers do
      alias Ezagent.Runtime.Resolver

      def a(pid, msg), do: Process.send(pid, msg, [:noconnect])
      def b(pid, msg), do: Process.send_after(pid, {:tick, msg}, 1_000)
      def c(topic, msg), do: Phoenix.PubSub.local_broadcast(EzagentCore.PubSub, topic, msg)
      def d(key, msg), do: Resolver.send_envelope(key, {:envelope, msg})
      def e(pid, msg), do: :erlang.send(pid, msg)
    end
    """

    targets =
      MapSet.new(ProducerEnumerator.sites_in_source(source, "synth/producers.ex"), & &1.target)

    assert MapSet.member?(targets, "Process.send/3")
    assert MapSet.member?(targets, "Process.send_after/3")
    assert MapSet.member?(targets, "Phoenix.PubSub.local_broadcast/3")
    assert MapSet.member?(targets, "Ezagent.Runtime.Resolver.send_envelope/2")
    assert MapSet.member?(targets, ":erlang.send/2")
  end

  test "synthetic: shape column — atom, tuple, module attribute, dynamic" do
    source = """
    defmodule SynthShapes do
      @reconcile :ezagent_ce_reconcile

      def a(pid), do: send(pid, :bare_atom)
      def b(pid), do: send(pid, {:head, 1, 2})
      def c(pid), do: send(pid, @reconcile)
      def d(pid, msg), do: send(pid, msg)
      def e(pid, x), do: send(pid, {:computed, x})
    end
    """

    shapes =
      Map.new(ProducerEnumerator.sites_in_source(source, "synth/shapes.ex"), &{&1.line, &1.shape})

    assert shapes[4] == :bare_atom
    assert shapes[5] == {:head, 3}
    assert shapes[6] == :ezagent_ce_reconcile
    assert shapes[7] == :dynamic
    assert shapes[8] == {:computed, 2}
  end

  test "regenerates the producer worklist markdown (full emit)" do
    sites = ProducerEnumerator.sites()
    assert sites != []

    path = Path.join(ProducerEnumerator.repo_root(), @worklist_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ProducerEnumerator.worklist_markdown(sites))
  end
end
