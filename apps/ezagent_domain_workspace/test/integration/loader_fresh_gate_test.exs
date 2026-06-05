defmodule Ezagent.Integration.LoaderFreshGateTest do
  @moduledoc """
  codex round-9 HIGH-1 regression test — `Ezagent.Workspace.Loader`
  must NOT rebind a `fresh?: false` worker it does not own.

  ## The bug this test prevents

  A Template Class may return the 3-element `{:ok, [uri], %{fresh?: _}}`
  form. Round 8 made an already-started Agent Kind report
  `fresh?: false` (no fresh sidecar, no fresh lineage/binding). The
  pre-round-9 Loader IGNORED `fresh?` — it unconditionally rebound
  every returned URI in `WorkspaceRegistry`. A persisted workspace
  template whose `agent_uri` points at an already-live worker could
  therefore REBIND that worker to THIS workspace with no ownership
  check — a corrupt-state / workspace-isolation path round 8 fixed in
  the Generator (`verify_slot_candidate_ownership/5`) but NOT in the
  Loader.

  ## The fix — adopt-only-if-owned for `fresh?: false`

  - `fresh?: false` worker NOT already bound to this workspace →
    `{:error, {:loader_adopt_not_owned, _}}`, the worker's existing
    binding is UNCHANGED, nothing rebound.
  - `fresh?: false` worker already correctly bound to this workspace →
    `{:ok, _}` (idempotent re-load).
  - `fresh?: true` (or a legacy 2-tuple return) → bound unconditionally
    after a URI/workspace-segment consistency check.

  Per `feedback_completion_requires_invariant_test`: this test IS the
  gate — the round-9 fix is not "done" on PR-merge alone.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{SpawnRegistry, TemplateRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Workspace.Loader

  # ── Fake plugin types — defined inline (NOT in lib/) ──────────────

  defmodule GateProbeBehavior do
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:ping]

    @impl true
    def cap_subjects, do: [{:ping, "test fixture"}]

    @impl true
    def state_slice, do: :gate_probe

    @impl true
    def init_slice(_args), do: %{pings: 0}

    @impl true
    def invoke(:ping, slice, _args, _ctx),
      do: {:ok, %{slice | pings: slice.pings + 1}, %{pong: true}}

    @impl true
    def interface,
      do: %{ping: %{args: %{}, returns: %{pong: :boolean}, modes: [:call]}}
  end

  defmodule GateProbeKind do
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :gate_probe

    @impl true
    def behaviors, do: [GateProbeBehavior]

    @impl true
    def persistence, do: :ephemeral

    @impl true
    def uri_from_args(args), do: Map.fetch!(args, :uri)
  end

  # A Template Class that ALWAYS returns the 3-element
  # `{:ok, [uri], %{fresh?: false}}` form — modelling round 8's
  # "already-started Agent Kind" result. The worker URI is spawned (so
  # the Kind is live, as a real already-started worker would be) but the
  # `fresh?: false` signal tells the Loader THIS call did not create it.
  defmodule NonFreshProbeTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "round9.nonfresh.probe"

    @impl true
    def validate(%{"class" => "round9.nonfresh.probe", "probe_name" => name})
        when is_binary(name),
        do: :ok

    def validate(_), do: {:error, :bad_probe_template}

    @impl true
    def instantiate(_tmpl_name, %{"probe_name" => name}, _workspace_uri) do
      uri = URI.parse("gate-probe-r9://#{name}")

      case SpawnRegistry.spawn(uri) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: false}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: false}}
        err -> err
      end
    end
  end

  # A Template Class that returns `{:ok, [uri], %{fresh?: true}}` — a
  # genuinely fresh worker the Loader must bind unconditionally.
  defmodule FreshProbeTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "round9.fresh.probe"

    @impl true
    def validate(%{"class" => "round9.fresh.probe", "probe_name" => name})
        when is_binary(name),
        do: :ok

    def validate(_), do: {:error, :bad_probe_template}

    @impl true
    def instantiate(_tmpl_name, %{"probe_name" => name}, _workspace_uri) do
      uri = URI.parse("gate-probe-r9://#{name}")

      case SpawnRegistry.spawn(uri) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: true}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: true}}
        err -> err
      end
    end
  end

  setup do
    :ok =
      SpawnRegistry.register("gate-probe-r9", fn uri ->
        DynamicSupervisor.start_child(
          Ezagent.Workspace.Supervisor,
          {Ezagent.Kind.Server, {GateProbeKind, %{uri: uri}}}
        )
      end)

    :ok = TemplateRegistry.register(NonFreshProbeTemplate)
    :ok = TemplateRegistry.register(FreshProbeTemplate)

    :ok
  end

  # Persist a workspace carrying ONE session template under `tmpl_name`
  # written directly into the store, then return its `workspace://` URI.
  # Used to drive `Loader.invoke_template/2` directly without going
  # through `Workspace.add_template` (whose own invoke would pre-empt
  # what the test measures).
  defp persisted_workspace_with_template(class, probe_name) do
    workspace_name = "r9-loader-#{System.unique_integer([:positive])}"
    tmpl_name = "main-#{System.unique_integer([:positive])}"

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    {:ok, _} =
      Workspace.Store.update_templates(workspace_name, %{
        tmpl_name => %{"class" => class, "probe_name" => probe_name}
      })

    {Ezagent.URI.new!("workspace://#{workspace_name}"), tmpl_name}
  end

  describe "HIGH-1 r9 — Loader fresh?: false adopt-only-if-owned gate" do
    test "a fresh?: false worker NOT bound to the workspace → error, no rebind" do
      probe_name = "r9-notowned-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("gate-probe-r9://#{probe_name}")

      # The worker exists and is bound to a DIFFERENT (foreign)
      # workspace — a worker some other workspace already owns.
      {:ok, _pid} = SpawnRegistry.spawn(probe_uri)
      foreign_ws = URI.new!("workspace://r9-foreign-#{System.unique_integer([:positive])}")
      :ok = WorkspaceRegistry.bind(probe_uri, foreign_ws)

      # A NEW workspace persists a template whose instantiate returns
      # this SAME worker URI with `fresh?: false`. The Loader must
      # REFUSE to adopt it.
      {workspace_uri, tmpl_name} =
        persisted_workspace_with_template("round9.nonfresh.probe", probe_name)

      result = Loader.invoke_template(workspace_uri, tmpl_name)

      assert match?({:error, {:loader_adopt_not_owned, _}}, result),
             "the Loader must REFUSE to adopt a fresh?: false worker not bound to this " <>
               "workspace. Got: #{inspect(result)}"

      # The worker's existing (foreign) binding is UNCHANGED — the
      # Loader rebound nothing.
      assert {:ok, bound_after} = WorkspaceRegistry.lookup(probe_uri)

      assert URI.to_string(bound_after) == URI.to_string(foreign_ws),
             "a rejected adoption must leave the worker's existing binding untouched. " <>
               "Expected #{URI.to_string(foreign_ws)}, got #{URI.to_string(bound_after)}"
    end

    test "a fresh?: false worker already bound to the workspace → succeeds (idempotent re-load)" do
      probe_name = "r9-owned-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("gate-probe-r9://#{probe_name}")

      {workspace_uri, tmpl_name} =
        persisted_workspace_with_template("round9.nonfresh.probe", probe_name)

      # The worker exists and is ALREADY bound to THIS workspace — the
      # legitimate idempotent re-load (every boot pass re-runs the
      # Loader; a worker this workspace already owns reports fresh?:
      # false on the re-instantiate).
      {:ok, _pid} = SpawnRegistry.spawn(probe_uri)
      :ok = WorkspaceRegistry.bind(probe_uri, workspace_uri)

      result = Loader.invoke_template(workspace_uri, tmpl_name)

      assert match?({:ok, _uris}, result),
             "a fresh?: false worker ALREADY bound to this workspace is owned — the " <>
               "Loader must accept the idempotent re-load. Got: #{inspect(result)}"

      # The binding is still THIS workspace — unchanged.
      assert {:ok, bound_after} = WorkspaceRegistry.lookup(probe_uri)
      assert URI.to_string(bound_after) == URI.to_string(workspace_uri)
    end

    test "a fresh?: true worker is bound unconditionally" do
      probe_name = "r9-fresh-#{System.unique_integer([:positive])}"
      probe_uri = URI.parse("gate-probe-r9://#{probe_name}")

      # No pre-existing binding — the fresh worker is created by this
      # instantiate and the Loader binds it (invariant 4).
      assert :error = WorkspaceRegistry.lookup(probe_uri),
             "test setup invalid — the fresh probe must start unbound"

      {workspace_uri, tmpl_name} =
        persisted_workspace_with_template("round9.fresh.probe", probe_name)

      result = Loader.invoke_template(workspace_uri, tmpl_name)

      assert match?({:ok, _uris}, result),
             "a fresh?: true worker must be bound. Got: #{inspect(result)}"

      assert {:ok, bound} = WorkspaceRegistry.lookup(probe_uri)

      assert URI.to_string(bound) == URI.to_string(workspace_uri),
             "a fresh?: true worker must be bound to its workspace"
    end
  end
end
