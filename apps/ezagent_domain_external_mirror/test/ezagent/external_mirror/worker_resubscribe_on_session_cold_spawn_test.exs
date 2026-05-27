defmodule Ezagent.ExternalMirror.WorkerResubscribeOnSessionColdSpawnTest do
  @moduledoc """
  Task #49 (2026-05-27) regression test — ExternalMirrorWorker must
  re-subscribe to its Session's Publisher when the Session is cold-
  spawned (terminated + re-spawned via `SpawnRegistry.spawn/1`) while
  the Worker itself stays alive.

  ## Scenario (NOT the rehydration case in PR-EM-3 (h))

  - Worker Kind is spawned + subscribed to the Session Publisher.
  - Session Kind is terminated, but the Worker is NOT terminated
    (the Worker lives under `Ezagent.ExternalMirror.RootSupervisor`,
    NOT under `EzagentDomainChat.SessionSupervisor` — they have
    independent lifecycles).
  - Session is cold-spawned via `SpawnRegistry.spawn/1` (the on-
    demand path — NOT a fresh boot).
  - The new Session's `:publisher.subscribers` is cleared by
    `Behavior.Publisher.SessionImpl.reconcile_after_load/2` (task #49
    codex round-1 CONCERN #3 fix — transient subscriber/monitor
    handles do not survive snapshot/restart).

  ## Pre-fix bug

  The still-alive Worker had no way to re-subscribe. The next slice
  mutation would publish into an empty subscriber map and silently
  drop. This was the Feishu e2e silent-drop discovered 2026-05-27
  (3 messages dispatched; worker's `publish_count` showed 2 — the
  FIRST after cold-spawn was lost).

  ## Post-fix wiring

  - `Ezagent.PublisherLifecycle` (in `:ezagent_core`) provides a
    per-publisher-URI lifecycle topic.
  - `Ezagent.Behavior.Publisher.SessionImpl.on_ready/2` broadcasts
    `{:publisher_alive, self_uri}` AFTER `Ezagent.ReadyGate.mark_ready/1`
    has flipped (codex round-1 FAIL #6 — pre-fix this lived in
    `handle_continue/3` and raced peer `:call` re-subscribes against
    the not-yet-flipped ReadyGate).
  - `Ezagent.Behavior.Publisher.SessionImpl.reconcile_after_load/2`
    clears the transient `:subscribers` + `:monitors` maps on
    snapshot load (codex round-1 CONCERN #3 — stale pids/refs from
    a previous BEAM cannot be routable / demonitorable; clearing
    them on load makes the transient nature of subscribership
    explicit and forces the lifecycle handshake on every cold spawn).
  - `Ezagent.Behavior.ExternalMirrorWorker.handle_continue/3`
    subscribes to the lifecycle topic.
  - `Ezagent.Behavior.ExternalMirrorWorker.handle_kind_message/3`
    `{:publisher_alive, _}` clause re-runs
    `subscribe_to_session_publisher/2`; on `{:error, :not_ready}`
    it schedules a bounded retry (defence-in-depth — the on_ready
    primary fix means the retry path should be cold in normal
    operation).

  Idempotent at every layer:
  - Publisher `ensure_monitored/2` dedupes by pid.
  - Worker's re-subscribe just refreshes `publisher_cursor`.

  ## Test shape (codex round-1 CONCERN #5)

  This test exercises the REAL production load path:
  1. Spawn the Worker (subscribes to the live Session, which adds
     the Worker's pid to `:publisher.subscribers` via the normal
     `:subscribe_from` dispatch).
  2. Drive a baseline publish to confirm the wire is alive.
  3. Force a snapshot write of the Session in its CURRENT state
     (live worker pid in the subscribers map). This is what the
     `:on_change` strategy already does on every mutation; we just
     force one synchronously so the assertion isn't time-dependent.
  4. Terminate the Session via its supervisor.
  5. Cold-spawn the Session via `SpawnRegistry.spawn/1`. The new
     Session's `:publisher` slice loads from snapshot — and the
     `reconcile_after_load/2` callback clears `:subscribers` +
     `:monitors`. (Pre-CONCERN-#3 fix the loaded slice would have
     re-installed the stale-pid map; the test had to fabricate the
     empty state via `:sys.replace_state` because same-VM
     `term_to_binary` round-trip preserves pid routability that
     doesn't survive an actual BEAM restart.)
  6. Trigger a slice change; assert the still-alive Worker receives
     the publish event via the lifecycle handshake.

  ## Test isolation (codex round-1 CONCERN #7)

  `EzagentDomainChat` is NOT a runtime dep of
  `ezagent_domain_external_mirror` (cycle break). When this file is
  the only test file that triggers (e.g. `mix test path/to/this`),
  `:ezagent_domain_chat` is not auto-started — its
  `SessionSupervisor`, scheme registration, etc. are absent and
  `SpawnRegistry.spawn(session_uri)` would fail with
  `{:error, :no_spawn_fn}`. We explicitly `Application.ensure_all_started/1`
  the chat app in setup; the umbrella-wide test run is a no-op
  (app already started).
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    RootSupervisor,
    WorkerRegistry,
    WorkerSpawn
  }

  alias Ezagent.ExternalMirror.TestSupport.{MockPublishAdapter, MockPublishBinding}

  setup do
    # codex round-1 CONCERN #7 — see moduledoc. Chat is a compile-
    # but-not-runtime dep here (the cycle break). Force-start so
    # `EzagentDomainChat.SessionSupervisor` + the `"session"` scheme
    # spawn fn exist when we resolve / cold-spawn the default Session.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)

    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    on_exit(fn -> cleanup_workers() end)

    # SliceChange hook is unconditional post-PR-N3, but keep the
    # explicit toggle for cross-branch resilience (matches
    # `worker_publish_test.exs`).
    orig = Application.get_env(:ezagent_core, :slice_change_hook)
    Application.put_env(:ezagent_core, :slice_change_hook, true)

    on_exit(fn ->
      if is_nil(orig) do
        Application.delete_env(:ezagent_core, :slice_change_hook)
      else
        Application.put_env(:ezagent_core, :slice_change_hook, orig)
      end
    end)

    {:ok, session_uri: URI.parse("session://default/system/main")}
  end

  describe "task #49 cold-spawn re-subscribe" do
    test "first slice change after Session cold-spawn reaches the still-alive Worker",
         %{session_uri: session_uri} do
      # Make sure the Session Kind exists + is ready before spawning
      # the Worker — the Worker's
      # `handle_continue(:subscribe_and_init, ...)` dispatches a `:call`
      # against the Session's `publisher.subscribe_from` action; that
      # raises `:no_such_actor` if the Session is not yet registered
      # in `Ezagent.KindRegistry`. The chat plugin's `:test`-env seed
      # may not have spawned the default session yet when this test
      # runs alone (vs as part of the full file where prior tests
      # warm the registry).
      _ = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = await_session_ready(session_uri, 100)

      target_id = "tgt-task49-cold-spawn"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, sup_pid_before} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      # Sanity: baseline publish flows through the live wire.
      send_chat_to_session(session_uri)
      assert_receive {:published, _, ^target_id, _}, 1_500

      # Drain residual `:published` messages from any extra slice
      # mutations (Session boot or first mutation noise).
      drain_mailbox()

      # Capture the inner Kind.Server pid — the CRUCIAL property is
      # that this pid survives the Session vanish + cold-spawn (the
      # Worker is under RootSupervisor, not SessionSupervisor).
      [{_id, worker_kind_pid_before, _, _}] = Supervisor.which_children(sup_pid_before)
      assert is_pid(worker_kind_pid_before)
      assert Process.alive?(worker_kind_pid_before)

      {:ok, session_pid_1} = Ezagent.KindRegistry.lookup(session_uri)

      # Production-faithful path (codex round-1 CONCERN #5 fix):
      # snapshot the LIVE state — the live worker pid IS in
      # `:publisher.subscribers`. `:on_change` would write the same
      # snapshot on any future slice mutation; forcing it
      # synchronously here makes the assertion time-independent.
      #
      # Crucially, this snapshot carries the worker's STILL-ALIVE
      # pid + monitor ref. The cold-spawn load path's
      # `Behavior.Publisher.SessionImpl.reconcile_after_load/2`
      # (CONCERN #3 fix) clears both maps on load — that's the
      # production behaviour we're testing. Pre-CONCERN-#3-fix the
      # test had to fabricate empty subscribers via
      # `:sys.replace_state`; post-fix we just save the natural
      # state and let `reconcile_after_load/2` do its job.
      kind_state = :sys.get_state(session_pid_1)
      :ok = Ezagent.Kind.Snapshot.save_now(session_uri, kind_state.kind, kind_state.state)

      # Sanity: the snapshot we just wrote includes the worker's
      # live pid. (If `reconcile_after_load/2` is missing the cold
      # spawn would re-install this pid, and the test would PASS
      # against a buggy build — that's exactly what CONCERN #5
      # called out. The first slice change after cold-spawn would
      # still publish to the pre-vanish pid, which happens to be
      # the same live pid in a same-VM test, masking the prod
      # silent-drop. Asserting the snapshot carries the pid +
      # then asserting `reconcile_after_load/2` clears it is what
      # makes this test a true regression for the prod path.)
      persisted_subscribers =
        kind_state.state.publisher.subscribers

      assert is_map(persisted_subscribers) and map_size(persisted_subscribers) >= 1,
             "test pre-condition broken — the Worker did not subscribe to the Session " <>
               "Publisher pre-vanish; cold-spawn scenario does not apply. " <>
               "subscribers=#{inspect(persisted_subscribers)}"

      # Terminate the Session via its supervisor (boot-seed path uses
      # EzagentDomainChat.SessionSupervisor; lazy-demand spawn path
      # also routes through Session's declared supervisor — resolve
      # from the pid's ancestors to be safe).
      session_supervisor = resolve_session_supervisor(session_pid_1)
      :ok = DynamicSupervisor.terminate_child(session_supervisor, session_pid_1)

      :ok = wait_until_dead(session_uri, 50)

      # Worker is STILL the same pid — survived the Session vanish.
      assert Process.alive?(worker_kind_pid_before),
             "Worker died when Session was terminated — invariant 4 (per-binding crash " <>
               "isolation) broken: ExternalMirrorWorker MUST live independently of the " <>
               "Session Kind it subscribes to."

      # Cold-spawn the Session via the production lazy-demand path.
      # The new Session rehydrates from snapshot; `:publisher.subscribers`
      # comes back as `%{}` via `Behavior.Publisher.SessionImpl.reconcile_after_load/2`
      # (codex round-1 CONCERN #3 fix). The Worker has no entry in the
      # new map; the lifecycle handshake (`on_ready/2` broadcast +
      # `handle_kind_message({:publisher_alive, _}, ...)`) is the ONLY
      # mechanism that re-attaches it.
      {:ok, session_pid_2} = Ezagent.SpawnRegistry.spawn(session_uri)
      refute session_pid_1 == session_pid_2
      :ok = await_session_ready(session_uri, 100)

      # Validate CONCERN #3 fix: the cold-spawned Session's publisher
      # slice came back with subscribers cleared. If a future change
      # accidentally removes `reconcile_after_load/2` the loaded map
      # would re-install the pre-vanish pid and this assertion fails
      # — independent of whether the lifecycle handshake works.
      cold_spawn_state = :sys.get_state(session_pid_2)

      assert cold_spawn_state.state.publisher.subscribers == %{},
             "Behavior.Publisher.SessionImpl.reconcile_after_load/2 did NOT clear " <>
               "`:publisher.subscribers` on snapshot load. Cold-spawned Session " <>
               "subscribers=#{inspect(cold_spawn_state.state.publisher.subscribers)}. " <>
               "Stale subscriber pids from the snapshot must be cleared because they " <>
               "are BEAM-local handles that don't survive restart in production."

      assert cold_spawn_state.state.publisher.monitors == %{},
             "Behavior.Publisher.SessionImpl.reconcile_after_load/2 did NOT clear " <>
               "`:publisher.monitors` on snapshot load. monitors=" <>
               "#{inspect(cold_spawn_state.state.publisher.monitors)}."

      # The Worker is STILL the same pid (post-cold-spawn invariant).
      binding_uri =
        URI.to_string(WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id))

      {:ok, sup_pid_after} = WorkerRegistry.lookup(binding_uri)
      assert sup_pid_after == sup_pid_before

      [{_id, worker_kind_pid_after, _, _}] = Supervisor.which_children(sup_pid_after)

      assert worker_kind_pid_after == worker_kind_pid_before,
             "Worker Kind pid changed across Session cold-spawn — this test asserts the " <>
               "*Worker stayed alive* across the Session vanish. If the Worker died, the " <>
               "scenario reduces to PR-EM-3 (h) and this test is no longer covering task #49."

      # Re-register the observer (test infra may have flushed) + give
      # the PublisherLifecycle broadcast + Worker re-subscribe time to
      # propagate. The lifecycle broadcast fires in SessionImpl's
      # `handle_continue/3` immediately after `:announce_ready`; the
      # Worker receives it as a `Kind.Server` mailbox message and
      # re-runs `subscribe_to_session_publisher/2` synchronously.
      MockPublishBinding.register_observer(target_id, self())
      Process.sleep(100)

      # First slice change after the cold-spawn — pre-fix this was
      # silently dropped (the Worker pid wasn't in the new
      # subscribers map). Post-fix, the lifecycle handshake re-
      # attached the Worker before this fires.
      send_chat_to_session(session_uri)

      assert_receive {:published, _, ^target_id, _},
                     2_000,
                     "Task #49 regression — first slice change after Session cold-spawn " <>
                       "did NOT reach the Worker. The Worker subscribed pre-vanish, the " <>
                       "Session vanished + cold-spawned, and no event flowed. The expected " <>
                       "fix is `Ezagent.PublisherLifecycle.broadcast_alive/1` in " <>
                       "`Ezagent.Behavior.Publisher.SessionImpl.handle_continue/3` + the " <>
                       "matching `:publisher_alive` clause in " <>
                       "`Ezagent.Behavior.ExternalMirrorWorker.handle_kind_message/3`."
    end
  end

  # ----- helpers ----------------------------------------------------------

  defp ensure_adapter_registered(adapter, binding) do
    _ = AdapterRegistry.register(adapter)
    _ = BindingRegistry.register_module(adapter.adapter_id(), binding)
    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_workers do
    case Process.whereis(RootSupervisor) do
      nil ->
        :ok

      _ ->
        DynamicSupervisor.which_children(RootSupervisor)
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          if is_pid(pid) do
            _ = DynamicSupervisor.terminate_child(RootSupervisor, pid)
          end
        end)
    end

    :ok
  end

  # Drives a Publisher event by mutating the Session's `:chat` slice
  # via `:chat.join` (same pattern as `worker_publish_test.exs`'s
  # helper). SliceChange fires only on actual slice mutation, so a
  # fresh member each call guarantees a new event.
  defp send_chat_to_session(%URI{} = session_uri) do
    member_uri =
      URI.parse("entity://user/team-alpha/em-pub-test-#{System.unique_integer([:positive])}")

    user_module = Module.concat([Ezagent, Entity, User])

    case apply(Ezagent.Kind, :spawn, [
           user_module,
           %{uri: member_uri, initial_caps: MapSet.new()}
         ]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    admin_uri = URI.parse("entity://user/system/admin")
    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{caller: admin_uri, caps: admin_caps(), reply: :ignore}
    })
  end

  defp admin_caps do
    MapSet.new([
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap/default"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
    ])
  end

  defp wait_until_dead(_uri, 0), do: :error

  defp wait_until_dead(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      _ -> Process.sleep(20) && wait_until_dead(uri, retries - 1)
    end
  end

  defp await_session_ready(_uri, 0), do: {:error, :timeout}

  defp await_session_ready(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        case Ezagent.ReadyGate.status(URI.to_string(uri)) do
          :ready -> :ok
          _ -> Process.sleep(20) && await_session_ready(uri, retries - 1)
        end

      _ ->
        Process.sleep(20)
        await_session_ready(uri, retries - 1)
    end
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      50 -> :ok
    end
  end

  # The boot-seeded default Session may live under either
  # `EzagentDomainChat.SessionSupervisor` (test-env seed via
  # `EzagentDomainChat.create_session/3` → `Ezagent.Kind.spawn(Session,
  # _)` → SessionSupervisor) OR the lazy-demand-spawn path that
  # routes through `Ezagent.SpawnRegistry.spawn/1` (which also uses
  # `Ezagent.Kind.spawn(Session, _)` since Session declares its
  # supervisor as `SessionSupervisor`). Resolve from the pid's
  # `$ancestors` dict so the terminate works regardless.
  defp resolve_session_supervisor(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        ancestors = Keyword.get(dict, :"$ancestors", [])

        Enum.find(ancestors, EzagentDomainChat.SessionSupervisor, fn ancestor ->
          ancestor == EzagentDomainChat.SessionSupervisor or
            ancestor == Ezagent.KindSupervisor
        end)

      _ ->
        EzagentDomainChat.SessionSupervisor
    end
  end
end
