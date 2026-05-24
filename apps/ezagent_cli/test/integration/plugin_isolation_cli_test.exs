defmodule EzagentCli.Integration.PluginIsolationCLITest do
  @moduledoc """
  Phase 4-completion Spec 02 invariant test (the architectural gate).

  Per memory `feedback_completion_requires_invariant_test`:
  Decision #58 (LV ↔ CLI 同构映射 — both derived from `@interface`) is
  fulfilled if a fake plugin author can register a new Kind + Behavior
  + action via runtime `BehaviorRegistry.register/3` and the CLI's
  `TreeBuilder` picks it up — **without any `Mix.Tasks.Ezagent.<Kind>.<Action>`
  module existing in the codebase**.

  This test inlines a fake ProbeKind + ProbeBehavior (NOT in lib/),
  registers them at runtime, builds the Optimus tree, asserts the new
  action appears as a subcommand, dispatches via the CLI's Dispatch
  module, asserts result.
  """

  use ExUnit.Case, async: false

  alias EzagentCli.{Dispatch, TreeBuilder}

  # ----- Fake plugin types — defined inline, NOT in lib/ ------------

  defmodule ProbeBehavior do
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:do_thing]

    @impl true
    def cap_subjects, do: [{:do_thing, "test fixture"}]

    @impl true
    def state_slice, do: :probe_cli

    @impl true
    def init_slice(_args), do: %{things: []}

    @impl true
    def invoke(:do_thing, slice, %{x: x}, _ctx) do
      {:ok, %{slice | things: [x | slice.things]}, %{result: x}}
    end

    @impl true
    def interface,
      do: %{
        do_thing: %{
          args: %{x: :string},
          returns: %{result: :string},
          modes: [:call]
        }
      }
  end

  defmodule ProbeKind do
    @behaviour Ezagent.Kind

    # Avoid underscore in type_name to keep URI parsing clean (scheme
    # per RFC 3986 is ALPHA + digits + "+/-/.").
    @impl true
    def type_name, do: :probecli

    @impl true
    def behaviors, do: [ProbeBehavior]

    @impl true
    def persistence, do: :ephemeral

    @impl true
    def uri_from_args(args), do: Map.fetch!(args, :uri)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # CLI/GUI audit HIGH-1 — Dispatch no longer silent-fallbacks to
    # admin. Tests set the per-process caller override.
    Process.put(
      :ezagent_cli_caller_override,
      {Ezagent.Entity.User.admin_uri(), Ezagent.Entity.User.admin_caps()}
    )

    :ok
  end

  test "PHASE 4 CLI INVARIANT: plugin-defined Behavior action auto-appears in mix esr tree" do
    # 1. Plugin-author work: register Kind ↔ Behavior at runtime
    :ok = Ezagent.BehaviorRegistry.register(ProbeKind, :do_thing, ProbeBehavior)

    # 2. Build CLI tree — picks up the new action without ANY mix task code
    spec = TreeBuilder.build()
    sub_names = spec.subcommands |> Enum.map(& &1.name)

    assert "probecli" in sub_names

    probe_sub = Enum.find(spec.subcommands, fn s -> s.name == "probecli" end)
    action_names = probe_sub.subcommands |> Enum.map(& &1.name)
    assert "do_thing" in action_names

    # 3. Spawn an instance + dispatch via CLI Dispatch — operator UX
    instance_name = "test-#{System.unique_integer([:positive])}"
    uri = URI.parse("probecli://#{instance_name}")

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Ezagent.Workspace.Supervisor,
        {Ezagent.Kind.Server, {ProbeKind, %{uri: uri}}}
      )

    parsed = %{
      options: %{probecli: instance_name, x: "hello-from-cli"},
      flags: %{cast: false, json: false}
    }

    assert {:ok, %{result: "hello-from-cli"}} =
             Dispatch.run_action(ProbeKind, ProbeBehavior, :do_thing, parsed)

    # 4. Strict check: no Mix.Tasks.Ezagent.Probecli.* module exists
    refute Code.ensure_loaded?(Mix.Tasks.Ezagent.Probecli)
    refute Code.ensure_loaded?(Mix.Tasks.Ezagent.Probecli.DoThing)
  end
end
