defmodule Ezagent.Behavior.LifecycleMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.Behavior.Lifecycle`
  per SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3
  Level 1 (dispatch parity).

  Validates that the migrated `Ezagent.Behavior.Lifecycle` produces
  the same dispatch-visible outcome via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_terminate/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration.

  ## Codex r3 P2-g coverage — full dispatch path

  The dispatch-level test (`"terminate via Kind.Runtime.handle_dispatch/4"`)
  exercises the WHOLE pipeline:

      Invocation → BehaviorRegistry lookup → CapBAC →
      handle_terminate/2 → apply_effects/2 → state writeback →
      effects executor (notify_spawning_principal + schedule_termination)

  No mocks beyond the StubAgentKind module + an admin caps set.
  Result-shape parity: legacy returned `{:ok, slice, {:ok, :terminated}}`;
  the new contract MUST return the same `{:ok, :terminated}` inner
  result so consumers (`Orchestrator.Tools.terminate_worker/3`,
  `TerminalLive`) keep pattern-matching unchanged.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.Behavior.Lifecycle

  defmodule StubAgentKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :lifecycle_parity_stub
    @impl true
    def behaviors, do: [Ezagent.Behavior.Lifecycle]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubAgentKind, :terminate, Lifecycle)

    agent_uri =
      URI.parse("entity://agent/parity/cc_lifecycle-#{System.unique_integer([:positive])}")

    # Bootstrap-admin caps satisfy the dispatch's CapBAC gate at step
    # 5.5 — the `cap(:agent, Lifecycle, :terminate)` shape is covered
    # by the admin's triple-:any cap.
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    state = %{lifecycle: %{terminations: 0}}

    {:ok, agent_uri: agent_uri, admin_caps: admin_caps, state: state}
  end

  defp build_invocation(agent_uri, caps) do
    target = URI.parse("#{URI.to_string(agent_uri)}?action=lifecycle.terminate")

    %Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: URI.parse("entity://user/system/admin"), caps: caps, reply: :sync}
    }
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.Behavior.new_style?(Lifecycle)
    end

    test "__action_names__/0 lists [:terminate]" do
      assert Lifecycle.__action_names__() == [:terminate]
    end

    test "handle_terminate/2 is exported (macro invariant)" do
      assert function_exported?(Lifecycle, :handle_terminate, 2)
    end
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test "terminate via Kind.Runtime.handle_dispatch/4 — full dispatch path",
         %{agent_uri: agent_uri, admin_caps: admin_caps, state: state} do
      # FULL dispatch-path coverage (codex r3 P2-g). Exercises:
      #   - BehaviorRegistry lookup
      #   - CapBAC (admin caps satisfy the :agent/:terminate gate)
      #   - handle_terminate/2 invocation
      #   - apply_effects/2 (state mutation + effect execution)
      #   - Result lift back to legacy 3-tuple shape
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, new_state, {:ok, :terminated}, _slice_change_event} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Counter bumped via {:set, :terminations, prev+1} effect
      assert new_state.lifecycle.terminations == 1

      # The schedule_termination effect spawned a Task; give it a moment
      # to complete its 20ms sleep + DynamicSupervisor lookup. The lookup
      # returns :error here (no live Kind) — the Task path is idempotent
      # against absent URIs, so this is a clean no-op.
      Process.sleep(50)
    end

    test "result shape — legacy callers see {:ok, :terminated} inner tuple",
         %{agent_uri: agent_uri, admin_caps: admin_caps, state: state} do
      # Result-shape regression gate: `Orchestrator.Tools.terminate_worker/3`
      # + `TerminalLive` match on `{:ok, {:ok, :terminated}}` (outer
      # `:ok` is the dispatch wrapper; inner `{:ok, :terminated}` is
      # the action result). Changing the result shape would silently
      # break the LV "Terminate" button.
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, _new_state, result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert result == {:ok, :terminated}
    end

    test "counter bumps from 0 to 1 (legacy `bump(slice)` parity)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # Pre-state with counter at 5 — verifies the bump increments
      # rather than resets.
      state = %{lifecycle: %{terminations: 5}}
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.lifecycle.terminations == 6
    end

    test "counter is lazy-seeded from empty slice (legacy `Map.update/4` parity)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # The Behavior is registered after-the-fact on the Agent Kind, so
      # the runtime may hand an empty slice. The handler must seed
      # via `ctx[:read].(:terminations, 0)` and bump to 1.
      state = %{lifecycle: %{}}
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.lifecycle.terminations == 1
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Lifecycle.actions() == [:terminate]
      assert Map.has_key?(Lifecycle.interface(), :terminate)

      assert [{:terminate, desc}] = Lifecycle.cap_subjects()
      assert is_binary(desc) and desc != ""
    end

    test "required_caps/0 uses the :agent axis (Agent Kind registration)" do
      caps = Lifecycle.required_caps()

      assert %Ezagent.Capability{kind: :agent, behavior: Lifecycle, action: :terminate} =
               caps[:terminate]
    end

    test "state_slice/0 + init_slice/1 unchanged" do
      assert Lifecycle.state_slice() == :lifecycle
      assert Lifecycle.init_slice(%{}) == %{terminations: 0}
    end

    test "data_owner/1 returns :no_owner (admin-only Behavior)" do
      uri = URI.parse("entity://agent/team-alpha/cc_x")
      assert Lifecycle.data_owner(uri) == :no_owner
      assert Lifecycle.data_owner(:any) == :no_owner
    end
  end
end
