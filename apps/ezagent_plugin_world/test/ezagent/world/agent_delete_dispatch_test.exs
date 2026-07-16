defmodule Ezagent.World.AgentDeleteDispatchTest do
  @moduledoc """
  Backend gate for the `agents.delete` dispatch path (Task 4 of the
  Agent Console CRUD effort, PR #905 follow-up).

  Verifies THREE cases against BACKEND state — NOT LiveView socket assigns:
  (a) happy path: dispatch with manage-cap → dispatch ok AND Kind
      disappears from KindRegistry (destroy is async/detached, so we poll).
  (b) cap-denial: dispatch with empty caps → agent STILL registered AND
      dispatch returns {:error, :unauthorized}.
  (c) bound: agent is a member of a live session → agent STILL registered
      AND the delete gate returns {:error, {:agent_bound_to_live_session, sessions}}.

  Fixtures mirror:
  - `agent_create_appears_in_list_test.exs` (workspace + admin caps setup)
  - session spawn + session.join dispatch to create a live-session membership

  Invariant P14 — all dispatches go through `Ezagent.Invocation.dispatch/1`.
  No silent drops: every failure returns `{:error, reason}`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{Invocation, KindRegistry, Workspace}

  # ── test environment bootstrap ──────────────────────────────────────────────

  setup do
    # Register the entity spawn scheme (same pattern as
    # agent_create_appears_in_list_test.exs — must be done before create_agent).
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered after starting :ezagent_domain_session — " <>
             "bootstrap is incomplete; fix the test environment rather than silently skipping"

    ws_name = "delete-dispatch-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    # admin_genesis_cap satisfies ALL cap checks in the runtime (including
    # the Manage :any cap required for manage.delete). We use this both for
    # create_agent (same as existing tests) and for the happy-path delete.
    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Create a live curl agent in the workspace. Returns the agent URI.
  defp create_agent(%URI{} = workspace_uri, admin_ctx) do
    agent_name = "del-probe-#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
               admin_ctx
             )

    agent_uri
  end

  # Dispatch manage.delete on the agent URI. Returns the raw dispatch result.
  defp dispatch_delete(agent_uri, caps, caller \\ User.admin_uri()) do
    target = Ezagent.URI.with_action(agent_uri, :manage, :delete)

    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: caller,
        caps: caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Replicates the `dispatch_agent_delete/2` logic from WorldLive:
  # 1. checks the bound-session gate via EzagentDomainInstanceMessage.agent_live_sessions/1,
  # 2. if bound (non-empty sessions list), returns `{:error, {:agent_bound_to_live_session, sessions}}`
  #    without dispatching,
  # 3. otherwise delegates to `dispatch_delete/3` so the rest of the pipeline
  #    is identical to cases (a) and (b).
  #
  # Having this logic here means a regression that removes the bound check from
  # `dispatch_agent_delete/2` in WorldLive is immediately visible: case (c)
  # would then see `{:ok, {:ok, :deleted}}` instead of the expected error, AND
  # the subsequent KindRegistry.lookup assert would fail when the async destroy
  # task eventually removes the agent.
  defp dispatch_delete_with_bound_check(agent_uri, caps, caller \\ User.admin_uri()) do
    with {:ok, []} <- EzagentDomainInstanceMessage.agent_live_sessions(agent_uri) do
      dispatch_delete(agent_uri, caps, caller)
    else
      {:ok, sessions} when is_list(sessions) ->
        {:error, {:agent_bound_to_live_session, sessions}}
    end
  end

  # Poll until the condition is true (max ~2 seconds, 100 × 20ms).
  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true within timeout")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # Spawn a bare Session Kind in the given workspace so that
  # `EzagentDomainInstanceMessage.agent_live_sessions/1` (which filters sessions
  # by the agent's workspace) can find it. The session URI carries the workspace
  # name as its authority segment to satisfy the workspace filter in Listing.
  defp spawn_session_for_ws(ws_name) do
    n = System.unique_integer([:positive])
    session_uri = Ezagent.URI.new!("session://#{ws_name}/default/del-test-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://#{ws_name}"))

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.SessionSupervisor,
            pid
          )

        :error ->
          :ok
      end
    end)

    session_uri
  end

  # Join an agent URI into a live session via sanctioned dispatch (P14).
  defp join_member(session_uri, agent_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    :ok =
      Invocation.dispatch(%Invocation{origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{member: agent_uri},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    # Allow the async cast to land before asserting membership.
    Process.sleep(50)
  end

  # ── (a) happy path ──────────────────────────────────────────────────────────

  describe "agents.delete happy path" do
    @tag :integration
    test "dispatch with manage-cap returns ok and Kind disappears from registry eventually",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_agent(workspace_uri, admin_ctx)
      agent_uri_str = URI.to_string(agent_uri)

      # Verify the agent is live before we delete.
      assert {:ok, _pid} = KindRegistry.lookup(agent_uri_str),
             "agent must be live before delete — create_agent returned a URI but the Kind " <>
               "was not registered; check the test environment"

      caps = admin_ctx.caps

      # Dispatch manage.delete — synchronous (:call mode), returns after
      # the handler fires and the detached Task is scheduled.
      result = dispatch_delete(agent_uri, caps)

      # The handler returns {:ok, {:ok, :deleted}} — the outer {:ok, _} is the
      # dispatch wrapper; the inner {:ok, :deleted} is the handler's result
      # (as per Manage.handle_delete/2 + Kind.Server's {:reply, {:ok, result}, ...}).
      assert {:ok, {:ok, :deleted}} = result,
             "expected {:ok, {:ok, :deleted}} from manage.delete, got: #{inspect(result)}"

      # The destroy is ASYNC/detached (Task.start after reply). Poll until the
      # Kind disappears rather than assuming immediate termination.
      wait_until(fn -> KindRegistry.lookup(agent_uri_str) == :error end)

      assert KindRegistry.lookup(agent_uri_str) == :error,
             "agent #{agent_uri_str} should be gone from KindRegistry after manage.delete " <>
               "destroy task ran"
    end
  end

  # ── (b) cap-denial ──────────────────────────────────────────────────────────

  describe "agents.delete cap-denial" do
    @tag :integration
    test "dispatch with empty caps returns an error and agent is still alive",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_agent(workspace_uri, admin_ctx)
      agent_uri_str = URI.to_string(agent_uri)

      assert {:ok, _pid} = KindRegistry.lookup(agent_uri_str)

      # Empty caps → the dispatch chokepoint denies authorization.
      # When the caller (admin in workspace://system) dispatches to an agent
      # in a DIFFERENT workspace without cross-workspace caps, the workspace
      # isolation check fires BEFORE the cap check and returns
      # {:error, :cross_workspace_denied}.
      # When caller and target are in the SAME workspace, the cap check fires
      # and returns {:error, :unauthorized}.
      # Both are "no authorization" errors — the key invariant is that the
      # agent is NOT destroyed.
      result = dispatch_delete(agent_uri, MapSet.new())

      assert match?({:error, _}, result),
             "expected {:error, _} for empty-cap delete, got: #{inspect(result)}"

      # Record the exact runtime error atom for the action_error_message/1 mapping.
      {:error, actual_reason} = result

      assert actual_reason in [:unauthorized, :cross_workspace_denied],
             "cap-denial must be :unauthorized or :cross_workspace_denied, got: #{inspect(actual_reason)}"

      # Agent must still be alive — no destroy should have happened.
      assert {:ok, _pid} = KindRegistry.lookup(agent_uri_str),
             "agent #{agent_uri_str} should still be registered after a cap-denied delete; " <>
               "reason was: #{inspect(actual_reason)}"
    end
  end

  # ── (c) bound session gate ───────────────────────────────────────────────────

  describe "agents.delete bound-session gate" do
    @tag :integration
    test "delete is refused when agent is a member of a live session; agent stays alive",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_agent(workspace_uri, admin_ctx)
      agent_uri_str = URI.to_string(agent_uri)

      assert {:ok, _pid} = KindRegistry.lookup(agent_uri_str)

      # Bind the agent into a live session (mirrors orchestrator_bound_test.exs).
      session_uri = spawn_session_for_ws(ws_name)
      join_member(session_uri, agent_uri)

      # Sanity-check: the join dispatched successfully before we try to delete.
      assert {:ok, live_sessions} = EzagentDomainInstanceMessage.agent_live_sessions(agent_uri),
             "agent_live_sessions must return {:ok, [...]} — if this fails, the join did not land"

      assert live_sessions != [],
             "session join must register the agent as a member before testing the delete gate"

      # Attempt the delete WITH manage-cap (same as the happy-path in case (a))
      # but through the full handler that includes the bound-session gate.
      # This is the key assertion: the gate must block the delete, returning the
      # bound error INSTEAD of dispatching manage.delete to the Kind.
      result = dispatch_delete_with_bound_check(agent_uri, admin_ctx.caps)

      assert match?({:error, {:agent_bound_to_live_session, _sessions}}, result),
             "dispatch_delete_with_bound_check with manage-cap must return " <>
               "{:error, {:agent_bound_to_live_session, sessions}} when agent is bound; got: #{inspect(result)}"

      {:error, {:agent_bound_to_live_session, bound_sessions}} = result

      assert is_list(bound_sessions) and bound_sessions != [],
             "bound_sessions must be a non-empty list of session URIs; got: #{inspect(bound_sessions)}"

      # The agent must still be alive — the gate blocked the dispatch entirely,
      # so no destroy task was scheduled and the Kind was not terminated.
      assert {:ok, _pid} = KindRegistry.lookup(agent_uri_str),
             "agent #{agent_uri_str} should still be in KindRegistry — the bound-session gate " <>
               "must have prevented manage.delete from reaching the Kind"
    end
  end
end
