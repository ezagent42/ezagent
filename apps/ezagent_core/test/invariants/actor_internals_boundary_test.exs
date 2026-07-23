defmodule EzagentCore.Invariants.ActorInternalsBoundaryTest do
  @moduledoc """
  Actor-framework extraction boundary gate — chunk C0 (spec §4). Delegates all
  scanning + enforcement to the SHARED `Ezagent.ActorBoundaryScanner` (SSOT,
  §4.5) so this ExUnit gate (PR-gate parity) and `mix ezagent.check_invariants`
  invariant #13 (ci.local parity) enforce the identical ledger.

  Two directions (§4.2): FORWARD — non-framework code must not reach INTO actor
  internals (seeds the §4.4 census); REVERSE — the mover set must not reach UP
  into staying-core (seeds the §3.4 port worklist).

  ## SITE-level ratchet

  The ledger (`Ezagent.ActorBoundaryLedger`) is a set of SITE fingerprints
  `{path, target, content_sha}`. Enforcement = `scanned − ledger == []`, so a
  NEW reach-in — even inside an already-allowlisted file, or naming an
  already-allowlisted module — has a new content SHA, is absent from the ledger,
  and REDs the gate (proven by the enforcement self-tests below). The ledger can
  only shrink: a stale entry fails the exact test.

  ## Re-seeding the ledger

      ACTOR_BOUNDARY_ALLOWLIST=empty mix test \
        apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs

  prints every scanned site; regenerate `Ezagent.ActorBoundaryLedger` from it
  when reach-ins migrate.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActorBoundaryScanner, as: Scanner

  # Committed ledger sizes — the ratchet asserts the live ledger never GROWS past
  # these. Later chunks LOWER them as reach-ins migrate / ports land.
  @forward_frozen 252
  @forward_fixed_frozen 2
  @reverse_frozen 123
  @reverse_fixed_frozen 3

  # ── FORWARD (§4.2 "The rule") ──────────────────────────────────────────────

  test "no non-framework code reaches INTO the actor internals (§4.2 forward)" do
    offenders = Scanner.forward_new_offenders()

    assert offenders == [],
           """
           FORWARD reach-in gate (§4.2): a non-framework module touches an actor
           internal directly. Route it through the §2.2 read surface (Kind.read/3,
           read_classified/2, read_durable/3 + read_durable_many/3, alive?/1,
           self?/1, list_instances/0, resolve_action_subject/2). New offenders:

           #{format_sites(offenders)}
           """
  end

  test "the forward ledger only shrinks — no stale entries (§4.2 ratchet)" do
    stale = Scanner.forward_stale()

    assert stale == [],
           "stale forward-ledger entries (migrated — remove them):\n#{format_sites(stale)}"

    assert Scanner.forward_fixed_missing() == [],
           "a fixed process-generation consumer site vanished (door check)"
  end

  test "the forward ledger does not grow past the frozen size" do
    # Sizes are frozen literals; the ratchet may only shrink. (Duplicate
    # identities are legitimate — two byte-identical reach-in lines in one file —
    # and enforcement is by frequency, so no uniqueness assertion here.)
    assert length(Scanner.forward_ratchet()) <= @forward_frozen
    assert length(Scanner.forward_fixed()) <= @forward_fixed_frozen
  end

  test "FORWARD enforcement is SITE-level — a NEW reach-in in an allowlisted FILE REDs" do
    # entity_caps.ex is already in the forward ledger (existing reach-ins).
    allowlisted = "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex"
    assert Enum.any?(Scanner.forward_ratchet(), &(&1.path == allowlisted))

    ledger = Scanner.forward_ratchet() ++ Scanner.forward_fixed()

    # A NEW, distinct reach-in scanned AS that already-allowlisted file. The
    # distinctive arg guarantees a fresh content SHA absent from the ledger.
    injected =
      Scanner.forward_sites_in_source(
        "defmodule X do\n  def go(u), do: Ezagent.SnapshotStore.latest(u, :gate_teeth_probe)\nend",
        allowlisted
      )

    assert injected != []

    # The ENFORCEMENT decision itself flags the injected site — the file already
    # being in the ledger does NOT cover a new-content reach-in.
    assert Scanner.new_offenders(ledger ++ injected, ledger) == injected
  end

  # ── REVERSE (§4.2 "Reverse direction") ─────────────────────────────────────

  test "the actor framework makes no un-ported upward reference into staying core (§4.2 reverse)" do
    offenders = Scanner.reverse_new_offenders()

    assert offenders == [],
           """
           REVERSE upward gate (§4.2): a mover-set file references a staying-core
           module that is neither in the mover set nor a §3.4 port. Re-shape it
           into a port. New offenders:

           #{format_sites(offenders)}
           """
  end

  test "the reverse ledger only shrinks — no stale entries (§4.2 ratchet)" do
    stale = Scanner.reverse_stale()
    assert stale == [], "stale reverse-ledger entries:\n#{format_sites(stale)}"

    assert length(Scanner.reverse_ratchet()) <= @reverse_frozen
    assert length(Scanner.reverse_fixed()) <= @reverse_fixed_frozen
  end

  test "REVERSE enforcement is SITE-level — a NEW upward ref to an allowlisted MODULE REDs" do
    # Ezagent.Capability is already allowlisted (existing mover-set refs).
    ledger = Scanner.reverse_ratchet() ++ Scanner.reverse_fixed()
    assert Enum.any?(ledger, &(&1.target == "Ezagent.Capability"))

    # A NEW %Ezagent.Capability{} pattern scanned AS a mover file. The distinctive
    # binding guarantees a fresh content SHA absent from the ledger.
    injected =
      Scanner.reverse_sites_in_source(
        "defmodule Ezagent.Kind.Server do\n  def m(%Ezagent.Capability{} = gate_teeth_probe), do: gate_teeth_probe\nend",
        "apps/ezagent_core/lib/ezagent/kind/server.ex",
        MapSet.new([Ezagent.Kind.Server])
      )

    assert injected != []

    # The ENFORCEMENT decision flags it — the module already being allowlisted
    # does NOT cover a new-content upward reference.
    assert Scanner.new_offenders(ledger ++ injected, ledger) == injected
  end

  # ── raw-scanner teeth + no-false-positives ─────────────────────────────────

  test "the forward scanner flags every banned shape" do
    root = "defmodule W do\n  def go(u), do: Ezagent.SnapshotStore.latest(u)\nend"

    aliased_root =
      "defmodule W do\n  alias Ezagent.KindRegistry\n  def go(u), do: KindRegistry.lookup(u)\nend"

    get_slice = "defmodule W do\n  def go(u), do: Ezagent.Kind.get_slice(u, :s)\nend"
    runtime_view = "defmodule W do\n  def go(p), do: Ezagent.Kind.runtime_view(p)\nend"

    genserver =
      "defmodule W do\n  def go(p), do: GenServer.call(p, {:ezagent_get_slice, :s})\nend"

    genserver_indirect =
      "defmodule W do\n  def go(p) do\n    msg = {:ezagent_get_slice, :s}\n    GenServer.call(p, msg)\n  end\nend"

    ready = "defmodule W do\n  def go(u), do: Ezagent.ReadyGate.await(u)\nend"
    runtime = "defmodule W do\n  def go(x), do: Ezagent.Kind.Runtime.Context.build(x)\nend"

    proc_gen =
      "defmodule W do\n  def go(u), do: Ezagent.Cap.Authority.current_process_generation(u)\nend"

    for src <- [
          root,
          aliased_root,
          get_slice,
          runtime_view,
          genserver,
          genserver_indirect,
          ready,
          runtime,
          proc_gen
        ] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "forward scanner must flag a reach-in:\n#{src}"
    end
  end

  test "the forward scanner has no false positives (read surface, register_external_gate, non-Kind :sys, stdlib)" do
    benign = """
    defmodule Fine do
      def wire, do: Ezagent.ReadyGate.register_external_gate(SomeGate)
      def read(u), do: Ezagent.Kind.read(u, :s)
      def alive(u), do: Ezagent.Kind.alive?(u)
      def dispatch(inv), do: Ezagent.Invocation.dispatch(inv)
      def sidecar(p), do: :sys.get_state(p)
      def other(p), do: GenServer.call(p, {:run_tool, :x})
      def std, do: Enum.map([1], & &1)
    end
    """

    assert Scanner.forward_sites_in_source(benign, "apps/x/lib/fine.ex") == []
  end

  test "the reverse scanner flags call / atom / struct shapes; no self-ref/stdlib false positives" do
    call_shape =
      "defmodule Ezagent.Kind.F do\n  def go, do: Ezagent.Cap.DeliveryOutbox.replay?(:x)\nend"

    atom_shape =
      "defmodule Ezagent.Kind.F do\n  @t [Ezagent.SagaRunner.Saga]\n  def t, do: @t\nend"

    struct_shape = "defmodule Ezagent.Kind.F do\n  def m(%Ezagent.Capability{} = c), do: c\nend"

    for src <- [call_shape, atom_shape, struct_shape] do
      assert Scanner.reverse_sites_in_source(src, "apps/x/lib/f.ex", MapSet.new()) != [],
             "reverse scanner must flag an upward reference:\n#{src}"
    end

    own = MapSet.new([Ezagent.Kind.Server, Ezagent.Kind.BehaviorSet, Ezagent.URI])

    benign = """
    defmodule Ezagent.Kind.Server do
      alias Ezagent.Kind.BehaviorSet
      def go(uri) do
        _ = BehaviorSet.resolve_action(__MODULE__, :x, %{})
        _ = Ezagent.URI.to_string(uri)
        Enum.map([1, 2], &(&1 + 1))
      end
    end
    """

    assert Scanner.reverse_sites_in_source(benign, "apps/x/lib/server.ex", own) == []
  end

  test "the reverse fixed carve-out is real (LegacyCallbacks quotes Ezagent.Capability.cap)" do
    assert Scanner.reverse_fixed() != []

    source =
      File.read!(
        Path.join(
          Scanner.repo_root(),
          "apps/ezagent_core/lib/ezagent/behavior/legacy_callbacks.ex"
        )
      )

    assert String.contains?(source, "Ezagent.Capability.cap")
  end

  # ── enumerator (re-seeding aid) ────────────────────────────────────────────

  test "the enumerator dumps the current census when ACTOR_BOUNDARY_ALLOWLIST=empty" do
    fwd = Scanner.forward_sites()
    rev = Scanner.reverse_sites()

    if System.get_env("ACTOR_BOUNDARY_ALLOWLIST") == "empty" do
      files = fwd |> Enum.map(& &1.path) |> Enum.uniq() |> length()
      IO.puts("\n=== §4.4 forward census (#{files} files, #{length(fwd)} sites) ===")

      for s <- Enum.sort_by(fwd, &{&1.path, &1.line}),
          do: IO.puts("  #{s.path}:#{s.line}  #{s.target}")

      IO.puts("=== §3.4 reverse worklist (#{length(rev)} sites) ===")

      for s <- Enum.sort_by(rev, &{&1.path, &1.line}),
          do: IO.puts("  #{s.path}:#{s.line}  #{s.target}")
    end

    assert fwd != [] and rev != [], "the scans must be non-empty, or the gate is vacuous"
  end

  defp format_sites([]), do: "(none)"

  defp format_sites(sites),
    do: Enum.map_join(sites, "\n", fn s -> "  #{s.target} — #{s.path}:#{s.line}" end)
end
