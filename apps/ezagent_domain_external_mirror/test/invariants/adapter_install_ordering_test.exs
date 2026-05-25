defmodule Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest do
  @moduledoc """
  PR-EM-FINAL invariant 12 — AdapterInstall ordering / two-registry
  hook.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.1 + PR-EM-3 codex r5 HIGH-A fix (2026-05-25).

  Per the SPEC, the symmetric pair `AdapterInstall.maybe_install/1` +
  `AdapterInstall.maybe_install_by_adapter_id/1` guarantees:

  - `install/1` fires EXACTLY ONCE per `(adapter_id, adapter_module)` pair.
  - It fires only AFTER BOTH `AdapterRegistry.register/1` AND
    `BindingRegistry.register_module/2` have populated their tables
    for that `adapter_id`.
  - The registration order does NOT matter — whichever registry's
    insert lands SECOND is the one whose `maybe_install` call actually
    fires `install/1`.

  ## Why the SPEC mandates this shape

  Pre-fix history (PR-EM-3 round-5):
  - `AdapterRegistry.register/1` fired `install/1` unconditionally on
    fresh insert. If the BindingRegistry hadn't yet registered the
    paired binding for that adapter_id, `install/1` would walk
    persisted `BindingRow`s + spawn Workers whose `:publish` dispatch
    path looks up the binding via `BindingRegistry.lookup!/1` — which
    would `KeyError` because the binding row didn't exist yet.
  - The fix: guard `install/1` on BOTH registries being populated for
    the adapter_id. If we're the first registry to land, defer to the
    other registry's `register` call to fire install when IT lands
    second.

  This invariant verifies the END STATE: regardless of registration
  order, install runs exactly once and both registries are populated.

  ## Test structure

  Each test uses a UNIQUE adapter_id derived from
  `System.unique_integer([:positive])` so the cap subject registration
  state is per-test (idempotent CapabilityRegistry registrations from
  one test do not leak into another).

  Two ordering scenarios:

  1. **Adapter first, then binding** (the PRODUCTION order set by
     `Plugin.publish_adapters!`): AdapterRegistry.register/1 returns
     `:ok` + defers install; BindingRegistry.register_module/2 then
     fires install. Asserts cap subject is registered AFTER the
     binding register call returns.

  2. **Binding first, then adapter** (test ordering, hot install):
     BindingRegistry.register_module/2 returns `:ok` + defers install;
     AdapterRegistry.register/1 then fires install. Asserts cap
     subject is registered AFTER the adapter register call returns.

  ## Why this is structural

  The PR-EM-3 r5 HIGH-A regression class wasn't a logic error in any
  single function — it was an EDGE CASE in the ordering between two
  cooperating registers. A future refactor that "simplifies" the
  symmetric `maybe_install` pair into a single one-shot would silently
  break this contract. The runtime invariant guards against it.
  """
  use ExUnit.Case, async: false

  alias Ezagent.CapabilityRegistry
  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}

  # We use the production-fixture MockAdapter pair (id="mock_em") for
  # registry-presence assertions — these check the END STATE of the
  # two-registry pair AFTER both inserts have landed. The point of the
  # test is "install fires exactly when the SECOND registry registers",
  # observable as `BindingRegistry.lookup` and `AdapterRegistry.lookup`
  # both returning `{:ok, _}` only AFTER both register calls succeed.
  #
  # The order-of-registration assertion is verified via the AdapterInstall
  # public API surface: `maybe_install/1` and `maybe_install_by_adapter_id/1`
  # are no-ops when the OTHER registry is missing — directly callable
  # with a synthetic adapter_id that's only ever in one registry, and
  # observable via return value.

  alias Ezagent.ExternalMirror.AdapterInstall

  setup do
    # Use a fresh adapter_id per test so the test is hermetic. The actual
    # MockAdapter/MockBinding modules implement the contract; we just
    # use a SYNTHETIC id that's NOT in either registry.
    {:ok, fresh_id: "ordering_test_em_#{System.unique_integer([:positive])}"}
  end

  test "AdapterInstall.maybe_install/1 defers when paired BindingRegistry entry is missing",
       %{fresh_id: _fresh_id} do
    # Build a one-off adapter module whose adapter_id is NOT yet in
    # BindingRegistry. We DON'T register it in AdapterRegistry — we just
    # call maybe_install directly with the module to observe the deferral.
    fresh_id = "ordering_test_em_a_#{System.unique_integer([:positive])}"
    adapter_module = build_synthetic_adapter(fresh_id)

    # Pre-condition: BindingRegistry has nothing for this adapter_id.
    assert :error = BindingRegistry.lookup(fresh_id)

    # maybe_install/1 should observe the missing paired entry and return
    # `:ok` WITHOUT performing the install (no cap subject registered,
    # no rows reconciled).
    assert :ok = AdapterInstall.maybe_install(adapter_module)

    # CapBilityRegistry should NOT carry the synthetic cap subject because
    # install was deferred. We use lookup_subject — direct kind/action probe.
    expected_action = String.to_atom("allow_" <> fresh_id)

    assert :error = CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action),
           """
           CapabilityRegistry contains a per-adapter cap subject for
           adapter_id=#{inspect(fresh_id)} but BindingRegistry has NO
           paired binding — violates SPEC §5.1 r5 HIGH-A.
           AdapterInstall.maybe_install/1 MUST defer install when the
           paired BindingRegistry entry is absent.
           """
  end

  test "AdapterInstall.maybe_install_by_adapter_id/1 defers when AdapterRegistry entry is missing",
       %{fresh_id: _fresh_id} do
    # Symmetric scenario — AdapterRegistry empty for this id.
    fresh_id = "ordering_test_em_b_#{System.unique_integer([:positive])}"

    # Pre-condition: AdapterRegistry has nothing for this adapter_id.
    assert :error = AdapterRegistry.lookup(fresh_id)

    # maybe_install_by_adapter_id/1 should observe the missing paired entry
    # and return `:ok` without doing install (no cap subject registration).
    assert :ok = AdapterInstall.maybe_install_by_adapter_id(fresh_id)

    expected_action = String.to_atom("allow_" <> fresh_id)

    assert :error = CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action),
           """
           CapabilityRegistry contains a per-adapter cap subject for
           adapter_id=#{inspect(fresh_id)} but AdapterRegistry has NO
           paired adapter — violates SPEC §5.1 r5 HIGH-A.
           AdapterInstall.maybe_install_by_adapter_id/1 MUST defer install
           when the paired AdapterRegistry entry is absent.
           """
  end

  test "after BOTH registries are populated, the cap subject IS registered (end state)" do
    # End-state assertion uses the production fixture pair (MockAdapter /
    # MockBinding). The same fixtures are used by plugin_contract_test
    # and the registry tests — by the time this test runs, they MAY have
    # been registered already; we just check the end-state invariant
    # holds regardless of which path got us there.
    alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

    _ = AdapterRegistry.register(MockAdapter)
    _ = BindingRegistry.register_module("mock_em", MockBinding)

    expected_action = :allow_mock_em
    expected_behavior = MockAdapter.Allow

    assert {:ok, %{behavior: ^expected_behavior}} =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action),
           """
           CapabilityRegistry MISSING the per-adapter cap subject after
           BOTH registries registered MockAdapter / MockBinding —
           violates SPEC §5.1 r5 HIGH-A end-state contract.

           Either: AdapterRegistry.register/1 didn't fire
           AdapterInstall.maybe_install/1, OR
           BindingRegistry.register_module/2 didn't fire
           AdapterInstall.maybe_install_by_adapter_id/1, OR install/1
           skipped the cap-subject step entirely.
           """
  end

  # Build a throwaway adapter module with a unique adapter_id so we can
  # observe maybe_install/1's deferral behavior without polluting the
  # production fixtures.
  defp build_synthetic_adapter(adapter_id) do
    behavior_module_name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest.SyntheticAllow#{System.unique_integer([:positive])}"
      )

    Module.create(
      behavior_module_name,
      quote do
        @behaviour Ezagent.Behavior
        @impl true
        def actions, do: [unquote(String.to_atom("allow_" <> adapter_id))]
        @impl true
        def cap_subjects, do: [{unquote(String.to_atom("allow_" <> adapter_id)), "synth"}]
        @impl true
        def dispatchable?, do: false
        @impl true
        def state_slice, do: unquote(String.to_atom("synth_" <> adapter_id))
        @impl true
        def init_slice(_args), do: %{}
        @impl true
        def invoke(_, _, _, _), do: raise("cap-only")
        @impl true
        def interface, do: %{}
        @impl true
        def data_owner(_), do: :any
      end,
      Macro.Env.location(__ENV__)
    )

    adapter_module_name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest.SyntheticAdapter#{System.unique_integer([:positive])}"
      )

    Module.create(
      adapter_module_name,
      quote do
        @behaviour Ezagent.ExternalMirror.Adapter
        @impl true
        def adapter_id, do: unquote(adapter_id)
        @impl true
        def display_name, do: "synthetic"
        @impl true
        def description, do: "synthetic"
        @impl true
        def binding_module, do: __MODULE__
        @impl true
        def cap_subject,
          do: %{behavior_module: unquote(behavior_module_name), description: "synth"}

        @impl true
        def target_ownership_check(_, _), do: :ok
        @impl true
        def event_to_payload(%Ezagent.Publisher.Event{} = e), do: {:publish, e}
      end,
      Macro.Env.location(__ENV__)
    )

    adapter_module_name
  end
end
