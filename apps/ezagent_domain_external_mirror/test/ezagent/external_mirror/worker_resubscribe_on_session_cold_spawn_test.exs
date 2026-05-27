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
  - The new Session's `:publisher.subscribers` rehydrates from
    snapshot as `%{}` (stale persisted pids dropped by the
    `init_slice/1` → snapshot-merge codepath).

  ## Pre-fix bug

  The still-alive Worker had no way to re-subscribe. The next slice
  mutation would publish into an empty subscriber map and silently
  drop. This was the Feishu e2e silent-drop discovered 2026-05-27
  (3 messages dispatched; worker's `publish_count` showed 2 — the
  FIRST after cold-spawn was lost).

  ## Post-fix wiring

  - `Ezagent.PublisherLifecycle` (in `:ezagent_core`) provides a
    per-publisher-URI lifecycle topic.
  - `Ezagent.Behavior.Publisher.SessionImpl.handle_continue/3`
    broadcasts `{:publisher_alive, self_uri}` AFTER `:announce_ready`.
  - `Ezagent.Behavior.ExternalMirrorWorker.handle_continue/3`
    subscribes to that topic.
  - `Ezagent.Behavior.ExternalMirrorWorker.handle_kind_message/3`
    `{:publisher_alive, _}` clause re-runs
    `subscribe_to_session_publisher/2`.

  Idempotent at every layer:
  - Publisher `ensure_monitored/2` dedupes by pid.
  - Worker's re-subscribe just refreshes `publisher_cursor`.

  ## Test shape

  Spawn the worker via the direct `WorkerSpawn.spawn` path (matches
  `worker_publish_test.exs` — bypasses the bind facade so caps don't
  enter the picture). Drive a baseline publish to confirm the wire
  is alive. Terminate the default Session via its supervisor,
  re-spawn via `SpawnRegistry.spawn/1`, and confirm the FIRST slice
  change after cold-spawn reaches the Worker.
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

      # Production-faithful scenario: force the persisted snapshot
      # to carry an EMPTY `:publisher.subscribers` map. In a real
      # BEAM restart the pids in the snapshot are non-routable
      # (PIDs are local to a BEAM node and a fresh BEAM reissues
      # them); same-VM `term_to_binary`/`binary_to_term` preserves
      # them as still-routable values, so a vanilla test cannot
      # reproduce the prod silent-drop without simulating the
      # stale-pid map. We do it via `:sys.replace_state` on the
      # SessionImpl `:publisher` slice — clearing `subscribers` +
      # `monitors` so the snapshot persisted via the standard
      # `:on_change` codepath captures the empty shape.
      :sys.replace_state(session_pid_1, fn state ->
        new_publisher = %{
          state.state.publisher
          | subscribers: %{},
            monitors: %{}
        }

        put_in(state.state.publisher, new_publisher)
      end)

      # Force a snapshot write so the empty subscribers shape lands
      # on disk before we terminate + cold-spawn. Use `Snapshot.save_now/3`
      # against the current state.
      kind_state = :sys.get_state(session_pid_1)
      :ok = Ezagent.Kind.Snapshot.save_now(session_uri, kind_state.kind, kind_state.state)

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
      # comes back as `%{}` (the persisted shape is reset via the
      # init_slice → merge codepath).
      {:ok, session_pid_2} = Ezagent.SpawnRegistry.spawn(session_uri)
      refute session_pid_1 == session_pid_2
      :ok = await_session_ready(session_uri, 100)

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
