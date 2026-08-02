defmodule EzagentDomainSocialware.Integration.TurnConfigEvolveRewireTest do
  @moduledoc """
  PR-3 — `Turn.config_update_effects` cut-over (spec 2026-06-11 rev 4/5, §5
  data flow + §4 authority).

  The NORMAL settlement path no longer self-dispatches `:apply_delta` to the
  SESSION (the old `ConfigUpdate`). It now extracts `subject_uri` from the
  settled `config_delta` and dispatches `config_evolve.apply_config_delta` to
  the TARGET AGENT, forwarding the delta fields as args and carrying the
  settling manager's caps. The settling caller must hold the target agent's
  manage-cap (`cap(:agent, Manage, :any, instance: agent)`); without it the
  agent-side apply is denied and the agent's config does NOT advance.

  Covers:
   * Task 3.1 — authorized settler (holds the agent's manage-cap) → the agent's
     ConfigStore pointer advances (the new agent-owned path ran).
   * Task 3.1 (denial) — settler WITHOUT the manage-cap → the agent-side apply
     is denied; the pointer does NOT advance.
   * Task 3.2 — settlement RECOVERY replays the config apply under the RECORDED
     manager's CURRENTLY-loaded caps (re-validated against the manager's current
     authority), never bootstrap-laundered:
       (a) manager still holds the manage-cap → apply runs (pointer advances);
       (b) manager's manage-cap was REVOKED → apply denied (does NOT run);
       (c) no manager URI recorded (legacy/edge) → config replay skipped.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{CreatorGrant, Invocation}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Socialware.ConfigStore

  @cascade_key "agent.soul"

  # PR-甲-2 (#154): `User.default_caps/1` is now `[]` (the broad
  # `cap(:session,:any,:any)` baseline that used to silently authorize the
  # session turn lifecycle was removed). In production a settler holds the
  # specific session-scoped Turn caps (or runs under the orchestrator/system
  # authority that drives turns); the test must mirror that instead of leaning
  # on the wildcard baseline. These are the concrete `cap(:session, Turn, <a>)`
  # caps the open→compose→claim→settle drive needs, scoped to THIS session.
  defp turn_drive_caps(session, grantee) do
    for action <- [:open, :compose, :claim, :settle, :deliver, :dispatch, :cancel] do
      target = Ezagent.URI.with_action(session, :turn, action)
      Ezagent.Test.CapHelper.signed_action_cap!(target, grantee)
    end
  end

  setup do
    owner = Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "tce-owner")

    session =
      Ezagent.URI.session(:team_alpha, :socialware, "tce-#{System.unique_integer([:positive])}")

    workspace = Ezagent.Capability.workspace_of(session)

    agent =
      Ezagent.URI.entity(:team_alpha, :agent, "tce-agent-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    %{session: session, workspace: workspace, agent: agent, owner: owner}
  end

  # ---- Task 3.1 — normal settlement rewires to the target agent ------------

  test "a settled config_delta evolves the TARGET AGENT when the settler holds the manage-cap",
       %{session: session, workspace: workspace, agent: agent, owner: owner} do
    manager = spawn_manager_with_manage_cap(owner, session, agent, workspace)

    turn_id = run_turn_to_settle(session, manager, workspace, agent)

    # The new agent-owned path ran: the agent's user-layer pointer now resolves
    # an object whose body carries the patch.
    assert wait_until(fn ->
             match?({:ok, _}, ConfigStore.current_user_object(agent, @cascade_key))
           end),
           "agent's ConfigStore pointer never advanced (config_evolve.apply_config_delta " <>
             "did not run on the target agent)"

    {:ok, object_id} = ConfigStore.current_user_object(agent, @cascade_key)
    {:ok, object} = ConfigStore.fetch_object(object_id)
    assert object.body["tone"] == "decisive"
    assert ConfigStore.applied_for_turn?(turn_id)
  end

  test "a settler WITHOUT the agent's manage-cap does NOT evolve the agent",
       %{session: session, workspace: workspace, agent: agent, owner: owner} do
    # A manager principal that holds ordinary session-scoped caps but NOT the
    # agent's manage-cap.
    settler = %{
      uri: owner,
      # Holds the session turn-drive caps (so it CAN run the turn) but NOT the
      # agent's manage-cap — the point of this test (the agent-side apply is
      # denied for lack of the manage-cap, not for lack of turn authority).
      caps: MapSet.new(turn_drive_caps(session, owner))
    }

    _turn_id = run_turn_to_settle(session, settler, workspace, agent)

    # The agent-side apply was denied → no pointer was ever set for the agent.
    refute eventually_true?(fn ->
             match?({:ok, _}, ConfigStore.current_user_object(agent, @cascade_key))
           end),
           "agent's config advanced despite the settler lacking the manage-cap"
  end

  # ---- Task 3.2 — recovery replays under the RECORDED manager's caps -------

  test "recovery replays the config apply under the recorded manager (still authorized)",
       %{session: session, workspace: workspace, agent: agent, owner: owner} do
    manager = spawn_manager_with_manage_cap(owner, session, agent, workspace)

    settled_turn = settled_turn_with_delta(workspace, agent, manager.uri)
    turn_id = "#{URI.to_string(session)}#turn-recover-ok"

    effects =
      recovery_config_effects(session, turn_id, settled_turn)

    assert effects != [], "recovery emitted no config-apply effect for a recorded manager"
    assert Enum.all?(effects, &match?({:dispatch, _}, &1))

    # The replayed dispatch targets the AGENT's apply_config_delta and carries
    # the manager's CURRENT caps (not bootstrap).
    [{:dispatch, cmd}] = effects
    assert cmd.action == :apply_config_delta
    assert cmd.target == agent
    assert cmd.ctx.caller == manager.uri
    # The manager's currently-loaded caps include the agent's manage-cap.
    assert Enum.any?(cmd.ctx.caps, fn c ->
             c.behavior == Ezagent.ActionSet.Manage and c.instance == agent
           end)
  end

  test "recovery DENIES the config apply when the recorded manager's manage-cap was revoked",
       %{session: session, workspace: workspace, agent: agent, owner: owner} do
    manager = spawn_manager_with_manage_cap(owner, session, agent, workspace)
    # Revoke the manage-cap from the manager's identity (current authority lost).
    revoke_manage_cap(manager.uri, agent, workspace)

    settled_turn = settled_turn_with_delta(workspace, agent, manager.uri)
    turn_id = "#{URI.to_string(session)}#turn-recover-revoked"

    effects = recovery_config_effects(session, turn_id, settled_turn)

    # The effect is still emitted (recovery re-dispatches), but it carries the
    # manager's CURRENT caps — which no longer include the manage-cap — so the
    # standard gate denies it. Prove the laundering is gone: the dispatched ctx
    # must NOT hold the manage-cap (and must not be bootstrap).
    case effects do
      [] ->
        :ok

      [{:dispatch, cmd}] ->
        refute Enum.any?(cmd.ctx.caps, fn c ->
                 c.behavior == Ezagent.ActionSet.Manage and c.instance == agent
               end),
               "recovery re-dispatched with the manage-cap despite it being revoked (laundering)"

        refute bootstrap_caps?(cmd.ctx.caps),
               "recovery used bootstrap caps for the config replay (laundering)"
    end
  end

  test "recovery SKIPS the config apply when no manager URI was recorded (legacy/edge)",
       %{session: session, workspace: workspace, agent: agent} do
    # A settled turn whose config_delta is present but with NO recorded settler.
    settled_turn =
      workspace
      |> settled_turn_with_delta(agent, nil)
      |> Map.delete(:settler_uri)

    turn_id = "#{URI.to_string(session)}#turn-recover-legacy"

    effects = recovery_config_effects(session, turn_id, settled_turn)

    assert effects == [],
           "recovery emitted a config-apply effect despite no recorded manager (fail-safe violated)"
  end

  # ========================================================================
  # Fixtures / helpers
  # ========================================================================

  # Spawn a manager User Kind whose Identity slice holds the agent's manage-cap,
  # so both the normal-path dispatch caps AND `Identity.list_caps_for/1`
  # (recovery) see it.
  defp spawn_manager_with_manage_cap(manager, session, agent, workspace) do
    manage_cap =
      :agent
      |> CreatorGrant.manage_cap(agent, workspace, manager)
      |> then(&Ezagent.Test.CapHelper.signed_cap!(agent, manager, &1))

    # The settler drives the session turn (open/compose/claim/settle), so it
    # holds the concrete session-scoped Turn caps — plus the agent's manage-cap
    # that authorizes the agent-side apply. (PR-甲-2: no broad default baseline.)
    caps = MapSet.new([manage_cap | turn_drive_caps(session, manager)])
    :ok = Ezagent.IdentityCaps.grant(manager, manage_cap)
    %{uri: manager, caps: caps}
  end

  defp revoke_manage_cap(manager_uri, agent, workspace) do
    {:ok, caps} =
      Ezagent.Domain.Agent.read_caps(manager_uri, %{
        caller: manager_uri,
        authenticated_principal: manager_uri
      })

    cap =
      Enum.find(caps, fn cap ->
        cap.behavior == Ezagent.ActionSet.Manage and cap.instance == agent and
          cap.workspace_uri == workspace
      end)

    target =
      Ezagent.URI.new!("#{URI.to_string(manager_uri)}?action=identity_admin.revoke_cap")

    caller = User.admin_uri()
    authority = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{cap: cap},
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: MapSet.new([authority]),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  # Run a full turn (open → compose with a config_delta → claim → settle) under
  # the given settler's caps, returning the turn_id.
  defp run_turn_to_settle(session, settler, workspace, agent) do
    {:ok, %{turn_id: turn_id}} =
      dispatch_as(session, :turn, :open, %{trigger: %{message_id: "t"}, opened_at: 1}, settler)

    {:ok, _} =
      dispatch_as(
        session,
        :turn,
        :compose,
        %{
          turn_id: turn_id,
          result_refs: [
            %{
              kind: :config_delta,
              layer: :user,
              workspace_uri: workspace,
              subject_uri: agent,
              key: @cascade_key,
              patch: %{"tone" => "decisive"}
            }
          ]
        },
        settler
      )

    {:ok, _} = dispatch_as(session, :turn, :claim, %{turn_id: turn_id, by: settler.uri}, settler)
    {:ok, _} = dispatch_as(session, :turn, :settle, %{turn_id: turn_id}, settler)
    turn_id
  end

  defp dispatch_as(session, behavior, action, args, settler) do
    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.new!("#{URI.to_string(session)}?action=#{behavior}.#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: settler.uri,
        authenticated_principal: settler.uri,
        caps: settler.caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  # A settled-turn map shaped as the `:turns` slice stores it (with the
  # config_delta in `result` and the recorded settler URI).
  defp settled_turn_with_delta(workspace, agent, settler_uri) do
    %{
      status: :settled,
      settler_uri: settler_uri,
      result: %{
        version: nil,
        message_ids: [],
        config_delta: %{
          kind: :config_delta,
          layer: :user,
          workspace_uri: workspace,
          subject_uri: agent,
          key: @cascade_key,
          patch: %{"tone" => "recovered"}
        }
      }
    }
  end

  # Drive the recovery signal path against a single settled turn and return the
  # CONFIG effects only (filter out settlement approve/commit). Uses a fresh
  # turn_id so the `applied_for_turn?` idempotency gate lets the replay through.
  defp recovery_config_effects(session, turn_id, settled_turn) do
    signal_ctx = %{
      self_uri: session,
      read: fn
        :turns, _default -> %{turn_id => settled_turn}
        _key, default -> default
      end
    }

    {:ok, effects} =
      Ezagent.ActionSet.Turn.handle_signal({:ezagent_recover_settlements}, signal_ctx)

    Enum.filter(effects, fn
      {:dispatch, %Ezagent.Cmd{action: :apply_config_delta}} -> true
      _ -> false
    end)
  end

  defp bootstrap_caps?(caps) do
    Enum.any?(caps, fn
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # Poll a few times and return whether the condition EVER became true (for
  # asserting a NEGATIVE — the apply must never run).
  defp eventually_true?(fun, attempts \\ 25) do
    wait_until(fun, attempts)
  end
end
