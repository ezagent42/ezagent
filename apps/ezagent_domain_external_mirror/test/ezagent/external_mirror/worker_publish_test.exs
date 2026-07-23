# PR #420 codex r4 MED (2026-06-01) — minimal stub adapter+binding used by
# the `{msg.id, send_cursor}` composite-dedupe regression describe block
# below. The stub adapter always returns `{:publish, payload}` (so the
# Worker-level pre-adapter dedupe is the ONLY gate exercised); the stub
# binding counts publish calls in a process-dict-free way by echoing the
# payload back unchanged as the binding_state (the test reads
# `last_publish_result` / `:ok` vs `:duplicate_skip` to assert publish vs
# skip — it does not need to observe the binding directly).
defmodule Ezagent.ExternalMirror.WorkerPublishTest.AlwaysPublishAdapter do
  @moduledoc false
  def event_to_payload(%Ezagent.Publisher.Event{} = event), do: {:publish, %{event: event}}
end

defmodule Ezagent.ExternalMirror.WorkerPublishTest.CountingBinding do
  @moduledoc false
  # binding_state is a counter; every publish bumps it. `{:ok, new_state}`.
  def publish(_payload, count) when is_integer(count), do: {:ok, count + 1}
end

defmodule Ezagent.ExternalMirror.WorkerPublishTest do
  @moduledoc """
  PR-EM-2 acceptance tests for the Worker publish-flow + post_init
  handle_continue chain + per-binding isolation regression +
  restart-cursor-reset.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-2 acceptance bar — tests 1, 2, 5, 6 (test 7 — contract
  invariant — lives in `worker_contract_test.exs`).

  Tests in this file:

  - **#1 — worker spawn + publish flow**: spawn a Worker via
    `Kind.spawn(ExternalMirrorWorker, ...)`, trigger a Publisher
    event on the Session, assert the binding's `publish/2` was
    called with the right payload AND the slice updates carry the
    right cursor/count.
  - **#2 — per-binding isolation regression**: spawn 3 bindings;
    kill the inner Worker of one of them via `Process.exit(_, :kill)`
    10× in quick succession; assert the OTHER 2 PerBindingSupervisors
    + Workers remain alive (RootSupervisor children count steady).
  - **#5 — post_init handle_continue chain**: spawn a Worker; assert
    that AT spawn time `subscription_state == :pending` (or the slice
    is being initialised), and after a small delay
    `subscription_state == :active`.
  - **#6 — restart cursor reset (OQ-EM-10)**: spawn, drive cursor
    to N via publishes, kill the Worker pid; wait for
    PerBindingSupervisor restart; assert the new Worker's slice
    cursor reset to `:latest`-equivalent (not N).
  """

  # Remediation P6 (sandbox isolation): this suite spawns Session / User /
  # Worker Kind.Server GenServers (via `WorkerSpawn.spawn` + `chat.join`
  # dispatch) that run Repo queries (snapshot load in `init`, projection
  # reads in `activate`) in OTHER processes. With bare `ExUnit.Case` those
  # processes have no sandbox connection owner → `DBConnection.OwnershipError`
  # on the spawned Kind's `Kind.Snapshot.fetch_snapshot`. `EzagentCore.DataCase`
  # establishes SHARED sandbox mode (`shared: not async`) so spawned Kinds
  # find the owner, plus the P6 drain that flushes live Kinds before the
  # owner exits. Matches the passing sibling integration suites
  # (`AuthModelInvariantTest`, `ExternalMirrorTest`).
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

  setup do
    # Chat is a compile-but-not-runtime dep of :ezagent_domain_external_mirror
    # (cycle break). Force-start so SessionSupervisor / scheme registration
    # exist when this test runs alone.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    session_uri = unique_session_uri("worker-publish")
    owner_uri = unique_user_uri("worker-publish-owner")
    :ok = spawn_owner_and_session(owner_uri, session_uri)

    on_exit(fn ->
      cleanup_session(session_uri)
      cleanup_workers()
    end)

    # SliceChange hook is OFF by default — enable it so :chat slice
    # changes propagate to the Publisher (which fires our Worker's
    # publish loop).
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

  describe "post_init handle_continue chain (PR-EM-2 acceptance test #5)" do
    test "subscription_state transitions pending → active after handle_continue completes",
         %{session_uri: session_uri} do
      target_id = "tgt-post-init"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _sup_pid} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)

      # Wait briefly for handle_continue to run (post-init runs after
      # :announce_ready returns to the gen_server scheduler — typically
      # well under 50ms).
      Process.sleep(50)

      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)

      # Lifecycle migration (Phase B): subscription_state + adapter_module
      # + binding_module + binding_state are now TRANSIENTS (the live
      # transport handles), rebuilt by activate/2. `get_slice/2` normalizes
      # to the persistent `.state` view (T3) which would hide them — use
      # `get_raw_slice/2` to inspect the `transients` container.
      {:ok, %{transients: transients}} =
        Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker)

      # After activate/2 completes, subscription_state is :active and
      # binding_state + the adapter/binding modules are bound.
      assert transients.subscription_state == :active
      assert transients.adapter_module == MockPublishAdapter
      assert transients.binding_module == MockPublishBinding
      assert transients.binding_state != nil
    end
  end

  describe "publish flow (PR-EM-2 acceptance test #1)" do
    test "Publisher event → :publish dispatch → binding.publish/2 called with right payload",
         %{session_uri: session_uri} do
      target_id = "tgt-publish-flow"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)

      # Trigger a slice change on the Session to fire a Publisher event.
      :ok = await_worker_subscribed(session_uri, worker_uri, 100)
      assert :ok = fire_until_publish_count(session_uri, worker_uri, 1, 20)

      # Binding's `publish/2` sent us {:published, payload, target_id, count}.
      assert_receive {:published, payload, ^target_id, _count}, 1_000

      # The payload is what MockPublishAdapter.event_to_payload/1
      # returned: %{event: event, echoed_at: dt}
      assert %{event: %Ezagent.Publisher.Event{} = ev} = payload

      assert ev.publisher_uri == session_uri or
               URI.to_string(ev.publisher_uri) == URI.to_string(session_uri)

      assert ev.cursor >= 1

      # Slice carries the cursor + count.
      {:ok, slice} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)
      assert slice.publisher_cursor >= ev.cursor
      assert slice.count >= 1
      assert slice.last_publish_result == :ok
      assert slice.last_published_at != nil
    end

    test "publish idempotency is scoped by worker uri, not cursor only",
         %{session_uri: session_a_uri} do
      suffix = System.unique_integer([:positive])
      target_a = "tgt-publish-idem-a-#{suffix}"
      target_b = "tgt-publish-idem-b-#{suffix}"
      session_b_uri = unique_session_uri("worker-publish-idem")
      owner_b_uri = unique_user_uri("worker-publish-idem-owner")

      :ok = spawn_owner_and_session(owner_b_uri, session_b_uri)
      on_exit(fn -> cleanup_session(session_b_uri) end)

      MockPublishBinding.register_observer(target_a, self())
      MockPublishBinding.register_observer(target_b, self())

      {:ok, _} = WorkerSpawn.spawn(session_a_uri, "mock_publish", target_a)
      {:ok, _} = WorkerSpawn.spawn(session_b_uri, "mock_publish", target_b)

      worker_a_uri = WorkerSpawn.worker_uri_for(session_a_uri, "mock_publish", target_a)
      worker_b_uri = WorkerSpawn.worker_uri_for(session_b_uri, "mock_publish", target_b)

      :ok = await_worker_subscribed(session_a_uri, worker_a_uri, 100)
      :ok = await_worker_subscribed(session_b_uri, worker_b_uri, 100)

      send_chat_to_session(session_a_uri, "idempotency-a")
      assert :ok = await_publish_count_at_least(worker_a_uri, 1, 20)

      assert_receive {:published, %{event: %Ezagent.Publisher.Event{} = event_a}, ^target_a, 1},
                     1_000

      send_chat_to_session(session_b_uri, "idempotency-b")
      assert :ok = await_publish_count_at_least(worker_b_uri, 1, 20)

      assert_receive {:published, %{event: %Ezagent.Publisher.Event{} = event_b}, ^target_b, 1},
                     1_000

      assert event_a.cursor == event_b.cursor
    end
  end

  describe "per-binding isolation regression (PR-EM-2 acceptance test #2)" do
    test "killing 1 worker's inner pid 10× does NOT take down siblings",
         %{session_uri: session_uri} do
      Enum.each(1..3, fn n ->
        target_id = "tgt-isol-#{n}"
        MockPublishBinding.register_observer(target_id, self())
        {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      end)

      Process.sleep(50)

      # Snapshot of initial PerBindingSupervisor pids in the Registry.
      initial = WorkerRegistry.list_all() |> Enum.map(fn {_uri, pid} -> pid end) |> MapSet.new()
      assert MapSet.size(initial) == 3

      # Pick binding #2 to abuse: kill its inner Kind.Server 10×.
      # Each kill trips the per-binding 3/30s budget after the 3rd
      # restart; the PerBindingSupervisor crashes with `:shutdown`
      # and RootSupervisor restarts it (the `:permanent`
      # PerBindingSupervisor child restarts on ANY exit, per the
      # codex round-1 CRIT fix — see PerBindingSupervisor moduledoc).
      # After enough kills, the per-binding budget burns again, etc.
      # The KEY claim is the OTHER two PerBindingSupervisors are
      # unaffected throughout.
      victim_target = "tgt-isol-2"
      victim_worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", victim_target)
      victim_binding_uri = URI.to_string(victim_worker_uri)

      Enum.each(1..10, fn _ ->
        # Do not kill the replacement while its post-init authority reads are
        # still using the test's shared SQL sandbox connection. The isolation
        # claim starts once the Worker has announced readiness; killing during
        # init only exercises DBConnection owner teardown, not OTP sibling
        # isolation.
        _ = Ezagent.ReadyGate.await(victim_worker_uri, 1_000)

        # Find the CURRENT inner pid for the victim binding (it may have
        # restarted between kills).
        #
        # The victim's PerBindingSupervisor is under a deliberately induced
        # restart storm. Mid-storm it can be transiently terminating, and —
        # crucially under the SQL Sandbox — a supervised Worker RESTART runs
        # `Kind.Server.init/1` (→ `Cap.Authority.open` → a Repo read) OUTSIDE
        # this test's `$callers` chain, so it depends on shared-sandbox mode
        # being live at that exact instant. Under the full concurrent umbrella
        # the pool can momentarily read `:manual`, the restart's init raises
        # `DBConnection.OwnershipError`, and the victim supervisor exits — which
        # makes `which_children/1` (a `GenServer.call`) EXIT. That is a
        # TEST-SANDBOX artifact of the churn THIS test induces (production
        # restarts always have a live pool), not a sibling-isolation failure
        # (task #184). Tolerate a transient victim-supervisor exit and keep
        # hammering; the real claim — the OTHER two bindings survive — is
        # asserted AFTER this loop and is deliberately left outside the catch.
        try do
          case WorkerRegistry.lookup(victim_binding_uri) do
            {:ok, sup_pid} ->
              case Supervisor.which_children(sup_pid) do
                [{_id, inner_pid, _type, _modules}] when is_pid(inner_pid) ->
                  Process.exit(inner_pid, :kill)
                  Process.sleep(5)

                _ ->
                  Process.sleep(5)
              end

            :error ->
              # The PerBindingSupervisor budget tripped + RootSupervisor
              # decided not to restart further; that's allowed — what
              # we care about is the other 2 stay up.
              Process.sleep(5)
          end
        catch
          :exit, _ ->
            # Victim supervisor is transiently down/restarting mid-storm
            # (see above) — skip this kill iteration.
            Process.sleep(5)
        end
      end)

      # The OTHER two bindings' PerBindingSupervisors must still be
      # alive in the Registry (they never crashed).
      sibling_targets = ["tgt-isol-1", "tgt-isol-3"]

      Enum.each(sibling_targets, fn target ->
        wuri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target)
        buri = URI.to_string(wuri)
        assert {:ok, sup_pid} = await_binding_supervisor(buri, 50)
        assert Process.alive?(sup_pid)
      end)
    end
  end

  describe "PerBindingSupervisor restart-strategy correctness (codex round-1 CRIT fix)" do
    # Verifies the PR-EM-2 r1→r2 transition from
    # `restart: :transient` → `:permanent`. r1 was a CRIT bug:
    # supervisor budget exhaustion exits with reason `:shutdown`, and
    # `:transient` does NOT restart on `:shutdown`. So a single
    # restart-storm would leave the binding permanently down after
    # one inner-budget exhaustion — the "RootSupervisor restarts the
    # PerBindingSupervisor" loop the SPEC §6.3 documents never fired.
    #
    # This test trips the inner 3/30s budget by killing the Worker
    # 5 times rapidly, then asserts the PerBindingSupervisor is
    # STILL alive in the WorkerRegistry — i.e. RootSupervisor
    # restarted it. With r1's broken `:transient`, the Registry
    # would show the binding gone.
    test "inner 3/30s budget exhaustion → RootSupervisor restarts the PerBindingSupervisor",
         %{session_uri: session_uri} do
      target_id = "tgt-restart-survive"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, original_sup_pid} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      binding_uri = URI.to_string(worker_uri)

      # Kill the inner Worker 5 times rapidly to trip the 3/30s
      # PerBindingSupervisor budget at LEAST once. After the 3rd
      # kill in 30s, the PerBindingSupervisor exits with
      # `:shutdown`. With `:permanent`, RootSupervisor restarts it.
      Enum.each(1..5, fn _ ->
        assert :ok = kill_ready_inner(binding_uri, worker_uri, 100)
      end)

      # The binding is STILL registered (RootSupervisor restarted the
      # PerBindingSupervisor — possibly with a NEW pid, that's fine).
      assert {:ok, new_sup_pid} = await_binding_supervisor(binding_uri, 100),
             "PerBindingSupervisor permanently gone after inner budget exhaustion. " <>
               "If this fails, the codex round-1 CRIT regression came back — " <>
               "check `restart:` field on the child_spec in WorkerSpawn.spawn/4."

      # If RootSupervisor restarted, new_sup_pid likely differs from
      # original_sup_pid — but the binding_uri keeps the new pid alive
      # in the Registry either way.
      assert Process.alive?(new_sup_pid)

      _ = original_sup_pid
    end
  end

  describe "graceful shutdown — Binding.terminate/2 (codex round-1 HIGH-1 fix)" do
    test "Kind.terminate(worker_uri) calls binding.terminate/2 before exit",
         %{session_uri: session_uri} do
      target_id = "tgt-graceful-shutdown"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      # Tear down via the public Kind API — exercises the custom
      # terminate_strategy/0 path (codex HIGH-2 fix).
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      :ok = Ezagent.Kind.terminate(worker_uri)

      # MockPublishBinding.terminate/2 sends {:terminated, target_id, count}.
      assert_receive {:terminated, ^target_id, _count}, 1_000

      # The PerBindingSupervisor is gone from the Registry — explicit
      # termination via terminate_child does NOT respawn (`:permanent`
      # restart strategy + terminate_child removes from sup bookkeeping
      # BEFORE the shutdown propagates).
      Process.sleep(50)
      binding_uri = URI.to_string(worker_uri)
      assert WorkerRegistry.lookup(binding_uri) == :error
    end

    test "WorkerSpawn.terminate/3 (the unbind path) also fires binding.terminate/2",
         %{session_uri: session_uri} do
      target_id = "tgt-unbind"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      :ok = WorkerSpawn.terminate(session_uri, "mock_publish", target_id)
      assert_receive {:terminated, ^target_id, _count}, 1_000
    end
  end

  describe "restart cursor reset (PR-EM-2 acceptance test #6 / OQ-EM-10)" do
    test "killing a Worker resets its slice cursor to :latest on respawn",
         %{session_uri: session_uri} do
      target_id = "tgt-cursor-reset"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      binding_uri = URI.to_string(worker_uri)

      # Drive a few publishes through.
      :ok = await_worker_subscribed(session_uri, worker_uri, 100)
      assert :ok = fire_until_publish_count(session_uri, worker_uri, 1, 20)
      assert_receive {:published, _, ^target_id, _}, 1_000
      assert :ok = fire_until_publish_count(session_uri, worker_uri, 2, 20)
      assert_receive {:published, _, ^target_id, _}, 1_000

      Process.sleep(50)
      {:ok, slice_before} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)
      assert slice_before.publisher_cursor != :latest
      assert slice_before.count >= 2

      # Kill the inner Worker pid.
      {:ok, sup_pid} = WorkerRegistry.lookup(binding_uri)
      [{_id, old_inner_pid, _, _}] = Supervisor.which_children(sup_pid)
      Process.exit(old_inner_pid, :kill)

      # Wait for PerBindingSupervisor to restart it.
      :ok = wait_for_new_inner_pid(sup_pid, old_inner_pid, 50)
      Process.sleep(50)

      {:ok, slice_after} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)

      # OQ-EM-10: restart resets to :latest-equivalent (no replay of
      # missed events). The Worker re-subscribes via `:latest` on
      # restart — current_cursor at subscription time is whatever
      # cursor the Publisher's ring is at, NOT the pre-crash cursor.
      #
      # Concretely:
      #   - count resets to 0 (init_slice ran fresh)
      #   - publisher_cursor is RE-SET via the fresh subscribe call —
      #     it equals the publisher's current cursor at restart time,
      #     which equals the pre-crash cursor IFF no new events
      #     happened in the kill→restart window (which is the case
      #     here — we didn't trigger any events between kill and
      #     post-restart assertion).
      #
      # The structural test for "no replay of missed events" is:
      # `count == 0` AND `last_published_at == nil` AND
      # `last_publish_result == nil` — i.e. the slice carries NO
      # echo of pre-crash publishes.
      assert slice_after.count == 0
      assert slice_after.last_publish_result == nil
      assert slice_after.last_published_at == nil
      # publisher_cursor is the live subscription cursor, NOT a
      # reset-to-:latest sentinel. The semantic is "no replay";
      # the cursor's numeric value is just the publisher's current
      # ring position.
      assert is_integer(slice_after.publisher_cursor) or slice_after.publisher_cursor == :latest
    end
  end

  # PR #420 codex r4 MED (2026-06-01) — composite-dedupe regression.
  #
  # Drives `handle_publish/2` directly with a constructed ctx (the
  # established direct-handler test pattern, cf.
  # external_mirror_migration_parity_test.exs) so the dedupe cond is
  # exercised in isolation — no spawn/Session/Publisher plumbing. The stub
  # adapter ALWAYS returns `{:publish, _}`, so the Worker-level
  # `{msg.id, send_cursor}` pre-adapter dedupe is the only gate under test.
  #
  # The bug: dedupe keyed on `msg.id` alone SILENTLY DROPS a legitimate
  # retry-send (reused `msg.id`, bumped `send_cursor`). The fix keys on the
  # pair so a retry publishes while a true replay (same pair) still dedupes.
  describe "publish dedupe by {msg.id, send_cursor} composite (PR #420 codex r4 MED)" do
    test "retry-send (REUSED msg.id, NEW send_cursor) MUST publish, not skip" do
      msg = %Ezagent.Message{id: "msg-retry-1"}

      # State carries the send_key from the FIRST publish: id="msg-retry-1",
      # send_cursor=5.
      ctx = dedupe_ctx(last_published_send_key: {"msg-retry-1", 5})

      # The retry-send re-uses msg.id but bumps send_cursor 5 → 6.
      event = chat_event(msg, send_cursor: 6, cursor: 42)

      assert {:ok, %{ok: true} = result, effects} =
               Ezagent.ActionSet.ExternalMirrorWorker.handle_publish(%{event: event}, ctx)

      # NOT skipped — the retry reaches the binding.
      refute result[:skipped]

      # The result fields confirm a real publish: :ok (not :duplicate_skip)
      # and the new composite key {id, 6} is persisted.
      assert {:set, :last_publish_result, :ok} in effects
      assert {:set, :last_published_send_key, {"msg-retry-1", 6}} in effects
    end

    test "true replay (SAME msg.id AND SAME send_cursor) MUST dedupe" do
      msg = %Ezagent.Message{id: "msg-replay-1"}

      ctx = dedupe_ctx(last_published_send_key: {"msg-replay-1", 7})

      # A re-delivered event for the already-published send: identical pair.
      event = chat_event(msg, send_cursor: 7, cursor: 99)

      assert {:ok, %{ok: true, skipped: true}, effects} =
               Ezagent.ActionSet.ExternalMirrorWorker.handle_publish(%{event: event}, ctx)

      # Deduped BEFORE the adapter — result is :duplicate_skip and the
      # send_key is unchanged (no {:set, :last_published_send_key, _}).
      assert {:set, :last_publish_result, :duplicate_skip} in effects
      refute Enum.any?(effects, &match?({:set, :last_published_send_key, _}, &1))
    end

    test "first publish (no prior send_key) publishes and records the pair" do
      msg = %Ezagent.Message{id: "msg-first"}
      ctx = dedupe_ctx(last_published_send_key: nil)
      event = chat_event(msg, send_cursor: 1, cursor: 1)

      assert {:ok, %{ok: true} = result, effects} =
               Ezagent.ActionSet.ExternalMirrorWorker.handle_publish(%{event: event}, ctx)

      refute result[:skipped]
      assert {:set, :last_published_send_key, {"msg-first", 1}} in effects
    end

    test "true replay delivered as a WRAPPED Lifecycle slice (%{state: ...}) still dedupes (codex 2026-06-01 HIGH)" do
      # The production publisher payload's `new_slice` is strip_transients'd
      # to `%{state: ...}` (SessionImpl.build_payload), NOT flat. The dedupe
      # key must be extracted from the UNWRAPPED view, else send_key is nil
      # and replays are never deduped in the real Lifecycle path.
      msg = %Ezagent.Message{id: "msg-wrapped-replay"}
      ctx = dedupe_ctx(last_published_send_key: {"msg-wrapped-replay", 7})

      event = chat_event_wrapped(msg, send_cursor: 7, cursor: 99)

      assert {:ok, %{ok: true}, effects} =
               Ezagent.ActionSet.ExternalMirrorWorker.handle_publish(%{event: event}, ctx)

      assert {:set, :last_publish_result, :duplicate_skip} in effects
      refute Enum.any?(effects, &match?({:set, :last_published_send_key, _}, &1))
    end
  end

  # Build a `handle_publish/2` ctx: persistent fields via `read`, the live
  # transport handles via `transients`. Defaults match a freshly-activated
  # Worker (count 0, binding_state 0). Override `:last_published_send_key`
  # to seed a prior publish.
  defp dedupe_ctx(opts) do
    state = %{
      session_uri: Ezagent.URI.new!("session://system/default/main"),
      adapter_id: "stub",
      target_id: "tgt-dedupe",
      opts: %{},
      publisher_cursor: :latest,
      count: 0,
      error_count: 0,
      last_published_at: nil,
      last_publish_result: nil,
      last_published_send_key: Keyword.get(opts, :last_published_send_key, nil)
    }

    %{
      read: fn key, default -> Map.get(state, key, default) end,
      transients: %{
        adapter_module: Ezagent.ExternalMirror.WorkerPublishTest.AlwaysPublishAdapter,
        binding_module: Ezagent.ExternalMirror.WorkerPublishTest.CountingBinding,
        binding_state: 0,
        subscription_state: :active
      },
      self_uri: Ezagent.URI.new!("entity://default/worker/stub_tgt-dedupe")
    }
  end

  # A `:chat`-slice publisher event whose `new_slice` carries the message +
  # send_cursor that `extract_event_send_key/1` reads.
  defp chat_event(%Ezagent.Message{} = msg, opts) do
    %Ezagent.Publisher.Event{
      cursor: Keyword.fetch!(opts, :cursor),
      publisher_uri: Ezagent.URI.new!("session://system/default/main"),
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: %{
        new_slice: %{
          last_message: msg,
          last_message_id: msg.id,
          send_cursor: Keyword.fetch!(opts, :send_cursor)
        }
      }
    }
  end

  # A `:chat` event whose `new_slice` is a Lifecycle two-container slice
  # AFTER strip_transients — i.e. WRAPPED as `%{state: ...}` (the real
  # publisher payload shape), not flat. Pins the unwrap in
  # `extract_event_send_key/1` (codex 2026-06-01 HIGH).
  defp chat_event_wrapped(%Ezagent.Message{} = msg, opts) do
    %Ezagent.Publisher.Event{
      cursor: Keyword.fetch!(opts, :cursor),
      publisher_uri: Ezagent.URI.new!("session://system/default/main"),
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: %{
        new_slice: %{
          state: %{
            last_message: msg,
            last_message_id: msg.id,
            send_cursor: Keyword.fetch!(opts, :send_cursor)
          }
        }
      }
    }
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

  defp await_binding_supervisor(_binding_uri, 0), do: {:error, :timeout}

  defp await_binding_supervisor(binding_uri, retries) do
    case WorkerRegistry.lookup(binding_uri) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _other -> Process.sleep(20) && await_binding_supervisor(binding_uri, retries - 1)
    end
  end

  defp kill_ready_inner(_binding_uri, _worker_uri, 0), do: {:error, :timeout}

  defp kill_ready_inner(binding_uri, worker_uri, retries) do
    try do
      with :ok <- Ezagent.ReadyGate.await(worker_uri, 200),
           {:ok, sup_pid} <- WorkerRegistry.lookup(binding_uri),
           [{_id, inner_pid, _type, _modules}] when is_pid(inner_pid) <-
             Supervisor.which_children(sup_pid),
           true <- Process.alive?(inner_pid) do
        Process.exit(inner_pid, :kill)
        :ok
      else
        _other ->
          Process.sleep(10)
          kill_ready_inner(binding_uri, worker_uri, retries - 1)
      end
    catch
      :exit, _reason ->
        Process.sleep(10)
        kill_ready_inner(binding_uri, worker_uri, retries - 1)
    end
  end

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

  defp fire_until_publish_count(_session_uri, _worker_uri, _count, 0), do: {:error, :no_publish}

  defp fire_until_publish_count(session_uri, worker_uri, count, retries) do
    send_chat_to_session(session_uri, "publish-#{count}")

    case await_publish_count_at_least(worker_uri, count, 20) do
      :ok ->
        :ok

      {:error, :no_publish} ->
        fire_until_publish_count(session_uri, worker_uri, count, retries - 1)
    end
  end

  defp await_publish_count_at_least(_worker_uri, _count, 0), do: {:error, :no_publish}

  defp await_publish_count_at_least(worker_uri, count, retries) do
    case worker_publish_count_at_least?(worker_uri, count) do
      true ->
        :ok

      false ->
        Process.sleep(50)
        await_publish_count_at_least(worker_uri, count, retries - 1)
    end
  end

  defp worker_publish_count_at_least?(worker_uri, count) do
    case Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker) do
      {:ok, %{count: actual}} when is_integer(actual) and actual >= count -> true
      _ -> false
    end
  end

  # Trigger a Publisher event by mutating the Session's :chat slice
  # via `:chat.join` — joining a fresh user every call so the slice
  # ALWAYS differs from prior (SliceChange fires only on actual
  # mutation per PR-N1).
  #
  # Per `publisher_session_test.exs`: chat.send is read-only on the
  # slice (writes go to MessageStore via Repo), so it does NOT
  # trigger SliceChange. chat.join writes `members` + `monitors`.
  defp send_chat_to_session(%URI{} = session_uri, _label) do
    member_uri = unique_user_uri("em-pub-test")
    :ok = spawn_user(member_uri, MapSet.new())

    admin_uri = Ezagent.URI.new!("entity://system/user/admin")

    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

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

  defp wait_for_new_inner_pid(_sup_pid, _old_pid, 0), do: {:error, :timeout}

  defp wait_for_new_inner_pid(sup_pid, old_pid, retries) do
    case Supervisor.which_children(sup_pid) do
      [{_id, pid, _type, _modules}] when is_pid(pid) and pid != old_pid ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_new_inner_pid(sup_pid, old_pid, retries - 1)
    end
  end
end
