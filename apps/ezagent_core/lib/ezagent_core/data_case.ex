defmodule EzagentCore.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EzagentCore.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias EzagentCore.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import EzagentCore.DataCase
      import Ezagent.Test.CapHelper
    end
  end

  setup tags do
    EzagentCore.DataCase.setup_sandbox(tags)
    EzagentCore.DataCase.reset_boot_seed_registry()
    :ok
  end

  @doc """
  Run every registered per-boot reset hook so one test behaves as one fresh VM
  boot.

  Downstream apps keep VM-global (persistent_term) per-boot state that survives a
  test's DB rollback — e.g. `ezagent_domain_agent`'s role-seed registry, the
  `{name → body_hash}` map that distinguishes a genuine same-boot
  two-plugins-one-name collision from a cross-version reboot UPGRADE. Without a
  per-test reset a fixed-name seed in one test would spuriously collide with a
  differing-body seed of the same name in another.

  The hooks are registered (0-arity funs) into a PLAIN-ATOM persistent_term list
  by the owning app at boot, and drained here — so `ezagent_core` names NO
  downstream module (the `no_role_concept_in_core` layering gate), takes no
  compile dependency on the domain layer, and is a no-op in suites that register
  none.
  """
  @spec reset_boot_seed_registry() :: :ok
  def reset_boot_seed_registry do
    :ezagent_test_boot_reset_hooks
    |> :persistent_term.get([])
    |> Enum.each(fn hook -> hook.() end)

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  ## Why the extra `on_exit` (remediation P6 — sandbox-owner-exit drain)

  Integration tests spawn `Ezagent.Kind.Server` GenServers (via
  `Ezagent.Kind.spawn/2` / dispatch) under GLOBAL `DynamicSupervisor`s.
  In shared sandbox mode (`shared: not async`) those Kinds inherit the
  test's checked-out connection from the sandbox owner. A Kind runs
  Repo queries OUTSIDE the test process — in `handle_continue`
  (`activate/2` → DB projection reads), `handle_info` snapshot writes,
  etc. — so it can still be mid-query when the test body returns.

  `start_owner!` registers `on_exit(stop_owner)` for us. If that were
  the only teardown, the owner's connection would be reclaimed while a
  Kind is still using it, producing the deterministic
  `DBConnection.ConnectionError` "owner #PID exited / Client #PID is
  still using a connection from owner" error. In the
  `apps/ezagent_domain_session` suite (`--max-cases 1 --seed 0`) this
  surfaced as ~40-50 such error log occurrences per run, crashing the
  offending Kinds mid-teardown. (The chat suite's *test* failures are a
  separate, pre-existing set of assertion / `:not_ready` bugs out of P6
  scope — the DBConnection errors were async log noise from torn-down
  Kinds, not the cause of those assertions.)

  Fix: register a SECOND `on_exit` that DRAINS every live Kind *before*
  the owner is stopped. ExUnit runs `on_exit` callbacks LIFO, and this
  one is registered after `start_owner!`'s, so it runs first. The drain
  issues a benign synchronous `GenServer.call(pid, :ezagent_kind_module)`
  to each Kind: a `call` only returns once the GenServer has processed
  every message ahead of it in its mailbox — including any in-flight
  `handle_continue` / `handle_info` that is mid-query. So when the call
  returns, that Kind has no DB work outstanding on the owner's
  connection, and `stop_owner` can safely reclaim it.

  We deliberately DRAIN rather than TERMINATE: this suite reuses fixed
  Kind URIs across tests and relies on `SpawnRegistry.spawn/1` being
  idempotent for an already-live Kind. Terminating the Kinds would
  expose latent per-test activation races (`:not_ready`) that Kind
  persistence currently masks — i.e. it would trade the DBConnection
  flakiness for a *different* flakiness class. Draining keeps the blast
  radius to exactly the DBConnection class.
  """
  def setup_sandbox(tags) do
    pid = start_owner_stable!(not tags[:async])
    allow_live_kinds(pid)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    on_exit(&drain_to_quiescence/0)
  end

  @doc """
  Register a `Task.Supervisor` whose fire-and-forget children the test
  teardown must DRAIN before it stops the sandbox owner (P6 async-escape
  fix — 2026-07-11).

  ## The bug this closes

  The Kind-mailbox flush (`flush_live_kinds/0`, below) drains every live
  `Kind.Server`'s mailbox, but the platform ALSO fans DB-touching work OFF a
  Kind's process into
  UNLINKED supervised Tasks under GLOBAL `Task.Supervisor`s — the dominant
  one being `Ezagent.Session.DeliverySupervisor`, which runs
  `Delivery.deliver_async/5 → ReadMarker.insert_marker/…` and Kind-snapshot
  writes. Those Tasks are NOT in `KindRegistry`, so the Kind-drain never
  waits for them. When the test body returns and `stop_owner` reclaims the
  shared connection, an in-flight delivery Task either is mid-query
  (`… is still using a connection from owner …`) or starts its query after
  the owner exited and the pool reverted to `:manual`
  (`cannot find ownership process for #PID<…>`). In the SECOND case the
  Task's write is silently DROPPED — and any test that asserts the
  delivered effect (a read marker, an audit event, a snapshot) goes RED,
  non-deterministically, ONLY under the full-umbrella concurrency that
  widens the straddle window (task #108-class flake).

  `Sandbox.allow`-ing the Task is NOT the fix: in shared mode every process
  already sees the owner's connection, so the failure is purely a LIFETIME
  race — the Task outlives `stop_owner`. The fix is to make teardown WAIT
  for these Tasks to finish (against the still-valid connection) before it
  stops the owner. Because that write work interleaves with Kind mailboxes
  (a delivery Task casts back into a Kind, which may enqueue another
  delivery), the drain loops kinds ⇄ supervisors to JOINT quiescence.

  ## Why register-at-boot rather than name the supervisors here

  `ezagent_core` must name no downstream module (the `no_role_concept_in_core`
  layering gate). So — exactly like the `:ezagent_test_boot_reset_hooks`
  registry drained by `reset_boot_seed_registry/0` — the owning app registers
  its supervisor NAME (a plain atom) into a `persistent_term` list at boot
  (test env only), and core drains the list without referencing the domain
  or plugin layer. A suite that boots none registers none and pays nothing.
  """
  @async_drain_key :ezagent_test_async_drain_supervisors
  @async_idle_key :ezagent_test_async_drain_idle_checks

  @spec register_async_drain_supervisor(atom()) :: :ok
  def register_async_drain_supervisor(name) when is_atom(name) do
    existing = :persistent_term.get(@async_drain_key, [])
    :persistent_term.put(@async_drain_key, Enum.uniq([name | existing]))
    :ok
  end

  @doc """
  Register a `(-> boolean)` quiescence probe that the teardown drain must
  see return `true` before it treats the async work as drained.

  ## Why a probe is needed on top of the supervisor drain

  A supervisor's children only tell half the story when the fan-out sits
  behind a FEEDER GenServer. `Ezagent.Session.DeliveryQueue` is the case in
  point: a Kind casts an `enqueue` to it, and only when the queue processes
  that cast does the job become a live child of `Ezagent.Session.DeliverySupervisor`.
  Flushing the Kind's mailbox lands the `enqueue` in the QUEUE's mailbox — but
  in the instant before the queue promotes it, the supervisor still has zero
  children, so a bare "children empty?" check reads FALSE-quiescent, the drain
  returns, and the just-promoted delivery Tasks escape past `stop_owner`
  (observed as a single-test broadcast burst still emitting
  `cannot find ownership process`).

  The probe closes that gap because it is a synchronous `GenServer.call`
  (`DeliveryQueue.idle?/0`): the call cannot be answered until the queue has
  processed every `enqueue` ahead of it — so by the time the probe returns,
  any pending job has ALREADY been promoted to a supervisor child that the
  child-drain then waits out. Owning apps register their feeder's `idle?`
  here (test env only), the same plain-atom persistent_term convention as
  `:ezagent_test_boot_reset_hooks`.
  """
  @spec register_async_drain_idle_check((-> boolean())) :: :ok
  def register_async_drain_idle_check(fun) when is_function(fun, 0) do
    existing = :persistent_term.get(@async_idle_key, [])
    :persistent_term.put(@async_idle_key, [fun | existing])
    :ok
  end

  defp registered_async_supervisors do
    :persistent_term.get(@async_drain_key, [])
  end

  defp registered_async_idle_checks do
    :persistent_term.get(@async_idle_key, [])
  end

  # #52 Mode-B tightening (design §3.2). Walk every Kind ALREADY LIVE in
  # `KindRegistry` at setup time and `Sandbox.allow/3` its pid onto this
  # test's owner connection. A globally-supervised `Kind.Server` runs Repo
  # queries OUTSIDE the test's `$callers` chain (in `handle_continue` /
  # `handle_info` — snapshot writes, `EventLog.append`), so without an
  # explicit allow it can hit `cannot find ownership process for #PID<…>
  # (:proc_lib)` and degrade to in-memory-only / log noise. Allowing the
  # live pids here closes that gap for Kinds alive at setup.
  #
  # This is best-effort and complements (does not replace) the P6
  # `drain_to_quiescence/0` teardown + the cold-restart fix (gating the boot
  # singleton out of `:test`). Kinds spawned LATER in the test under a
  # global supervisor still inherit via `$callers` when spawned from the
  # (allowed) test process; the residual detached class is best-effort
  # drained at teardown. `Sandbox.allow/3` is idempotent and tolerates an
  # already-owned or dead pid, so we ignore its result.
  defp allow_live_kinds(owner) do
    Enum.each(registered_kinds(), fn {_uri, pid} ->
      try do
        Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, owner, pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # P6 cold-restart determinism (remediation §3 C-D). A drop-in for
  # `Ecto.Adapters.SQL.Sandbox.start_owner!/2` whose SHARED-mode handshake
  # RETRIES past a lingering prior owner instead of crashing on it.
  #
  # ## Why the stock `start_owner!(shared: true)` flakes
  #
  # `start_owner!(shared: true)` spawns an `Agent` owner that runs
  # `:ok = mode(Repo, {:shared, agent})`. `DBConnection.Ownership.Manager`
  # answers `:already_shared` whenever a PRIOR non-async test's
  # shared-owner `Agent` is *still alive* at that instant — its
  # `stop_owner` `on_exit` may not have completed, or a leftover Kind
  # keeps it referenced. On `:already_shared` the `:ok =` match CRASHES
  # the new owner `Agent`, so THIS test has no live shared owner of its
  # own and free-rides on the lingering prior owner's connection. When
  # that prior owner finally exits, the Manager's `:DOWN` handler reverts
  # the pool to `:manual`.
  #
  # That revert is invisible to ordinary tests (they finish their queries
  # before it lands), but it is fatal to the cold-restart GATE tests
  # (`SandboxColdRestartTest`, `TerminableColdLoadTest`,
  # `PtyColdRestartTest`, `LifecycleTest "THE GATE"`): they
  # `Process.exit(pid, :kill)` a `:snapshot` Kind, OTP auto-restarts a
  # NEW pid that reads `kind_snapshots` in `Kind.Server.init/1` BEFORE it
  # registers in `KindRegistry`. That pid is the supervisor's child, so
  # `DBConnection`'s `$callers`-chain owner lookup finds only the
  # supervisor (never allowed) — the test cannot `Sandbox.allow/3` it
  # ahead of the first read. Its ONLY route to a connection is shared
  # mode, so a reverted pool raises `DBConnection.OwnershipError`, the
  # restart never reaches `:ready`, and `wait_until` flunks. Passes in
  # isolation; flakes ~half the seeds in the full concurrent umbrella run.
  #
  # ## The fix
  #
  # `:already_shared` is TRANSIENT: the Manager reverts to `:manual` the
  # moment the prior owner's `:DOWN` lands, at which point a re-attempt
  # wins. So we retry the `mode/2` call on a short tick until it succeeds
  # (or a generous ceiling, after which we flunk LOUDLY rather than
  # silently run in a reverted pool). The owner then OWNS shared mode for
  # the whole test — and since the cold-restart test process blocks in
  # `wait_until` across the kill→restart→ready cycle, the share can no
  # longer revert mid-restart. This removes the revert *cause* (an
  # unstable, foreign shared owner). It is NOT a masked sleep or a
  # widened `wait_until`, and it never stamps the pool to `:manual`
  # globally (which would check in connections in-use by concurrent
  # leftover Kinds). The async path is unchanged: `shared: false` uses
  # per-connection `allow`, has no shared mode, and never flaked.
  @share_attempts 500

  defp start_owner_stable!(false = _shared) do
    Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: false)
  end

  defp start_owner_stable!(true = _shared) do
    parent = self()

    {:ok, owner} =
      Agent.start(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
        :ok = share_with_retry(self(), @share_attempts)
        # Allow the test process itself onto the stable shared connection
        # so the test body is robust even in the instant before shared
        # mode is observed everywhere.
        _ = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), parent)
        :ok
      end)

    owner
  end

  defp share_with_retry(_owner, 0) do
    raise "EzagentCore.DataCase: could not acquire stable {:shared, _} sandbox mode — " <>
            "a prior shared owner stayed alive past the retry budget (cold-restart reads would flake)"
  end

  defp share_with_retry(owner, attempts) when attempts > 0 do
    case Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, owner}) do
      :ok ->
        :ok

      :already_shared ->
        Process.sleep(5)
        share_with_retry(owner, attempts - 1)
    end
  end

  # Bounded number of drain passes. One pass flushes each Kind's mailbox
  # AND waits for every registered async Task.Supervisor's in-flight
  # children (deliveries, snapshot writes) to finish. The two escape
  # hatches feed each other — a delivery Task casts back into a Kind, a
  # Kind's `handle_info` enqueues another delivery — so we re-pass while
  # EITHER still has outstanding work. A late PubSub broadcast (presence
  # diff, slice-change fan-out) from a still-running process can also land
  # a fresh `handle_info` after a pass. Bounded so a genuinely busy-looping
  # Kind or a wedged delivery can't hang teardown; the rare straggler that
  # arrives after the final pass is best-effort (it logs but does not fail
  # any assertion — see moduledoc + `register_async_drain_supervisor/1`).
  @drain_passes 6

  # Per-pass budget for waiting out one supervisor's in-flight Task
  # children. A single delivery Task is a handful of ms; this ceiling only
  # bites a pathologically slow/wedged Task, which we then leave to the
  # next pass / best-effort.
  @sup_drain_budget_ms 2_000

  # Interleave the Kind-mailbox flush with the async-supervisor drain,
  # looping until BOTH are quiescent (or the pass budget is spent). This is
  # the seam that keeps fire-and-forget DB work from outliving the sandbox
  # owner's connection — see `register_async_drain_supervisor/1`.
  defp drain_to_quiescence, do: drain_to_quiescence(@drain_passes)

  defp drain_to_quiescence(0), do: :ok

  defp drain_to_quiescence(passes_left) do
    # 1. Flush Kind mailboxes first: a queued delivery cast is processed
    #    now, landing its `enqueue` in the feeder queue's mailbox.
    flush_live_kinds()

    # 2. Flush the feeder GenServers (a synchronous `idle?` call) so any
    #    just-enqueued job is PROMOTED to a supervisor child before we look —
    #    closing the false-quiescent gap (see `register_async_drain_idle_check/1`).
    run_idle_checks()

    # 3. Wait for the async Task.Supervisors' in-flight children to finish
    #    their DB work against the still-valid connection.
    await_async_supervisors_drained()

    if quiescent?() do
      :ok
    else
      drain_to_quiescence(passes_left - 1)
    end
  end

  # Invoke each registered quiescence probe. The RETURN value is folded into
  # `quiescent?/0`; the SIDE EFFECT (a synchronous `GenServer.call` into the
  # feeder) is what flushes the feeder's mailbox so queued jobs become live
  # supervisor children. Best-effort: a feeder that is down/absent is idle.
  defp run_idle_checks do
    Enum.each(registered_async_idle_checks(), fn check ->
      _ = safe_idle_check(check)
    end)
  end

  defp safe_idle_check(check) do
    check.()
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # Flush in-flight DB work out of every live Kind so no query outlives
  # the sandbox owner's connection. A synchronous `GenServer.call`
  # returns only after the Kind has drained its mailbox up to that call,
  # so any mid-flight `handle_continue`/`handle_info` that is mid-query
  # completes against the still-valid connection. Best-effort: a Kind
  # that exits or times out mid-drain is already not holding the
  # connection.
  defp flush_live_kinds do
    Enum.each(registered_kinds(), fn {_uri, pid} ->
      try do
        GenServer.call(pid, :ezagent_kind_module, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # For each registered async Task.Supervisor, block until it has no live
  # children — monitoring the current children and waiting for their
  # `:DOWN`. A queued job (e.g. the per-recipient FIFO in
  # `Ezagent.Session.DeliveryQueue`) promotes to a fresh child once the
  # running one finishes, so we re-poll until the supervisor is empty (or
  # the budget is spent). Draining here means the Task's
  # `ReadMarker.insert`/snapshot write COMMITS before `stop_owner` reclaims
  # the connection — closing the "cannot find ownership process" /
  # "still using a connection from owner" flake.
  defp await_async_supervisors_drained do
    Enum.each(registered_async_supervisors(), fn sup ->
      await_supervisor_empty(sup, @sup_drain_budget_ms)
    end)
  end

  @doc """
  Block until `sup` (a `Task.Supervisor` name) has no live children, or the
  default per-supervisor budget is spent. This is the primitive the teardown
  uses to keep fire-and-forget delivery/snapshot Tasks from outliving the
  sandbox owner; exposed for the regression guard that asserts the wait
  actually blocks (drop the wait → the guard's task is still running when
  this returns → the guard fails).
  """
  @spec drain_async_supervisor(atom()) :: :ok
  def drain_async_supervisor(sup) when is_atom(sup) do
    await_supervisor_empty(sup, @sup_drain_budget_ms)
  end

  defp await_supervisor_empty(_sup, budget_ms) when budget_ms <= 0, do: :ok

  defp await_supervisor_empty(sup, budget_ms) do
    case supervisor_children(sup) do
      [] ->
        :ok

      pids ->
        t0 = System.monotonic_time(:millisecond)
        Enum.each(pids, fn pid -> await_pid_down(pid, budget_ms) end)
        # Let a same-key queued job promote to a new child, then re-poll.
        Process.sleep(5)
        spent = max(System.monotonic_time(:millisecond) - t0, 1)
        await_supervisor_empty(sup, budget_ms - spent)
    end
  end

  defp await_pid_down(pid, timeout_ms) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout_ms -> Process.demonitor(ref, [:flush])
    end
  end

  defp supervisor_children(sup) do
    Task.Supervisor.children(sup)
  rescue
    # Supervisor not started in this suite — nothing to drain.
    _ -> []
  catch
    :exit, _ -> []
  end

  # Quiescent = no live Kind has a queued message AND every registered
  # async supervisor has no live children.
  defp quiescent? do
    no_queued_kind_messages?() and
      Enum.all?(registered_async_supervisors(), fn sup -> supervisor_children(sup) == [] end) and
      Enum.all?(registered_async_idle_checks(), fn check -> safe_idle_check(check) == true end)
  end

  defp no_queued_kind_messages? do
    not Enum.any?(registered_kinds(), fn {_uri, pid} ->
      match?({:message_queue_len, n} when n > 0, Process.info(pid, :message_queue_len))
    end)
  end

  defp registered_kinds do
    Ezagent.KindRegistry.list_all()
  rescue
    # KindRegistry not started (pure-unit suites) — nothing to drain.
    _ -> []
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
