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
    NOT under `EzagentDomainInstanceMessage.SessionSupervisor` — they have
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
  - `Ezagent.ActionSet.Publisher.SessionImpl.on_ready/2` broadcasts
    `{:publisher_alive, self_uri}` AFTER `Ezagent.ReadyGate.mark_ready/1`
    has flipped (codex round-1 FAIL #6 — pre-fix this lived in
    `handle_continue/3` and raced peer `:call` re-subscribes against
    the not-yet-flipped ReadyGate).
  - `Ezagent.ActionSet.Publisher.SessionImpl.reconcile_after_load/2`
    clears the transient `:subscribers` + `:monitors` maps on
    snapshot load (codex round-1 CONCERN #3 — stale pids/refs from
    a previous BEAM cannot be routable / demonitorable; clearing
    them on load makes the transient nature of subscribership
    explicit and forces the lifecycle handshake on every cold spawn).
  - `Ezagent.ActionSet.ExternalMirrorWorker.handle_continue/3`
    subscribes to the lifecycle topic.
  - `Ezagent.ActionSet.ExternalMirrorWorker.handle_kind_message/3`
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

  `EzagentDomainInstanceMessage` is NOT a runtime dep of
  `ezagent_domain_external_mirror` (cycle break). When this file is
  the only test file that triggers (e.g. `mix test path/to/this`),
  `:ezagent_domain_session` is not auto-started — its
  `SessionSupervisor`, scheme registration, etc. are absent and
  `SpawnRegistry.spawn(session_uri)` would fail with
  `{:error, :no_spawn_fn}`. We explicitly `Application.ensure_all_started/1`
  the chat app in setup; the umbrella-wide test run is a no-op
  (app already started).
  """

  # Remediation P6 (sandbox isolation): spawns Session/Worker Kinds that run
  # Repo queries in other processes; `EzagentCore.DataCase` provides the
  # shared sandbox owner + P6 drain so they don't hit
  # `DBConnection.OwnershipError`. See WorkerPublishTest for the full note.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    RootSupervisor,
    WorkerRegistry,
    WorkerSpawn
  }

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.ExternalMirror.TestSupport.{MockPublishAdapter, MockPublishBinding}
  alias Ezagent.Test.SnapshotFixtures

  setup do
    # codex round-1 CONCERN #7 — see moduledoc. Chat is a compile-
    # but-not-runtime dep here (the cycle break). Force-start so
    # `EzagentDomainInstanceMessage.SessionSupervisor` + the `"session"` scheme
    # spawn fn exist when we resolve / cold-spawn the default Session.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    session_uri = unique_session_uri("worker-resub-cold")
    owner_uri = unique_user_uri("worker-resub-owner")
    :ok = spawn_owner_and_session(owner_uri, session_uri)

    on_exit(fn ->
      cleanup_session(session_uri)
      cleanup_workers()
    end)

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

    {:ok, session_uri: session_uri}
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

      # Production-faithful path: snapshot the LIVE state. `:on_change`
      # would write the same snapshot on any future slice mutation; forcing
      # it synchronously here makes the assertion time-independent.
      #
      # Post-lifecycle migration (remediation 2026-05-30): `subscribers` +
      # `monitors` are now TRANSIENTS on the `:publisher` slice
      # (`%{state: …, transients: %{subscribers, monitors}}`), NOT persisted
      # slice fields. The cold-restart bug the old `reconcile_after_load/2`
      # scrubbed (a snapshotted-then-rehydrated dead subscriber pid) is now
      # IMPOSSIBLE BY CONSTRUCTION — `Snapshot.save_now` only persists the
      # `.state` sub-key, so the live worker pid never reaches the snapshot,
      # and every `activate/2` rebuilds `subscribers` empty. So we read the
      # LIVE subscribers from the `transients` container (to confirm the
      # pre-condition that the Worker subscribed pre-vanish) and no longer
      # assert the snapshot carries the pid (it correctly does not — that is
      # the structural guarantee the migration delivered).
      kind_state = :sys.get_state(session_pid_1)
      :ok = SnapshotFixtures.save_kind_snapshot(session_uri, kind_state.kind, kind_state.state)

      live_subscribers =
        get_in(kind_state.state, [:publisher, :transients, :subscribers]) || %{}

      assert is_map(live_subscribers) and map_size(live_subscribers) >= 1,
             "test pre-condition broken — the Worker did not subscribe to the Session " <>
               "Publisher pre-vanish; cold-spawn scenario does not apply. " <>
               "live subscribers (transient)=#{inspect(live_subscribers)}"

      # Terminate the Session via its supervisor (boot-seed path uses
      # EzagentDomainInstanceMessage.SessionSupervisor; lazy-demand spawn path
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
      #
      # NOTE (codex r2 MEDIUM): we do NOT assert
      # `subscribers == %{}` here. By the time the Session reaches
      # `:ready` and `:sys.get_state/1` returns, the lifecycle
      # handshake may have already re-attached the Worker — the very
      # behaviour this test exercises. Direct `reconcile_after_load/2`
      # unit coverage lives in
      # `apps/ezagent_domain_session/test/ezagent/behavior/publisher/session_impl_reconcile_after_load_test.exs`
      # (race-free, pure-function test). This integration test
      # exercises only the END-TO-END invariant: the first slice
      # change after cold-spawn must reach the still-alive Worker.
      {:ok, session_pid_2} = Ezagent.SpawnRegistry.spawn(session_uri)
      refute session_pid_1 == session_pid_2
      :ok = await_session_ready(session_uri, 100)

      # The Worker is STILL the same pid (post-cold-spawn invariant).
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      binding_uri = URI.to_string(worker_uri)

      {:ok, sup_pid_after} = WorkerRegistry.lookup(binding_uri)
      assert sup_pid_after == sup_pid_before

      [{_id, worker_kind_pid_after, _, _}] = Supervisor.which_children(sup_pid_after)

      assert worker_kind_pid_after == worker_kind_pid_before,
             "Worker Kind pid changed across Session cold-spawn — this test asserts the " <>
               "*Worker stayed alive* across the Session vanish. If the Worker died, the " <>
               "scenario reduces to PR-EM-3 (h) and this test is no longer covering task #49."

      # Re-register the observer (test infra may have flushed), then
      # wait for the PublisherLifecycle broadcast + Worker re-subscribe
      # to actually land. A fixed sleep is flaky under the full suite:
      # the lifecycle broadcast fires in SessionImpl's `on_ready/2`,
      # then the Worker handles `:publisher_alive`, dispatches a
      # `:subscribe_from` call, and the Session mutates its transient
      # subscriber map. The observable postcondition is the Worker's pid
      # in that map.
      MockPublishBinding.register_observer(target_id, self())
      :ok = await_worker_subscribed(session_uri, worker_uri, 100)

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
                       "`Ezagent.ActionSet.Publisher.SessionImpl.on_ready/2` (fires AFTER " <>
                       "ReadyGate flip per codex r1 FAIL #6) + the matching " <>
                       "`:publisher_alive` clause in " <>
                       "`Ezagent.ActionSet.ExternalMirrorWorker.handle_kind_message/3`."
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

  defp cleanup_session(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  end

  defp spawn_owner_and_session(%URI{} = owner_uri, %URI{} = session_uri) do
    :ok = spawn_user(owner_uri, MapSet.new([Ezagent.Capability.admin_genesis_cap()]))

    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: owner_uri,
           behaviors: Session.behaviors()
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = workspace_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      :any -> :ok
    end

    await_session_ready(session_uri, 50)
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Drives a Publisher event by mutating the Session's `:chat` slice
  # via `:chat.join` (same pattern as `worker_publish_test.exs`'s
  # helper). SliceChange fires only on actual slice mutation, so a
  # fresh member each call guarantees a new event.
  defp send_chat_to_session(%URI{} = session_uri) do
    member_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/em-pub-test-#{System.unique_integer([:positive])}"
      )

    :ok = spawn_user_with_retry(member_uri, 20)

    admin_uri = Ezagent.URI.new!("entity://system/user/admin")
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    dispatch_chat_join_with_retry(target, member_uri, admin_uri, 20)
  end

  defp spawn_user_with_retry(member_uri, 0),
    do: flunk("timed out spawning chat member for publisher event: #{URI.to_string(member_uri)}")

  defp spawn_user_with_retry(member_uri, attempts) do
    case Ezagent.Kind.spawn(User, %{uri: member_uri, initial_caps: MapSet.new()}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {:persistence_failed, %{message: "Database busy"}}} ->
        Process.sleep(25)
        spawn_user_with_retry(member_uri, attempts - 1)

      other ->
        flunk("failed to spawn chat member for publisher event: #{inspect(other)}")
    end
  end

  defp dispatch_chat_join_with_retry(target, member_uri, _admin_uri, 0),
    do:
      flunk(
        "timed out dispatching chat.join for publisher event: " <>
          "target=#{URI.to_string(target)} member=#{URI.to_string(member_uri)}"
      )

  defp dispatch_chat_join_with_retry(target, member_uri, admin_uri, attempts) do
    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: admin_uri,
          authenticated_principal: admin_uri,
          caps: admin_caps(target, admin_uri),
          reply: :ignore
        }
      })

    case result do
      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, {:persistence_failed, %{message: "Database busy"}}} ->
        Process.sleep(25)
        dispatch_chat_join_with_retry(target, member_uri, admin_uri, attempts - 1)

      other ->
        flunk("chat.join failed while driving publisher event: #{inspect(other)}")
    end
  end

  defp admin_caps(target, admin_uri),
    do: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, admin_uri)])

  defp unique_user_uri(prefix) do
    Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_session_uri(prefix) do
    Ezagent.URI.new!(
      "session://team-alpha/default/#{prefix}-#{System.unique_integer([:positive])}"
    )
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

  defp await_worker_subscribed(session_uri, worker_uri, 0),
    do:
      flunk(
        "worker did not re-subscribe to Session publisher: " <>
          "session=#{URI.to_string(session_uri)} worker=#{URI.to_string(worker_uri)}"
      )

  defp await_worker_subscribed(session_uri, worker_uri, retries) do
    with {:ok, worker_pid} <- Ezagent.KindRegistry.lookup(worker_uri),
         {:ok, %{transients: %{subscribers: subscribers}}} <-
           Ezagent.Kind.get_raw_slice(session_uri, :publisher),
         true <- Map.has_key?(subscribers, worker_pid) do
      :ok
    else
      _ ->
        Process.sleep(20)
        await_worker_subscribed(session_uri, worker_uri, retries - 1)
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
  # `EzagentDomainInstanceMessage.SessionSupervisor` (test-env seed via
  # `EzagentDomainInstanceMessage.SessionCreator.create_session/3` → `Ezagent.Kind.spawn(Session,
  # _)` → SessionSupervisor) OR the lazy-demand-spawn path that
  # routes through `Ezagent.SpawnRegistry.spawn/1` (which also uses
  # `Ezagent.Kind.spawn(Session, _)` since Session declares its
  # supervisor as `SessionSupervisor`). Resolve from the pid's
  # `$ancestors` dict so the terminate works regardless.
  defp resolve_session_supervisor(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        ancestors = Keyword.get(dict, :"$ancestors", [])

        Enum.find(ancestors, EzagentDomainInstanceMessage.SessionSupervisor, fn ancestor ->
          ancestor == EzagentDomainInstanceMessage.SessionSupervisor or
            ancestor == Ezagent.KindSupervisor
        end)

      _ ->
        EzagentDomainInstanceMessage.SessionSupervisor
    end
  end
end
