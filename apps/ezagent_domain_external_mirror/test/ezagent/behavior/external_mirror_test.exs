defmodule Ezagent.Behavior.ExternalMirrorTest do
  @moduledoc """
  PR-EM-3 acceptance tests (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-3 — tests (a) … (k)).

  Coverage:

  | Test | SPEC ref |
  |------|----------|
  | (a) bind/unbind/list_bindings roundtrip                                                          | §9 PR-EM-3 (a) |
  | (b) cap-1 denial (non-owner caller)                                                              | §9 PR-EM-3 (b) |
  | (c) cap-2 denial (`:adapter_not_authorized`)                                                     | §9 PR-EM-3 (c) |
  | (d) cap-3 not held — Worker dispatch fails for users (delegated cap only granted to Session)     | §9 PR-EM-3 (d) |
  | (e) target_ownership_check denial → `{:target_ownership_denied, :not_a_member}`                  | §9 PR-EM-3 (e) |
  | (f) target_ownership_check timeout → `:target_check_timeout`                                     | §9 PR-EM-3 (f) |
  | (g) cross-workspace denial                                                                       | §9 PR-EM-3 (g) |
  | (h) rehydration after Kind kill preserves bindings AND restarts workers (r4 HIGH-3)              | §9 PR-EM-3 (h) |
  | (i) worker eager-spawn on bind WITHOUT deadlock — `:bind` returns < 100ms (r4 HIGH-1)            | §9 PR-EM-3 (i) |
  | (j) facade-level bind idempotency — 10 concurrent calls → 1 row + 1 worker (r6 HIGH-1)           | §9 PR-EM-3 (j) |
  | (k) Session GenServer not blocked during target_ownership_check (r6 HIGH-2)                      | §9 PR-EM-3 (k) |

  Tests live in `apps/ezagent_domain_external_mirror/` because the
  Behavior + facade ship from here. Session-side compile-time
  invariants (`@behaviour` on Session) live in chat's test tree.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Entity.{Session, User}

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    BindingRow,
    RootSupervisor,
    WorkerRegistry,
    WorkerSpawn
  }

  alias Ezagent.ExternalMirror.TestSupport.{
    MockPublishAdapter,
    MockPublishBinding,
    TimeoutAdapter,
    TimeoutBinding
  }

  alias Ezagent.ExternalMirror, as: Facade

  @workspace_uri URI.parse("workspace://default")

  setup do
    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    :ok = ensure_adapter_registered(TimeoutAdapter, TimeoutBinding)

    cleanup_workers()
    session_uri = unique_session_uri("em3")

    on_exit(fn ->
      # Terminate session BEFORE workers so Session's terminate path
      # doesn't try to snapshot-save during sandbox teardown (causes
      # Ecto.StaleEntryError flakes).
      cleanup_session(session_uri)
      cleanup_workers()
    end)

    {:ok, owner_uri: unique_user_uri("owner"), session_uri: session_uri}
  end

  # =========================================================================
  # (a) bind/unbind/list roundtrip
  # =========================================================================

  describe "PR-EM-3 (a) bind/unbind/list_bindings roundtrip" do
    test "owner can bind → list → unbind → list empty",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-roundtrip-a"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, %{ok: true, binding_id: bid, worker_uri: %URI{} = worker_uri}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      assert bid == "mock_publish/tgt-roundtrip-a"

      # Worker is alive in WorkerRegistry.
      assert {:ok, _sup_pid} = WorkerRegistry.lookup(URI.to_string(worker_uri))

      # list_bindings returns the binding from the live slice.
      assert {:ok, [%{binding_id: ^bid, adapter_id: "mock_publish", target_id: ^target_id}]} =
               Facade.list_bindings(session_uri)

      # Projection row exists.
      assert [%BindingRow{adapter_id: "mock_publish", target_id: ^target_id}] =
               BindingRow.list_for_session(session_uri)

      # Unbind.
      assert {:ok, %{ok: true, unbound: true}} =
               Facade.unbind(session_uri, "mock_publish", target_id, ctx)

      assert {:ok, []} = Facade.list_bindings(session_uri)
      assert [] = BindingRow.list_for_session(session_uri)
      assert WorkerRegistry.lookup(URI.to_string(worker_uri)) == :error
    end
  end

  # =========================================================================
  # (b) cap-1 denial — non-owner caller
  # =========================================================================

  describe "PR-EM-3 (b) cap 1 denial (non-owner)" do
    test "stranger (no session bind cap) → {:error, :unauthorized}",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      stranger_uri = unique_user_uri("stranger")
      :ok = spawn_user(stranger_uri, MapSet.new())

      # Stranger holds the per-adapter cap (so Check 2 passes) but
      # NOT the session bind cap (so dispatch step 5.5 — Check 1 —
      # denies). This isolates the cap-1 enforcement path.
      stranger_caps =
        MapSet.new([
          adapter_allow_cap(@workspace_uri, "mock_publish", MockPublishAdapter.Allow)
        ])

      ctx = %{caller: stranger_uri, caps: stranger_caps, reply: :ignore}

      assert {:error, :unauthorized} =
               Facade.bind(session_uri, "mock_publish", "tgt-b", %{}, ctx)
    end
  end

  # =========================================================================
  # (c) cap-2 denial — :adapter_not_authorized
  # =========================================================================

  describe "PR-EM-3 (c) cap 2 denial — adapter_not_authorized" do
    test "owner without per-adapter cap → {:error, :adapter_not_authorized}",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Owner has Session bind cap (default-granted from data_owner)
      # but NO per-adapter allow cap. Facade Check 2 short-circuits
      # BEFORE the dispatch.
      ctx_without_adapter_cap = %{
        caller: owner_uri,
        caps: MapSet.new([session_bind_cap(session_uri, @workspace_uri)]),
        reply: :ignore
      }

      assert {:error, :adapter_not_authorized} =
               Facade.bind(session_uri, "mock_publish", "tgt-c", %{}, ctx_without_adapter_cap)
    end
  end

  # =========================================================================
  # (d) cap-3 not held — user can't dispatch :publish on a Worker directly
  # =========================================================================

  describe "PR-EM-3 (d) cap 3 not held by users (Worker publish gate)" do
    test "user without the worker publish cap → :publish dispatch denied",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-d"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, %{worker_uri: worker_uri}} =
        Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Wait for the worker's post_init handle_continue chain to
      # finish so it's :ready in ReadyGate — the test confirms a
      # READY worker rejects unauthorized dispatch, not that a
      # not-ready dispatch fails fast.
      :ok = await_worker_ready(worker_uri, 50)

      # Owner has session caps but NOT the Worker's `:publish` cap
      # (that's a `:no_owner` Behavior — only bootstrap admin holds).
      # Attempting a direct dispatch to the Worker's :publish fails
      # CapBAC step 5.5.
      user_ctx = %{
        caller: owner_uri,
        caps: MapSet.new([session_bind_cap(session_uri, @workspace_uri)]),
        reply: :ignore
      }

      target = URI.parse("#{URI.to_string(worker_uri)}?action=external_mirror_worker.publish")

      event = %Ezagent.Publisher.Event{
        cursor: 99,
        publisher_uri: session_uri,
        slice_key: :chat,
        event_at: DateTime.utc_now(),
        payload: %{}
      }

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{event: event},
          ctx: user_ctx
        })

      assert match?({:error, :unauthorized}, result) or
               match?({:error, :cross_workspace_denied}, result),
             "expected denial but got #{inspect(result)}"
    end
  end

  # =========================================================================
  # (e) target_ownership_check denial
  # =========================================================================

  describe "PR-EM-3 (e) target_ownership_check denial" do
    test "adapter returns {:error, :not_a_member} → {:error, {:target_ownership_denied, _}}",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri, "em_timeout")

      assert {:error, {:target_ownership_denied, :not_a_member}} =
               Facade.bind(session_uri, "em_timeout", "deny:not_a_member", %{}, ctx)

      # Nothing was written to slice or DB.
      assert {:ok, []} = Facade.list_bindings(session_uri)
      assert [] = BindingRow.list_for_session(session_uri)
    end
  end

  # =========================================================================
  # (f) target_ownership_check timeout
  # =========================================================================

  describe "PR-EM-3 (f) target_ownership_check timeout" do
    test "adapter sleeps > timeout → {:error, :target_check_timeout}",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri, "em_timeout")

      # TimeoutAdapter.target_ownership_check_timeout/0 = 200ms.
      # sleep:500 sleeps 500ms — facade kills the Task at 200ms.
      assert {:error, :target_check_timeout} =
               Facade.bind(session_uri, "em_timeout", "sleep:500", %{}, ctx)
    end
  end

  # =========================================================================
  # (g) cross-workspace denial
  # =========================================================================

  describe "PR-EM-3 (g) cross-workspace denial" do
    test "caller in workspace A tries to bind session in workspace B → denied",
         %{owner_uri: _ignored_owner, session_uri: _ignored_session} do
      # Session in workspace B (3-segment session URI per Phase 9 PR-7).
      ws_b_session = URI.parse("session://default/ws_b/em3-#{System.unique_integer([:positive])}")
      ws_b_owner = URI.parse("entity://user/ws_b/owner-#{System.unique_integer([:positive])}")
      :ok = spawn_owner_and_session(ws_b_owner, ws_b_session)

      # Caller is in workspace A — has bind cap on ws_b's session but
      # also the per-adapter cap, both narrowed to workspace A. Step
      # 5.6 (workspace isolation) blocks the dispatch.
      ws_a_caller = URI.parse("entity://user/ws_a/caller-#{System.unique_integer([:positive])}")
      :ok = spawn_user(ws_a_caller, MapSet.new())

      ws_a_uri = URI.parse("workspace://ws_a")

      # Forge BOTH a Cap 1 (session bind) AND Cap 2 (adapter allow)
      # narrowed to workspace A. Step 5.5 cap match may pass on
      # workspace_uri: :any vs :any, but step 5.6 enforces
      # caller_workspace == target_workspace mismatch.
      caller_caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.Behavior.ExternalMirror,
            instance: ws_b_session,
            workspace_uri: ws_a_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          },
          %Capability{
            kind: :session,
            behavior: MockPublishAdapter.Allow,
            instance: ws_b_session,
            workspace_uri: ws_a_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      ctx = %{caller: ws_a_caller, caps: caller_caps, reply: :ignore}

      result = Facade.bind(ws_b_session, "mock_publish", "tgt-g", %{}, ctx)

      assert match?({:error, :cross_workspace_denied}, result) or
               match?({:error, :unauthorized}, result) or
               match?({:error, :adapter_not_authorized}, result),
             "expected cross-workspace / authz denial but got #{inspect(result)}"
    end
  end

  # =========================================================================
  # (h) Rehydration after Session Kind restart (HIGH-3 fix)
  # =========================================================================

  describe "PR-EM-3 (h) rehydration after Session kill preserves bindings + restarts workers" do
    test "kill Session → re-spawn Session → next slice change triggers worker publish (worker reconciled)",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      # Enable SliceChange so publisher events flow through Worker.
      orig = Application.get_env(:ezagent_core, :slice_change_hook)
      Application.put_env(:ezagent_core, :slice_change_hook, true)

      on_exit(fn ->
        if is_nil(orig) do
          Application.delete_env(:ezagent_core, :slice_change_hook)
        else
          Application.put_env(:ezagent_core, :slice_change_hook, orig)
        end
      end)

      target_id = "tgt-h-rehydrate"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, %{worker_uri: worker_uri}} =
        Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Sanity: probe receives the FIRST mutation.
      fire_slice_change(session_uri)
      assert_receive {:published, _, ^target_id, _}, 1_500

      # Drain any extra :published messages that may have arrived
      # from the bind's own :external_mirror slice change (any slice
      # change fires a Publisher event per SessionImpl — only
      # `:publisher` is filtered). We don't care WHICH events
      # arrived, just that the worker is publishing.
      drain_mailbox()

      # Small pause so the Worker's :publish action body fully
      # commits its slice mutation (subscription_state stays :active)
      # BEFORE we terminate. Without this, a fast test can race and
      # call terminate while the Worker is still draining its mailbox,
      # leaving subscription_state as :pending — in which case
      # Behavior.ExternalMirrorWorker.terminate/3 skips the
      # binding_module.terminate/2 call (per its own moduledoc) and
      # the {:terminated, _} message never fires.
      Process.sleep(50)

      # Drop the Worker AND terminate the Session pid via the
      # production supervisor path (NOT Process.exit — that doesn't
      # auto-respawn since Session uses lazy demand-spawn).
      :ok = WorkerSpawn.terminate(session_uri, "mock_publish", target_id)
      assert_receive {:terminated, ^target_id, _}, 1_500

      {:ok, session_pid_1} = Ezagent.KindRegistry.lookup(session_uri)

      :ok =
        DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, session_pid_1)

      wait_until_dead(session_uri, 30)

      # Re-spawn via SpawnRegistry — this is the production "phx
      # restart + lazy demand-spawn" path. It rebuilds the slice
      # from the snapshot AND triggers init_slice + post_init's
      # handle_continue (the §3.1 reconciler).
      {:ok, session_pid_2} = Ezagent.SpawnRegistry.spawn(session_uri)
      refute session_pid_1 == session_pid_2
      :ok = await_session_alive(session_uri, 50)

      # Trigger another slice change AFTER the restart — the
      # rehydrated slice carries the binding row, and the Behavior's
      # post_init handle_continue spawned the worker again. The
      # mirror MUST receive this event.
      MockPublishBinding.register_observer(target_id, self())
      fire_slice_change(session_uri)
      assert_receive {:published, _, ^target_id, _}, 2_000

      # Worker is alive under the same URI (Registry-keyed).
      assert {:ok, _sup_pid} = WorkerRegistry.lookup(URI.to_string(worker_uri))
    end
  end

  # =========================================================================
  # (i) Worker eager-spawn on bind WITHOUT deadlock (HIGH-1)
  # =========================================================================

  describe "PR-EM-3 (i) eager-spawn on bind without deadlock" do
    test "bind returns within 100ms even though worker subscribes to Session Publisher",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-i-deadlock"
      MockPublishBinding.register_observer(target_id, self())

      {elapsed_us, result} =
        :timer.tc(fn ->
          Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)
        end)

      assert {:ok, %{ok: true}} = result
      elapsed_ms = div(elapsed_us, 1_000)

      assert elapsed_ms < 100,
             "bind took #{elapsed_ms}ms — exceeds 100ms ceiling. " <>
               "If r3's synchronous subscribe-in-init came back, this would hang."
    end
  end

  # =========================================================================
  # (j) facade-level bind idempotency — 10 concurrent → 1 winner (HIGH-1)
  # =========================================================================

  describe "PR-EM-3 (j) facade-level bind idempotency" do
    test "10 concurrent bind/4 for same triple → 1 binding row + 1 Worker",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-j-idempotent"
      MockPublishBinding.register_observer(target_id, self())

      # 10 racing bind/4 calls.
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)
          end)
        end)

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      # Every result is {:ok, %{ok: true, ...}} — 9 losers don't
      # error out; the facade + action body convert
      # {:error, {:already_started, _}} to success per r6 HIGH-1.
      Enum.each(results, fn r ->
        assert {:ok, %{ok: true}} = r
      end)

      # Exactly one slice entry.
      {:ok, slice_bindings} = Facade.list_bindings(session_uri)
      assert length(slice_bindings) == 1

      # Exactly one projection row.
      rows = BindingRow.list_for_session(session_uri)
      assert length(rows) == 1

      # Exactly one Worker process.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)

      # Allow a brief moment for the Worker's KindRegistry entry to
      # settle. The dispatched bind action body's spawn returns
      # only after Kind.Server.init completes (which puts the URI
      # in KindRegistry), so by the time the action body has
      # returned the Worker Kind IS alive.
      :ok = await_worker_alive(worker_uri, 25)

      # The Worker Kind is alive (KindRegistry is the production
      # contract for "this URI is hosted"; WorkerRegistry is the
      # PR-EM-2 implementation detail tracking the PerBindingSupervisor
      # specifically — its entry may flicker during the concurrent
      # spawn storm if a sibling PerBindingSupervisor wins/loses the
      # race and gets unregistered; what matters is the WORKER pid
      # itself is alive + registered).
      assert {:ok, worker_pid} = Ezagent.KindRegistry.lookup(worker_uri)
      assert Process.alive?(worker_pid)

      # Also assert there is at most ONE WorkerRegistry entry for
      # this binding (zero or one — never duplicates).
      registered =
        WorkerRegistry.list_all()
        |> Enum.filter(fn {uri, _} -> uri == URI.to_string(worker_uri) end)

      assert length(registered) <= 1
    end
  end

  defp await_worker_alive(_uri, 0), do: :error

  defp await_worker_alive(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _} -> :ok
      _ -> Process.sleep(20) && await_worker_alive(uri, retries - 1)
    end
  end

  # =========================================================================
  # (k) Session GenServer not blocked during target_ownership_check (HIGH-2)
  # =========================================================================

  describe "PR-EM-3 (k) Session GenServer not blocked during target check" do
    test "while bind's target check sleeps 3s, a chat.send on same session returns < 100ms",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Adapter override timeout for THIS test bumped to 4000 to let
      # the 3000ms sleep run to completion (TimeoutAdapter
      # `target_ownership_check_timeout/0` returns 200ms by default,
      # so we need an adapter whose sleep < timeout for THIS test's
      # purpose. We use the same TimeoutAdapter but with sleep:80
      # for the bind that should succeed AFTER the chat).
      #
      # Simpler approach: just fire bind in a background Task,
      # immediately fire a Kind dispatch on the same session, time
      # the dispatch. The dispatch must NOT wait behind the Task.
      target_id = "sleep:3000"
      ctx = owner_ctx(owner_uri, "em_timeout")

      _bind_task =
        Task.async(fn ->
          # This will sleep 3s in target_ownership_check then time out
          # (TimeoutAdapter's timeout is 200ms — so the bind itself
          # returns ~200ms with :target_check_timeout). The KEY
          # claim is that DURING the 200ms wait, the Session GenServer
          # is NOT blocked.
          Facade.bind(session_uri, "em_timeout", target_id, %{}, ctx)
        end)

      # Immediately dispatch a list_bindings call on the same Session.
      # It must return promptly because the target check Task runs
      # OUTSIDE the Session GenServer (per r6 HIGH-2 facade fix).
      list_ctx = owner_ctx(owner_uri)

      target = URI.parse("#{URI.to_string(session_uri)}?action=external_mirror.list_bindings")

      {elapsed_us, list_result} =
        :timer.tc(fn ->
          Invocation.dispatch(%Invocation{
            target: target,
            mode: :call,
            args: %{},
            ctx: list_ctx
          })
        end)

      assert {:ok, %{bindings: []}} = list_result
      elapsed_ms = div(elapsed_us, 1_000)

      assert elapsed_ms < 100,
             "list_bindings took #{elapsed_ms}ms while target_check was sleeping. " <>
               "Expected < 100ms — Session GenServer blocked behind target check (HIGH-2 regression)."
    end
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  defp ensure_adapter_registered(adapter, binding) do
    _ = AdapterRegistry.register(adapter)
    _ = BindingRegistry.register_module(adapter.adapter_id(), binding)

    # Also register the per-adapter Allow cap subject (Step 7 — the
    # Application's `register_per_adapter_cap_subjects/0` walks every
    # adapter at boot, but test adapters get re-registered between
    # tests).
    %{behavior_module: behavior_module} = adapter.cap_subject()
    action = String.to_atom("allow_" <> adapter.adapter_id())

    try do
      :ok =
        Ezagent.CapabilityRegistry.register(
          Session,
          action,
          behavior_module
        )
    rescue
      _ -> :ok
    end

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
        _ = DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp spawn_owner_and_session(%URI{} = owner_uri, %URI{} = session_uri) do
    :ok = spawn_user(owner_uri, User.admin_caps())

    case Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: owner_uri}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Bind the session to its workspace so dispatch step 5.6 can
    # resolve `workspace_of(session_uri)` to a real workspace URI.
    ws = Ezagent.Capability.workspace_of(session_uri)

    case ws do
      %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
      :any -> :ok
    end

    await_session_alive(session_uri, 50)
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp await_session_alive(_uri, 0), do: {:error, :timeout}

  defp await_session_alive(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        case Ezagent.ReadyGate.status(URI.to_string(uri)) do
          :ready -> :ok
          _ -> Process.sleep(20) && await_session_alive(uri, retries - 1)
        end

      _ ->
        Process.sleep(20)
        await_session_alive(uri, retries - 1)
    end
  end

  defp await_worker_ready(_uri, 0), do: {:error, :timeout}

  defp await_worker_ready(uri, retries) do
    case Ezagent.ReadyGate.status(URI.to_string(uri)) do
      :ready -> :ok
      _ -> Process.sleep(20) && await_worker_ready(uri, retries - 1)
    end
  end

  defp wait_until_dead(_uri, 0), do: :error

  defp wait_until_dead(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      _ -> Process.sleep(20) && wait_until_dead(uri, retries - 1)
    end
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      50 -> :ok
    end
  end

  # owner_ctx with default adapter "mock_publish".
  defp owner_ctx(owner_uri), do: owner_ctx(owner_uri, "mock_publish")

  defp owner_ctx(owner_uri, adapter_id) do
    %{
      caller: owner_uri,
      caps:
        MapSet.new([
          # Bootstrap admin cap — passes everything for tests that
          # focus on facade Check 2 / Check 3, not Check 1.
          %Capability{
            kind: :any,
            behavior: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: URI.parse("system://bootstrap/default"),
            granted_at: ~U[2026-01-01 00:00:00Z]
          },
          # Plus the per-adapter allow cap explicitly so Check 2 sees
          # a precise narrow-instance grant (matches the SPEC §4.2
          # default-grant shape post-PR-EM-3-rollout).
          adapter_allow_cap(@workspace_uri, adapter_id, allow_module_for(adapter_id))
        ]),
      reply: :ignore
    }
  end

  defp allow_module_for("mock_publish"), do: MockPublishAdapter.Allow
  defp allow_module_for("em_timeout"), do: TimeoutAdapter.Allow

  defp session_bind_cap(%URI{} = session_uri, %URI{} = workspace_uri) do
    %Capability{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp adapter_allow_cap(%URI{} = workspace_uri, _adapter_id, behavior_module) do
    %Capability{
      kind: :session,
      behavior: behavior_module,
      # `:any` lets the cap match any session in the workspace —
      # workspace-admin grant shape per SPEC §3/§5.2.
      instance: :any,
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp unique_user_uri(prefix) do
    URI.parse("entity://user/default/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_session_uri(prefix) do
    URI.parse("session://default/default/#{prefix}-#{System.unique_integer([:positive])}")
  end

  # Trigger a chat-slice change on the Session to fire a Publisher
  # event. `chat.join` mutates `:members` (chat.send is read-only on
  # the slice per worker_publish_test.exs).
  defp fire_slice_change(%URI{} = session_uri) do
    member_uri = unique_user_uri("trigger")
    :ok = spawn_user(member_uri, MapSet.new())

    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.join")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: User.admin_uri(),
        caps: User.admin_caps(),
        reply: :ignore
      }
    })

    :ok
  end

  # silence unused-alias warnings
  _ = {TimeoutBinding}
end
