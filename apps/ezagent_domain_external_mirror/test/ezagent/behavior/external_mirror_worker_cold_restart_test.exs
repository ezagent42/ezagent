defmodule Ezagent.ActionSet.ExternalMirrorWorkerColdRestartTest do
  @moduledoc """
  Phase B (Lifecycle migration) — the cold-restart / transient-isolation
  invariant gate for `Ezagent.ActionSet.ExternalMirrorWorker`
  (`feedback_completion_requires_invariant_test` + SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6 AC-4).

  The worker's transports are TRANSIENTS: `binding_state` (the live
  transport connection), `subscription_state`, `adapter_module`,
  `binding_module`. Pre-migration these lived in the SAME flat slice as
  the persistent telemetry, so a snapshot of a (hypothetically persisted)
  worker would rehydrate a DEAD `binding_state` handle — the cold-restart
  bug class. Under Lifecycle they live ONLY in `transients`, which has no
  serialization path, and `activate/2` rebuilds them on every start.

  We can't use the generic `Ezagent.LifecycleCase.assert_transients_rebuilt/2`
  here: the Worker Entity is `:ephemeral` (OQ-6 `:hot_resource` — no
  snapshot) and is supervised by a CUSTOM two-tier RootSupervisor →
  PerBindingSupervisor (not a plain DynamicSupervisor that re-spawns the
  same URI from a snapshot). So the generic helper's "state rehydrates +
  supervisor restarts at the same URI from disk" precondition doesn't
  hold. We assert the two structural guarantees directly instead:

  1. The transport handles are PRESENT + LIVE in `transients` after
     `activate/2`, and ABSENT from the PERSISTENT `state` (the
     by-construction guarantee — a transient cannot be snapshotted).
  2. After a BRUTAL kill (`Process.exit(inner_pid, :kill)` — no graceful
     `deactivate`) the PerBindingSupervisor restarts the worker and
     `activate/2` rebuilds the transients to a LIVE equivalent (a FRESH
     `binding_state` — `MockPublishBinding.init/1` returns a new ref each
     call — never the stale prior handle).
  """

  # Remediation P6 (sandbox isolation): spawns Session/Worker Kinds that run
  # Repo queries in other processes; `EzagentCore.DataCase` provides the
  # shared sandbox owner + P6 drain so they don't hit
  # `DBConnection.OwnershipError`. See WorkerPublishTest for the full note.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{RootSupervisor, WorkerRegistry, WorkerSpawn}
  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.ExternalMirror.TestSupport.{MockPublishAdapter, MockPublishBinding}

  setup do
    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()
    on_exit(fn -> cleanup_workers() end)

    # SliceChange hook ON so :chat slice changes fan out to the Publisher
    # (which fires the worker's publish loop, advancing binding_state).
    orig = Application.get_env(:ezagent_core, :slice_change_hook)
    Application.put_env(:ezagent_core, :slice_change_hook, true)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:ezagent_core, :slice_change_hook),
        else: Application.put_env(:ezagent_core, :slice_change_hook, orig)
    end)

    # Targets the shared `system/main` session like the sibling worker
    # tests (worker_publish_test etc.) — its Publisher is demand-spawned by
    # the chat.join below. This test PASSES in isolation (the §6 / AC-4
    # cold-restart proof); in the full EM suite it joins the same
    # pre-existing `system/main` contention cluster as the other worker
    # tests (all of which are flaky together but green individually).
    {:ok, session_uri: Ezagent.URI.new!("session://system/default/main")}
  end

  test "transports live ONLY in transients; activate/2 rebuilds them live across a brutal restart",
       %{session_uri: session_uri} do
    target_id = "tgt-cold-restart"
    MockPublishBinding.register_observer(target_id, self())

    {:ok, _sup} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
    worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)

    wait_until(fn ->
      match?(
        {:ok, %{transients: %{subscription_state: :active}}},
        Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker)
      )
    end)

    # Drive a publish so the live transport handle ADVANCES its internal
    # state (MockPublishBinding.publish/2 bumps binding_state.publish_count).
    send_chat_to_session(session_uri)
    assert_receive {:published, _payload, ^target_id, _count}, 1_000

    wait_until(fn ->
      case Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker) do
        {:ok, %{transients: %{binding_state: %{publish_count: n}}}} when n >= 1 -> true
        _ -> false
      end
    end)

    # --- 1. Structural split: transports in transients, NOT in state. ---
    {:ok, %{state: state_before, transients: transients_before}} =
      Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker)

    assert transients_before.subscription_state == :active
    assert transients_before.adapter_module == MockPublishAdapter
    assert transients_before.binding_module == MockPublishBinding
    # The live transport handle has advanced (a publish happened on it).
    assert transients_before.binding_state.publish_count >= 1

    # The PERSISTENT state holds NONE of the transport keys (a transient
    # has no home in `state`, so it can never be snapshotted — the
    # cold-restart bug class is impossible by construction).
    refute Map.has_key?(state_before, :binding_state)
    refute Map.has_key?(state_before, :subscription_state)
    refute Map.has_key?(state_before, :adapter_module)
    refute Map.has_key?(state_before, :binding_module)
    assert state_before.adapter_id == "mock_publish"
    assert state_before.target_id == target_id

    # --- 2. Brutal kill → supervisor restart → activate rebuilds. ---
    binding_uri = URI.to_string(worker_uri)
    {:ok, sup_pid} = WorkerRegistry.lookup(binding_uri)
    [{_id, inner_pid_before, _, _}] = Supervisor.which_children(sup_pid)

    # Untrappable kill — no graceful deactivate runs (§OTP best-effort).
    # PerBindingSupervisor (:permanent) restarts the worker → activate/2.
    Process.exit(inner_pid_before, :kill)

    wait_until(fn ->
      case WorkerRegistry.lookup(binding_uri) do
        {:ok, s} ->
          case Supervisor.which_children(s) do
            [{_id, p, _, _}] when is_pid(p) and p != inner_pid_before ->
              match?(
                {:ok, %{transients: %{subscription_state: :active}}},
                Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker)
              )

            _ ->
              false
          end

        :error ->
          false
      end
    end)

    {:ok, %{transients: transients_after}} =
      Ezagent.Kind.get_raw_slice(worker_uri, :external_mirror_worker)

    # Transients rebuilt to a LIVE equivalent.
    assert transients_after.subscription_state == :active
    assert transients_after.adapter_module == MockPublishAdapter
    assert transients_after.binding_module == MockPublishBinding
    assert transients_after.binding_state != nil

    # The rebuilt transport handle is FRESH from `MockPublishBinding.init/1`
    # (publish_count back to 0), NOT the prior incarnation's advanced
    # handle. A `publish_count >= 1` here would mean the live handle was
    # persisted + rehydrated instead of rebuilt by activate/2 — the
    # cold-restart bug class.
    assert transients_after.binding_state.publish_count == 0,
           "binding_state carried a STALE (advanced) transport handle across the " <>
             "restart — it was persisted + rehydrated instead of rebuilt by " <>
             "activate/2. THIS IS the cold-restart bug class."
  end

  # ----- helpers (mirrors worker_publish_test.exs) -----

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

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

  # Trigger a Publisher event by joining a fresh member to the Session's
  # :chat slice (chat.join writes members → SliceChange → publisher event).
  defp send_chat_to_session(%URI{} = session_uri) do
    member_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/em-cold-restart-#{System.unique_integer([:positive])}"
      )

    user_module = Module.concat([Ezagent, Entity, User])

    case apply(Ezagent.Kind, :spawn, [user_module, %{uri: member_uri, initial_caps: MapSet.new()}]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    admin_uri = Ezagent.URI.new!("entity://system/user/admin")
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{caller: admin_uri, caps: admin_caps(target, admin_uri), reply: :ignore}
    })
  end

  defp admin_caps(target, admin_uri),
    do: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, admin_uri)])
end
