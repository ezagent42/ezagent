defmodule Ezagent.ActionSet.SandboxColdRestartTest do
  @moduledoc """
  THE FLAGSHIP cold-restart invariant test for the Lifecycle migration —
  the reference module (`Ezagent.ActionSet.Sandbox`, SPEC §2.3B), reworked
  for V5 use-side H1 (delete-holes #200).

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6 +
  AC-4: this is the architectural-goal gate. It drives the Sandbox to
  non-trivial durable state via the H1 POINT-TO-POINT phase path
  (`EzagentActor.Signal.signal/2` → the sealed `%Signal{}` enabler →
  `handle_signal({:pty_phase, …})` → `{:set, :pty_phase, _}`), brutal-kills
  the host process (skipping graceful `deactivate`/`destroy` — §OTP
  best-effort), demand-loads the same URI via the supervisor's own
  cold-restart, and asserts:

    1. the Kind is NOT subscribed to the shared `pty:phase:` topic — a raw
       PubSub broadcast to it does NOT mutate the Kind (H1 hole deleted);
    2. the phase reaches + PERSISTS via the point-to-point Signal (the H1
       Kind path — this is the "phase still reaches + persists" gate);
    3. `state` rehydrates correctly across the crash (config_dir_path /
       template_class / pty_phase survive via the snapshot);
    4. post-restart the phase path needs NO rebuilt subscription — a fresh
       point-to-point Signal lands immediately (there is no transient to
       rebuild; Sandbox has none post-H1).

  Pre-H1 this test proved the `phase_subscription` PubSub transient was
  rebuilt on cold-load. H1 DELETED that subscription (a Kind subscribed to
  a shared broadcast topic + mutating on receipt was the hole), so the
  rebuild assertion is gone and the no-subscription negative check (1)
  takes its place.
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.Sandbox

  # Test Kind hosting the single Sandbox Lifecycle module. `{:snapshot,
  # :on_change}` so the durable `state` survives a brutal kill.
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

  # T3 (Phase B foundation): `get_slice/2` normalizes a two-container slice
  # to its flat `.state` view for production consumers. This test reads the
  # RAW two-container slice so it can match on the explicit
  # `%{state: %{...}}` / `%{transients: %{...}}` shape.
  defp raw_sandbox_slice(uri), do: Ezagent.Kind.SliceAccess.get_raw_slice(uri, :sandbox)

  defp phase_is?(uri, phase) do
    case raw_sandbox_slice(uri) do
      {:ok, %{state: %{pty_phase: ^phase}}} -> true
      _ -> false
    end
  end

  test "THE GATE — phase persists via the point-to-point Signal + rehydrates across a cold restart" do
    self_uri = uri()
    topic = "pty:phase:" <> URI.to_string(self_uri)

    # 1. Spawn fresh via the SOLE Kind-spawn entry, wait for :ready
    #    (activate has run).
    {:ok, pid1} =
      Ezagent.Kind.spawn(SandboxColdRestartKind, %{
        uri: self_uri,
        config_dir_path: "/tmp/sandbox-cold-restart",
        template_class: Enum,
        respawn_template_data: %{"cwd" => "/tmp/sandbox-cold-restart"}
      })

    wait_until(fn -> Ezagent.ReadyGate.status(self_uri) == :ready end)

    # 2. H1 NEGATIVE CHECK — the Kind is NOT subscribed to the shared
    #    `pty:phase:` topic anymore: a raw PubSub broadcast (the UI-facing
    #    dual-emit half, and the shape any same-VM injector could send)
    #    must NOT mutate the Kind's durable phase.
    :ok =
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        topic,
        {:pty_phase, self_uri, :dead, %{reason: :injected, at: 1_700_000_000_000}}
      )

    Process.sleep(150)

    refute phase_is?(self_uri, :dead),
           "raw pty:phase: PubSub broadcast mutated the Kind — the H1 subscription delete regressed"

    # 3. Drive a DURABLE state change through the H1 point-to-point path:
    #    Signal.signal/2 → sealed %Signal{} → the B2-core enabler →
    #    Sandbox.handle_signal({:pty_phase, …}) → {:set, :pty_phase, _}
    #    → persisted by the handle_info commit path.
    :ok =
      EzagentActor.Signal.signal(
        self_uri,
        {:pty_phase, self_uri, :running, %{os_pid: 4242, at: 1_700_000_000_000}}
      )

    wait_until(fn -> phase_is?(self_uri, :running) end)

    {:ok, %{state: state_before}} = raw_sandbox_slice(self_uri)

    # 4. Brutal kill — no graceful deactivate/destroy (§OTP best-effort,
    #    SPEC §6 step 3). The `:permanent` Kind is AUTO-RESTARTED by its
    #    supervisor at the same URI: init → cold-load → activate → ready.
    Process.exit(pid1, :kill)

    wait_until(
      fn ->
        case Ezagent.KindRegistry.lookup(self_uri) do
          {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(self_uri) == :ready
          _ -> false
        end
      end,
      600
    )

    {:ok, pid2} = Ezagent.KindRegistry.lookup(self_uri)
    refute pid1 == pid2

    # 5. Durable state rehydrated correctly across the crash.
    {:ok, %{state: state_after, transients: transients_after}} = raw_sandbox_slice(self_uri)

    assert state_after == state_before

    assert state_after == %{
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

    # 6. Post-H1 there is NO subscription transient to rebuild — Sandbox
    #    has no transients at all.
    assert transients_after == %{}

    # 7. The phase path is functional post-restart with NO rebuilt
    #    subscription: a fresh point-to-point Signal lands immediately.
    :ok =
      EzagentActor.Signal.signal(
        self_uri,
        {:pty_phase, self_uri, :dead, %{reason: :exit, at: 1_700_000_001_000}}
      )

    wait_until(fn -> phase_is?(self_uri, :dead) end)
  end
end
