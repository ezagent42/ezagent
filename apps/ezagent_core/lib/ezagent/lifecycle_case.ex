defmodule Ezagent.LifecycleCase do
  @moduledoc """
  Reusable ExUnit case template + the cold-restart invariant helper for
  the Lifecycle API (SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`
  §6).

  Builds on `EzagentCore.DataCase` (SQL sandbox) and adds
  `assert_transients_rebuilt/2` — the architectural-goal gate that FAILS
  exactly when the cold-restart bug class reappears (a transient that got
  persisted, or an `activate/2` rebuild that was deleted).

  ## Why this lives in `lib/` (T2 — Phase B foundation)

  It is an `ExUnit.CaseTemplate` and therefore looks like test code, but
  it is deliberately in `lib/` (NOT `test/support/`) — EXACTLY the
  convention `EzagentCore.DataCase` (`lib/ezagent_core/data_case.ex`)
  already uses. `test/support/` is only on the OWNING app's elixirc path
  (`elixirc_paths(:test)` = `["lib", "test/support"]`), so a helper there
  is invisible to the plugin / domain test suites (curl / feishu / np,
  domain_instance_message / identity / …) that must `use Ezagent.LifecycleCase` to
  assert `assert_transients_rebuilt/2` on their converted modules.
  Compiling it into `ezagent_core/lib` puts it on every dependent app's
  compile path (those apps already depend on `:ezagent_core` and
  `use EzagentCore.DataCase` cross-app today). `CaseTemplate` compiles
  cleanly in all envs — `ExUnit` ships with Elixir and is always loadable
  — so it adds no prod runtime cost beyond a never-instantiated module,
  the same trade-off `DataCase` accepts.

  ## Phase A status

  `assert_transients_rebuilt/2` is implemented (not stubbed) for the
  single-Lifecycle-slice case the Phase A fixture needs. Phase B widens
  the four named historical restart tests (session-members,
  orchestrator-MCP, codex-bridge, AgentLineage) onto it, and the plugin /
  domain batches import it cross-app via the `lib/` relocation above.
  """

  use ExUnit.CaseTemplate

  @doc """
  Registered name of the dedicated `DynamicSupervisor` that hosts
  cold-restart GATE test Kinds, isolating them from the shared
  `Ezagent.KindSupervisor`. GATE Kinds opt in with
  `def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()`. See
  `ensure_gate_supervisor!/0` for the full rationale (P6 determinism).
  """
  @gate_supervisor Ezagent.LifecycleCase.GateSupervisor
  def gate_supervisor, do: @gate_supervisor

  using do
    quote do
      use EzagentCore.DataCase, async: false

      import Ezagent.LifecycleCase

      alias Ezagent.KindRegistry

      # P6 cold-restart determinism (remediation §3 C-D / §1 P6). Ensure
      # the dedicated gate supervisor is running before any GATE test
      # spawns under it. Idempotent; started once per BEAM and reused.
      setup do
        Ezagent.LifecycleCase.ensure_gate_supervisor!()
        :ok
      end
    end
  end

  @doc """
  Idempotently start `Ezagent.LifecycleCase.GateSupervisor`, the
  dedicated `DynamicSupervisor` for cold-restart GATE test Kinds.

  ## Why a dedicated supervisor (P6 — the residual restart-intensity flake)

  The cold-restart GATE tests (`SandboxColdRestartTest`,
  `TerminableColdLoadTest`, `PtyColdRestartTest`, `LifecycleTest "THE
  GATE"`) `Process.exit(pid, :kill)` a `:snapshot` Kind and rely on the
  OTHER end of the contract: the OTP supervisor AUTO-RESTARTS a new pid
  that cold-loads from `kind_snapshots`. By default a Kind with no
  `supervisor/0` spawns under the SHARED `Ezagent.KindSupervisor`
  (`max_restarts: 3, max_seconds: 5`).

  In the full concurrent umbrella run that shared supervisor is also the
  host of dozens of OTHER test Kinds. When a wave of those crash inside a
  5-second window — the inherent residue of `Ecto.Adapters.SQL.Sandbox`
  owner-exit (a late PubSub `handle_info` snapshot-write after the owning
  test's connection is reclaimed; the `EzagentCore.DataCase` drain is
  best-effort and cannot catch a delivery that lands post-drain) — the
  shared `KindSupervisor` exceeds its restart intensity and **terminates
  itself**, to be restarted EMPTY by its parent. The GATE's
  deliberately-killed Kind is collateral: it is never restarted, so
  `KindRegistry.lookup/1` stays `:error` and the test's `wait_until`
  flunks. (Diagnosed live: at failure time the test process can still
  read the DB — shared mode is fine — but `KindSupervisor` is alive with
  `active = 0` children, i.e. it was bounced and came back empty.)

  This is the SAME P6 test-isolation class as the DB-read flake fixed in
  `EzagentCore.DataCase.start_owner_stable!/1`, one layer up: there the
  victim was the restart's first DB read; here it is the restart itself.

  ## The fix

  Host GATE Kinds on a DEDICATED `DynamicSupervisor` that no
  crash-storming production-shaped Kind shares. A GATE test kills its own
  Kind at most a couple of times, so a high `max_restarts` here is the
  honest budget for "deliberate brutal-kills in a tight test loop" — NOT
  a weakening of production restart-storm detection (the real
  `Ezagent.KindSupervisor` keeps `max_restarts: 3` unchanged, so a
  genuine production thrash is still caught). GATE Kinds opt in by
  declaring `def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()`.

  Started under `EzagentCore.Supervisor`'s lifetime via a plain
  `DynamicSupervisor.start_link` (named, idempotent) rather than
  `start_supervised!/1` so it OUTLIVES individual tests — the GATE Kinds
  it hosts must survive across the kill→restart cycle and across the
  serial GATE tests, and a per-test teardown would defeat the isolation.
  """
  @spec ensure_gate_supervisor!() :: :ok
  def ensure_gate_supervisor! do
    case Process.whereis(@gate_supervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        # Start the gate supervisor UNLINKED from the (transient) test
        # process so it persists for the whole BEAM and survives across
        # the serial GATE tests + each test's kill→restart cycle. A
        # short-lived starter Task owns the `start_link`, then we unlink
        # so the supervisor is parentless (a deliberate, test-only
        # long-lived singleton). Idempotent under the `whereis` guard +
        # the `:already_started` race branch.
        opts = [
          name: @gate_supervisor,
          strategy: :one_for_one,
          # Test-only budget for deliberate brutal-kills in a tight GATE
          # loop. High enough that the gate's own kill→restart cycles
          # (plus any sandbox-teardown crash of a gate Kind) never bounce
          # THIS supervisor; production `KindSupervisor` is untouched.
          max_restarts: 1_000_000,
          max_seconds: 1
        ]

        case DynamicSupervisor.start_link(opts) do
          {:ok, pid} ->
            Process.unlink(pid)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end
    end
  end

  @doc """
  Poll `fun` until it returns truthy, or flunk after `attempts` 10ms
  ticks. Mirrors the private helper used across the engine integration
  tests; lifted here so every Lifecycle test reuses one copy.

  Default budget is 300 ticks (~3s). The poll returns the instant the
  condition holds, so a healthy fast path is unaffected; the generous
  ceiling is for the FULL concurrent umbrella run, where a brutal-kill →
  supervisor-restart → `activate` → ReadyGate-flip → snapshot-commit
  round-trip (the SandboxColdRestart GATE) competes for schedulers + the
  Ecto sandbox connection and legitimately needs more than the prior
  500ms before the condition becomes true. A genuinely stuck restart
  still flunks (at 3s), so this is a realistic bound, not a masked hang.
  """
  def wait_until(fun, attempts \\ 300)
  def wait_until(_fun, 0), do: ExUnit.Assertions.flunk("wait_until: condition never became true")

  def wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  @doc """
  Spawn a Lifecycle Kind fresh, drive it to a non-trivial state via
  `drive`, capture both containers, then force a BRUTAL cold restart
  (`Process.exit(pid, :kill)` — skipping graceful `deactivate`/`destroy`)
  and demand-spawn the same URI. Returns the rehydrated containers +
  the pre/post transient snapshots so the caller can assert on them.

  Per SPEC §6 the gate asserts:

  1. `state` rehydrated correctly (the persistent container survived).
  2. `transients` rebuilt to a LIVE equivalent (new pids/refs/handles,
     functionally present) — NOT restored, NOT carrying a stale
     reference from the prior incarnation.

  ## Arguments

  - `opts.kind` — the Kind module (composes one Lifecycle module).
  - `opts.uri` — the instance URI.
  - `opts.slice_key` — the Lifecycle slice key (= `state_slice/0`).
  - `opts.spawn_args` — args passed to the first (creating) spawn.
  - `drive` — a 1-arity fn taking the live URI; drives the Kind into a
    non-trivial state (dispatch actions, etc.). MUST leave a non-empty
    transient behind.

  Returns `%{before: %{state, transients}, after: %{state, transients}}`.
  """
  @spec assert_transients_rebuilt(map(), (URI.t() -> any())) :: map()
  def assert_transients_rebuilt(opts, drive) when is_map(opts) and is_function(drive, 1) do
    kind = Map.fetch!(opts, :kind)
    uri = Map.fetch!(opts, :uri)
    slice_key = Map.fetch!(opts, :slice_key)
    spawn_args = Map.get(opts, :spawn_args, %{})

    # 1. Spawn fresh via the SOLE Kind-spawn entry (`Ezagent.Kind.spawn/2`
    #    — invariant #2 / SingleSpawnEntry gate), then wait for :ready
    #    (activate has run).
    # derivation-edge: test-scenario lifecycle fixture, never a product principal
    {:ok, pid1} = Ezagent.Kind.spawn(kind, Map.put(spawn_args, :uri, uri))

    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    # The cold-restart wait below (step 4) is the slowest operation in
    # this gate: a brutal kill triggers an OTP supervisor auto-restart
    # (which may carry a small restart-backoff) followed by a full
    # init → cold-load → activate → ReadyGate-flip cycle. Under the full
    # concurrent umbrella run (ezagent_core alone runs ~22s) that
    # legitimately needs a larger budget than the generic 3s default, so
    # the restart-readiness poll gets an explicit ~6s ceiling.
    cold_restart_attempts = 600

    # 2. Drive to a non-trivial state, then capture both containers.
    drive.(uri)

    # T3: `get_slice/2` now normalizes a two-container slice to its flat
    # `.state` view for production consumers — which would HIDE the
    # `transients` container this gate must inspect. Use the RAW read so we
    # see the full `%{state:, transients:}` split.
    {:ok, %{state: state_before, transients: transients_before}} =
      Ezagent.Kind.get_raw_slice(uri, slice_key)

    ExUnit.Assertions.assert(
      map_size(transients_before) > 0,
      "assert_transients_rebuilt: pre-restart transients are empty — the test must " <>
        "drive the Kind into a state with at least one live transient resource"
    )

    # 3. Brutal kill — no graceful deactivate/destroy (§OTP best-effort,
    #    SPEC §6 step 3). `Process.exit(pid, :kill)` is untrappable, so
    #    the `:trap_exit` Kind.Server dies without reaching its
    #    terminate/2 — exactly the "deactivate/destroy skipped" path.
    #
    #    The `Kind.Server` is a `:permanent` child of its
    #    `DynamicSupervisor`, so OTP AUTO-RESTARTS it at the same URI.
    #    The restart re-runs `init/1` → cold-load (`ever_created?` true
    #    → `create` skipped, `state` rehydrated from the snapshot) →
    #    `activate/2` (transients rebuilt). This is the most
    #    production-faithful cold-load path: the supervisor's own
    #    restart, not a hand-rolled re-spawn. We therefore wait for the
    #    registry to point at a DIFFERENT, ready pid.
    Process.exit(pid1, :kill)

    wait_until(
      fn ->
        case Ezagent.KindRegistry.lookup(uri) do
          {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(uri) == :ready
          _ -> false
        end
      end,
      cold_restart_attempts
    )

    {:ok, pid2} = Ezagent.KindRegistry.lookup(uri)
    ExUnit.Assertions.refute(pid1 == pid2, "cold restart must produce a new pid")

    {:ok, %{state: state_after, transients: transients_after}} =
      Ezagent.Kind.get_raw_slice(uri, slice_key)

    # 5a. State rehydrated correctly.
    ExUnit.Assertions.assert(
      state_after == state_before,
      "assert_transients_rebuilt: persistent state did NOT rehydrate correctly.\n" <>
        "before: #{inspect(state_before)}\nafter:  #{inspect(state_after)}"
    )

    # 5b. Transients rebuilt to a LIVE equivalent — non-empty.
    ExUnit.Assertions.assert(
      map_size(transients_after) > 0,
      "assert_transients_rebuilt: transients were NOT rebuilt on cold-load — " <>
        "activate/2 either didn't run or returned empty. THIS IS the cold-restart bug class."
    )

    # 5c. No stale reference from the prior incarnation survived: every
    #     pid/ref transient must differ from the pre-restart one (a dead
    #     reference rehydrated from a snapshot would be EQUAL).
    Enum.each(transients_after, fn {k, v} ->
      case Map.get(transients_before, k) do
        nil ->
          :ok

        prior when is_pid(v) or is_reference(v) ->
          ExUnit.Assertions.refute(
            v == prior,
            "assert_transients_rebuilt: transient #{inspect(k)} carried a STALE " <>
              "reference (#{inspect(prior)}) across the restart — it was persisted + " <>
              "rehydrated instead of rebuilt. THIS IS the cold-restart bug class."
          )

        _ ->
          :ok
      end
    end)

    %{
      before: %{state: state_before, transients: transients_before},
      after: %{state: state_after, transients: transients_after},
      pids: {pid1, pid2}
    }
  end
end
