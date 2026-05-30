defmodule Ezagent.ExternalMirror.WorkerResubscribeCatchupTest do
  @moduledoc """
  Task #49 codex round-3 NEW CHECK C regression test (2026-05-27) —
  ExternalMirrorWorker MUST replay events emitted during the empty-
  fanout window when it re-subscribes via the `:publisher_alive`
  lifecycle handshake.

  ## The window this test exercises

  Between `Ezagent.Behavior.Publisher.SessionImpl.on_ready/2` firing
  `broadcast_alive/1` and the Worker's `:publisher_alive` handler
  dispatching its subscribe `:call`, the Publisher slice has:

  - `:subscribers = %{}` (cleared by `reconcile_after_load/2`)
  - `:ring` + `:cursor` preserved across the snapshot load

  A slice mutation in this window:

  1. fires SliceChange → Publisher's `handle_kind_message/3`
  2. appends a `%Event{}` to `:ring` with `cursor = old + 1`
  3. `fan_out(event, %{})` is a no-op — silent drop

  ## Pre-fix bug (codex r3 NEW CHECK C)

  The Worker's re-subscribe used `cursor: :latest` → zero replay. The
  event sitting in the ring with `cursor = N+1` never reached the
  Worker. First message in the cold-spawn window dropped — the same
  class of bug PR #420 was meant to fix.

  ## Post-fix behaviour

  Worker passes its persisted `publisher_cursor` to
  `subscribe_from`; Publisher replays every ring event with
  `cursor > persisted` BEFORE returning. Replay messages land in the
  Worker's mailbox, self-dispatch through the normal `:publish` path,
  hit the same `last_published_message_id` dedupe — so duplicate
  replays (e.g. on snapshot churn) do not produce duplicate Feishu
  posts.

  ## Test shape (independent of cold-spawn end-to-end)

  We deliberately do NOT exercise the full cold-spawn path here —
  `worker_resubscribe_on_session_cold_spawn_test.exs` already covers
  the e2e. This test surgically reproduces the empty-fanout WINDOW
  by:

  1. Spawn Session + Worker; drive one publish (worker
     `publisher_cursor` becomes `N`).
  2. Clear `:publisher.subscribers` directly via `:sys.replace_state`
     — simulating the post-`reconcile_after_load` state without
     terminating the Session (so the same publisher `:cursor` keeps
     ticking).
  3. Fire a slice mutation (`chat.join`). The Publisher appends to
     `:ring` with `cursor = N+1` and fans out to the (now-empty)
     subscribers map — silent drop.
  4. Manually invoke `Ezagent.PublisherLifecycle.broadcast_alive/1`
     to trigger the Worker's re-subscribe handler.
  5. Assert the Worker eventually publishes the missed event.

  Without the catchup fix, step 5 times out (the Worker re-subscribes
  at `:latest`, no replay, the event is gone).
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
    WorkerSpawn
  }

  alias Ezagent.ExternalMirror.TestSupport.{MockPublishAdapter, MockPublishBinding}

  setup do
    # Chat is a compile-but-not-runtime dep of :ezagent_domain_external_mirror
    # (cycle break). Force-start so SessionSupervisor / scheme registration
    # exist when this test runs alone.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)

    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    on_exit(fn -> cleanup_workers() end)

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

  describe "task #49 codex r3 NEW CHECK C — empty-fanout window catchup" do
    test "event emitted while subscribers is empty is replayed on re-subscribe",
         %{session_uri: session_uri} do
      _ = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = await_session_ready(session_uri, 100)

      target_id = "tgt-catchup-window"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _sup_pid} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      # Baseline publish — confirms the wire is live AND advances the
      # Worker's `publisher_cursor` to a non-`:latest` integer so the
      # catchup path has a concrete cursor to replay from.
      send_chat_to_session(session_uri)
      assert_receive {:published, _, ^target_id, _}, 1_500
      drain_mailbox()

      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      {:ok, worker_slice_before} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)

      assert is_integer(worker_slice_before.publisher_cursor),
             "test pre-condition broken — worker publisher_cursor must be an integer " <>
               "after baseline publish; got #{inspect(worker_slice_before.publisher_cursor)}. " <>
               "If this fails the test cannot demonstrate the catchup gap (only :latest " <>
               "cursors trigger the original no-replay branch — which is fine since the " <>
               "first subscribe in handle_continue/3 IS no-replay by design)."

      cursor_at_window_start = worker_slice_before.publisher_cursor

      # ----- enter the empty-fanout window --------------------------------
      #
      # Clear `:publisher.subscribers` + `:monitors` directly via
      # `:sys.replace_state` — simulating the post-`reconcile_after_load`
      # state. Critically we DO NOT terminate the Session: the publisher's
      # `:ring` + `:cursor` stay continuous (same numbering scheme), so
      # the cursor the Worker persisted from the baseline publish is a
      # valid lower bound for replay.
      #
      # In production this empty-subscribers state is reached when a
      # cold-spawned Session loads its snapshot through
      # `reconcile_after_load/2`. The behaviour from this point onward
      # is identical regardless of HOW the subscribers map got cleared.
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      # Post-lifecycle migration (remediation 2026-05-30): `subscribers` +
      # `monitors` are TRANSIENTS on the `:publisher` slice
      # (`%{state: …, transients: %{subscribers, monitors}}`), not flat slice
      # fields. Clear them in the `transients` container — writing the old
      # flat keys raises `{:badkey, :monitors}`. This simulates the
      # empty-fanout window (the same state a cold-spawned Session loads,
      # where `activate/2` rebuilds `subscribers`/`monitors` empty).
      :sys.replace_state(session_pid, fn kind_state ->
        publisher_slice = kind_state.state.publisher
        cleared_transients = %{publisher_slice.transients | subscribers: %{}, monitors: %{}}
        cleared_publisher = %{publisher_slice | transients: cleared_transients}
        new_state = %{kind_state.state | publisher: cleared_publisher}
        %{kind_state | state: new_state}
      end)

      # ----- emit one event INTO the empty subscribers map ----------------
      #
      # `chat.join` mutates `:chat.members` → SliceChange fires →
      # Publisher's `handle_kind_message/3` appends to `:ring` at
      # `cursor = N+1` and fans out to `subscribers = %{}` (no-op).
      # The Worker (subscribed to the lifecycle topic but NOT to the
      # publisher) sees nothing.
      send_chat_to_session(session_uri)

      # Brief wait for SliceChange / Publisher append. The event is now
      # in the ring; without catchup it will never reach the Worker.
      Process.sleep(50)

      # Sanity: publisher's `:cursor` has advanced past the worker's
      # persisted cursor — there IS something to catch up on.
      # Post-lifecycle migration (remediation 2026-05-30): `cursor` is a
      # PERSISTENT field (T3-normalized `get_slice` view), while `subscribers`
      # is a TRANSIENT — read the latter from the `transients` container via
      # `get_raw_slice/2` (the `get_slice` view hides it).
      {:ok, publisher_slice_mid} = Ezagent.Kind.get_slice(session_uri, :publisher)
      {:ok, %{transients: publisher_transients_mid}} =
        Ezagent.Kind.get_raw_slice(session_uri, :publisher)

      assert publisher_slice_mid.cursor > cursor_at_window_start,
             "test pre-condition broken — the slice change in the empty-fanout window " <>
               "did not advance the publisher cursor. Worker cursor=#{cursor_at_window_start}, " <>
               "publisher cursor=#{publisher_slice_mid.cursor}. SliceChange may not be firing."

      assert publisher_transients_mid.subscribers == %{},
             "test pre-condition broken — subscribers should still be empty (the missed " <>
               "event happened with no subscribers). Found: #{inspect(publisher_transients_mid.subscribers)}"

      # Re-register the observer (some test infra paths can flush it).
      MockPublishBinding.register_observer(target_id, self())

      # ----- trigger the lifecycle handshake ------------------------------
      #
      # `broadcast_alive/1` fires `{:publisher_alive, session_uri}` on
      # the lifecycle topic. The Worker is subscribed; its
      # `handle_kind_message/3` `:publisher_alive` clause runs
      # `attempt_resubscribe/3` which (with the catchup fix) passes the
      # persisted `publisher_cursor` to `subscribe_from` and the
      # Publisher replays the ring event with `cursor = N+1` BEFORE
      # returning.
      :ok = Ezagent.PublisherLifecycle.broadcast_alive(session_uri)

      # ----- assert: the missed event IS published ------------------------
      assert_receive {:published, _, ^target_id, _},
                     2_000,
                     "Task #49 codex r3 NEW CHECK C regression — event emitted during " <>
                       "the empty-fanout window did NOT reach the Worker after the " <>
                       "`:publisher_alive` re-subscribe. The expected fix is for " <>
                       "`Ezagent.Behavior.ExternalMirrorWorker.attempt_resubscribe/3` to " <>
                       "pass the worker's persisted `publisher_cursor` to " <>
                       "`Publisher.subscribe_from` instead of `:latest` so the publisher " <>
                       "ring's events past the persisted cursor are replayed on subscribe."
    end

    test "out-of-window cursor falls back to :latest without crashing",
         %{session_uri: session_uri} do
      # Defensive coverage: if the worker's persisted cursor is older
      # than the publisher's retention ring, Publisher returns
      # `{:error, :cursor_out_of_window}`. The catchup fix MUST fall
      # back to `:latest` — keeping the Worker subscribed (live wire
      # restored) is more important than replaying unrecoverable
      # events.
      _ = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = await_session_ready(session_uri, 100)

      target_id = "tgt-out-of-window"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _sup_pid} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      Process.sleep(50)

      # Baseline publish to get a real cursor in the worker.
      send_chat_to_session(session_uri)
      assert_receive {:published, _, ^target_id, _}, 1_500
      drain_mailbox()

      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)

      # Force the worker's persisted cursor to a value older than
      # ANY ring entry (cursor 0 - the pre-publication zero). This
      # in itself is in-window (the ring's oldest entry has
      # cursor >= 1, so 0 < oldest - 1 is false for oldest=1, true
      # for oldest >= 2). To actually trip cursor_out_of_window? we
      # also need the ring to NOT contain cursor 0's neighbour, which
      # the SessionImpl maintains because cursor 0 is the initial
      # value before any events.
      #
      # Simpler: force the persisted cursor to a NEGATIVE value via
      # the dispatched-shape — Publisher's validate_window/3 raises
      # `{:invalid_cursor, _}`. That also exercises the error
      # fallback path. We want :cursor_out_of_window specifically,
      # so we mutate the publisher's ring to have all-high cursors
      # via `:sys.replace_state` while the worker carries cursor 0.
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)
      {:ok, worker_pid} = Ezagent.KindRegistry.lookup(worker_uri)

      # Move the worker's persisted cursor to 0 (older than the
      # ring's current contents which is cursor=1+).
      #
      # Lifecycle migration (Phase B): the worker slice is now the
      # two-container `%{state: %{...}, transients: %{...}}` shape, and
      # `publisher_cursor` is a PERSISTENT field — so mutate it under
      # `.state` (not the top level).
      :sys.replace_state(worker_pid, fn kind_state ->
        worker_slice = kind_state.state.external_mirror_worker
        new_worker_state = %{worker_slice.state | publisher_cursor: 0}
        new_worker_slice = %{worker_slice | state: new_worker_state}
        new_state = %{kind_state.state | external_mirror_worker: new_worker_slice}
        %{kind_state | state: new_state}
      end)

      # Bump the publisher ring's oldest cursor to a high value by
      # replacing the ring contents — emulates the retention window
      # having scrolled past cursor 0.
      :sys.replace_state(session_pid, fn kind_state ->
        publisher_slice = kind_state.state.publisher
        # Replace ring with synthetic high-cursor entries (so cursor 0
        # is clearly out-of-window per cursor_out_of_window?/2).
        synthetic_ring = [
          %Ezagent.Publisher.Event{
            cursor: 100,
            publisher_uri: session_uri,
            slice_key: :chat,
            event_at: DateTime.utc_now(),
            payload: %{}
          }
        ]

        # Post-lifecycle migration (remediation 2026-05-30): split the
        # persistent fields (`ring`/`cursor`, under `.state`) from the
        # transient bookkeeping (`subscribers`/`monitors`, under
        # `.transients`). A flat update raises `{:badkey, :monitors}`.
        new_pub_state = %{publisher_slice.state | ring: synthetic_ring, cursor: 100}
        new_pub_transients = %{publisher_slice.transients | subscribers: %{}, monitors: %{}}

        cleared_publisher = %{
          publisher_slice
          | state: new_pub_state,
            transients: new_pub_transients
        }

        new_state = %{kind_state.state | publisher: cleared_publisher}
        %{kind_state | state: new_state}
      end)

      # Trigger the re-subscribe handshake.
      :ok = Ezagent.PublisherLifecycle.broadcast_alive(session_uri)

      # Give it time to process. We don't assert on a Feishu publish
      # here (replay is impossible — that's the whole point of this
      # case). We assert the worker SURVIVED (didn't crash) and the
      # subscription was restored: the worker pid is in the new
      # subscribers map.
      Process.sleep(300)

      # `subscribers` is a TRANSIENT (remediation 2026-05-30) — read it from
      # the `transients` container via `get_raw_slice/2`.
      {:ok, %{transients: publisher_transients_after}} =
        Ezagent.Kind.get_raw_slice(session_uri, :publisher)

      assert map_size(publisher_transients_after.subscribers) >= 1,
             "Out-of-window fallback did not re-subscribe the worker at :latest. " <>
               "subscribers=#{inspect(publisher_transients_after.subscribers)}"

      # Sanity: worker is still alive (no crash).
      assert Process.alive?(worker_pid),
             "Worker crashed handling :cursor_out_of_window — fallback path is broken."
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

  defp send_chat_to_session(%URI{} = session_uri) do
    member_uri =
      URI.parse("entity://user/team-alpha/em-catchup-#{System.unique_integer([:positive])}")

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
end
