defmodule Ezagent.Invariants.KindProvenanceTest do
  @moduledoc """
  Asserts every alive Kind in `Ezagent.KindRegistry` has its pid
  supervised by one of the declared Kind supervisors. Catches future
  "spawned outside `Ezagent.Kind.spawn/2`" drift at runtime, even if
  the grep gate is somehow bypassed (e.g. by `apply/3` or a string
  build).

  Per V1 prevention layer 2 (Allen 2026-05-21): runtime invariant
  that drift cannot hide. If a Kind appears in KindRegistry but no
  declared supervisor owns its pid, either the spawn went through an
  unknown path OR a new per-Kind supervisor needs to be added to
  `supervisors/0` below.

  The list is the union of every `supervisor/0` declared on a Kind
  module today, plus the default `Ezagent.KindSupervisor`. Tests
  reference Kinds across all umbrella apps so this runs in the
  ezagent_core test env where the full supervision tree boots.
  """
  use ExUnit.Case

  test "every alive Kind URI has a pid supervised by a declared Kind supervisor" do
    alive = Ezagent.KindRegistry.list_all()

    supervised_pids =
      supervisors()
      |> Enum.flat_map(&direct_children/1)
      |> Enum.flat_map(&expand_via_tier/1)
      |> MapSet.new()

    unsupervised =
      Enum.reject(alive, fn {_uri, pid} -> MapSet.member?(supervised_pids, pid) end)

    assert unsupervised == [],
           """
           Alive Kinds NOT under any declared Kind supervisor:

           #{Enum.map_join(unsupervised, "\n", fn {uri, pid} -> "  #{uri} (pid #{inspect(pid)})" end)}

           Kinds spawned outside Ezagent.Kind.spawn/2 are caught here.
           Either route the spawn through the API, or — if a new Kind
           declared its own DynamicSupervisor — add the supervisor module
           to supervisors/0 in this test.
           """
  end

  # First-tier children of a top-level DynamicSupervisor. Empty list
  # when the supervisor isn't started in this test env.
  defp direct_children(sup) do
    case Process.whereis(sup) do
      nil -> []
      _pid -> DynamicSupervisor.which_children(sup)
    end
  end

  # For most Kind supervisors the direct child IS the Kind.Server pid.
  # For ExternalMirror's two-tier topology (SPEC §6.3, PR-EM-2), the
  # direct child of `RootSupervisor` is a `PerBindingSupervisor`
  # (NOT a Kind.Server) and the Kind.Server lives one tier deeper —
  # so we recurse one level for `:supervisor`-typed children.
  defp expand_via_tier({_id, child_pid, :supervisor, _modules}) when is_pid(child_pid) do
    # The inner Supervisor's children are the actual Kind.Server pids.
    inner =
      child_pid
      |> Supervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
      |> Enum.filter(&is_pid/1)

    [child_pid | inner]
  rescue
    _ -> [child_pid]
  end

  defp expand_via_tier({_id, pid, _type, _modules}) when is_pid(pid), do: [pid]
  defp expand_via_tier(_), do: []

  # Union of every `supervisor/0` declared on a Kind module + the
  # default. Adding a new per-Kind supervisor: append it here.
  defp supervisors do
    [
      Ezagent.KindSupervisor,
      Ezagent.Core.SingletonSupervisor,
      Ezagent.Workspace.Supervisor,
      EzagentDomainIdentity.Application.UserSupervisor,
      EzagentDomainChat.SessionSupervisor,
      EzagentDomainChat.AgentSupervisor,
      EzagentDomainChat.AgentTemplateSupervisor,
      EzagentDomainChat.SessionTemplateSupervisor,
      EzagentPluginCurlAgent.InstanceSupervisor,
      # PR-EM-2: ExternalMirrorWorker Kinds spawn under a two-tier
      # topology (SPEC §6.3) — RootSupervisor's direct children are
      # PerBindingSupervisors (`:supervisor`-typed); the actual
      # Kind.Server pids are the inner tier. `expand_via_tier/1`
      # recurses one level for `:supervisor` children.
      Ezagent.ExternalMirror.RootSupervisor,
      # P6 cold-restart determinism: cold-restart GATE test Kinds
      # declare `supervisor/0 -> Ezagent.LifecycleCase.gate_supervisor()`
      # to isolate their kill→restart cycle from the shared
      # `KindSupervisor`'s restart-intensity exhaustion. Started lazily
      # by `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`, so it is
      # `nil` (skipped by `direct_children/1`) when no GATE test ran in
      # this BEAM, and a live `DynamicSupervisor` otherwise.
      Ezagent.LifecycleCase.gate_supervisor()
    ]
  end
end
