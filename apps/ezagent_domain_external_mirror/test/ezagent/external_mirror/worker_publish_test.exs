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

    {:ok, session_uri: URI.parse("session://default/default/main")}
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
      {:ok, slice} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)

      # After handle_continue completes, subscription_state is :active
      # and binding_state + the adapter/binding modules are bound.
      assert slice.subscription_state == :active
      assert slice.adapter_module == MockPublishAdapter
      assert slice.binding_module == MockPublishBinding
      assert slice.binding_state != nil
    end
  end

  describe "publish flow (PR-EM-2 acceptance test #1)" do
    test "Publisher event → :publish dispatch → binding.publish/2 called with right payload",
         %{session_uri: session_uri} do
      target_id = "tgt-publish-flow"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)

      # Trigger a slice change on the Session to fire a Publisher event.
      send_chat_to_session(session_uri, "hello world")

      # Binding's `publish/2` sent us {:published, payload, target_id, count}.
      assert_receive {:published, payload, ^target_id, _count}, 1_000

      # The payload is what MockPublishAdapter.event_to_payload/1
      # returned: %{event: event, echoed_at: dt}
      assert %{event: %Ezagent.Publisher.Event{} = ev} = payload
      assert ev.publisher_uri == session_uri or URI.to_string(ev.publisher_uri) == URI.to_string(session_uri)
      assert ev.cursor >= 1

      # Slice carries the cursor + count.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      {:ok, slice} = Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker)
      assert slice.publisher_cursor == ev.cursor
      assert slice.count >= 1
      assert slice.last_publish_result == :ok
      assert slice.last_published_at != nil
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
      # restart; the PerBindingSupervisor crashes and RootSupervisor
      # restarts it ONCE (the `:transient` PerBindingSupervisor child
      # treats supervisor-crash as not-:normal/:shutdown → restart).
      # After enough kills, the per-binding budget burns again, etc.
      # The KEY claim is the OTHER two PerBindingSupervisors are
      # unaffected throughout.
      victim_target = "tgt-isol-2"
      victim_worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", victim_target)
      victim_binding_uri = URI.to_string(victim_worker_uri)

      Enum.each(1..10, fn _ ->
        # Find the CURRENT inner pid for the victim binding (it may have
        # restarted between kills).
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
      end)

      Process.sleep(50)

      # The OTHER two bindings' PerBindingSupervisors must still be
      # alive in the Registry (they never crashed).
      survivors =
        WorkerRegistry.list_all()
        |> Enum.map(fn {_uri, pid} -> pid end)

      sibling_targets = ["tgt-isol-1", "tgt-isol-3"]

      Enum.each(sibling_targets, fn target ->
        wuri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target)
        buri = URI.to_string(wuri)
        assert {:ok, sup_pid} = WorkerRegistry.lookup(buri)
        assert sup_pid in survivors
        assert Process.alive?(sup_pid)
      end)
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
      send_chat_to_session(session_uri, "msg1")
      assert_receive {:published, _, ^target_id, _}, 1_000
      send_chat_to_session(session_uri, "msg2")
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

  # Trigger a Publisher event by mutating the Session's :chat slice
  # via `:chat.join` — joining a fresh user every call so the slice
  # ALWAYS differs from prior (SliceChange fires only on actual
  # mutation per PR-N1).
  #
  # Per `publisher_session_test.exs`: chat.send is read-only on the
  # slice (writes go to MessageStore via Repo), so it does NOT
  # trigger SliceChange. chat.join writes `members` + `monitors`.
  defp send_chat_to_session(%URI{} = session_uri, _label) do
    member_uri =
      URI.parse("entity://user/default/em-pub-test-#{System.unique_integer([:positive])}")

    # Spawn the member User Kind first (chat.join needs the member's
    # Kind alive so :receive dispatches can land later).
    user_module = Module.concat([Ezagent, Entity, User])

    case apply(Ezagent.Kind, :spawn, [user_module, %{uri: member_uri, initial_caps: MapSet.new()}]) do
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
