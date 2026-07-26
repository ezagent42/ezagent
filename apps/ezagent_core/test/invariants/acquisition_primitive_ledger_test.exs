defmodule EzagentCore.Invariants.AcquisitionPrimitiveLedgerTest do
  @moduledoc """
  V5 pid-closure, Track A (obtain side) — the acquisition-primitive census's
  HAS-TEETH self-test (**report-only** — nothing here gates on a violation).

  Two jobs:

    1. prove the scanner is not blinded: it MUST surface every known
       acquisition-primitive seed site below (a FLOOR, not the whole list),
       INCLUDING sites inside the actor app (which the FORWARD boundary gate
       excludes — codex round-2 #2). If the scanner misses any, the SCANNER
       is wrong — fix the scanner, not this test.
    2. regenerate the committed acquisition-primitive ledger
       `docs/notes/v5-acquisition-primitive-ledger.md` (full emit).
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActorBoundaryScanner, as: Scanner

  @ledger_path "docs/notes/v5-acquisition-primitive-ledger.md"

  # The seed floor ({path-fragment, target}) — every entry MUST be surfaced.
  @seeds [
    # actor-app coverage (codex round-2 #2): the FORWARD gate excludes the
    # actor app; this census must NOT
    {"apps/ezagent_actor/lib/ezagent/kind_registry.ex", "Registry.lookup/2"},
    {"apps/ezagent_actor/lib/ezagent/kind/termination.ex", "Process.monitor/1"},
    {"apps/ezagent_actor/lib/ezagent/kind.ex", "Process.info/2"},
    {"apps/ezagent_actor/lib/ezagent/kind/server.ex", "Process.whereis/1"},
    # domain/plugin apps
    # (V5 A1b REMOVED the ezagent_domain_pty server.ex seeds —
    # `DynamicSupervisor.which_children/1` + `:sys.get_state/2` — the PTY
    # sidecar migrated onto the resolver seam; its entries left the ledger.
    # The `:sys.get_state` seed is RETARGETED to the remaining Python
    # sidecar site so the census keeps teeth on the primitive (codex #1),
    # and a synthetic detector test below covers `which_children/1`.)
    {"apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex", ":sys.get_state/2"},
    {"apps/ezagent_domain_workspace/lib/ezagent/workspace.ex", "Task.Supervisor.start_child/2"},
    {"apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/gates.ex",
     "Task.Supervisor.async_nolink/2"},
    {"apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/registry_readiness.ex",
     ":global.whereis_name/1"},
    {"apps/ezagent_domain_session/lib/ezagent/behavior/session.ex", "Process.monitor/1"}
  ]

  # The ONLY exempt files: the D3 resolver seam + the explicit supervision
  # spine. They must NEVER contribute a site.
  @exempt [
    "apps/ezagent_actor/lib/ezagent/runtime/resolver.ex",
    "apps/ezagent_actor/lib/ezagent/runtime/sidecar_registry.ex",
    "apps/ezagent_actor/lib/ezagent/spawn_registry.ex",
    "apps/ezagent_actor/lib/ezagent/kind_supervisor.ex",
    "apps/ezagent_actor/lib/ezagent/kind/spawner.ex"
  ]

  test "has-teeth: surfaces every known acquisition-primitive seed site" do
    found = MapSet.new(Scanner.acquisition_sites(), &{&1.path, &1.target})

    for {path, target} <- @seeds do
      assert MapSet.member?(found, {path, target}),
             "scanner MISSED seed #{target} at #{path} — the scanner is blinded"
    end
  end

  test "exemptions: the resolver seam + supervision spine contribute no sites" do
    paths = MapSet.new(Scanner.acquisition_sites(), & &1.path)

    for exempt <- @exempt do
      refute MapSet.member?(paths, exempt),
             "exempt file #{exempt} contributed an acquisition site — exemption broken"
    end
  end

  test "synthetic: DynamicSupervisor.which_children/1 is still detected (pilot teeth)" do
    # The PTY pilot removed the last REAL which_children site; this synthetic
    # source proves the census still has teeth on the primitive (codex #1).
    source = """
    defmodule SynthWhichChildren do
      def child_pids(sup), do: DynamicSupervisor.which_children(sup)
    end
    """

    sites = Scanner.acquisition_sites_in_source(source, "synth/which_children.ex")

    assert %{target: "DynamicSupervisor.which_children/1"} =
             Enum.find(sites, &(&1.target == "DynamicSupervisor.which_children/1"))
  end

  test "synthetic: seam-internal pid accessors are flagged OUTSIDE the seam (codex #1)" do
    source = """
    defmodule SynthSeamExternal do
      alias Ezagent.Runtime.Resolver
      alias Ezagent.Runtime.SidecarRegistry

      def leak(key), do: Resolver.pid_for(key)
      def leak2(key), do: SidecarRegistry.lookup(key)
      def leak3(plugin), do: SidecarRegistry.entries_for_plugin(plugin)
    end
    """

    targets =
      MapSet.new(Scanner.acquisition_sites_in_source(source, "synth/leak.ex"), & &1.target)

    assert MapSet.member?(targets, "Ezagent.Runtime.Resolver.pid_for/1")
    assert MapSet.member?(targets, "Ezagent.Runtime.SidecarRegistry.lookup/1")
    assert MapSet.member?(targets, "Ezagent.Runtime.SidecarRegistry.entries_for_plugin/1")
  end

  test "regenerates the acquisition-primitive ledger markdown (full emit)" do
    sites = Scanner.acquisition_sites()
    assert sites != []

    path = Path.join(Scanner.repo_root(), @ledger_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Scanner.acquisition_markdown(sites))
  end
end
