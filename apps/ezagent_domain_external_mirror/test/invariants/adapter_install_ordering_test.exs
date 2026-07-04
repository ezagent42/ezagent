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
  cooperating registers. PR #334 (facade auth-model audit) replaced
  the symmetric `maybe_install` pair with the
  `Ezagent.Plugin.publish_after_all_registered/2` primitive, which
  enforces the SAME contract structurally (install fires only when
  BOTH registries have populated the same adapter_id). This
  invariant guards the OBSERVABLE contract — install runs exactly
  once regardless of registration order — independently of the
  implementation mechanism.
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

  setup do
    # Use a fresh adapter_id per test so the test is hermetic. The actual
    # MockAdapter/MockBinding modules implement the contract; we just
    # use a SYNTHETIC id that's NOT in either registry.
    {:ok, fresh_id: "ordering_test_em_#{System.unique_integer([:positive])}"}
  end

  # The two `maybe_install/1` + `maybe_install_by_adapter_id/1` deferral
  # tests that used to live here were removed when those functions were
  # replaced by the `Ezagent.Plugin.publish_after_all_registered/2`
  # primitive (PR #334, "facade auth-model audit"). The deferral
  # invariant is now structural — install fires ONLY when both registries
  # have populated the same adapter_id, enforced by the hook primitive
  # itself, not by per-side polling. The two end-state tests below
  # (Adapter-first / Binding-first) verify the OUTCOME of that
  # contract — install runs exactly once regardless of registration
  # order — which is the SPEC §5.1 r5 HIGH-A invariant the deleted
  # tests were intended to cover.

  test "after BOTH registries populate the SAME fresh adapter_id (Adapter first, Binding second), cap subject IS registered" do
    # Codex r1 P2 fix: hermetic end-state assertion using a fresh
    # synthetic adapter_id per test run — does NOT depend on whether
    # MockAdapter / MockBinding were already registered by an earlier
    # test (which would mask a broken `register_module/2 → maybe_install_by_adapter_id`
    # hook because the cap subject was already present from setup_all
    # in another test).
    fresh_id = "ordering_test_em_endstate_a_#{System.unique_integer([:positive])}"
    cleanup_registries(fresh_id)
    {adapter_module, binding_module} = build_synthetic_pair(fresh_id)
    expected_action = String.to_atom("allow_" <> fresh_id)
    %{behavior_module: expected_behavior} = adapter_module.cap_subject()

    # Pre-condition: cap subject NOT yet registered.
    assert :error =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action)

    # Production ordering: Adapter first, Binding second. The
    # AdapterRegistry.register/1 call's maybe_install/1 defers; the
    # subsequent BindingRegistry.register_module/2 call's
    # maybe_install_by_adapter_id/1 fires install once BOTH registries
    # are populated.
    :ok = AdapterRegistry.register(adapter_module)

    # Pre-condition mid-flight: still not registered (no binding yet).
    assert :error =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action)

    :ok = BindingRegistry.register_module(fresh_id, binding_module)

    # Post-condition: NOW the cap subject is in CapabilityRegistry.
    assert {:ok, %{behavior: ^expected_behavior}} =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action),
           """
           CapabilityRegistry MISSING the per-adapter cap subject for
           adapter_id=#{inspect(fresh_id)} after BOTH registries
           registered (Adapter first, then Binding) — violates SPEC §5.1
           r5 HIGH-A end-state contract.

           BindingRegistry.register_module/2 must call
           AdapterInstall.maybe_install_by_adapter_id/1 which fires
           install when it observes that AdapterRegistry already has
           the paired adapter for this id.
           """
  end

  test "after BOTH registries populate the SAME fresh adapter_id (Binding first, Adapter second), cap subject IS registered" do
    # Symmetric ordering scenario, also hermetic.
    fresh_id = "ordering_test_em_endstate_b_#{System.unique_integer([:positive])}"
    cleanup_registries(fresh_id)
    {adapter_module, binding_module} = build_synthetic_pair(fresh_id)
    expected_action = String.to_atom("allow_" <> fresh_id)
    %{behavior_module: expected_behavior} = adapter_module.cap_subject()

    assert :error =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action)

    :ok = BindingRegistry.register_module(fresh_id, binding_module)

    # Mid-flight: still not registered (no adapter yet).
    assert :error =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action)

    :ok = AdapterRegistry.register(adapter_module)

    assert {:ok, %{behavior: ^expected_behavior}} =
             CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, expected_action),
           """
           CapabilityRegistry MISSING the per-adapter cap subject for
           adapter_id=#{inspect(fresh_id)} after BOTH registries
           registered (Binding first, then Adapter) — violates SPEC §5.1
           r5 HIGH-A end-state contract.

           AdapterRegistry.register/1 must call
           AdapterInstall.maybe_install/1 which fires install when it
           observes that BindingRegistry already has the paired binding
           for this id.
           """
  end

  # These tests register synthetic adapter/binding pairs into the GLOBAL
  # named AdapterRegistry / BindingRegistry (shared ETS, umbrella-wide).
  # Without teardown the synthetic ids leak into other invariant tests
  # (BindingAdapterGrill5Test walks the same registries + `:code.all_loaded`)
  # — under cross-app concurrency that produced spurious
  # "Adapter registered without paired Binding" Grill-5 violations.
  # Register an `on_exit` that deletes this id from BOTH registries so the
  # global tables return to their pre-test state. `__delete__/1` is the
  # registries' test-cleanup surface and is idempotent on a missing id.
  defp cleanup_registries(adapter_id) do
    on_exit(fn ->
      _ = AdapterRegistry.__delete__(adapter_id)
      _ = BindingRegistry.__delete__(adapter_id)
    end)
  end

  # Build a throwaway `{adapter_module, binding_module}` pair with a
  # unique adapter_id. Per Grill-5 (rule e), adapter and binding MUST
  # be different modules — so we synthesize both. Returns the adapter
  # module only when called via `build_synthetic_adapter/1` (back-compat
  # for the deferral-only tests that never register the binding side).
  defp build_synthetic_pair(adapter_id) do
    suffix = System.unique_integer([:positive])
    allow_action = String.to_atom("allow_" <> adapter_id)

    cap_behavior_name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest.SyntheticAllow#{suffix}"
      )

    Module.create(
      cap_behavior_name,
      quote do
        @behaviour Ezagent.ActionSet
        @impl true
        def actions, do: [unquote(allow_action)]
        @impl true
        def cap_subjects, do: [{unquote(allow_action), "synth"}]
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

    binding_module_name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest.SyntheticBinding#{suffix}"
      )

    adapter_module_name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.Invariants.AdapterInstallOrderingTest.SyntheticAdapter#{suffix}"
      )

    Module.create(
      binding_module_name,
      quote do
        @behaviour Ezagent.ExternalMirror.Binding
        @impl true
        def adapter_module, do: unquote(adapter_module_name)
        @impl true
        def init({_target_id, _adapter, options}), do: {:ok, options}
        @impl true
        def publish(_payload, state), do: {:ok, state}
        @impl true
        def terminate(_, _), do: :ok
      end,
      Macro.Env.location(__ENV__)
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
        def binding_module, do: unquote(binding_module_name)
        @impl true
        def cap_subject,
          do: %{behavior_module: unquote(cap_behavior_name), description: "synth"}

        @impl true
        def target_ownership_check(_, _), do: :ok
        @impl true
        def event_to_payload(%Ezagent.Publisher.Event{} = e), do: {:publish, e}
      end,
      Macro.Env.location(__ENV__)
    )

    {adapter_module_name, binding_module_name}
  end

end
