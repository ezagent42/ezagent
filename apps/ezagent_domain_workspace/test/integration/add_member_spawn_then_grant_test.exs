defmodule Ezagent.Integration.AddMemberSpawnThenGrantTest do
  @moduledoc """
  Task #46 (Allen 2026-05-27) — `Behavior.Workspace.invoke(:add_member, ...)`
  pre-spawns the member's User Kind via `SpawnRegistry.spawn/1` BEFORE
  dispatching `identity.grant_cap`. Pre-fix the grant raced the
  `KindRegistry` registration and silently failed with `:no_such_actor`
  for any user who had not yet logged in, defeating PR #408's UX
  promise that workspace members can `mix ezagent workspace create_session`
  without an admin intervention.

  The invariant test exercises a dispatch-level `:add_member` (mirrors
  the `Behavior.Workspace.invoke/4` body — the same code path the LV
  workspace settings, mix tasks, and CLI all converge on) and asserts:

    1. The member's User Kind is alive in `KindRegistry` post-dispatch.
    2. The member holds a `workspace.:create_session` cap on the
       workspace (the per-`add_member` grant from
       `grant_member_create_session_cap/2` landed).

  Both checks together prove the spawn-then-grant ordering: without
  the pre-spawn, (1) would be missing and the dispatch in (2) would
  return `{:error, :no_such_actor}` → no cap on the member.

  The test invokes the Behavior action body directly (`Workspace.invoke/4`)
  rather than going through the `Ezagent.Workspace.add_member/2` facade
  because the facade dispatches via `:cast` (fire-and-forget), making
  it racy to assert on side-effects synchronously. The Behavior action
  body is the canonical chokepoint — every dispatch path lands here.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Identity, KindRegistry, SpawnRegistry, Workspace}
  alias Ezagent.Behavior.Workspace, as: WB

  setup do
    ws_name = "addmember-spawn-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")
    workspace_uri_str = URI.to_string(workspace_uri)

    # Generate a fresh user URI that is NOT yet in `KindRegistry` —
    # the exact pre-fix race condition.
    user_name = "alice-#{System.unique_integer([:positive])}"
    user_uri = URI.new!("entity://user/#{ws_name}/#{user_name}")

    refute_user_alive(user_uri)

    on_exit(fn ->
      # Cleanup — terminate the User Kind we spawn up so subsequent
      # test runs don't see a stale registration. Best-effort.
      _ = Ezagent.Kind.terminate(user_uri)
    end)

    {:ok,
     ws_name: ws_name,
     workspace_uri: workspace_uri,
     workspace_uri_str: workspace_uri_str,
     user_uri: user_uri}
  end

  test "invoke(:add_member, ...) of a previously-unspawned user (a) spawns the User Kind and (b) grants :create_session cap",
       %{workspace_uri: workspace_uri, workspace_uri_str: workspace_uri_str, user_uri: user_uri} do
    # Pre-condition: the user is genuinely not in the registry.
    assert KindRegistry.lookup(user_uri) == :error

    # Drive the Behavior action body directly — the canonical dispatch
    # chokepoint shared by every caller (LV form, mix task, CLI, RPC).
    slice = WB.init_slice(%{})
    ctx = %{self_uri: workspace_uri}

    assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: user_uri}, ctx)
    assert MapSet.member?(new_slice.members, user_uri)

    # (a) User Kind alive — pre-fix this lookup was `:error` (no spawn
    # happened; the grant dispatched against an unregistered URI and
    # the workaround was to ask an admin to provision the user first).
    assert {:ok, _pid} = KindRegistry.lookup(user_uri)

    # (b) The member holds the workspace.:create_session cap. The
    # grant dispatches via `:cast` — `Ezagent.PendingDelivery` buffers
    # it while the User Kind is `:not_ready` (post_init reconcile),
    # then `Kind.Server` flushes the buffer on the ready transition.
    # We poll with a brief deadline so the test is robust without
    # tying the wait to a fixed `Process.sleep`. Pre-fix the grant
    # was a `:call` that fail-fasted with `:not_ready` and the cap
    # never landed — `:create_session` then denied every attempt.
    #
    # Compare via `URI.to_string/1` because the cap struct stores the
    # workspace URI as parsed by `URI.parse/1` (carries the `:authority`
    # field) whereas `URI.new!` does not — equal-as-strings, not as
    # structs.
    assert eventually_has_create_session_cap?(user_uri, workspace_uri_str),
           "expected workspace.create_session cap on #{URI.to_string(user_uri)} " <>
             "within 2s; got #{inspect(MapSet.to_list(Identity.list_caps_for(user_uri)))}"
  end

  test "facade Workspace.add_member/2 reaches the same spawn-then-grant chokepoint",
       %{
         ws_name: ws_name,
         workspace_uri_str: workspace_uri_str,
         user_uri: user_uri
       } do
    # The `Ezagent.Workspace.add_member/2` facade dispatches via
    # `:cast` to the live Workspace Kind, which runs the Behavior
    # action body. The facade-local `grant_member_create_session_cap/2`
    # helper was deleted in task #46 — every grant flows through the
    # single Behavior chokepoint. This test asserts the facade path
    # produces the same post-state (User Kind alive + cap landed)
    # so callers like LV / mix-task / RPC don't regress.
    assert KindRegistry.lookup(user_uri) == :error

    assert :ok = Workspace.add_member(ws_name, user_uri)

    # Cast is fire-and-forget — poll for the chokepoint's side effects.
    assert eventually_alive?(user_uri)
    assert eventually_has_create_session_cap?(user_uri, workspace_uri_str)
  end

  test "invoke(:add_member, ...) is idempotent for an already-spawned user", %{
    workspace_uri: workspace_uri,
    workspace_uri_str: workspace_uri_str,
    user_uri: user_uri
  } do
    # Pre-spawn the user explicitly before the action fires. This is
    # the alternate path: user logs in first, then admin adds them.
    # `SpawnRegistry.spawn` is idempotent inside the action body, so a
    # duplicate spawn must NOT crash.
    assert {:ok, pid1} = SpawnRegistry.spawn(user_uri)

    slice = WB.init_slice(%{})
    ctx = %{self_uri: workspace_uri}

    assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: user_uri}, ctx)
    assert MapSet.member?(new_slice.members, user_uri)

    # Same PID — the action body adopted the existing Kind rather
    # than starting a new one (KindRegistry is keyed by URI).
    assert {:ok, ^pid1} = KindRegistry.lookup(user_uri)

    # And the cap still landed (poll briefly — same `:cast` buffered
    # delivery as the unspawned-user test).
    assert eventually_has_create_session_cap?(user_uri, workspace_uri_str)
  end

  # Poll `KindRegistry.lookup/1` for up to 2s waiting for the
  # spawn-step to land. Used by the facade test where the entire
  # add_member path is async (facade dispatches `add_member` mutation
  # as `:cast`).
  defp eventually_alive?(uri) do
    Enum.reduce_while(1..40, false, fn _, _ ->
      case KindRegistry.lookup(uri) do
        {:ok, _pid} -> {:halt, true}
        :error -> Process.sleep(50) && {:cont, false}
      end
    end)
  end

  # Poll Identity.list_caps_for/1 for up to 2s waiting for the
  # buffered grant_cap cast to be delivered. `:cast` is fire-and-forget
  # at the dispatch level, so the test cannot synchronously await it;
  # 2s is generous compared to the User Kind's post_init reconcile +
  # PendingDelivery flush, which complete sub-millisecond in practice.
  defp eventually_has_create_session_cap?(user_uri, workspace_uri_str) do
    Enum.reduce_while(1..40, false, fn _, _ ->
      caps = Identity.list_caps_for(user_uri)

      hit? =
        Enum.any?(caps, fn cap ->
          match?(%Ezagent.Capability{}, cap) and
            cap.kind == :workspace and
            cap.behavior == Ezagent.Behavior.Workspace and
            cap.action == :create_session and
            match?(%URI{}, cap.instance) and
            URI.to_string(cap.instance) == workspace_uri_str
        end)

      if hit? do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  defp refute_user_alive(uri) do
    case KindRegistry.lookup(uri) do
      :error ->
        :ok

      {:ok, _pid} ->
        flunk(
          "test bug — user URI #{URI.to_string(uri)} is alive at setup; " <>
            "the task #46 invariant test must start with a NOT-yet-spawned user"
        )
    end
  end
end
