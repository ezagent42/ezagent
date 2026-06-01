defmodule Ezagent.Behavior.NpAgentColdRestartTest do
  @moduledoc """
  Phase B (2026-05-29) Lifecycle migration — THE cold-restart invariant
  gate for `Ezagent.Behavior.NpAgent` (the TRANSIENTS case, modeled on
  the reference `Ezagent.Behavior.SandboxColdRestartTest`).

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6 +
  AC-4: drives the NpAgent to a LIVE phase-topic subscription transient +
  non-trivial durable `python_phase` state, brutal-kills the host process
  (skipping graceful `deactivate`/`destroy` — §OTP best-effort),
  demand-loads the same URI via the supervisor's own cold-restart, and
  asserts:

    1. `state` rehydrated correctly (`python_phase` survived the crash via
       the snapshot).
    2. `transients` rebuilt to a LIVE equivalent — a NEW phase-topic
       subscription bound to the NEW host pid (NOT the killed
       incarnation's stale, dead pid).

  It FAILS exactly when the cold-restart bug class reappears: if the
  subscription were persisted (it would carry the dead prior pid) or if
  `activate/2`'s rebuild were deleted (transients would be empty).

  ## Why a test-only `{:snapshot, :on_change}` Kind

  The production `Ezagent.Entity.NpAgent` declares `persistence:
  :ephemeral` (np agents are throwaway + their Python subprocess can't be
  snapshotted). To exercise the cold-restart contract — which REQUIRES
  durable `state` to survive the kill — we host the unchanged `NpAgent`
  Behavior on a test-only Kind with `{:snapshot, :on_change}` (the same
  technique the reference SandboxColdRestartTest uses). The NpAgent's
  subprocess self-heal (`activate/2` step 2) is skipped here because the
  spawn args carry no `cwd` — the demand-spawn path — so the test does
  NOT require a real Python interpreter; it isolates the phase-subscription
  transient + python_phase state, which is what the gate is about.
  """

  use Ezagent.LifecycleCase

  alias Ezagent.Behavior.NpAgent

  defmodule NpAgentColdRestartKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :np_agent_cold_restart

    @impl Ezagent.Kind
    def behaviors, do: [NpAgent]

    # `{:snapshot, :on_change}` so the durable `python_phase` survives a
    # brutal kill and the phase-subscription transient is proven REBUILT
    # (not restored) on cold-load.
    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}
  end

  setup_all do
    Code.ensure_loaded!(NpAgent)
    Code.ensure_loaded!(NpAgentColdRestartKind)

    for action <- [:receive, :reset, :configure] do
      if Ezagent.BehaviorRegistry.lookup(NpAgentColdRestartKind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(NpAgentColdRestartKind, action, NpAgent)
      end
    end

    :ok
  end

  defp uri do
    URI.new!("system://np_agent_cold_restart/inst-#{System.unique_integer([:positive])}")
  end

  test "THE GATE — cold restart rehydrates python_phase + REBUILDS the phase subscription transient" do
    self_uri = uri()
    topic = "pty:phase:" <> URI.to_string(self_uri)

    result =
      assert_transients_rebuilt(
        %{
          kind: NpAgentColdRestartKind,
          uri: self_uri,
          slice_key: :np_agent,
          # No :cwd → demand-spawn path: activate/2 rebuilds the phase
          # subscription transient but skips the (no-Python) subprocess
          # self-heal, so the gate needs no real interpreter.
          spawn_args: %{}
        },
        fn live_uri ->
          live_topic = "pty:phase:" <> URI.to_string(live_uri)

          # Drive a DURABLE state change through the LIVE transient: the
          # subscription (rebuilt in activate/2) delivers this broadcast
          # to handle_signal/2, which emits {:set, :python_phase, :running}.
          # This proves the transient is functional AND seeds durable
          # state that must survive the restart.
          :ok =
            Phoenix.PubSub.broadcast(
              EzagentCore.PubSub,
              live_topic,
              {:pty_phase, live_uri, :running, %{os_pid: 4242, at: 1_700_000_000_000}}
            )

          # T3: RAW read of the two-container slice.
          wait_until(fn ->
            case Ezagent.Kind.get_raw_slice(live_uri, :np_agent) do
              {:ok, %{state: %{python_phase: :running}}} -> true
              _ -> false
            end
          end)
        end
      )

    # ---- 1. Durable state rehydrated correctly across the crash. ----
    assert result.after.state.python_phase == :running

    # ---- 2. Transient REBUILT to a live equivalent. ----
    assert %{phase_subscription: %{topic: ^topic, subscriber: new_sub}} =
             result.after.transients

    # The subscriber is the NEW host Kind.Server pid (the cold-restart
    # incarnation), not the killed one. THIS is the rebuild proof.
    {_pid1, pid2} = result.pids
    assert new_sub == pid2
    assert Process.alive?(new_sub)

    %{phase_subscription: %{subscriber: old_sub}} = result.before.transients
    refute new_sub == old_sub

    # ---- 3. The rebuilt subscription is FUNCTIONAL post-restart. ----
    :ok =
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        topic,
        {:pty_phase, self_uri, :dead, %{reason: :exit, at: 1_700_000_001_000}}
      )

    wait_until(fn ->
      case Ezagent.Kind.get_raw_slice(self_uri, :np_agent) do
        {:ok, %{state: %{python_phase: :dead}}} -> true
        _ -> false
      end
    end)

    {:ok, %{state: %{python_phase: final_phase}}} =
      Ezagent.Kind.get_raw_slice(self_uri, :np_agent)

    assert final_phase == :dead
  end
end
