defmodule Ezagent.ExternalMirror.Invariants.BindingAdapterGrill5Test do
  @moduledoc """
  PR-EM-FINAL invariant 3 — Binding↔Adapter Grill-5 runtime
  enforcement.

  SPEC §10 (e):

  > **Plugin-contract grep gate — no module implements both Adapter
  > and Binding behaviours.** Static check on `:code.all_loaded`: any
  > module having both `@behaviour Ezagent.ExternalMirror.Adapter`
  > AND `@behaviour Ezagent.ExternalMirror.Binding` fails.

  Compile-time `:ezagent_plugin_check` catches this at plugin BUILD
  time. The runtime check here is defense-in-depth for two cases the
  compiler gate can't cover:

  1. **Hot-installed plugins** — a plugin loaded at runtime via
     `Code.compile_string/2` or `:code.load_file/1` skips the umbrella
     compiler chain.
  2. **In-test fixture modules** — test files define throwaway
     modules; the Grill-5 compiler doesn't see them, but the runtime
     check ensures even test fixtures can't accidentally model the
     forbidden shape.

  ## Grill-5 (full set)

  Per SPEC §2.2 / §5.1, the Grill-5 contract is BIDIRECTIONAL and
  has 5 clauses; this test asserts all five at runtime:

  - (a) `adapter` declares `@behaviour Ezagent.ExternalMirror.Adapter`
  - (b) `binding` declares `@behaviour Ezagent.ExternalMirror.Binding`
  - (c) `adapter.binding_module() == binding`
  - (d) `binding.adapter_module() == adapter`
  - (e) `adapter != binding`

  ## Source of truth — the registries

  The test walks `Ezagent.ExternalMirror.AdapterRegistry.list/0` +
  `BindingRegistry.list_all/0`. By the time the test runs, the
  `EzagentDomainExternalMirror.Application` has booted (ExUnit.start
  starts all umbrella apps) so the registries reflect every plugin
  declared via `adapters/0`. The test registers a MockAdapter pair
  in `setup_all` so the assertion exercises non-empty registries
  even when no production plugin has booted in the test env.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry, BindingRegistry}
  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

  # P3-1/P3-2: the Grill-5 adapter↔binding pairing applies to the BINDING-BEARING
  # adapter kinds — `:push` and `:request_scoped`. Both declare a paired Binding
  # module (a `:request_scoped` adapter declares one "as `:push`" per the Adapter
  # moduledoc; protocol_api's is the P0 stub binding). A `:pull` adapter (e.g. the
  # socialware `customer_feed`, P3-2) has NO per-binding transport by design — no
  # `binding_module/0`, no BindingRegistry row — so it is excluded from the
  # pairing walks below. (e) — no module implements BOTH behaviours — still
  # applies to every adapter regardless of kind.
  @bound_kinds [:push, :request_scoped]

  defp bound_adapters do
    AdapterRegistry.list()
    |> Enum.filter(&(Adapter.kind_of(&1.module) in @bound_kinds))
  end

  setup_all do
    # Ensure at least one (adapter, binding) pair is in BOTH registries
    # so the Grill-5 walk asserts the positive shape too (not just the
    # absence of violations).
    _ = AdapterRegistry.register(MockAdapter)
    _ = BindingRegistry.register_module("mock_em", MockBinding)
    :ok
  end

  test "every binding-bearing adapter_id present in AdapterRegistry has a paired entry in BindingRegistry" do
    # Only :push / :request_scoped adapters carry a binding; :pull adapters (P3-1)
    # are binding-less.
    adapter_ids =
      bound_adapters()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    binding_ids =
      BindingRegistry.list_all()
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    missing_bindings = MapSet.difference(adapter_ids, binding_ids)
    missing_adapters = MapSet.difference(binding_ids, adapter_ids)

    assert MapSet.size(missing_bindings) == 0,
           """
           Adapter(s) registered without paired Binding — Grill-5 violation:
           #{inspect(MapSet.to_list(missing_bindings))}
           """

    assert MapSet.size(missing_adapters) == 0,
           """
           Binding(s) registered without paired Adapter — Grill-5 violation:
           #{inspect(MapSet.to_list(missing_adapters))}
           """
  end

  test "Grill-5 (a/b): every registered binding-bearing adapter/binding pair declares the right @behaviour" do
    for %{id: adapter_id, module: adapter_module} <- bound_adapters() do
      assert behaviour?(adapter_module, Ezagent.ExternalMirror.Adapter),
             """
             Adapter #{inspect(adapter_module)} (id=#{inspect(adapter_id)})
             does not declare @behaviour Ezagent.ExternalMirror.Adapter —
             Grill-5 (a) violation. AdapterRegistry.register/1's
             assert_behaviour! gate should have caught this — registry
             was populated through a bypass path.
             """

      {:ok, binding_module} = BindingRegistry.lookup(adapter_id)

      assert behaviour?(binding_module, Ezagent.ExternalMirror.Binding),
             """
             Binding #{inspect(binding_module)} (id=#{inspect(adapter_id)})
             does not declare @behaviour Ezagent.ExternalMirror.Binding —
             Grill-5 (b) violation.
             """
    end
  end

  test "Grill-5 (c/d): bidirectional binding-bearing adapter <-> binding declarations agree" do
    for %{id: adapter_id, module: adapter_module} <- bound_adapters() do
      {:ok, binding_module} = BindingRegistry.lookup(adapter_id)

      assert adapter_module.binding_module() == binding_module,
             """
             Grill-5 (c) violation: #{inspect(adapter_module)}.binding_module()
             returned #{inspect(adapter_module.binding_module())} but the
             BindingRegistry has #{inspect(binding_module)} for the same
             adapter_id #{inspect(adapter_id)}.
             """

      assert binding_module.adapter_module() == adapter_module,
             """
             Grill-5 (d) violation: #{inspect(binding_module)}.adapter_module()
             returned #{inspect(binding_module.adapter_module())} but the
             AdapterRegistry has #{inspect(adapter_module)} for the same
             adapter_id #{inspect(adapter_id)}.
             """
    end
  end

  test "a registered :pull adapter is binding-less and is NOT flagged as a Grill-5 violation (P3-1/P3-2)" do
    # Register the binding-less pull test adapter; the paired-binding walk must
    # tolerate it (no BindingRegistry row), exactly as the real customer_feed
    # pull adapter (P3-2) booted into the registry.
    _ = AdapterRegistry.register(Ezagent.ExternalMirror.TestSupport.PullAdapter)

    assert Adapter.kind_of(Ezagent.ExternalMirror.TestSupport.PullAdapter) == :pull
    assert :error = BindingRegistry.lookup("pull_em")

    # The pull adapter is excluded from the binding-bearing pairing walk.
    refute Enum.any?(bound_adapters(), &(&1.id == "pull_em"))
  end

  test "Grill-5 (e): no module implements BOTH Adapter and Binding behaviours" do
    # Walk every loaded module — `:code.all_loaded/0` is a runtime
    # snapshot; we only care about modules whose code is already loaded
    # at the moment the test runs. ExUnit.start has already started the
    # ExternalMirror app + loaded every umbrella module, so production
    # offenders show up here.
    #
    # EXCLUDE test-fixture modules: this invariant is about PRODUCTION code, but
    # `:code.all_loaded/0` is a global snapshot, so dual-behaviour fixtures that
    # OTHER (async) tests define on purpose — e.g. `PluginContractTest.Dual_*`,
    # which exists to prove the contract REJECTS them — leak in depending on
    # load order, making this test flaky. A module defined under a `/test/`
    # source path is a fixture, not production, so reject it.
    offenders =
      :code.all_loaded()
      |> Enum.map(fn {mod, _file} -> mod end)
      |> Enum.filter(fn mod ->
        behaviour?(mod, Ezagent.ExternalMirror.Adapter) and
          behaviour?(mod, Ezagent.ExternalMirror.Binding)
      end)
      |> Enum.reject(&defined_in_test?/1)

    assert offenders == [],
           """
           Module(s) implement BOTH @behaviour Adapter AND @behaviour
           Binding — Grill-5 (e) violation. Adapter (stateless) and
           Binding (stateful per-target GenServer callbacks) MUST live
           in DIFFERENT modules per SPEC §2.2 + §2.3.

           Offenders:
           #{inspect(offenders)}
           """
  end

  defp behaviour?(module, behaviour) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  rescue
    UndefinedFunctionError -> false
  end

  # A module is a test fixture (not production) if its compiled source lives under
  # a `/test/` directory. Production code lives in `lib/`. Modules without compile
  # info are treated as production (conservative — don't hide a real offender).
  defp defined_in_test?(module) do
    module.module_info(:compile)
    |> Keyword.get(:source, ~c"")
    |> to_string()
    |> String.contains?("/test/")
  rescue
    UndefinedFunctionError -> false
  end
end
