defmodule Ezagent.ActionSet.SandboxColdRestartTest do
  @moduledoc """
  THE FLAGSHIP cold-restart invariant test for the Lifecycle migration —
  the reference TRANSIENTS module (`Ezagent.ActionSet.Sandbox`, SPEC §2.3B).

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6 +
  AC-4: this is the architectural-goal gate. It drives the Sandbox to a
  LIVE phase-topic subscription transient + non-trivial durable state,
  brutal-kills the host process (skipping graceful `deactivate`/`destroy`
  — §OTP best-effort), demand-loads the same URI via the supervisor's own
  cold-restart, and asserts:

    1. `state` rehydrated correctly (config_dir_path / template_class /
       pty_phase survived the crash via the snapshot).
    2. `transients` rebuilt to a LIVE equivalent — a NEW phase-topic
       subscription bound to the NEW host pid (NOT the killed
       incarnation's stale, dead pid).

  It FAILS exactly when the cold-restart bug class reappears: if the
  subscription were persisted (it would carry the dead prior pid) or if
  `activate/2`'s rebuild were deleted (transients would be empty).
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.Sandbox

  # Test Kind hosting the single Sandbox Lifecycle module. `{:snapshot,
  # :on_change}` so the durable `state` survives a brutal kill and the
  # transient is proven REBUILT (not restored) on cold-load.
  defmodule SandboxColdRestartKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :sandbox_cold_restart

    @impl Ezagent.Kind
    def behaviors, do: [Sandbox]

    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}

    # P6 cold-restart determinism: isolate THE GATE Kind's kill→restart
    # from the shared `Ezagent.KindSupervisor`'s restart-intensity
    # exhaustion — see `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`.
    @impl Ezagent.Kind
    def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
  end

  setup_all do
    Code.ensure_loaded!(Sandbox)
    Code.ensure_loaded!(SandboxColdRestartKind)

    # Register the Sandbox actions for this test-only Kind so dispatch can
    # resolve them (production Kinds register at app boot). Idempotent.
    for action <- [:read, :update_config, :destroy] do
      if Ezagent.BehaviorRegistry.lookup(SandboxColdRestartKind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(SandboxColdRestartKind, action, Sandbox)
      end
    end

    :ok
  end

  defp uri do
    URI.new!("system://sandbox_cold_restart/inst-#{System.unique_integer([:positive])}")
  end

  test "THE GATE — cold restart rehydrates state + REBUILDS the phase subscription transient" do
    self_uri = uri()
    topic = "pty:phase:" <> URI.to_string(self_uri)

    result =
      assert_transients_rebuilt(
        %{
          kind: SandboxColdRestartKind,
          uri: self_uri,
          slice_key: :sandbox,
          # create/1 reads these durable fields from the spawn args. They
          # must survive the brutal kill via the snapshot.
          spawn_args: %{
            config_dir_path: "/tmp/sandbox-cold-restart",
            template_class: Enum,
            respawn_template_data: %{"cwd" => "/tmp/sandbox-cold-restart"}
          }
        },
        fn live_uri ->
          live_topic = "pty:phase:" <> URI.to_string(live_uri)

          # Drive a DURABLE state change through the LIVE transient: the
          # subscription (rebuilt in activate/2) delivers this broadcast
          # to handle_signal/2, which emits {:set, :pty_phase, :running}.
          # This proves the transient is functional AND seeds durable
          # state that must survive the restart.
          :ok =
            Phoenix.PubSub.broadcast(
              EzagentCore.PubSub,
              live_topic,
              {:pty_phase, live_uri, :running, %{os_pid: 4242, at: 1_700_000_000_000}}
            )

          # Wait for the signal to land + commit (pty_phase mirrors the
          # broadcast in the durable state container).
          #
          # T3 (Phase B foundation): `get_slice/2` now normalizes a
          # two-container slice to its flat `.state` view for production
          # consumers. This test reads the RAW two-container slice so it can
          # match on the explicit `%{state: %{...}}` shape.
          wait_until(fn ->
            case Ezagent.Kind.SliceAccess.get_raw_slice(live_uri, :sandbox) do
              {:ok, %{state: %{pty_phase: :running}}} -> true
              _ -> false
            end
          end)
        end
      )

    # ---- 1. Durable state rehydrated correctly across the crash. ----
    assert result.after.state == %{
             config_dir_path: "/tmp/sandbox-cold-restart",
             template_class: Enum,
             respawn_template_data: %{"cwd" => "/tmp/sandbox-cold-restart"},
             pty_phase: :running,
             # RF-5a/RF-6 durable passive marker — rehydrated false (principal)
             # for a non-role agent across the crash.
             passive: false,
             # RF-7 durable role NAME — nil (no role) for this non-role agent.
             recipe: nil
           }

    # ---- 2. Transient REBUILT to a live equivalent. ----
    # The phase-subscription transient exists after the restart.
    assert %{phase_subscription: %{topic: ^topic, subscriber: new_sub}} =
             result.after.transients

    # The subscriber is the NEW host Kind.Server pid (the cold-restart
    # incarnation), not the killed one. THIS is the rebuild proof.
    {_pid1, pid2} = result.pids
    assert new_sub == pid2
    assert Process.alive?(new_sub)

    # The prior incarnation's subscription carried the OLD (now dead) pid;
    # the rebuilt one carries a DIFFERENT live pid. A persisted-then-
    # rehydrated transient would have kept the stale pid — the cold-restart
    # bug class. (assert_transients_rebuilt also enforces non-empty
    # transients + state parity above.)
    %{phase_subscription: %{subscriber: old_sub}} = result.before.transients
    refute new_sub == old_sub

    # ---- 3. The rebuilt subscription is FUNCTIONAL post-restart. ----
    # Broadcast a fresh phase to the live topic; the rebuilt subscription
    # must deliver it → handle_signal → durable pty_phase update. This
    # proves the new subscription is actually bound (not just a recorded
    # map), closing the "looks rebuilt but isn't wired" gap.
    :ok =
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        topic,
        {:pty_phase, self_uri, :dead, %{reason: :exit, at: 1_700_000_001_000}}
      )

    wait_until(fn ->
      # T3: RAW read — match on the explicit two-container shape (see note above).
      case Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :sandbox) do
        {:ok, %{state: %{pty_phase: :dead}}} -> true
        _ -> false
      end
    end)

    {:ok, %{state: %{pty_phase: final_phase}}} = Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :sandbox)
    assert final_phase == :dead
  end
end
