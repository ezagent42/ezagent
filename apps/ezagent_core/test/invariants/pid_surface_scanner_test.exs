defmodule EzagentCore.Invariants.PidSurfaceScannerTest do
  @moduledoc """
  V5 pid-closure, Track A (obtain side) — the pid-surface enumerator's
  HAS-TEETH self-test (**report-only** — nothing here gates on a violation).

  Two jobs:

    1. prove the scanner is not blinded: it MUST surface every known
       pid-yielding seed site below (a FLOOR, not the whole list). If the
       scanner misses any, the SCANNER is wrong — fix the scanner, not this
       test.
    2. regenerate the committed Track-A worklist
       `docs/notes/v5-obtain-side-pid-surface.md` (empty allowlist = full emit).
  """
  use ExUnit.Case, async: true

  alias Ezagent.PidSurfaceScanner, as: Scanner

  @worklist_path "docs/notes/v5-obtain-side-pid-surface.md"

  # The seed floor (module, fun, arity) — every entry MUST be surfaced.
  @seeds [
    # return pids; only register/2 is meant to stay public
    {Ezagent.SpawnRegistry, :spawn, 2},
    {Ezagent.SpawnRegistry, :spawn_detailed, 2},
    # pid self-detection + a raw serialized call — NOT via issue_for_action
    {Ezagent.Cap, :revoke_all_to, 2},
    # pid self-detect + subject resolution
    {Ezagent.Cap, :issue_for_action, 3},
    # pids drive supervised termination in Terminable + Sandbox
    {Ezagent.Kind, :list_instances, 0},
    # pids exposed in summaries/details
    {EzagentDomainUi.AutoDerive, :list_instances, 1},
    # pid-returning wrapper, re-obtains pid from KindRegistry
    {Ezagent.DomainGit.TaskAccessSupervisor, :ensure_started, 1},
    # pid form (consumed by composition_caps.ex, auto_derive.ex)
    {Ezagent.Kind, :runtime_view, 1},
    # intentional operator metadata — flagged, noted as candidate exception
    {Ezagent.Identity.OperatorReads, :registry_all, 1}
  ]

  test "has-teeth: surfaces every known pid-yielding seed site" do
    found = MapSet.new(Scanner.scan(), &{&1.module, &1.fun, &1.arity})

    for {module, fun, arity} <- @seeds do
      assert MapSet.member?(found, {module, fun, arity}),
             "scanner MISSED seed #{inspect(module)}.#{fun}/#{arity} — the scanner is blinded"
    end
  end

  test "regenerates the Track-A worklist markdown (empty allowlist = full emit)" do
    sites = Scanner.scan()
    assert sites != []

    path = Path.join(Scanner.repo_root(), @worklist_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Scanner.markdown(sites))
  end
end
