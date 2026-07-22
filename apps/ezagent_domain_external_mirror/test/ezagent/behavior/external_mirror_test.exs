defmodule Ezagent.ActionSet.ExternalMirrorTest do
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
    FacadeNonceTable,
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

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

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
               Facade.list_bindings(session_uri, ctx)

      # Projection row exists.
      assert [%BindingRow{adapter_id: "mock_publish", target_id: ^target_id}] =
               BindingRow.list_for_session(session_uri)

      # Unbind.
      assert {:ok, %{ok: true, unbound: true}} =
               Facade.unbind(session_uri, "mock_publish", target_id, ctx)

      assert {:ok, []} = Facade.list_bindings(session_uri, ctx)
      assert [] = BindingRow.list_for_session(session_uri)
      assert WorkerRegistry.lookup(URI.to_string(worker_uri)) == :error
    end

    # codex r1 CRIT regression test (2026-05-25): two sessions binding
    # the SAME (adapter, target) must produce TWO distinct projection
    # rows, and unbinding one MUST NOT delete the other's row.
    #
    # Pre-fix, the DB row `:id` was just `"<adapter>/<target>"` —
    # session-unscoped — so both inserts would collide on the PK and
    # unbinding from session A would clobber session B's row.
    test "two sessions can bind the same (adapter, target) without cross-session row collision" do
      owner_a = unique_user_uri("owner-a")
      owner_b = unique_user_uri("owner-b")
      session_a = unique_session_uri("em3-cross-a")
      session_b = unique_session_uri("em3-cross-b")

      :ok = spawn_owner_and_session(owner_a, session_a)
      :ok = spawn_owner_and_session(owner_b, session_b)

      on_exit(fn ->
        cleanup_session(session_a)
        cleanup_session(session_b)
      end)

      shared_target = "tgt-shared-across-sessions"
      MockPublishBinding.register_observer(shared_target, self())

      ctx_a = owner_ctx(owner_a)
      ctx_b = owner_ctx(owner_b)

      assert {:ok, %{ok: true}} =
               Facade.bind(session_a, "mock_publish", shared_target, %{}, ctx_a)

      assert {:ok, %{ok: true}} =
               Facade.bind(session_b, "mock_publish", shared_target, %{}, ctx_b)

      # Both sessions have the binding in their slice.
      assert {:ok, [%{adapter_id: "mock_publish", target_id: ^shared_target}]} =
               Facade.list_bindings(session_a, ctx_a)

      assert {:ok, [%{adapter_id: "mock_publish", target_id: ^shared_target}]} =
               Facade.list_bindings(session_b, ctx_b)

      # Two distinct projection rows.
      rows_a = BindingRow.list_for_session(session_a)
      rows_b = BindingRow.list_for_session(session_b)
      assert length(rows_a) == 1
      assert length(rows_b) == 1
      [%BindingRow{id: id_a}] = rows_a
      [%BindingRow{id: id_b}] = rows_b
      assert id_a != id_b

      # Unbind from session_a — session_b's row MUST survive.
      assert {:ok, %{ok: true, unbound: true}} =
               Facade.unbind(session_a, "mock_publish", shared_target, ctx_a)

      assert [] = BindingRow.list_for_session(session_a)
      assert [%BindingRow{id: ^id_b}] = BindingRow.list_for_session(session_b)
      assert {:ok, [_]} = Facade.list_bindings(session_b, ctx_b)
    end

    # codex r1 HIGH regression test (2026-05-25): caller-supplied
    # `opts` keys must NOT be atomized on rehydration (atom-leak DoS).
    #
    # Decoded opts must come back as a string-keyed map; the test
    # asserts the type so a regression to `String.to_atom/1` would
    # fail loudly.
    test "rehydrated opts keys stay as STRINGS (no String.to_atom on caller input)" do
      session_uri = unique_session_uri("em3-opts-strings")
      owner_uri = unique_user_uri("opts-owner")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      ctx = owner_ctx(owner_uri)
      target_id = "tgt-opts-keys"
      MockPublishBinding.register_observer(target_id, self())

      # Caller-controlled opts with a key that does NOT exist as an
      # atom in the system. If decode_opts ever calls String.to_atom/1
      # this would silently create a new atom every restart.
      malicious_opts = %{"caller_controlled_unbounded_key" => 1}

      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, malicious_opts, ctx)

      # Re-spawn the Session to exercise the init_slice rehydration path.
      {:ok, pid_a} = Ezagent.KindRegistry.lookup(session_uri)

      :ok =
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid_a)

      wait_until_dead(session_uri, 30)
      {:ok, _pid_b} = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = await_session_alive(session_uri, 50)

      # Slice's binding carries the opts MAP back — keys MUST be
      # strings (per codex r1 HIGH fix). String.to_atom would have
      # converted "caller_controlled_unbounded_key" to an atom.
      {:ok, [%{opts: opts}]} = Facade.list_bindings(session_uri, ctx)
      assert is_map(opts)

      Enum.each(Map.keys(opts), fn k ->
        assert is_binary(k),
               "opts key #{inspect(k)} is an atom — String.to_atom regressed (codex r1 HIGH)"
      end)

      assert opts["caller_controlled_unbounded_key"] == 1
    end
  end

  # =========================================================================
  # Task #53 regression — slice/projection desync on unbind
  # =========================================================================
  #
  # 2026-05-27 02:53 repro (Allen): facade returned
  # `{:ok, %{ok: true, unbound: true}}` but the `external_mirror_bindings`
  # row was NOT deleted. The previous `BindingRow.delete_by_id/1`
  # returned bare `:ok` when `Repo.get` found nothing, so a row_id
  # mismatch (or any other not-found scenario) silently produced
  # "successful" slice mutations alongside an undeleted projection
  # row — surfacing later as `:ambiguous_chat_binding` on the inbound
  # dispatch.
  #
  # Post-fix: when the slice claims the binding exists but the
  # projection delete reports `:not_found`, the action body returns
  # `{:error, :projection_desync}` instead of `{:ok, ...}`. The
  # corresponding `delete_by_id/1` / `delete_by_natural_key/3` return
  # shape is pinned by `Ezagent.ExternalMirror.BindingRowTest`.
  describe "Task #53 — unbind projection sync" do
    test "deletes the projection row on the happy path",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-task-53-happy"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      assert [%BindingRow{}] = BindingRow.list_for_session(session_uri)

      assert {:ok, %{ok: true, unbound: true}} =
               Facade.unbind(session_uri, "mock_publish", target_id, ctx)

      # The actual bug — projection row MUST be gone after unbind.
      assert [] = BindingRow.list_for_session(session_uri)
    end

    test "returns {:error, :projection_desync} when slice claims binding but DB row is missing",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-task-53-desync"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Simulate the desync: nuke the projection row out from under
      # the slice via direct SQL (the same kind of operator hand-fix
      # / parallel-process race that produces the symptom in prod).
      row_id = BindingRow.row_id(session_uri, "mock_publish", target_id)
      assert %BindingRow{} = EzagentCore.Repo.get(BindingRow, row_id)
      _ = EzagentCore.Repo.delete!(EzagentCore.Repo.get!(BindingRow, row_id))
      assert nil == EzagentCore.Repo.get(BindingRow, row_id)

      # Slice still has the binding (we bypassed the action path
      # when we hand-deleted the row). Pre-task-53 the facade would
      # have returned `{:ok, %{ok: true, unbound: true}}` and we
      # would have falsely advertised durability. Post-fix it
      # surfaces the desync as a hard error.
      assert {:error, :projection_desync} =
               Facade.unbind(session_uri, "mock_publish", target_id, ctx)

      # codex PR #418 r1 HIGH ordering invariant (2026-05-27): the
      # post-r1 ordering is delete-then-terminate, so on a desync
      # error the slice's binding remains. Pre-r1 ordering would
      # have terminated the worker before discovering the desync —
      # observable as "active slice binding with no live worker".
      # Check the slice didn't lose the binding (a successful unbind
      # would have).
      assert {:ok, [%{adapter_id: "mock_publish", target_id: ^target_id}]} =
               Facade.list_bindings(session_uri, ctx)
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

      # The publish gate must be exercised by a caller that GENUINELY
      # lacks the Worker `:publish` cap. The shared `owner_uri` is spawned
      # with `system://bootstrap` caps (all-`:any`), so its IDENTITY SLICE
      # holds a wildcard cap — and CapBAC step 5.5's slice-backed
      # `holds_cap?` path (correctly) authorizes anything for a bootstrap
      # holder, regardless of the narrowed `user_ctx.caps`. Using `owner_uri`
      # as the caller therefore can NEVER be denied; the original assertion
      # only "passed" historically because an unrelated deadlock made the
      # bind above time out before reaching here (masking a real
      # contradiction — verified red at baseline 54df56c9). Spawn a fresh
      # NON-privileged user holding ONLY the session bind cap (memory
      # `feedback_e2e_prefers_non_admin_user`) and dispatch as THEM.
      unpriv_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/unpriv-d-#{System.unique_integer([:positive])}"
        )

      :ok = spawn_user(unpriv_uri, MapSet.new())

      user_ctx = %{
        caller: unpriv_uri,
        authenticated_principal: unpriv_uri,
        caps: MapSet.new(),
        reply: :ignore
      }

      target =
        Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=external_mirror_worker.publish")

      event = %Ezagent.Publisher.Event{
        cursor: 99,
        publisher_uri: session_uri,
        slice_key: :session,
        event_at: DateTime.utc_now(),
        payload: %{}
      }

      result =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{event: event},
          ctx: user_ctx
        })

      assert {:error, :missing_cap} = result
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
      assert {:ok, []} = Facade.list_bindings(session_uri, ctx)
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
      ws_b_session =
        Ezagent.URI.new!("session://ws_b/default/em3-#{System.unique_integer([:positive])}")

      ws_b_owner =
        Ezagent.URI.new!("entity://ws_b/user/owner-#{System.unique_integer([:positive])}")

      :ok = spawn_owner_and_session(ws_b_owner, ws_b_session)

      # Caller is in workspace A — has bind cap on ws_b's session but
      # also the per-adapter cap, both narrowed to workspace A. Step
      # 5.6 (workspace isolation) blocks the dispatch.
      ws_a_caller =
        Ezagent.URI.new!("entity://ws_a/user/caller-#{System.unique_integer([:positive])}")

      :ok = spawn_user(ws_a_caller, MapSet.new())

      ws_a_uri = Ezagent.URI.new!("workspace://ws_a")

      # Forge BOTH a Cap 1 (session bind) AND Cap 2 (adapter allow)
      # narrowed to workspace A. Step 5.5 cap match may pass on
      # workspace_uri: :any vs :any, but step 5.6 enforces
      # caller_workspace == target_workspace mismatch.
      caller_caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.ActionSet.ExternalMirror,
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

      # Remediation 2026-05-30 (C-A): the Worker's first Publisher subscribe
      # is now DEFERRED to a detached Task (off its GenServer, to break the
      # unbind→terminate deadlock — see ExternalMirrorWorker.activate/2). So
      # `bind/4` returning no longer implies "Worker is in the Publisher
      # subscribers map". Wait for the subscription to land before firing the
      # first slice change — this still asserts the publish reaches the
      # Worker (NOT weakened); it only corrects the now-invalid
      # bind⇒subscribed timing assumption the deferral legitimately changed.
      # (Matches WorkerPublishTest's `Process.sleep`-after-spawn pattern.)
      :ok = await_worker_subscribed(session_uri, worker_uri, 100)

      # Sanity: the Worker publishes a slice change. The Worker's first
      # Publisher subscribe is now deferred (off-process, remediation C-A),
      # so there is a brief window where it is in the subscribers map but a
      # just-fanned event raced the subscribe commit. `fire_until_published`
      # fires a fresh slice change (new cursor → fresh fan-out) and retries
      # until the steady-state publish lands — asserting the same invariant
      # (publish reaches the Worker) without racing the async subscribe.
      assert :ok = fire_until_published(session_uri, worker_uri, 20)
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
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          session_pid_1
        )

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
      :ok = await_worker_subscribed(session_uri, worker_uri, 100)
      assert :ok = fire_until_published(session_uri, worker_uri, 20)
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
      {:ok, slice_bindings} = Facade.list_bindings(session_uri, ctx)
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

      target =
        Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=external_mirror.list_bindings")

      {elapsed_us, list_result} =
        :timer.tc(fn ->
          Invocation.dispatch(%Invocation{
            origin: :trusted_internal,
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
  # PR-EM-3 r3 codex regressions — HIGH-1 / HIGH-2 / HIGH-3
  # =========================================================================

  describe "PR-EM-3 r3 HIGH-3 regression — AdapterRegistry.register/1 ALSO registers per-adapter cap subject" do
    test "registering an adapter immediately lands its cap subject in CapabilityRegistry" do
      # Use a fresh adapter (re-register tolerant; first :ok triggers
      # install/1). Test asserts the per-adapter cap subject
      # `(Session, allow_<adapter_id>)` is observable IMMEDIATELY
      # after register/1 returns — not deferred to some later
      # Application-level pass that NEVER runs in production because
      # adapter plugins boot AFTER external_mirror (codex r2 HIGH-3).
      #
      # The cap subject for MockPublishAdapter is
      # `MockPublishAdapter.Allow` with action atom `:allow_mock_publish`.
      AdapterRegistry.register(MockPublishAdapter)

      assert {:ok, %{behavior: MockPublishAdapter.Allow}} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 :allow_mock_publish
               )
    end
  end

  describe "PR-EM-3 r3 HIGH-1 regression — AdapterRegistry.register/1 reconciles persisted bindings" do
    test "registering an adapter idempotently spawns Workers for already-persisted bindings",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      # Set up: bind once normally so a row exists in
      # external_mirror_bindings AND a Worker is alive.
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_ctx(owner_uri)

      target_id = "tgt-r3-h1-persistence"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, %{ok: true, worker_uri: worker_uri}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Confirm the row + worker exist.
      assert [%BindingRow{adapter_id: "mock_publish", target_id: ^target_id}] =
               BindingRow.list_for_session(session_uri)

      # Give the WorkerRegistry via-registration a tick to settle —
      # `Facade.bind` returns once the supervisor `start_child`
      # call resolves, but the inner Kind.Server's KindRegistry
      # entry can lag by a small async window.
      :ok = await_worker_registry_alive(worker_uri, 25)

      # Kill the worker out-of-band (simulates a fresh boot where the
      # worker process is gone but the row persists).
      cleanup_workers()
      :ok = await_worker_registry_dead(worker_uri, 25)

      # Wipe the adapter registry entry (simulates the pre-fix state
      # where the adapter plugin hadn't yet booted).
      :ets.delete(AdapterRegistry.table(), "mock_publish")
      assert :error = AdapterRegistry.lookup("mock_publish")

      # NOW re-register the adapter — this MUST reconcile the
      # persisted binding by spawning its Worker. The test is the
      # whole point of codex r2 HIGH-1: prior code waited for a
      # one-shot Application boot pass that NEVER re-ran after
      # plugin boot order resolved.
      :ok = AdapterRegistry.register(MockPublishAdapter)

      # The Worker MUST be alive again within ~500ms of register/1.
      assert :ok = await_worker_registry_alive(worker_uri, 25)
    end
  end

  defp await_worker_registry_alive(_uri, 0), do: :error

  defp await_worker_registry_alive(%URI{} = uri, retries) do
    case WorkerRegistry.lookup(URI.to_string(uri)) do
      {:ok, _} -> :ok
      _ -> Process.sleep(20) && await_worker_registry_alive(uri, retries - 1)
    end
  end

  defp await_worker_registry_dead(_uri, 0), do: :error

  defp await_worker_registry_dead(%URI{} = uri, retries) do
    case WorkerRegistry.lookup(URI.to_string(uri)) do
      :error -> :ok
      _ -> Process.sleep(20) && await_worker_registry_dead(uri, retries - 1)
    end
  end

  describe "PR-EM-3 r3 HIGH-2 regression — read facade enforces CapBAC" do
    test "list_bindings/2 with no caps returns {:error, :unauthorized}",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Bind once with admin ctx so a binding exists.
      owner = owner_ctx(owner_uri)
      target_id = "tgt-r3-h2-readgate"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, _} = Facade.bind(session_uri, "mock_publish", target_id, %{}, owner)

      # A stranger ctx with NO caps (the stranger isn't even a
      # registered User Kind — we just supply caller + empty caps
      # because dispatch only looks at ctx.caps for authz step 5.5).
      stranger = unique_user_uri("stranger-r3")
      :ok = spawn_user(stranger, MapSet.new())

      stranger_ctx = %{
        caller: stranger,
        authenticated_principal: stranger,
        caps: MapSet.new(),
        reply: :ignore
      }

      # Pre-fix this returned {:ok, [_]} (slice read bypass); post-fix
      # it routes through dispatch and the CapBAC step 5.5 denies.
      assert {:error, :missing_cap} = Facade.list_bindings(session_uri, stranger_ctx)
    end

    test "sessions_for_adapter/2 filters by caller workspace",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      # Setup: bind one session in the default workspace.
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      owner = owner_ctx(owner_uri)
      target_id = "tgt-r3-h2-wsfilter"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, _} = Facade.bind(session_uri, "mock_publish", target_id, %{}, owner)

      # Admin caller (wildcard cap) sees the session.
      admin_ctx = %{
        caller: Ezagent.URI.new!("system://bootstrap/default"),
        caps:
          MapSet.new([
            %Ezagent.Capability{
              kind: :any,
              behavior: :any,
              instance: :any,
              workspace_uri: :any,
              granted_by: Ezagent.URI.user(:system, :admin),
              granted_at: ~U[2026-01-01 00:00:00Z]
            }
          ]),
        reply: :ignore
      }

      assert {:ok, admin_sessions} = Facade.sessions_for_adapter("mock_publish", admin_ctx)
      assert session_uri in admin_sessions

      # A caller in a DIFFERENT workspace (no admin cap) sees NO sessions.
      foreign_ctx = %{
        caller: Ezagent.URI.new!("entity://other-ws/user/foreigner"),
        caps: MapSet.new(),
        reply: :ignore
      }

      assert {:ok, []} = Facade.sessions_for_adapter("mock_publish", foreign_ctx)
    end

    test "list_all_bindings/1 returns decorated rows for admin, [] for foreign caller (2026-05-25 /admin/routing Bindings tab)",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      owner = owner_ctx(owner_uri)
      target_id = "tgt-list-all-bindings"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, _} = Facade.bind(session_uri, "mock_publish", target_id, %{}, owner)

      # Admin wildcard sees the binding row.
      admin_ctx = %{
        caller: Ezagent.URI.new!("system://bootstrap/default"),
        caps:
          MapSet.new([
            %Ezagent.Capability{
              kind: :any,
              behavior: :any,
              instance: :any,
              workspace_uri: :any,
              granted_by: Ezagent.URI.user(:system, :admin),
              granted_at: ~U[2026-01-01 00:00:00Z]
            }
          ]),
        reply: :ignore
      }

      assert {:ok, admin_rows} = Facade.list_all_bindings(admin_ctx)
      assert is_list(admin_rows)

      assert Enum.any?(admin_rows, fn row ->
               row.adapter_id == "mock_publish" and
                 row.target_id == target_id and
                 match?(%URI{}, row.session_uri)
             end)

      # Foreign caller in a different workspace with no caps sees nothing.
      foreign_ctx = %{
        caller: Ezagent.URI.new!("entity://other-ws/user/foreigner"),
        caps: MapSet.new(),
        reply: :ignore
      }

      assert {:ok, foreign_rows} = Facade.list_all_bindings(foreign_ctx)
      refute Enum.any?(foreign_rows, fn row -> row.target_id == target_id end)
    end
  end

  # =========================================================================
  # PR-EM-3 r4 (codex r3 → r4) regressions — CRIT + HIGH-1 + HIGH-2
  # =========================================================================

  describe "PR-EM-3 r4 CRIT — forgery-proof :bind handoff (nonce replaces _facade_checks_ok flag)" do
    test "caller with session :bind cap CANNOT bypass Checks 2+3 by forging args" do
      owner_uri = unique_user_uri("crit-forge-owner")
      session_uri = unique_session_uri("em3-crit-forge")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      # Caller holds ONLY the session `:bind` cap on Behavior.ExternalMirror,
      # NOT the per-adapter allow cap. Pre-r4-fix, they could dispatch
      # :bind directly with `_facade_checks_ok: true` and bypass Check
      # 2 (adapter allow) + Check 3 (target_ownership_check).
      caller_caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.ActionSet.ExternalMirror,
            instance: session_uri,
            workspace_uri: @workspace_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      ctx =
        Ezagent.Test.CapHelper.signed_ctx!(
          session_uri,
          %{caller: owner_uri, caps: caller_caps, reply: :ignore},
          :session
        )

      target =
        Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=external_mirror.bind")

      # Forge attempt 1: random binary as nonce.
      inv_a = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{
          adapter_id: "mock_publish",
          target_id: "tgt-crit-forge-a",
          opts: %{},
          _facade_nonce: :crypto.strong_rand_bytes(32)
        },
        ctx: ctx
      }

      assert {:error, :bind_must_go_through_facade} = Invocation.dispatch(inv_a)

      # Forge attempt 2: caller also sets the OLD :_facade_checks_ok
      # flag (verifying the pre-fix bypass is gone — the flag should
      # be ignored entirely now).
      inv_b = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{
          adapter_id: "mock_publish",
          target_id: "tgt-crit-forge-b",
          opts: %{},
          _facade_checks_ok: true,
          _facade_nonce: :crypto.strong_rand_bytes(32)
        },
        ctx: ctx
      }

      assert {:error, :bind_must_go_through_facade} = Invocation.dispatch(inv_b)

      # Forge attempt 3: no nonce at all, only the old flag.
      inv_c = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{
          adapter_id: "mock_publish",
          target_id: "tgt-crit-forge-c",
          opts: %{},
          _facade_checks_ok: true
        },
        ctx: ctx
      }

      assert {:error, :bind_must_go_through_facade} = Invocation.dispatch(inv_c)

      # No slice mutation, no row.
      assert {:ok, []} = Facade.list_bindings(session_uri, owner_ctx(owner_uri))
      assert [] = BindingRow.list_for_session(session_uri)
    end

    test "FacadeNonceTable.consume_nonce/2 is single-use (replay protection)" do
      # Audit-SPEC CRIT-1 (2026-05-25): claim_nonce/4 now enforces
      # Gates 1+2+3+4 internally. Provide admin caller + the real
      # MockPublishAdapter so the gates pass + a nonce is minted.
      session_uri = unique_session_uri("nonce-replay")
      caller_uri = unique_user_uri("nonce-replay")
      ctx = owner_ctx(caller_uri)

      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_uri,
          ctx,
          "mock_publish",
          "tgt-replay"
        )

      assert :ok =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-replay", caller_uri}
               )

      # Second consume → :error (consumed-once)
      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-replay", caller_uri}
               )
    end

    test "FacadeNonceTable.consume_nonce/2 rejects tuple mismatch (session/adapter/target/caller)" do
      # Audit-SPEC CRIT-1 (2026-05-25): claim_nonce/4 now enforces
      # Gates 1+2+3+4 internally. Provide admin caller + the real
      # MockPublishAdapter so the gates pass + a nonce is minted.
      session_a = unique_session_uri("nonce-tup-a")
      session_b = unique_session_uri("nonce-tup-b")
      caller_uri = unique_user_uri("nonce-tup")
      ctx = owner_ctx(caller_uri)

      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_a,
          ctx,
          "mock_publish",
          "tgt-A"
        )

      # Different session → reject (also consumes the nonce — single-use even on mismatch)
      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_b, "mock_publish", "tgt-A", caller_uri}
               )

      # Correct tuple AFTER mismatch consume → still :error (gone)
      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_a, "mock_publish", "tgt-A", caller_uri}
               )
    end

    test "FacadeNonceTable.consume_nonce/2 rejects expired nonces (TTL)" do
      # Audit-SPEC CRIT-1 (2026-05-25): claim_nonce/5 (test-only
      # @doc false form) takes ctx + adapter_module + ttl_ms; gates
      # run internally before mint.
      session_uri = unique_session_uri("nonce-ttl")
      caller_uri = unique_user_uri("nonce-ttl")
      ctx = owner_ctx(caller_uri)

      # 50ms TTL so the test doesn't have to wait 5 seconds.
      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_uri,
          ctx,
          "mock_publish",
          "tgt-ttl",
          50
        )

      Process.sleep(100)

      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-ttl", caller_uri}
               )
    end
  end

  describe "PR-EM-3 r4 HIGH-1 — sessions_for_adapter/2 requires per-session :list_bindings cap" do
    test "same-workspace caller with NO caps → []",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_id = "tgt-r4-h1-empty-caps"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, _} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, owner_ctx(owner_uri))

      # Same-workspace caller with EMPTY caps. Pre-r4-fix would return
      # [session_uri] (workspace match passed, no further cap check).
      # Post-fix must return [] because the caller holds no
      # `:list_bindings` cap on the session.
      same_ws_caller =
        Ezagent.URI.new!(
          "entity://team-alpha/user/h1-empty-#{System.unique_integer([:positive])}"
        )

      empty_ctx = %{
        caller: same_ws_caller,
        caps: MapSet.new(),
        reply: :ignore
      }

      assert {:ok, []} = Facade.sessions_for_adapter("mock_publish", empty_ctx)
    end

    test "same-workspace caller with :list_bindings cap on ONE of N sessions sees only that one" do
      owner_a = unique_user_uri("h1-multi-a")
      owner_b = unique_user_uri("h1-multi-b")
      owner_c = unique_user_uri("h1-multi-c")
      session_a = unique_session_uri("h1-a")
      session_b = unique_session_uri("h1-b")
      session_c = unique_session_uri("h1-c")

      :ok = spawn_owner_and_session(owner_a, session_a)
      :ok = spawn_owner_and_session(owner_b, session_b)
      :ok = spawn_owner_and_session(owner_c, session_c)

      on_exit(fn ->
        cleanup_session(session_a)
        cleanup_session(session_b)
        cleanup_session(session_c)
      end)

      # Bind all three with each session's own owner ctx.
      [{session_a, owner_a}, {session_b, owner_b}, {session_c, owner_c}]
      |> Enum.each(fn {s, o} ->
        tid = "tgt-h1-multi-#{:erlang.phash2(s)}"
        MockPublishBinding.register_observer(tid, self())
        assert {:ok, _} = Facade.bind(s, "mock_publish", tid, %{}, owner_ctx(o))
      end)

      # Caller holds :list_bindings cap on session_b only.
      caller_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/h1-caller-#{System.unique_integer([:positive])}"
        )

      caller_caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.ActionSet.ExternalMirror,
            instance: session_b,
            workspace_uri: @workspace_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      ctx = %{caller: caller_uri, caps: caller_caps, reply: :ignore}

      assert {:ok, visible} = Facade.sessions_for_adapter("mock_publish", ctx)
      visible_strs = Enum.map(visible, &URI.to_string/1)

      assert URI.to_string(session_b) in visible_strs
      refute URI.to_string(session_a) in visible_strs
      refute URI.to_string(session_c) in visible_strs
    end
  end

  describe "PR-EM-3 r4 HIGH-2 — BindingRow.insert/1 unique_constraint maps DB error to changeset" do
    test "duplicate-insert for same natural-key triple returns {:error, %Changeset{}} (NOT raise)" do
      session_uri = unique_session_uri("h2-dup")
      adapter_id = "mock_publish"
      target_id = "tgt-h2-dup"

      base_attrs = %{
        id: BindingRow.row_id(session_uri, adapter_id, target_id),
        session_uri: URI.to_string(session_uri),
        adapter_id: adapter_id,
        target_id: target_id,
        opts_json: "{}",
        bound_by: "entity://team-alpha/user/h2",
        bound_at: DateTime.utc_now(),
        workspace_uri: URI.to_string(@workspace_uri)
      }

      # First insert succeeds.
      assert {:ok, %BindingRow{}} = BindingRow.insert(base_attrs)

      # Second insert MUST return {:error, %Ecto.Changeset{}} — pre-r4
      # this raised Ecto.ConstraintError because no unique_constraint
      # was declared on the changeset, even though the DB index existed.
      assert {:error, %Ecto.Changeset{} = cs} = BindingRow.insert(base_attrs)

      # Changeset carries a unique-constraint error.
      has_unique_err? =
        Enum.any?(cs.errors, fn {_field, {_msg, opts}} ->
          Keyword.get(opts, :constraint) == :unique
        end)

      assert has_unique_err?,
             "expected unique-constraint error in changeset; got #{inspect(cs.errors)}"

      # Exactly one row landed.
      assert [%BindingRow{}] = BindingRow.list_for_session(session_uri)
    end

    test "Behavior :bind action body treats {:error, changeset} as idempotent success",
         %{owner_uri: owner_uri, session_uri: session_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_id = "tgt-r4-h2-idemp"
      MockPublishBinding.register_observer(target_id, self())

      ctx = owner_ctx(owner_uri)

      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Second bind — the slice path already short-circuits to the
      # "existing" branch. This pins that the idempotency contract
      # holds end-to-end after the changeset-error mapping.
      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      assert [%BindingRow{}] = BindingRow.list_for_session(session_uri)
    end
  end

  # =========================================================================
  # PR-EM-3 r5 (codex r4 → r5) regressions
  # =========================================================================

  describe "PR-EM-3 r5 HIGH-2 — spawn_worker_idempotently retry-exhausted does NOT silently persist" do
    test "Kind.spawn returning the inner-race shape repeatedly → :bind returns error AND no row + no slice entry" do
      session_uri = unique_session_uri("em3-r5-h2-spawn-exhaust")
      owner_uri = unique_user_uri("h2-spawn-exhaust")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      ctx = owner_ctx(owner_uri)
      target_id = "tgt-r5-h2-spawn-exhaust"
      MockPublishBinding.register_observer(target_id, self())

      # Drive retry exhaustion by pre-registering a FOREIGN pid in
      # `Ezagent.KindRegistry` under the Worker URI BEFORE the bind.
      # When the dispatch's `Kind.spawn` cascade reaches the inner
      # `Kind.Server.init/1` → `KindRegistry.put_new`, it returns
      # `{:error, {:already_registered, <foreign_pid>}}`. The
      # init crashes; the PerBindingSupervisor's start_child
      # returns the
      # `{:shutdown, {:failed_to_start_child, _, {:already_registered, _}}}`
      # shape. The retry loop sees this 3 times in a row and exhausts.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      worker_uri_str = URI.to_string(worker_uri)

      blocker_parent = self()

      blocker =
        spawn(fn ->
          {:ok, _} = Registry.register(Ezagent.KindRegistry, worker_uri_str, :blocker)
          send(blocker_parent, :blocker_registered)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :blocker_registered, 500

      try do
        result = Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

        # The spawn loop hits the `:already_registered` shape every
        # retry (3 attempts). After exhaustion, do_bind MUST return an
        # error — NOT silently persist the row + claim ok.
        assert match?({:error, :worker_spawn_failed}, result),
               "expected {:error, :worker_spawn_failed} after retry exhaustion, " <>
                 "got #{inspect(result)}"

        # Slice unchanged.
        assert {:ok, []} = Facade.list_bindings(session_uri, ctx)

        # Projection row NOT persisted.
        assert [] = BindingRow.list_for_session(session_uri)
      after
        # Release the blocker so the registry entry frees.
        send(blocker, :release)
        Process.sleep(20)
      end
    end
  end

  describe "PR-EM-3 r5 MED — bind/5 enforces session :bind cap BEFORE running target_ownership_check" do
    test "caller without session :bind cap + with adapter allow cap → :unauthorized AND adapter check NOT invoked" do
      owner_uri = unique_user_uri("med-owner")
      session_uri = unique_session_uri("em3-r5-med-order")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      # Caller in same workspace, holds the per-adapter allow cap
      # (Check 2 would pass), but NO session :bind cap. Pre-fix, the
      # facade ran Check 2 + Check 3 (adapter I/O) BEFORE dispatch
      # discovered the missing session :bind cap — DoS / target
      # enumeration surface.
      caller_uri = unique_user_uri("med-caller")
      :ok = spawn_user(caller_uri, MapSet.new())

      caller_caps =
        MapSet.new([
          adapter_allow_cap(@workspace_uri, "em_timeout", TimeoutAdapter.Allow)
        ])

      ctx = %{caller: caller_uri, caps: caller_caps, reply: :ignore}

      # Use TimeoutAdapter sleep:500 — Check 3 sleeps 500ms but the
      # adapter timeout is 200ms. If the facade ran Check 3 we'd see
      # `:target_check_timeout`. Post-fix Check 1 short-circuits
      # BEFORE Check 3, so we see `:unauthorized` essentially
      # instantly (<50ms) — no adapter I/O fired.
      {elapsed_us, result} =
        :timer.tc(fn ->
          Facade.bind(session_uri, "em_timeout", "sleep:500", %{}, ctx)
        end)

      elapsed_ms = div(elapsed_us, 1_000)

      assert {:error, :unauthorized} = result

      assert elapsed_ms < 100,
             "bind/5 took #{elapsed_ms}ms — Check 3 ran before Check 1 (pre-fix order). " <>
               "Post-fix must short-circuit on session :bind cap miss BEFORE adapter I/O."
    end
  end

  # =========================================================================
  # PR-EM-3 codex r5 (this PR's final round) regressions — HIGH-A + HIGH-B
  # =========================================================================

  describe "PR-EM-3 codex r5 HIGH-B — atomic persist-then-spawn with discriminated changeset errors" do
    # Test 1: non-unique changeset error (NOT NULL violation) MUST NOT
    # be mapped to :ok. Pre-fix, the BLANKET `{:error, changeset} → :ok`
    # mapping silently swallowed real DB failures. Post-fix, only
    # unique-constraint violations are mapped to idempotency success;
    # every other changeset error returns {:error, {:db_insert_failed, _}}.
    test "BindingRow.insert/1 with a NOT NULL violation returns changeset (and Behavior would surface it)" do
      # Craft attrs with `:bound_at` missing (validate_required). The
      # changeset error is NOT a unique-constraint error, so the new
      # `unique_constraint_violation?/1` discriminator returns false
      # and the Behavior would return {:error, {:db_insert_failed, _}}.
      session_uri = unique_session_uri("em3-r5-ha-notnull")
      adapter_id = "mock_publish"
      target_id = "tgt-r5-ha-notnull"

      bad_attrs = %{
        id: BindingRow.row_id(session_uri, adapter_id, target_id),
        session_uri: URI.to_string(session_uri),
        adapter_id: adapter_id,
        target_id: target_id,
        opts_json: "{}",
        # bound_by missing → validate_required failure
        bound_at: DateTime.utc_now(),
        workspace_uri: URI.to_string(@workspace_uri)
      }

      assert {:error, %Ecto.Changeset{} = cs} = BindingRow.insert(bad_attrs)

      # Assert this is NOT a unique-constraint error.
      refute Enum.any?(cs.errors, fn
               {_field, {_msg, opts}} when is_list(opts) ->
                 Keyword.get(opts, :constraint) == :unique

               _ ->
                 false
             end),
             "Changeset error must NOT carry constraint: :unique for the " <>
               "non-unique failure mode test (got: #{inspect(cs.errors)})"

      # No row landed.
      assert [] = BindingRow.list_for_session(session_uri)
    end

    # Test 2: spawn failure AFTER persist succeeded runs the
    # compensating delete so the projection table stays consistent
    # with the live worker population. Re-uses the KindRegistry
    # blocker pattern from r5 H2 — but here we verify the row
    # is deleted post-exhaustion (it would have been persisted
    # FIRST under the new persist-then-spawn flow, so the
    # compensating delete is the only thing that prevents an
    # orphan row).
    test "spawn failure after row persisted runs compensating delete (no orphan row)" do
      session_uri = unique_session_uri("em3-r5-hb-comp-delete")
      owner_uri = unique_user_uri("hb-comp-delete")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      ctx = owner_ctx(owner_uri)
      target_id = "tgt-r5-hb-comp-delete"
      MockPublishBinding.register_observer(target_id, self())

      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      worker_uri_str = URI.to_string(worker_uri)

      blocker_parent = self()

      blocker =
        spawn(fn ->
          {:ok, _} = Registry.register(Ezagent.KindRegistry, worker_uri_str, :blocker)
          send(blocker_parent, :blocker_registered)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :blocker_registered, 500

      try do
        # Pre-flight: confirm no row exists yet.
        assert [] = BindingRow.list_for_session(session_uri)

        result = Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

        # Spawn exhausts → bind returns error.
        assert match?({:error, :worker_spawn_failed}, result),
               "expected {:error, :worker_spawn_failed} after spawn exhaustion, " <>
                 "got #{inspect(result)}"

        # The crux of HIGH-B: even though the row was persisted FIRST
        # under the new flow (persist-then-spawn), the compensating
        # delete on spawn failure leaves NO orphan row. Pre-fix
        # (spawn-then-persist) didn't have this concern — but it had
        # the inverse: spawn-succeeded-but-DB-insert-failed leaked an
        # orphan worker. Post-fix, neither orphan state is reachable.
        assert [] = BindingRow.list_for_session(session_uri),
               "compensating delete failed — orphan row left after spawn exhaustion"

        # Slice also empty.
        assert {:ok, []} = Facade.list_bindings(session_uri, ctx)
      after
        send(blocker, :release)
        Process.sleep(20)
      end
    end

    # Test 3: 10 concurrent binds for the same triple → exactly 1 row
    # + 1 worker. This is the test j semantic, but with the post-fix
    # persist-first flow — verifies the idempotency contract holds
    # end-to-end when the FIRST DB insert wins and the 9 others land
    # on the natural-key unique-constraint path (idempotent success).
    test "10 concurrent binds for same triple → 1 row + 1 worker (idempotency holds under persist-first)" do
      session_uri = unique_session_uri("em3-r5-hb-concurrent")
      owner_uri = unique_user_uri("hb-concurrent")
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      on_exit(fn -> cleanup_session(session_uri) end)

      ctx = owner_ctx(owner_uri)
      target_id = "tgt-r5-hb-concurrent"
      MockPublishBinding.register_observer(target_id, self())

      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)
          end)
        end)

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      # Every result is success — winners are {:ok, %{ok: true}};
      # losers either hit the existing-binding branch in `do_bind`
      # (Enum.find match) and return `{idempotent: true}`, OR hit
      # the unique-constraint branch in insert_binding_row.
      Enum.each(results, fn r ->
        assert {:ok, %{ok: true}} = r
      end)

      # Exactly one projection row.
      rows = BindingRow.list_for_session(session_uri)
      assert length(rows) == 1, "expected 1 row, got #{length(rows)}"

      # Exactly one slice entry.
      {:ok, slice_bindings} = Facade.list_bindings(session_uri, ctx)
      assert length(slice_bindings) == 1
    end
  end

  describe "PR-EM-3 codex r5 HIGH-A — AdapterInstall fires only after BOTH registries populated" do
    # Uses MockAdapter / MockBinding (the bare-registry mocks) so this
    # test exercises the ordering contract without interfering with
    # the MockPublishAdapter caps set up by the outer `setup`.
    #
    # Pre-fix: AdapterRegistry.register/1 fired install/1 unconditionally,
    # so install ran BEFORE the binding was registered → workers
    # spawned for persisted rows of this adapter would crash on
    # BindingRegistry.lookup!/1 from the dispatch path.
    #
    # Post-fix: install fires only when BOTH registries have entries.
    # Whichever registers SECOND triggers install.
    test "register adapter alone → cap subject NOT yet installed; register binding → installed" do
      alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

      adapter_id = MockAdapter.adapter_id()
      %{behavior_module: behavior_module} = MockAdapter.cap_subject()
      cap_action = String.to_atom("allow_" <> adapter_id)

      # Reset BOTH registries for this adapter_id + drop the cap
      # subject so the post-condition assertions are meaningful.
      :ets.delete(AdapterRegistry.table(), adapter_id)
      :ets.delete(BindingRegistry.table(), adapter_id)

      # Drop the cap subject directly via the Subjects ETS table —
      # CapabilityRegistry deliberately exposes no public `delete/2`
      # since cap subjects are install-once-at-boot in production.
      try do
        :ets.match_delete(
          Ezagent.CapabilityRegistry.Subjects.table(),
          {{Ezagent.Entity.Session, :_, cap_action}, :_}
        )
      rescue
        _ -> :ok
      end

      # Step 1: register adapter alone → maybe_install/1 sees the
      # BindingRegistry empty for this adapter_id → DEFERS install.
      assert :ok = AdapterRegistry.register(MockAdapter)

      # Cap subject should NOT be installed yet (install deferred).
      assert :error =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 cap_action
               ),
             "install/1 should have been DEFERRED until BindingRegistry " <>
               "also has #{inspect(adapter_id)} — but cap subject was registered"

      # Step 2: register binding → maybe_install_by_adapter_id/1 sees
      # the AdapterRegistry already populated → FIRES install.
      assert :ok = BindingRegistry.register_module(adapter_id, MockBinding)

      # Cap subject MUST now be installed.
      assert {:ok, %{behavior: ^behavior_module}} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 cap_action
               ),
             "install/1 did not fire after BOTH registries populated"
    end

    test "register binding first, then adapter → install fires when adapter lands" do
      alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

      adapter_id = MockAdapter.adapter_id()
      %{behavior_module: behavior_module} = MockAdapter.cap_subject()
      cap_action = String.to_atom("allow_" <> adapter_id)

      # Reset.
      :ets.delete(AdapterRegistry.table(), adapter_id)
      :ets.delete(BindingRegistry.table(), adapter_id)

      # Drop the cap subject directly via the Subjects ETS table —
      # CapabilityRegistry deliberately exposes no public `delete/2`
      # since cap subjects are install-once-at-boot in production.
      try do
        :ets.match_delete(
          Ezagent.CapabilityRegistry.Subjects.table(),
          {{Ezagent.Entity.Session, :_, cap_action}, :_}
        )
      rescue
        _ -> :ok
      end

      # Step 1: register binding alone → maybe_install_by_adapter_id/1
      # sees AdapterRegistry empty → DEFERS install.
      assert :ok = BindingRegistry.register_module(adapter_id, MockBinding)

      assert :error =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 cap_action
               ),
             "install/1 should have been deferred — AdapterRegistry not yet populated"

      # Step 2: register adapter → maybe_install/1 sees BindingRegistry
      # populated → FIRES install.
      assert :ok = AdapterRegistry.register(MockAdapter)

      assert {:ok, %{behavior: ^behavior_module}} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 cap_action
               ),
             "install/1 did not fire when adapter registered second"
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
        _ = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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

    # Bind the session to its workspace so dispatch step 5.6 can
    # resolve `workspace_of(session_uri)` to a real workspace URI.
    ws = Ezagent.Capability.workspace_of(session_uri)

    case ws do
      %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
      :any -> :ok
    end

    :ok = await_session_alive(session_uri, 50)
    Process.put({__MODULE__, owner_uri}, session_uri)
    Process.put({__MODULE__, :last_session}, session_uri)
    :ok
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

  # Remediation 2026-05-30 (C-A): wait until the Worker's deferred Publisher
  # subscribe has landed — i.e. the Worker's pid is in the Session
  # `:publisher` slice's `transients.subscribers` map. `subscribers` is a
  # TRANSIENT, read via `get_raw_slice/2`. Used by tests that fire a slice
  # change immediately after `bind/4` and assert the publish reaches the
  # Worker (the deferred subscribe means bind-return no longer implies
  # subscribed).
  defp await_worker_subscribed(_session_uri, _worker_uri, 0), do: {:error, :timeout}

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

  # Remediation 2026-05-30 (C-A): fire fresh slice changes until the Worker
  # actually publishes (its persisted `count` advances), then return `:ok`
  # WITHOUT consuming the `{:published, …}` observer message (the caller's
  # `assert_receive` still verifies it). The Worker's deferred subscribe can
  # land in the subscribers map a beat after the FIRST fire's fan-out already
  # ran (a fanned event raced the subscribe commit); each subsequent fire is
  # a new cursor → fresh fan-out that reaches the now-subscribed Worker. This
  # asserts the steady-state publish invariant without flaking on the async
  # subscribe ordering.
  defp fire_until_published(_session_uri, _worker_uri, 0), do: {:error, :no_publish}

  defp fire_until_published(session_uri, worker_uri, retries) do
    fire_slice_change(session_uri)

    case worker_published?(worker_uri) do
      true ->
        :ok

      false ->
        Process.sleep(50)
        fire_until_published(session_uri, worker_uri, retries - 1)
    end
  end

  defp worker_published?(worker_uri) do
    case Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker) do
      {:ok, %{count: count}} when is_integer(count) and count > 0 -> true
      _ -> false
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
    ctx = %{
      caller: owner_uri,
      authenticated_principal: owner_uri,
      caps:
        MapSet.new([
          # Bootstrap admin cap — passes everything for tests that
          # focus on facade Check 2 / Check 3, not Check 1.
          %Capability{
            kind: :any,
            behavior: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.user(:system, :admin),
            granted_at: ~U[2026-01-01 00:00:00Z]
          },
          # Plus the per-adapter allow cap explicitly so Check 2 sees
          # a precise narrow-instance grant (matches the SPEC §4.2
          # default-grant shape post-PR-EM-3-rollout).
          adapter_allow_cap(@workspace_uri, adapter_id, allow_module_for(adapter_id))
        ]),
      reply: :ignore
    }

    case Process.get({__MODULE__, owner_uri}) || Process.get({__MODULE__, :last_session}) do
      %URI{} = session_uri -> Ezagent.Test.CapHelper.signed_ctx!(session_uri, ctx, :session)
      nil -> ctx
    end
  end

  defp allow_module_for("mock_publish"), do: MockPublishAdapter.Allow
  defp allow_module_for("em_timeout"), do: TimeoutAdapter.Allow

  defp session_bind_cap(%URI{} = session_uri, %URI{} = workspace_uri) do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.ExternalMirror,
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
    Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_session_uri(prefix) do
    # Use the CANONICAL constructor `Ezagent.URI.new!/1` (authority: nil),
    # NOT raw `URI.parse/1` (which sets authority: "default"). Production
    # read paths (`BindingRow.sessions_for_adapter/1` etc.) reconstruct
    # session URIs via `Ezagent.URI.new!/1`, so a test URI built with
    # `URI.parse/1` is NOT struct-equal to the one the facade returns even
    # though both stringify identically — breaking `session_uri in
    # admin_sessions` assertions on `==`. Building the test URI canonically
    # keeps the fixture shape == production shape.
    Ezagent.URI.new!(
      "session://team-alpha/default/#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  # Trigger a chat-slice change on the Session to fire a Publisher
  # event. `chat.join` mutates `:members` (chat.send is read-only on
  # the slice per worker_publish_test.exs).
  defp fire_slice_change(%URI{} = session_uri) do
    member_uri = unique_user_uri("trigger")
    :ok = spawn_user(member_uri, MapSet.new())

    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    admin_uri = User.admin_uri()
    join_cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin_uri)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: admin_uri,
        authenticated_principal: admin_uri,
        caps: MapSet.new([join_cap]),
        reply: :ignore
      }
    })

    :ok
  end

  # silence unused-alias warnings
  _ = {TimeoutBinding}
end
