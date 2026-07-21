defmodule Ezagent.ActionSet.TerminableMigrationParityTest do
  @moduledoc """
  Migration parity test for `Ezagent.ActionSet.Terminable` (renamed from
  `Ezagent.ActionSet.Lifecycle` in the Phase B Lifecycle migration, SPEC
  `2026-05-29-lifecycle-hooks-design.md` §9 OQ-6). Originally a Phase 2.5
  dispatch-parity test per SPEC `2026-05-28-router-behavior-kind-architecture.md`
  §7.3 Level 1.

  Validates that `Ezagent.ActionSet.Terminable` produces the same
  dispatch-visible outcome via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_terminate/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration —
  and now ALSO that the `use Ezagent.Lifecycle` conversion preserves the
  persisted `:lifecycle` slice key + the `%{terminations: 0}` persistent
  state.

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

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Capability, Invocation}
  alias Ezagent.ActionSet.Terminable

  defmodule StubAgentKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :terminable_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Terminable]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubAgentKind, :terminate, Terminable)

    agent_uri =
      Ezagent.URI.new!(
        "entity://parity/agent/cc_terminable-#{System.unique_integer([:positive])}"
      )

    _authority = install_test_authority!(agent_uri, StubAgentKind.type_name())
    admin_caps = :target_signed

    state = %{lifecycle: %{terminations: 0}}

    {:ok, agent_uri: agent_uri, admin_caps: admin_caps, state: state}
  end

  defp build_invocation(agent_uri, caps) do
    # Action namespace stays `lifecycle.terminate` post-rename — a cosmetic
    # dispatch label; the runtime resolves the handler by the `:terminate`
    # action atom (via BehaviorRegistry), not by the `lifecycle.` prefix.
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=lifecycle.terminate")

    presenter = Ezagent.URI.user(:system, :admin)
    authority = Process.get({Ezagent.Cap.Authority, :current})

    requested =
      Capability.cap(
        :agent,
        Terminable,
        :terminate,
        agent_uri,
        Capability.workspace_of(agent_uri)
      )

    signed = authority_signed_cap!(authority, presenter, requested)

    assert caps == :target_signed

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new([signed]),
        reply: :sync
      }
    }
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.ActionSet.new_style?(Terminable)
    end

    test "__action_names__/0 lists [:terminate]" do
      assert Terminable.__action_names__() == [:terminate]
    end

    test "handle_terminate/2 is exported (macro invariant)" do
      assert function_exported?(Terminable, :handle_terminate, 2)
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

      assert {:ok, new_state, {:ok, :terminated}, _slice_change_event, _deferred} =
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

      assert {:ok, _new_state, result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert result == {:ok, :terminated}
    end

    test "counter bumps from 0 to 1 (legacy `bump(slice)` parity)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # Pre-state with counter at 5 — verifies the bump increments
      # rather than resets.
      state = %{lifecycle: %{terminations: 5}}
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.lifecycle.terminations == 6
    end

    test "counter is lazy-seeded from empty slice (legacy `Map.update/4` parity)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # The Behavior is registered after-the-fact on the Agent Kind, so
      # the runtime may hand an empty slice. The handler must seed
      # via `ctx.read.(:terminations, 0)` and bump to 1.
      state = %{lifecycle: %{}}
      inv = build_invocation(agent_uri, admin_caps)

      assert {:ok, new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.lifecycle.terminations == 1
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Terminable.actions() == [:terminate]
      assert Map.has_key?(Terminable.interface(), :terminate)

      assert [{:terminate, desc}] = Terminable.cap_subjects()
      assert is_binary(desc) and desc != ""
    end

    test "required_caps/0 uses the :agent axis (Agent Kind registration)" do
      caps = Terminable.required_caps()

      assert %Ezagent.Capability{kind: :agent, behavior: Terminable, action: :terminate} =
               caps[:terminate]
    end

    test "state_slice/0 preserves the `:lifecycle` snapshot-compat key" do
      # Lifecycle migration: the slice key MUST stay `:lifecycle` (via the
      # `state_slice: :lifecycle` override) — NOT the module-name-derived
      # `:terminable` — so existing `:lifecycle` snapshot slices survive.
      assert Terminable.state_slice() == :lifecycle
    end

    test "create/1 builds the persistent `%{terminations: 0}` state (was init_slice/1)" do
      # Under `use Ezagent.Lifecycle`, the persistent-state builder is
      # `create/1`; `init_slice/1` is now the macro-emitted two-container
      # wrapper. Assert BOTH: create returns the persistent map, and the
      # engine-facing init_slice wraps it under the `:state` sub-key with
      # an empty `:transients` container.
      assert Terminable.create(%{}) == {:ok, %{terminations: 0}}
      assert Terminable.init_slice(%{}) == %{state: %{terminations: 0}, transients: %{}}
    end

    test "data_owner/1 returns :no_owner (admin-only Behavior)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      assert Terminable.data_owner(uri) == :no_owner
      assert Terminable.data_owner(:any) == :no_owner
    end
  end
end
