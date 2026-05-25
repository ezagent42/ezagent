defmodule Ezagent.Integration.AddTemplateInvokesTest do
  @moduledoc """
  V1 acceptance regression test (2026-05-21) —
  `Ezagent.Workspace.add_template/3` MUST chain into the Template
  Class's `instantiate/3` so any runtime-added template's Kind comes
  up immediately (without needing a phx restart for
  `Workspace.Loader.load_all/0` to fire).

  ## The bug this test prevents (Allen V1 acceptance fail)

  Operator created `entity://agent/team-alpha/cc_demo` via
  `AgentNewLive`. The UI showed "Not running" indefinitely because:
  1. `AgentNewLive.handle_event("create_agent")` called `Workspace
     .add_template/3` to register `cc.agent` in `session_templates`
     JSON
  2. `add_template/3` only wrote DB + dispatched the live Workspace
     Kind's `:add_template` action
  3. The Template Class's `instantiate/3` (which would spawn the
     PtyServer for `cc.agent`) only ran via `Workspace.Loader
     .load_all/0` at phx boot

  So newly-added templates' spawned Kinds were absent until the
  next phx restart. This test asserts the fix: after
  `add_template/3` returns `:ok`, the template's spawned Kind is
  alive in `KindRegistry`.

  ## Why a fake Template (not cc.agent)

  `ezagent_domain_workspace` does NOT depend on `ezagent_plugin_cc`
  (and shouldn't — plugins extend domain, not vice versa per
  invariant 8). So we can't reach for `cc.agent` here. Instead we
  register a `ProbeTemplate` inline in the test that mimics the
  shape — same `validate/1` + `instantiate/3` contract — and assert
  the spawn happened. The runtime invariant (template registered →
  Kind alive after `add_template`) is identical regardless of
  flavor; cc.agent's plugin-side test can layer on PtyServer
  specifics.

  Per memory `feedback_completion_requires_invariant_test`: the V1
  fix is not "done" on PR-merge alone — this test is the gate.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, SpawnRegistry, TemplateRegistry, Workspace}

  # ── Fake plugin types — defined inline (NOT in lib/) ──────────────

  defmodule ProbeBehavior do
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:ping]

    @impl true
    def cap_subjects, do: [{:ping, "test fixture"}]

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

  defmodule ProbeTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "v1_fix.probe.template"

    @impl true
    def validate(%{"class" => "v1_fix.probe.template", "probe_name" => name})
        when is_binary(name),
        do: :ok

    def validate(_), do: {:error, :bad_probe_template}

    @impl true
    def instantiate(_tmpl_name, %{"probe_name" => name}, _workspace_uri) do
      uri = URI.parse("probe-v1fix://#{name}")

      case SpawnRegistry.spawn(uri) do
        {:ok, _pid} -> {:ok, [uri]}
        # cc.agent returns this shape via its own idempotency
        # short-circuit; `add_template` must treat it as success.
        {:error, {:already_started, _pid}} -> {:ok, [uri]}
        err -> err
      end
    end
  end

  setup do
    # Register the probe spawn fn + template class for this test run.
    # ETS-backed registries persist across tests — keys are unique per
    # test via `System.unique_integer` so concurrent runs don't collide.
    :ok =
      SpawnRegistry.register("probe-v1fix", fn uri ->
        DynamicSupervisor.start_child(
          Ezagent.Workspace.Supervisor,
          {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
        )
      end)

    :ok = TemplateRegistry.register(ProbeTemplate)

    :ok
  end

  describe "add_template/3 chains into Template Class.instantiate/3 (V1 fix)" do
    test "after add_template returns :ok, the spawned Kind is alive in KindRegistry" do
      workspace_name = "v1-fix-add-tmpl-#{System.unique_integer([:positive])}"
      probe_name = "v1-fix-probe-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("probe-v1fix://#{probe_name}")

      # 1. Persist + spawn the Workspace Kind (workspace must be alive
      #    for add_template's dispatch_mutation to land).
      {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

      # Sanity: probe is NOT yet alive — the workspace was created
      # with no session_templates, so Loader has nothing to spawn.
      assert :error = KindRegistry.lookup(probe_uri),
             "probe should not be alive before add_template — test setup invalid"

      # 2. The fix under test: add_template MUST trigger instantiate.
      tmpl_name = "main-#{System.unique_integer([:positive])}"

      tmpl_data = %{
        "class" => "v1_fix.probe.template",
        "probe_name" => probe_name
      }

      assert :ok = Workspace.add_template(workspace_name, tmpl_name, tmpl_data)

      # 3. The assertion that fails without the fix: the probe Kind
      #    must be alive in KindRegistry immediately after
      #    add_template returns (no phx restart needed).
      assert {:ok, probe_pid} = KindRegistry.lookup(probe_uri),
             "REGRESSION (V1 acceptance fail): Workspace.add_template/3 must invoke " <>
               "the Template Class's instantiate/3 so the spawned Kind comes up " <>
               "immediately. If this fails, runtime-added templates only spawn " <>
               "their Kinds at the next phx boot (via Workspace.Loader.load_all/0). " <>
               "See docs/futures/v2-feedback-log.md `Architecture gap`."

      assert is_pid(probe_pid)
      assert Process.alive?(probe_pid)
    end

    test "WorkspaceRegistry binding is set after add_template's instantiate (invariant 4)" do
      workspace_name = "v1-fix-bind-#{System.unique_integer([:positive])}"
      probe_name = "v1-fix-bind-probe-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("probe-v1fix://#{probe_name}")
      workspace_uri = Ezagent.Entity.Workspace.uri_for(workspace_name)

      {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

      tmpl_name = "main-#{System.unique_integer([:positive])}"

      tmpl_data = %{
        "class" => "v1_fix.probe.template",
        "probe_name" => probe_name
      }

      assert :ok = Workspace.add_template(workspace_name, tmpl_name, tmpl_data)

      # Invariant 4: every URI a Template Class spawns must be bound
      # to its owning workspace in WorkspaceRegistry, so subsequent
      # dispatch can derive workspace_uri for the Resolver. Mirror of
      # what Loader.load_all/0 does on boot.
      assert {:ok, ^workspace_uri} = Ezagent.WorkspaceRegistry.lookup(probe_uri)
    end

    test "second add_template with same name idempotently succeeds (already-alive Kind)" do
      # When a Workspace's template is re-added (operator typo + retry,
      # or repeated programmatic call), the instantiate step must NOT
      # crash on `{:error, {:already_started, _}}` — that's success.
      workspace_name = "v1-fix-idem-#{System.unique_integer([:positive])}"
      probe_name = "v1-fix-idem-probe-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("probe-v1fix://#{probe_name}")

      {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

      tmpl_name = "main-#{System.unique_integer([:positive])}"

      tmpl_data = %{
        "class" => "v1_fix.probe.template",
        "probe_name" => probe_name
      }

      assert :ok = Workspace.add_template(workspace_name, tmpl_name, tmpl_data)
      {:ok, first_pid} = KindRegistry.lookup(probe_uri)

      # Second add_template with the same name: DB updates fine,
      # dispatch is idempotent, instantiate returns
      # `{:ok, [uri]}` because ProbeTemplate's instantiate maps
      # `{:already_started, _}` → `{:ok, [uri]}`.
      assert :ok = Workspace.add_template(workspace_name, tmpl_name, tmpl_data)
      assert {:ok, ^first_pid} = KindRegistry.lookup(probe_uri)
    end

    test "instantiate error propagates back to caller (no silent swallow)" do
      # Per feedback_let_it_crash_no_workarounds: if instantiate
      # fails for a real reason (validate error, spawn failure),
      # add_template MUST return the error. Use a template whose
      # instantiate returns an error.
      defmodule FailingTemplate do
        @behaviour Ezagent.Kind.Template

        @impl true
        def template_name, do: "v1_fix.failing.template"

        @impl true
        def validate(_), do: :ok

        @impl true
        def instantiate(_tmpl_name, _tmpl_data, _workspace_uri) do
          {:error, :deliberate_failure_for_test}
        end
      end

      :ok = TemplateRegistry.register(FailingTemplate)

      workspace_name = "v1-fix-fail-#{System.unique_integer([:positive])}"
      {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

      tmpl_name = "fail-#{System.unique_integer([:positive])}"
      tmpl_data = %{"class" => "v1_fix.failing.template"}

      assert {:error, :deliberate_failure_for_test} =
               Workspace.add_template(workspace_name, tmpl_name, tmpl_data)
    end
  end
end
