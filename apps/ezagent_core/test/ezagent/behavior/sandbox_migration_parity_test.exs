defmodule Ezagent.ActionSet.SandboxMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.ActionSet.Sandbox` per
  SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3 Level 1
  (dispatch parity).

  Validates that the migrated `Ezagent.ActionSet.Sandbox` produces the
  same dispatch-visible outcomes via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_<action>/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration
  across the three dispatchable actions:

    - `:read`        — read-only; gated by process-dict destroyed?
    - `:update_config`  — slice mutations via `{:set, key, value}` effects
    - `:destroy`     — terminal action with FS cleanup + termination

  ## Codex r3 P2-g coverage — full dispatch path

  The `:read` + `:update_config` dispatch-path tests exercise the WHOLE
  pipeline (`Invocation → BehaviorRegistry → CapBAC → handler →
  effects → state writeback`). The `:destroy` action's full path is
  exercised already by integration tests; here we drive the handler
  directly for ordering-invariant coverage (process-dict gate must
  be set BEFORE cleanup, see codex PR2 round-1 HIGH-2).

  ## Existing semantic coverage

  Pre-migration semantic coverage lives in `sandbox_test.exs` which
  was retrofitted with an `invoke_via_new_contract/4` legacy-shape
  adapter (see that test file's helper moduledoc). This parity test
  ADDS the Level 1 dispatch-path coverage on top — codex r3 P2-g
  flagged "parity tests do not exercise the full
  Kind.Runtime.handle_dispatch/4 path" as the gap that needs closing.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.ActionSet.Sandbox

  defmodule StubAgentKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :sandbox_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Sandbox]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubAgentKind, :read, Sandbox)
    :ok = BehaviorRegistry.register(StubAgentKind, :update_config, Sandbox)
    :ok = BehaviorRegistry.register(StubAgentKind, :destroy, Sandbox)

    agent_uri =
      Ezagent.URI.new!("entity://parity/agent/cc_sandbox-#{System.unique_integer([:positive])}")

    admin_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    # Lifecycle two-container slice — `init_slice/1` now returns
    # `%{state: ..., transients: %{}}` (SPEC §2.1). `create/1` (run on
    # first-ever existence; here the rescued no-DB path runs it) builds
    # the durable `state` fields.
    state = %{sandbox: Sandbox.init_slice(%{})}

    {:ok, agent_uri: agent_uri, admin_caps: admin_caps, state: state}
  end

  defp build_invocation(agent_uri, action, args, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=sandbox.#{action}")

    %Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: Ezagent.URI.new!("entity://system/user/admin"), caps: caps, reply: :sync}
    }
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.ActionSet.new_style?(Sandbox)
    end

    test "__action_names__/0 lists [:read, :update_config, :destroy]" do
      assert Enum.sort(Sandbox.__action_names__()) == [:destroy, :read, :update_config]
    end

    test "every action has a handler exported" do
      for action <- [:read, :update_config, :destroy] do
        handler = String.to_atom("handle_#{action}")

        assert function_exported?(Sandbox, handler, 2),
               "missing handler #{handler}/2 for action :#{action}"
      end
    end
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test ":read via Kind.Runtime.handle_dispatch/4 — full dispatch path",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # FULL dispatch-path coverage (codex r3 P2-g). Lifecycle
      # two-container slice — the durable fields live under `:state`.
      state = %{
        sandbox: %{
          state: %{
            config_dir_path: "/tmp/x",
            template_class: SomeMod,
            respawn_template_data: %{"cwd" => "/tmp/x"},
            pty_phase: :running
          },
          transients: %{}
        }
      }

      inv = build_invocation(agent_uri, :read, %{}, admin_caps)

      assert {:ok, new_state, result, _slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Read-only: slice unchanged.
      assert new_state == state

      # Result mirrors the slice fields.
      assert result.config_dir_path == "/tmp/x"
      assert result.template_class == SomeMod
      assert result.respawn_template_data == %{"cwd" => "/tmp/x"}
      assert result.pty_phase == :running
    end

    test ":read on cleared state returns nils (destroyed?-gate REMOVED — SPEC §2.3B)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # SPEC §2.3B: the process-dict `destroyed?` gate DISAPPEARS under
      # Lifecycle — destroyed = ABSENCE of state (the destroy path clears
      # `state` + terminates the process). A `:read` against a CLEARED
      # (destroyed-then-but-still-momentarily-alive) state is no longer
      # special-cased to `{:error, :destroyed}`; it reads the cleared
      # fields as nils. The race the gate guarded is closed by the
      # destroy path terminating the process (no live process to dispatch
      # a stale read to).
      cleared = %{
        sandbox: %{
          state: %{
            config_dir_path: nil,
            template_class: nil,
            respawn_template_data: nil,
            pty_phase: nil
          },
          transients: %{}
        }
      }

      inv = build_invocation(agent_uri, :read, %{}, admin_caps)

      assert {:ok, _new_state, result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, cleared, StubAgentKind, agent_uri)

      assert result.config_dir_path == nil
      assert result.template_class == nil
    end

    test ":update_config via Kind.Runtime — slice mutates via :set effects",
         %{agent_uri: agent_uri, admin_caps: admin_caps, state: state} do
      args = %{
        config_dir_path: "/tmp/agent-z",
        template_class: MyClass,
        respawn_template_data: %{"cwd" => "/tmp/agent-z"}
      }

      inv = build_invocation(agent_uri, :update_config, args, admin_caps)

      assert {:ok, new_state, result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Slice mutated through the {:set, key, value} effects — the
      # durable fields live under the Lifecycle `:state` container.
      assert new_state.sandbox.state.config_dir_path == "/tmp/agent-z"
      assert new_state.sandbox.state.template_class == MyClass
      assert new_state.sandbox.state.respawn_template_data == %{"cwd" => "/tmp/agent-z"}

      # Result mirrors what was written.
      assert result.config_dir_path == "/tmp/agent-z"
      assert result.template_class == MyClass
      assert result.respawn_template_data == %{"cwd" => "/tmp/agent-z"}
    end

    test ":update_config is NOT gated by a destroyed flag (gate REMOVED — SPEC §2.3B)",
         %{agent_uri: agent_uri, admin_caps: admin_caps, state: state} do
      # SPEC §2.3B: the process-dict `destroyed?` gate is gone. A
      # update_config is no longer rejected with `{:error, :destroyed}`; the
      # destroy path instead clears `state` + terminates the process, so
      # there is no live process to race a write against post-destroy.
      args = %{config_dir_path: "/new/path", template_class: NewMod}
      inv = build_invocation(agent_uri, :update_config, args, admin_caps)

      assert {:ok, new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.sandbox.state.config_dir_path == "/new/path"
      assert new_state.sandbox.state.template_class == NewMod
    end

    test ":update_config — invalid config_dir_path → {:error, _}",
         %{agent_uri: agent_uri, admin_caps: admin_caps, state: state} do
      args = %{config_dir_path: 12345, template_class: nil}
      inv = build_invocation(agent_uri, :update_config, args, admin_caps)

      # The Kind.Runtime's `validate_args/3` step (5.7) catches type
      # mismatches against the action's `args:` schema BEFORE the
      # handler runs, so the dispatch path surfaces an `:invalid_args`
      # tuple rather than the handler's `{:invalid_config_dir_path,
      # 12345}` validator. Both are `{:error, _}` from the caller's
      # POV — direct handler-level coverage of the handler's own
      # validator lives in `sandbox_test.exs` via the
      # `invoke_via_new_contract/4` helper.
      assert {:error, {:invalid_args, _}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)
    end

    test ":update_config — without respawn_template_data leaves slice's existing value",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      state = %{
        sandbox: %{
          state: %{
            config_dir_path: nil,
            template_class: nil,
            respawn_template_data: %{"prior" => "value"},
            pty_phase: nil
          },
          transients: %{}
        }
      }

      # Args omits :respawn_template_data → handler must NOT touch it.
      args = %{config_dir_path: "/tmp/x", template_class: MyClass}
      inv = build_invocation(agent_uri, :update_config, args, admin_caps)

      assert {:ok, new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Prior respawn_template_data preserved.
      assert new_state.sandbox.state.respawn_template_data == %{"prior" => "value"}
      # The other two fields ARE mutated.
      assert new_state.sandbox.state.config_dir_path == "/tmp/x"
      assert new_state.sandbox.state.template_class == MyClass
    end
  end

  describe ":destroy effect shape (cleanup success → clear all 4 fields)" do
    test ":destroy clears every state field via :set effects when FS cleanup succeeds" do
      # SPEC §2.3B: the process-dict `destroyed?` gate is GONE (destroyed
      # = absence of state, enforced by the destroy path clearing state +
      # terminating the process). The FS-cleanup-then-clear logic is
      # preserved: on cleanup `:ok` the handler emits `{:set, field, nil}`
      # for all four durable fields so the `:on_terminate` snapshot saves
      # cleared state and a re-spawn rehydrates as if fresh.
      defmodule SuccessTC do
        @moduledoc false
        @doc false
        def destroy_config_dir(_uri, _path), do: :ok
      end

      slice_state = %{
        config_dir_path: "/tmp/x",
        template_class: SuccessTC,
        respawn_template_data: nil,
        pty_phase: nil
      }

      read = fn key, default -> Map.get(slice_state, key, default) end

      ctx = %{
        self_uri:
          Ezagent.URI.new!("entity://parity/agent/cc_gate-#{System.unique_integer([:positive])}"),
        kind_module: SuccessTC,
        read: read
      }

      # Direct handler call — apply effects to verify shape.
      assert {:ok, result, effects} = Sandbox.handle_destroy(%{}, ctx)

      assert result.destroyed == true
      assert result.cleanup == :ok

      # cleanup-success case: clear all 4 fields + a {:effect, ...}
      # schedule_termination for the Task spawn.
      set_keys =
        for {:set, k, _v} <- effects, do: k

      assert Enum.sort(set_keys) ==
               [:config_dir_path, :pty_phase, :respawn_template_data, :template_class]

      assert Enum.any?(effects, fn
               {:effect, {Sandbox, :schedule_termination}, _args} -> true
               _ -> false
             end)
    end

    test ":destroy preserves slice fields when cleanup fails (codex round-4 HIGH-2)" do
      defmodule FailingTC do
        @moduledoc false
        @doc false
        def destroy_config_dir(_uri, _path), do: {:error, :permission_denied}
      end

      slice = %{
        config_dir_path: "/tmp/x",
        template_class: FailingTC,
        respawn_template_data: %{"k" => "v"},
        pty_phase: :running
      }

      read = fn key, default -> Map.get(slice, key, default) end

      ctx = %{
        self_uri:
          Ezagent.URI.new!(
            "entity://parity/agent/cc_failing-#{System.unique_integer([:positive])}"
          ),
        kind_module: FailingTC,
        read: read
      }

      assert {:ok, result, effects} = Sandbox.handle_destroy(%{}, ctx)

      # destroyed: true reports the action's terminal status; cleanup
      # carries the actual cleanup error for observability.
      assert result.destroyed == true
      assert match?({:error, :permission_denied}, result.cleanup)

      # FAILURE branch — NO :set effects (slice preserved).
      set_effects = for {:set, k, _v} <- effects, do: k
      assert set_effects == []

      # Termination still scheduled (process MUST go away even when
      # cleanup fails — codex round-4 HIGH-2).
      assert Enum.any?(effects, fn
               {:effect, {Sandbox, :schedule_termination}, _args} -> true
               _ -> false
             end)
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Enum.sort(Sandbox.actions()) == [:destroy, :read, :update_config]
      iface = Sandbox.interface()

      for action <- [:read, :update_config, :destroy] do
        assert Map.has_key?(iface, action), "interface missing #{action}"
      end

      subjects = Sandbox.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(subjects) == [:destroy, :read, :update_config]
    end

    test "required_caps/0 uses the :agent axis (Agent Kind registration)" do
      caps = Sandbox.required_caps()

      for action <- [:read, :update_config, :destroy] do
        assert %Ezagent.Capability{kind: :agent, behavior: Sandbox, action: ^action} =
                 caps[action]
      end
    end

    test "state_slice/0 unchanged; init_slice/1 builds the two-container shape" do
      # state_slice is auto-derived by the Lifecycle macro from the
      # module's last segment (`Sandbox` → `:sandbox`) — the SAME key the
      # pre-Lifecycle module declared, so snapshot compatibility holds
      # with no explicit override (SPEC §3 / §7 OQ-7).
      assert Sandbox.state_slice() == :sandbox

      # init_slice/1 now returns `%{state: ..., transients: %{}}` (SPEC
      # §2.1). The durable fields `create/1` builds live under `:state`;
      # `transients` always starts empty (activate/2 fills it).
      assert Sandbox.init_slice(%{}) ==
               %{
                 state: %{
                   config_dir_path: nil,
                   template_class: nil,
                   respawn_template_data: nil,
                   pty_phase: nil,
                   passive: false,
                   recipe: nil
                 },
                 transients: %{}
               }
    end

    test "data_owner/1 — entity URI returns the canonical instance URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      assert %URI{} = Sandbox.data_owner(uri)
    end
  end

  describe "activate/2 (boot hook — folds in the old post_init/handle_continue — SPEC §5/§10-R1)" do
    test "post_init/2 schedules the unified :ezagent_activate continuation (macro-emitted)" do
      # The pre-Lifecycle module returned `{:continue, {:setup_phase_tracking,
      # ...}}`; the Lifecycle macro now emits `{:continue, :ezagent_activate}`
      # which runs the author's `activate/2`. The subscribe + ensure-subprocess
      # logic moved INTO activate/2 (both pre-`:ready`, no self-deferral).
      assert {:continue, :ezagent_activate} = Sandbox.post_init(%{}, %{})
    end

    test "activate/2 rebuilds the phase-subscription transient (subscribe-only path)" do
      # nil template_class → no subprocess re-spawn; activate still
      # rebuilds the phase-topic subscription transient on every start.
      state = %{
        config_dir_path: nil,
        template_class: nil,
        respawn_template_data: nil,
        pty_phase: nil
      }

      ctx = %{
        self_uri:
          Ezagent.URI.new!("entity://parity/agent/cc_x-#{System.unique_integer([:positive])}"),
        kind_module: StubAgentKind
      }

      assert {:ok, transients} = Sandbox.activate(state, ctx)
      assert %{phase_subscription: %{topic: topic, subscriber: sub}} = transients
      assert is_binary(topic)
      assert sub == self()
    end
  end
end
