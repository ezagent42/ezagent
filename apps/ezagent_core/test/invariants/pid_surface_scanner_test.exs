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
    # (V5 A1c chunk2 REMOVED the {Ezagent.Cap, :revoke_all_to, 2} and
    # {Ezagent.Cap, :issue_for_action, 3} seeds — both went URI-native:
    # self-detection via Kind.self?/1, subject resolution via the URI-form
    # Kind.resolve_action_subject/2, delivery via Runtime.Resolver.call/3;
    # ensure_started's pid is discarded, never used. The scanner no longer
    # surfaces them — that is the closure, not blindness.)
    # (V5 A1c chunk1 REMOVED the {Ezagent.Kind, :list_instances, 0},
    # {EzagentDomainUi.AutoDerive, :list_instances, 1} and
    # {Ezagent.Identity.OperatorReads, :registry_all, 1} seeds — all three went
    # URI-native: list_instances/0 returns %{alive?: bool} status maps,
    # AutoDerive enumerates that public plane instead of a raw
    # Registry.select, and registry_all/1 passes the status map through. The
    # scanner no longer surfaces them — that is the closure, not blindness.)
    # pid-returning wrapper, re-obtains pid from KindRegistry
    {Ezagent.DomainGit.TaskAccessSupervisor, :ensure_started, 1},
    # body-bound pid (KindRegistry.lookup -> GenServer.call); the public
    # @spec is URI-only since V5 A1c chunk1
    {Ezagent.Kind, :runtime_view, 1},
    # A1a floor (codex round-2 #1): public Kind-pid contracts the A0 scope
    # (actor app + 5 seed files) MISSED — the whole-umbrella sweep must
    # surface them
    {Ezagent.Domain.Agent, :materialize_declared, 1},
    {Ezagent.Workspace, :create, 2}
    # (V5 A1c chunk3 REMOVED the {Ezagent.Entity.Session, :ensure_template_alive, 1}
    # seed — the wrapper now returns `:ok`; the Kind pid stays behind the
    # actor-app seam. The scanner no longer surfaces it — that is the closure,
    # not blindness.)
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
