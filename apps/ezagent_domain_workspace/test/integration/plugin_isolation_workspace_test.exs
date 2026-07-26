defmodule Ezagent.Integration.PluginIsolationWorkspaceTest do
  @moduledoc """
  # Phase 4 north-star invariant test (decomposed — #108)

  Per memory `feedback_completion_requires_invariant_test`:
  Phase 4 cannot be declared done on merge + tests-pass alone — there
  must be a test that fails when the architectural goal is unmet.

  **The goal**: future plugin authors add new Kinds without
  coordinating with core (and core never references plugin code) — a
  new Kind survives a node restart purely via runtime DI:
  `Ezagent.SpawnRegistry` (scheme→spawn fn) + `Loader.load_all/0`
  re-spawning from persisted Workspace state.

  **The proof**: fake types (`ProbeBehavior`, `ProbeKind`,
  `ProbeTemplate`) defined here in test/ (NOT in ezagent_core/lib/, NOT
  in any plugin/lib/), registered at runtime, come to life without
  ezagent_core or any plugin knowing about `:probe` ahead of time. The
  inline-in-test definitions ARE the "core doesn't reference plugin
  code" proof — keep them out of `lib/`.

  ## Why this is split into (i) + (ii) — the #108 de-flake

  The original invariant was one combined test:
  `Workspace.create` (persist) → `Loader.load_all` (spawn) →
  `DynamicSupervisor.terminate_child` (kill = "node down") →
  `Loader.load_all` (reload). That combined chain is FLAKY under the
  Postgres `Ecto.Adapters.SQL.Sandbox` shared-mode model: after the
  teardown, the *reload's* `load_all` re-spawns the Workspace Kind in a
  DynamicSupervisor child (a process OUTSIDE the test owner). If shared
  mode transiently reverts, that child's DB work hits
  `DBConnection.OwnershipError`, the reload finds nothing, and the test
  flunks — a PG-sandbox artifact of doing teardown WITH a DB-backed
  reload in ONE test.

  So the composed invariant is proven by the CONJUNCTION of two
  non-racing halves (a future reader needs BOTH — neither alone is the
  full north star, and no single test now runs the end-to-end
  persist→kill→reload chain):

  - **(i) runtime-DI re-spawn survives teardown** — registered spawn
    fn → `SpawnRegistry.spawn` → kill via `DynamicSupervisor` → spawn
    again → alive with a NEW pid. This half proves the DI + registry
    survival machinery across a "node down" WITHOUT touching the DB at
    all (`probe://` has no workspace segment, so the owner gate is a
    no-op, and `ProbeKind` is `:ephemeral` so `Kind.Server` writes no
    snapshot). No sandbox → the teardown-during-reload race cannot
    occur.

  - **(ii) persisted state → Loader spawn (NO teardown)** —
    `Workspace.create(members: [probe])` (and, for the EXT variant,
    `session_templates:`) then a single `Loader.load_all` asserts the
    probe spawned from persisted Workspace state. NO `terminate_child`
    → `load_all` finds the Workspace Kind already-started and only
    dispatches `:instantiate` + spawns the ephemeral probe; the sole DB
    read (`Store.list_all`) runs IN the test process. A single
    create+read the sandbox handles fine.

  If EITHER half breaks, plugin isolation is broken — investigate
  before shipping.

  ## What's verified

  1. A new URI scheme (`probe`) can be registered at runtime via
     `Ezagent.SpawnRegistry.register/2` — (i) + (ii)
  2. The runtime-registered spawn fn survives a `DynamicSupervisor`
     teardown (node-down) and re-spawns with a fresh pid — (i)
  3. A Workspace declaring `probe://X` as a member — or a
     `ProbeTemplate` Class instance — can be persisted via
     `Ezagent.Workspace.create/2` — (ii)
  4. `Ezagent.Workspace.Loader.load_all/0` spawns the fake Kind from
     persisted state, using the runtime-registered spawn fn /
     TemplateRegistry — (ii)

  ezagent_core never references `ProbeKind`, `ProbeBehavior`,
  `ProbeTemplate`, or `:probe`. The test enforces this by defining them
  in this module (not in `lib/`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, SpawnRegistry, TemplateRegistry, Workspace}

  setup do
    if Code.ensure_loaded?(Ezagent.AgentFlavorRegistry) and
         function_exported?(Ezagent.AgentFlavorRegistry, :seal!, 0) do
      Ezagent.AgentFlavorRegistry.seal!()
    end

    :ok
  end

  # ---------------------------------------------------------------
  # Fake plugin types — defined inline in the test, NOT in lib/
  # ---------------------------------------------------------------

  defmodule ProbeBehavior do
    @behaviour Ezagent.ActionSet

    @impl true
    def actions, do: [:ping]

    @impl true
    def cap_subjects, do: [{:ping, "test fixture"}]

    # #108 — required-callback parity with the live `Ezagent.ActionSet` contract
    # (`required_caps/0` is NOT in `@optional_callbacks`). The keys-equal-actions
    # invariant (`keys(required_caps) ∪ cap_exempt_actions == actions`) requires
    # the single `:ping` action to carry a cap declaration. Previously omitted —
    # a compile-warning-only contract drift; declared now so the fixture matches
    # the production contract and the warning stops masking signal.
    @impl true
    def required_caps do
      %{ping: Ezagent.Capability.cap(:probe, __MODULE__, :ping)}
    end

    @impl true
    def state_slice, do: :probe

    @impl true
    def init_slice(_args), do: %{pings: 0}

    @impl true
    def invoke(:ping, slice, _args, _ctx) do
      {:ok, %{slice | pings: slice.pings + 1}, %{pong: true}}
    end

    @impl true
    def interface,
      do: %{ping: %{args: %{}, returns: %{pong: :boolean}, modes: [:call]}}
  end

  defmodule ProbeKind do
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :probe

    @impl true
    def behaviors, do: [ProbeBehavior]

    @impl true
    def persistence, do: :ephemeral

    @impl true
    def uri_from_args(args), do: Map.fetch!(args, :uri)
  end

  # Phase 4-completion: fake Template Class for invariant test of
  # Decision #64's Class half. Inline here so ezagent_core never
  # references it — proves a plugin author's Template Class survives
  # restart purely via TemplateRegistry runtime DI.
  defmodule ProbeTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "probe.template"

    @impl true
    def validate(%{"class" => "probe.template", "probe_name" => name}) when is_binary(name),
      do: :ok

    def validate(_), do: {:error, :bad_probe_template}

    @impl true
    def instantiate(_tmpl_name, %{"probe_name" => name}, _workspace_uri) do
      uri = URI.new!("probe://#{name}")

      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, _pid} -> {:ok, [uri]}
        err -> err
      end
    end
  end

  # ---------------------------------------------------------------
  # The invariant
  # ---------------------------------------------------------------

  # ---------------------------------------------------------------
  # (i) Runtime-DI re-spawn survives teardown — ZERO DB.
  #
  # Proves the SpawnRegistry (scheme→spawn fn) + KindRegistry survival
  # machinery across a "node down" WITHOUT any Workspace persistence.
  # `probe://` has no workspace segment (owner gate is a no-op) and
  # `ProbeKind` is `:ephemeral` (Kind.Server writes no snapshot), so the
  # whole test body touches no DB — it cannot hit the #108
  # teardown-during-reload sandbox race by construction.
  # ---------------------------------------------------------------

  test "PHASE 4 INVARIANT (i): runtime-registered Kind survives teardown + re-spawn purely via SpawnRegistry DI (no DB)" do
    # 1. Plugin-author work: declare a new URI scheme + register spawn fn.
    #    This is what a future plugin's Application.start would do.
    probe_uri = URI.new!("probe://invariant-#{System.unique_integer([:positive])}")

    SpawnRegistry.register("probe", fn uri ->
      DynamicSupervisor.start_child(
        Ezagent.Workspace.Supervisor,
        {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
      )
    end)

    # 2. Spawn purely via the runtime-registered fn — no Workspace, no DB.
    assert {:ok, probe_pid} = SpawnRegistry.spawn(probe_uri)
    assert is_pid(probe_pid)
    assert Process.alive?(probe_pid)
    assert {:ok, ^probe_pid} = KindRegistry.lookup(probe_uri)

    # 3. Tear down: terminate via DynamicSupervisor so it doesn't auto-restart.
    #    (Process.exit would cause :one_for_one to immediately re-spawn,
    #    which is the wrong simulation — we want "node went down".)
    :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, probe_pid)

    # Wait for Registry cleanup (Registry monitors its keys). Load-bearing
    # for the `refute` below: while the old key is still registered,
    # `SpawnRegistry.spawn/1` would adopt the (now-dead) pid as
    # `:already_started` instead of starting a fresh worker.
    wait_until(fn -> KindRegistry.lookup(probe_uri) == :error end)

    # 4. The proof: re-spawn purely from the runtime-registered spawn fn —
    #    the Kind comes back alive with a NEW pid, and ezagent_core / no
    #    plugin ever referenced `:probe`.
    assert {:ok, new_probe_pid} = SpawnRegistry.spawn(probe_uri)
    assert is_pid(new_probe_pid)
    assert Process.alive?(new_probe_pid)
    assert {:ok, ^new_probe_pid} = KindRegistry.lookup(probe_uri)
    refute new_probe_pid == probe_pid
  end

  # ---------------------------------------------------------------
  # (ii) Persisted Workspace state → Loader spawn — NO teardown.
  #
  # Proves a plugin-defined Kind declared in a PERSISTED Workspace comes
  # to life via `Loader.load_all/0` reading persisted state. No
  # `terminate_child` → `load_all`'s `spawn_workspace` finds the
  # Workspace Kind already-started and only dispatches `:instantiate` +
  # spawns the ephemeral probe; the sole DB read (`Store.list_all`) runs
  # in the test process. A single create+read — no teardown-during-reload
  # race.
  # ---------------------------------------------------------------

  test "PHASE 4 INVARIANT (ii): plugin-defined Kind declared in a persisted Workspace spawns via Loader.load_all (no teardown)" do
    # 1. Plugin-author work: declare a new URI scheme + register spawn fn.
    probe_uri = URI.new!("probe://persist-#{System.unique_integer([:positive])}")

    SpawnRegistry.register("probe", allow_on_spawn_probe_fn())

    # 2. Plugin-author work: persist a Workspace declaring the probe as a member.
    workspace_name = "persist-#{System.unique_integer([:positive])}"
    {:ok, ws_uri} = Workspace.create(workspace_name, %{members: [probe_uri]})

    # Sanity: probe is not yet alive (create/2 only persists + spawns the
    # Workspace Kind itself; member spawning happens via Loader).
    assert :error = KindRegistry.lookup(probe_uri)

    # 3. Run the Loader — this is what happens at app start. It walks every
    #    persisted Workspace, dispatches :instantiate, and calls
    #    SpawnRegistry for each declared child.
    #
    # `load_all/0` can transiently return `[]` (its
    # `agent_flavor_registry_unsealed?` seal-gate — see
    # `Ezagent.Workspace.Loader.load_all/0`). The Loader is idempotent
    # (`load_one` adopts the already-started Workspace + re-dispatches
    # `:instantiate`; `SpawnRegistry.spawn/1` is idempotent), so we poll
    # it until our just-created workspace is present with children rather
    # than hard-matching the first call's result. The PROOF (the probe
    # spawns from persisted state) stays a hard assertion.
    {^workspace_name, children_results} = load_all_until_present(workspace_name)

    assert [{^probe_uri, {:ok, probe_pid}}] = children_results
    assert is_pid(probe_pid)
    assert Process.alive?(probe_pid)

    # #108: tear down this test's own lingering Kinds before the owner stops.
    terminate_kinds_on_exit([ws_uri, probe_pid])

    # 4. The probe is now in KindRegistry under its URI — Loader truly
    #    spawned it from persisted Workspace state, no ezagent_core /
    #    plugin code knowing about `:probe`.
    assert {:ok, ^probe_pid} = KindRegistry.lookup(probe_uri)
  end

  test "PHASE 4 INVARIANT (ii) EXT: plugin-defined Template Class spawns its Kind via Loader.load_all (no teardown)" do
    # Phase 4-completion (Spec 01): Decision #64 Class half. A fake
    # Template Class defined ONLY in test/ (NOT lib/) must spawn its
    # declared Kind purely via runtime TemplateRegistry + SpawnRegistry,
    # driven from persisted Workspace state by Loader.load_all/0.

    # 1. Plugin-author work: register both the probe Kind's spawn fn
    #    AND the probe Template Class.
    SpawnRegistry.register("probe", allow_on_spawn_probe_fn())

    :ok = TemplateRegistry.register(ProbeTemplate)

    # 2. Plugin-author work: persist a Workspace whose session_templates
    #    declares a ProbeTemplate instance. No members — template alone
    #    must produce the probe Kind via Loader.
    workspace_name = "tmpl-persist-#{System.unique_integer([:positive])}"
    probe_name = "tmpl-probe-#{System.unique_integer([:positive])}"
    probe_uri = URI.new!("probe://#{probe_name}")

    tmpl_data = %{
      "class" => "probe.template",
      "probe_name" => probe_name
    }

    {:ok, ws_uri} =
      Workspace.create(workspace_name, %{
        session_templates: %{"main" => tmpl_data}
      })

    # Sanity: probe not yet alive (create only persists + spawns Workspace Kind)
    assert :error = KindRegistry.lookup(probe_uri)

    # 3. Loader runs — instantiate the template. Poll past the transient
    #    empty-return path (seal-gate), same as (ii) — `load_all/0` is
    #    idempotent.
    {^workspace_name, children_results} = load_all_until_present(workspace_name)

    # Children: 1 template entry, no member entries
    assert [{"main", {:ok, [^probe_uri]}}] = children_results

    {:ok, probe_pid} = KindRegistry.lookup(probe_uri)
    assert is_pid(probe_pid)
    assert Process.alive?(probe_pid)

    # #108: tear down this test's own lingering Kinds before the owner stops.
    terminate_kinds_on_exit([ws_uri, probe_pid])
  end

  test "Workspace.add_template/3 fail-fast: rejects template without registered Class" do
    workspace_name = "addtmpl-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(workspace_name)

    tmpl = %{
      "class" => "never-registered-#{System.unique_integer([:positive])}",
      "session_name" => "x"
    }

    assert {:error, {:no_template_class, _}} =
             Workspace.add_template(workspace_name, "main", tmpl)

    # Verify SQLite row absent — template was not persisted
    assert %{session_templates: %{}} = Ezagent.Workspace.Store.get_by_name(workspace_name)
  end

  test "Workspace.add_template/3 fail-fast: rejects template missing class field" do
    workspace_name = "noclass-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(workspace_name)

    assert {:error, :missing_class_field} =
             Workspace.add_template(workspace_name, "main", %{"session_name" => "x"})
  end

  # Re-run the idempotent `Loader.load_all/0` until the named workspace
  # appears in its results WITH non-empty children, returning the
  # `{name, child_results}` tuple. Tolerates the Loader's transient
  # empty-result paths under concurrent load WITHOUT weakening any
  # downstream assertion:
  #   - whole-result `[]` (seal-gate not yet observed / sandbox
  #     OwnershipError rescue in `load_all/0`), AND
  #   - a transient `{name, []}` (workspace present but children not yet
  #     instantiated — e.g. `instantiate_via_dispatch/1` momentarily
  #     returns nothing) so the poll never returns a tuple that would
  #     then fail the hard non-empty children assert at the call site.
  # Flunks loudly if the workspace never appears with children within the
  # budget — a real (non-transient) load failure still fails the test.
  defp load_all_until_present(workspace_name, attempts \\ 250)

  defp load_all_until_present(workspace_name, 0) do
    flunk(
      "load_all_until_present: workspace #{inspect(workspace_name)} never appeared in Loader results with children"
    )
  end

  defp load_all_until_present(workspace_name, attempts) when attempts > 0 do
    # #108 (ii)/(ii)EXT de-flake — `Loader.load_all` SPAWNS the Workspace Kind's
    # children (the probe) mid-test under `Ezagent.Workspace.Supervisor`. Those
    # processes (and the freshly-created Workspace Kind, alive only AFTER this
    # test's `setup` ran) sit OUTSIDE the test owner's `$callers` chain, so
    # `EzagentCore.DataCase.allow_live_kinds/1` (which only allows Kinds alive AT
    # setup) never covered them. Under a transiently reverted shared-mode window
    # (heavy concurrent umbrella load), their DB access raises
    # `DBConnection.OwnershipError`, the child never registers, and this poll
    # never sees it → flaky flunk. Re-run the DataCase allow pattern over every
    # CURRENT `KindRegistry` pid BEFORE each idempotent `load_all` so any Kind
    # that came alive post-setup can reach this test's connection. Same
    # invariant, TEST-infra only (probe stays defined in test/, core untouched).
    allow_spawned_kinds()

    case Enum.find(Ezagent.Workspace.Loader.load_all(), fn {name, _} -> name == workspace_name end) do
      {^workspace_name, children} = found when children != [] ->
        found

      _ ->
        Process.sleep(20)
        load_all_until_present(workspace_name, attempts - 1)
    end
  end

  # The probe spawn fn a plugin's `Application.start` would register, PLUS the
  # #108 de-flake: `Sandbox.allow/3` the freshly-spawned probe pid onto this
  # test's owner connection the instant it starts. The probe is started under
  # `Ezagent.Workspace.Supervisor` (a global supervisor, never allowed at
  # setup), so without this its own DB access (any post-init/activate read)
  # could hit `DBConnection.OwnershipError` in a reverted shared-mode window.
  # The spawn fn runs in the (owner-allowed) test process, so `self()` is a
  # legitimate allow parent.
  # #108 de-flake (teardown owner-exit race): tests (ii)/(ii)EXT deliberately
  # skip `terminate_child` to prove the no-teardown reload path, so the probe
  # (and Workspace) Kinds outlive the test under the GLOBAL
  # `Ezagent.Workspace.Supervisor`, keep receiving PubSub, and a late
  # `handle_info` can do DB work through the sandbox owner that is about to
  # stop — surfacing `DBConnection.ConnectionError "owner … exited"` and
  # flaking a *passing* test. `DataCase.drain_live_kinds/0` is bounded +
  # best-effort, so it can miss the tail. Terminating THIS test's own Kinds
  # on_exit closes the window: on_exit runs LIFO, so this registers AFTER (→
  # runs BEFORE) DataCase's owner-stop. Safe here — the probes are unique-URI
  # + `:ephemeral`, so `terminate_child` won't wake the `:not_ready` restart
  # class the fixed-URI session suites protect against. `{:error, :not_found}`
  # (already gone / not this supervisor's child) is ignored.
  defp terminate_kinds_on_exit(refs) do
    on_exit(fn ->
      for ref <- refs do
        case ref do
          %URI{} = uri ->
            _ = Ezagent.Kind.terminate(uri)

          pid when is_pid(pid) ->
            if Process.alive?(pid),
              do: DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, pid)
        end
      end
    end)
  end

  defp allow_on_spawn_probe_fn do
    test_pid = self()

    fn uri ->
      case DynamicSupervisor.start_child(
             Ezagent.Workspace.Supervisor,
             {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
           ) do
        {:ok, pid} = ok ->
          allow_kind_pid(test_pid, pid)
          ok

        {:error, {:already_started, pid}} = adopted ->
          allow_kind_pid(test_pid, pid)
          adopted

        other ->
          other
      end
    end
  end

  # Re-run the `EzagentCore.DataCase.allow_live_kinds/1` pattern over every
  # currently-live Kind — for the ones that came alive AFTER `setup` (the
  # Workspace Kind + Loader-spawned children). Best-effort + idempotent,
  # mirroring DataCase: `Sandbox.allow/3` tolerates an already-owned/dead pid.
  defp allow_spawned_kinds do
    Enum.each(current_kind_pids(), fn pid -> allow_kind_pid(self(), pid) end)
  end

  defp current_kind_pids do
    Ezagent.KindRegistry.list_all()
    |> Enum.map(fn {_uri, pid} -> pid end)
  rescue
    _ -> []
  end

  defp allow_kind_pid(owner, pid) do
    Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, owner, pid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
