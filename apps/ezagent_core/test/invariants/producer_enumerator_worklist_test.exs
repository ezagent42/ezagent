defmodule EzagentCore.Invariants.ProducerEnumeratorWorklistTest do
  @moduledoc """
  V5 pid-closure, Track B (use side), B1/D2 — the producer enumerator's
  HAS-TEETH self-test (**report-only** — nothing here gates on a
  violation).

  Two jobs:

    1. prove the enumerator is not blinded: it MUST surface every known
       producer FLOOR site below. Post-B2 the floor is the DEFERRED
       mixed-subscriber family ONLY (`{:pty_phase}` / `{:slice_changed}` —
       topics with BOTH a Kind and a LiveView subscriber, left raw pending
       a separate UI-coupling decision). The B2-migrated sites are pinned
       by the "post-B2 migration" tests below (envelope-form sites are
       still enumerated, with their new shapes). If the enumerator misses
       any floor site, the ENUMERATOR is wrong — fix the enumerator, not
       this test.
    2. regenerate the committed producer worklist
       `docs/notes/v5-use-side-producer-worklist.md` (full emit) — the B2
       migration worklist authority.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ProducerEnumerator

  @worklist_path "docs/notes/v5-use-side-producer-worklist.md"

  # The has-teeth floor ({path, target, shape}) — every entry MUST be
  # surfaced. Post-B2 this is the DEFERRED mixed-subscriber family: both
  # topics have a LiveView subscriber as well as a Kind subscriber, so the
  # producer stays raw until the UI-coupling decision (a later, separate
  # task). Everything else from the B1 floor was migrated onto the
  # `%EzagentActor.Signal{}` transport in B2 (see the post-B2 tests below).
  @floor [
    {"apps/ezagent_domain_pty/lib/ezagent_domain_pty/phase_broadcast.ex",
     "Phoenix.PubSub.broadcast/3", {:pty_phase, 4}},
    {"apps/ezagent_actor/lib/ezagent/slice_change.ex", "Phoenix.PubSub.broadcast/3",
     {:slice_changed, 2}}
  ]

  test "has-teeth: surfaces every producer floor site (path + primitive + shape)" do
    found = MapSet.new(ProducerEnumerator.sites(), &{&1.path, &1.target, &1.shape})

    for {path, target, shape} <- @floor do
      assert MapSet.member?(found, {path, target, shape}),
             "enumerator MISSED floor site #{target} #{inspect(shape)} at #{path} — blinded"
    end
  end

  test "post-B2: the raw {:publisher_event} sends are gone; BOTH fan-out sites remain as bare-pid envelope wraps" do
    sites = ProducerEnumerator.sites()

    raw_count =
      Enum.count(sites, fn s ->
        s.path == "apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex" and
          s.target == "Kernel.send/2" and s.shape == {:publisher_event, 2}
      end)

    assert raw_count == 0,
           "expected 0 raw {:publisher_event} sends in session_impl.ex, got #{raw_count}"

    # The bare-pid fallback form (B2): `send(pid, %EzagentActor.Signal{…})`
    # is still a Kernel.send/2, with a :dynamic (struct-literal) shape.
    wrapped_count =
      Enum.count(sites, fn s ->
        s.path == "apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex" and
          s.target == "Kernel.send/2" and s.shape == :dynamic
      end)

    assert wrapped_count == 2,
           "expected 2 bare-pid %Signal{} wrap sends in session_impl.ex, got #{wrapped_count}"
  end

  test "post-B2: the deferred-dispatch self-send remains as the bare-self envelope wrap" do
    count =
      Enum.count(ProducerEnumerator.sites(), fn s ->
        s.path == "apps/ezagent_actor/lib/ezagent/kind/deferred_dispatch.ex" and
          s.target == "Kernel.send/2" and s.shape == :dynamic
      end)

    assert count == 1,
           "expected 1 bare-self %Signal{} wrap send in deferred_dispatch.ex, got #{count}"
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
