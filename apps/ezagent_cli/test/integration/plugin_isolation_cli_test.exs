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

  use EzagentCore.DataCase, async: false

  alias EzagentCli.{Dispatch, TreeBuilder}

  # ----- Fake plugin types — defined inline, NOT in lib/ ------------

  defmodule ProbeBehavior do
    # Migrated to the current `use Ezagent.Lifecycle` developer surface
    # (post-lifecycle remediation 2026-05-30). The legacy
    # `@behaviour Ezagent.ActionSet` + state_slice/init_slice/invoke form
    # no longer carries the `__behavior__?/0` marker the runtime
    # requires, so `Ezagent.Kind.Runtime` would REFUSE to dispatch to it.
    use Ezagent.Lifecycle, state_slice: :probe_cli

    action :do_thing,
      args: %{x: :string},
      returns: %{result: :string},
      caps: [:do_thing],
      modes: [:call],
      description: "test fixture — append x to the probe slice and echo it back"

    @impl Ezagent.Lifecycle
    def create(_args), do: {:ok, %{things: []}}

    def handle_do_thing(%{x: x}, ctx) do
      things = ctx[:read].(:things, [])
      {:ok, %{result: x}, [{:set, :things, [x | things]}]}
    end
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
    # Sandbox provided by EzagentCore.DataCase (#92).

    # CLI/GUI audit HIGH-1 — Dispatch no longer silent-fallbacks to
    # admin. Tests set the per-process caller override.
    Process.put(
      :ezagent_cli_caller_override,
      {Ezagent.Entity.User.admin_uri(), MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    :ok
  end

  test "PHASE 4 CLI INVARIANT: plugin-defined Behavior action auto-appears in mix ezagent tree" do
    # 1. Plugin-author work: register Kind ↔ Behavior at runtime.
    #    In production `Ezagent.SpawnRegistry.register/2` co-registers a
    #    new scheme into `Ezagent.URI.SchemeRegistry`; this fixture spawns
    #    `ProbeKind` directly (no scheme spawn fn), so register the
    #    `probecli` scheme explicitly — otherwise the canonical
    #    `Ezagent.URI.new!/1` in `Dispatch.run_action` rejects it as
    #    unregistered (SPEC 2026-05-27 URI canonicalization tightened the
    #    allowlist check).
    :ok = Ezagent.URI.SchemeRegistry.register("probecli")
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
    uri = URI.new!("probecli://#{instance_name}")

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
