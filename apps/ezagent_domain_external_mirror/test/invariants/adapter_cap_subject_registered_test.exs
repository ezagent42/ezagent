defmodule Ezagent.ExternalMirror.Invariants.AdapterCapSubjectRegisteredTest do
  @moduledoc """
  PR-EM-FINAL invariant 2.

  SPEC §4.2 Check 2 + §5.1 cap_subject contract: every adapter
  declared via `Plugin.adapters/0` MUST have its per-adapter cap
  subject (`adapter.cap_subject().behavior_module`) registered in
  `Ezagent.CapabilityRegistry` against `Ezagent.Entity.Session` with
  the action atom `:"allow_<adapter_id>"`.

  Without this registration, the bind facade's Check 2 cannot
  authorize the per-adapter cap — `Ezagent.Capability.matches?/2` has
  no way to know the cap shape exists, and grants/lookups would not
  surface in admin LV cap pickers.

  ## History

  PR-EM-3 round-2 HIGH-3: pre-fix, the cap-subject registration ran
  once at `Application.start/2` walking `AdapterRegistry.list/0` —
  but plugins boot LATER (chat depends on external_mirror; plugins
  depend on chat), so the boot-time list was empty and ZERO
  cap subjects were registered. The fix moved registration to
  `AdapterRegistry.register/1` (via `AdapterInstall.install/1`) so it
  fires the moment any adapter lands in the registry, regardless of
  boot order.

  This invariant test asserts the END STATE: for every adapter in
  the registry, the cap shape exists.

  ## Asserts a populated environment

  The test registers `MockAdapter` in `setup_all` so the invariant
  walks at least one pair. Adding more adapters (production plugins)
  to the test env only EXPANDS the check; never weakens it.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{
    CapabilityRegistry,
    ExternalMirror.AdapterRegistry,
    ExternalMirror.BindingRegistry
  }

  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

  setup_all do
    # Both register paths fire `AdapterInstall.maybe_install/_`; we need
    # BOTH registries populated so the install path runs (it's gated on
    # the symmetric BindingRegistry check per codex r5 HIGH-A fix).
    _ = AdapterRegistry.register(MockAdapter)
    _ = BindingRegistry.register_module("mock_em", MockBinding)
    :ok
  end

  test "every adapter in AdapterRegistry has its cap_subject registered against Session" do
    adapters = AdapterRegistry.list()

    # Walk every adapter and assert its cap_subject's behavior_module is
    # known to the CapabilityRegistry as a valid `(Session, :allow_<id>,
    # behavior_module)` triple. `CapabilityRegistry.list_grantable/0` is
    # the source of truth — it returns the maps populated by `register/3`
    # (see `apps/ezagent_core/lib/ezagent/capability_registry.ex`).
    registry_entries = CapabilityRegistry.list_grantable()

    for %{id: adapter_id, module: adapter_module} <- adapters do
      %{behavior_module: behavior_module} = adapter_module.cap_subject()
      expected_action = String.to_existing_atom("allow_" <> adapter_id)

      match =
        Enum.any?(registry_entries, fn entry ->
          entry_matches?(entry, Ezagent.Entity.Session, expected_action, behavior_module)
        end)

      assert match,
             """
             Adapter #{inspect(adapter_module)} (id=#{inspect(adapter_id)})
             has cap_subject.behavior_module = #{inspect(behavior_module)}
             but CapabilityRegistry contains NO matching
             (Ezagent.Entity.Session, #{inspect(expected_action)},
             #{inspect(behavior_module)}) triple.

             Per SPEC §5.1, `AdapterRegistry.register/1` must fire
             `AdapterInstall.maybe_install/1` which calls
             `CapabilityRegistry.register/3` with this triple — without
             it, the bind facade's Check 2 cannot authorize the cap.

             This was the PR-EM-3 round-2 HIGH-3 bug. The invariant
             guards against regression.

             Current CapabilityRegistry entries (#{length(registry_entries)} total):
             #{inspect(registry_entries, limit: :infinity, pretty: true)}
             """
    end
  end

  # CapabilityRegistry.list/0 returns maps of shape
  # %{kind: <Kind module>, action: <atom>, behavior: <Behavior module>, ...}
  # (See `apps/ezagent_core/lib/ezagent/capability_registry.ex`.) We
  # match on `kind` AND `action` AND `behavior` — three-way agreement
  # exactly mirrors the `register/3` call shape.
  defp entry_matches?(entry, kind, action, behavior) do
    Map.get(entry, :kind) == kind and
      Map.get(entry, :action) == action and
      Map.get(entry, :behavior) == behavior
  end
end
