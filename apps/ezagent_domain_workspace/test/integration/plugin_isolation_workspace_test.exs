defmodule Ezagent.Integration.PluginIsolationWorkspaceTest do
  @moduledoc """
  # Phase 4 north-star invariant test

  Per memory `feedback_completion_requires_invariant_test`:
  Phase 4 cannot be declared done on merge + tests-pass alone — there
  must be a test that fails when the architectural goal is unmet.

  **The goal**: future plugin authors add new Kinds without
  coordinating with core (and core never references plugin code).

  **The proof**: a fake Kind defined here in test/ (NOT in ezagent_core/lib/,
  NOT in any plugin/lib/) — registered at runtime via
  `Ezagent.SpawnRegistry` — is declared as a member of a persisted
  Workspace, the Workspace is torn down + reloaded, and the fake Kind
  comes back alive WITHOUT ezagent_core or any plugin needing to know
  about it ahead of time.

  If this test breaks, plugin isolation is broken — investigate before
  shipping.

  ## What's verified

  1. A new URI scheme (`probe`) can be registered at runtime via
     `Ezagent.SpawnRegistry.register/2`
  2. A Workspace declaring `probe://X` as a member can be persisted
     via `Ezagent.Workspace.create/2`
  3. Killing the Workspace + its declared members simulates a node
     restart's "everything gone" state
  4. `Ezagent.Workspace.Loader.load_all/0` re-spawns the fake Kind
     from persisted state, using the runtime-registered spawn fn

  ezagent_core never references `ProbeKind`, `ProbeBehavior`, or
  `:probe`. The test enforces this by defining them in this module
  (not in `lib/`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, SpawnRegistry, TemplateRegistry, Workspace}

  # ---------------------------------------------------------------
  # Fake plugin types — defined inline in the test, NOT in lib/
  # ---------------------------------------------------------------

  defmodule ProbeBehavior do
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:ping]

    @impl true
    def cap_subjects, do: [{:ping, "test fixture"}]

    # #108 — required-callback parity with the live `Ezagent.Behavior` contract
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

  test "PHASE 4 INVARIANT: plugin-defined Kind survives Workspace teardown + Loader rehydrate" do
    # 1. Plugin-author work: declare a new URI scheme + register spawn fn.
    #    This is what a future plugin's Application.start would do.
    probe_uri = URI.new!("probe://invariant-#{System.unique_integer([:positive])}")

    SpawnRegistry.register("probe", fn uri ->
      DynamicSupervisor.start_child(
        Ezagent.Workspace.Supervisor,
        {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
      )
    end)

    # 2. Plugin-author work: persist a Workspace declaring the probe as a member.
    workspace_name = "invariant-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Workspace.create(workspace_name, %{members: [probe_uri]})

    # Sanity: probe is not yet alive (create/2 only persists + spawns the
    # Workspace Kind itself; member spawning happens via Loader).
    assert :error = KindRegistry.lookup(probe_uri)

    # 3. Run the Loader — this is what happens at app start. It should
    #    walk every persisted Workspace, dispatch :instantiate, and call
    #    SpawnRegistry for each declared child.
    #
    # Under the full concurrent umbrella run, `load_all/0` can transiently
    # return `[]` (its `agent_flavor_registry_unsealed?` seal-gate or its
    # `DBConnection.{Ownership,Connection}Error -> []` rescue — see
    # `Ezagent.Workspace.Loader.load_all/0` + EzagentCore.DataCase
    # moduledoc). The Loader is idempotent (`load_one` adopts an
    # already-started Workspace + re-dispatches `:instantiate`;
    # `SpawnRegistry.spawn/1` is idempotent), so we poll it until our
    # just-created workspace is present rather than hard-matching the first
    # call's result. The isolation PROOF below (probe survives teardown +
    # rehydrate) is unchanged and stays a hard assertion.
    {^workspace_name, children_results} = load_all_until_present(workspace_name)

    assert [{^probe_uri, {:ok, probe_pid}}] = children_results
    assert is_pid(probe_pid)
    assert Process.alive?(probe_pid)

    # 4. The probe is now in KindRegistry under its URI — Loader truly
    #    re-spawned it from persisted Workspace state.
    assert {:ok, ^probe_pid} = KindRegistry.lookup(probe_uri)

    # 5. Tear down: terminate via DynamicSupervisor so it doesn't auto-restart.
    #    (Process.exit would cause :one_for_one to immediately re-spawn,
    #    which is the wrong simulation — we want "node went down".)
    workspace_uri = Ezagent.Entity.Workspace.uri_for(workspace_name)
    {:ok, workspace_pid} = KindRegistry.lookup(workspace_uri)

    :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, probe_pid)
    :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, workspace_pid)

    # Wait briefly for Registry cleanup (Registry monitors its keys)
    wait_until(fn -> KindRegistry.lookup(probe_uri) == :error end)
    wait_until(fn -> KindRegistry.lookup(workspace_uri) == :error end)

    # 6. The proof: Loader.load_all/0 re-runs and the probe is alive again
    #    — purely from persisted state + runtime-registered spawn fn,
    #    no ezagent_core / plugin code knows about :probe.
    #    `reload_until_alive/1` re-runs the idempotent Loader until the
    #    probe is back in KindRegistry, tolerating a transient empty
    #    Loader pass without weakening the survival proof: the probe MUST
    #    come back alive within the budget (flunks otherwise).
    new_probe_pid = reload_until_alive(probe_uri)
    assert is_pid(new_probe_pid)
    assert Process.alive?(new_probe_pid)
    refute new_probe_pid == probe_pid
  end

  test "PHASE 4 INVARIANT EXT: plugin-defined Template Class survives Workspace teardown + Loader rehydrate" do
    # Phase 4-completion (Spec 01): Decision #64 Class half landed.
    # This test extends the original invariant: a fake Template Class
    # defined ONLY in test/ (NOT lib/) must spawn its declared Kind
    # purely via runtime TemplateRegistry + SpawnRegistry registration,
    # then survive teardown + Loader.load_all/0.

    # 1. Plugin-author work: register both the probe Kind's spawn fn
    #    AND the probe Template Class.
    SpawnRegistry.register("probe", fn uri ->
      DynamicSupervisor.start_child(
        Ezagent.Workspace.Supervisor,
        {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
      )
    end)

    :ok = TemplateRegistry.register(ProbeTemplate)

    # 2. Plugin-author work: persist a Workspace whose session_templates
    #    declares a ProbeTemplate instance. No members — template alone
    #    must produce the probe Kind via Loader.
    workspace_name = "tmpl-invariant-#{System.unique_integer([:positive])}"
    probe_name = "tmpl-probe-#{System.unique_integer([:positive])}"
    probe_uri = URI.new!("probe://#{probe_name}")

    tmpl_data = %{
      "class" => "probe.template",
      "probe_name" => probe_name
    }

    {:ok, _ws_pid} =
      Workspace.create(workspace_name, %{
        session_templates: %{"main" => tmpl_data}
      })

    # Sanity: probe not yet alive (create only persists + spawns Workspace Kind)
    assert :error = KindRegistry.lookup(probe_uri)

    # 3. Loader runs — instantiate the template. Poll past the transient
    #    empty-return paths (seal-gate / sandbox OwnershipError rescue),
    #    same as the first invariant test — `load_all/0` is idempotent.
    {^workspace_name, children_results} = load_all_until_present(workspace_name)

    # Children: 1 template entry, no member entries
    assert [{"main", {:ok, [^probe_uri]}}] = children_results

    {:ok, probe_pid} = KindRegistry.lookup(probe_uri)
    assert is_pid(probe_pid)
    assert Process.alive?(probe_pid)

    # 4. Tear down via supervisor (no auto-restart)
    workspace_uri = Ezagent.Entity.Workspace.uri_for(workspace_name)
    {:ok, workspace_pid} = KindRegistry.lookup(workspace_uri)

    :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, probe_pid)
    :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, workspace_pid)

    wait_until(fn -> KindRegistry.lookup(probe_uri) == :error end)
    wait_until(fn -> KindRegistry.lookup(workspace_uri) == :error end)

    # 5. The proof: Loader.load_all/0 re-runs and the probe is alive
    #    again — purely from persisted Workspace state + runtime
    #    TemplateRegistry + SpawnRegistry, no ezagent_core / plugin code
    #    knows about probe.template. Poll the idempotent Loader until the
    #    probe is back (tolerates a transient empty pass; the probe MUST
    #    rehydrate within budget or this flunks).
    new_probe_pid = reload_until_alive(probe_uri)
    assert is_pid(new_probe_pid)
    assert Process.alive?(new_probe_pid)
    refute new_probe_pid == probe_pid
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
  defp load_all_until_present(workspace_name, attempts \\ 50)

  defp load_all_until_present(workspace_name, 0) do
    flunk(
      "load_all_until_present: workspace #{inspect(workspace_name)} never appeared in Loader results with children"
    )
  end

  defp load_all_until_present(workspace_name, attempts) when attempts > 0 do
    case Enum.find(Ezagent.Workspace.Loader.load_all(), fn {name, _} -> name == workspace_name end) do
      {^workspace_name, children} = found when children != [] ->
        found

      _ ->
        Process.sleep(20)
        load_all_until_present(workspace_name, attempts - 1)
    end
  end

  # Re-run the idempotent `Loader.load_all/0` until `uri` is alive in
  # KindRegistry, returning its pid. The survival proof: the Kind MUST
  # rehydrate from persisted state — this only tolerates a transient
  # empty Loader pass (seal-gate / sandbox rescue), it does NOT relax the
  # requirement that the Kind comes back (flunks if it never does).
  defp reload_until_alive(uri, attempts \\ 50)

  defp reload_until_alive(uri, 0) do
    flunk(
      "reload_until_alive: #{inspect(URI.to_string(uri))} never rehydrated after Loader re-runs"
    )
  end

  defp reload_until_alive(uri, attempts) when attempts > 0 do
    _ = Ezagent.Workspace.Loader.load_all()

    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        pid

      :error ->
        Process.sleep(20)
        reload_until_alive(uri, attempts - 1)
    end
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
