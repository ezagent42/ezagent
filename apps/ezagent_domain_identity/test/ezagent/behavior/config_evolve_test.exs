defmodule Ezagent.Behavior.ConfigEvolveTest do
  @moduledoc """
  PR-2 — `Ezagent.Behavior.ConfigEvolve` on the Agent (spec 2026-06-11 rev 4,
  §7 tests). The behavior is NOT yet wired into Turn (PR-3); the old
  `ConfigUpdate` path still runs. These tests drive ConfigEvolve in isolation
  by dispatching `config_evolve.apply_config_delta` directly to a spawned
  Agent Kind.

  Covers §7:
   1. authority gate — manager (manage-cap) CAN apply; stranger denied.
   2. durable apply — object + pointer written, applied marker set, idempotent.
   3. step-2 projection — deferred sandbox.write_path refreshes the cache.
   4. no cross-entity escalation — write fails (logged, non-fatal) without the
      self-cap (proves it is genuinely self-cap-gated).
   5. boot reconciliation — divergence (apply but drop the deferred dispatch)
      is healed on restart (`activate` → reconcile re-projects).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, CreatorGrant}
  alias Ezagent.Entity.{Agent, User}
  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  @cascade_key "advisor.behavior"

  setup do
    name = "ce-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    # Workspace-bind so manage-cap workspace matching resolves.
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    %{agent: agent, workspace: workspace}
  end

  # ---- §7.1 authority gate -------------------------------------------------

  test "apply_config_delta is DENIED without the agent's manage-cap", %{agent: agent} do
    target = action_uri(agent, :apply_config_delta)

    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{turn_id: "t1", patch: %{"tone" => "decisive"}},
               ctx: %{
                 caller: Ezagent.URI.entity(:team_alpha, :user, "stranger"),
                 caps: MapSet.new(),
                 reply: {:caller_inbox, self()}
               }
             })
  end

  # ---- §7.2 durable apply --------------------------------------------------

  test "apply_config_delta writes the immutable object + pointer (manager authorized)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-apply-#{System.unique_integer([:positive])}"

    assert {:ok, %{config_id: cid}} =
             apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})

    assert {:ok, _object} = ConfigStore.fetch_object(cid)
    assert ConfigStore.applied_for_turn?(turn_id)

    # The pointer resolves the new object on the agent's own user layer.
    assert {:ok, ^cid} = ConfigStore.current_user_object(agent, @cascade_key)
  end

  test "apply_config_delta is idempotent-stamped by source_turn_id (replay marker)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-replay-#{System.unique_integer([:positive])}"

    refute ConfigStore.applied_for_turn?(turn_id)
    assert {:ok, %{config_id: _}} = apply_delta(agent, manager, turn_id, %{"tone" => "v2"})
    assert ConfigStore.applied_for_turn?(turn_id)
  end

  # ---- §7.3 step-2 projection ---------------------------------------------

  test "after apply, the deferred sandbox.write_path refreshes cascade_resolution.user_layer_uri",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-proj-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})

    want = URI.to_string(ConfigProjection.object_uri(workspace, cid))

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "deferred sandbox.write_path never refreshed user_layer_uri to #{want}; " <>
             "got #{inspect(sandbox_user_layer_uri(agent))}"
  end

  # ---- §7.4 no cross-entity escalation (self-cap gated) --------------------

  # The sandbox write is genuinely cap-gated: a caller WITHOUT the agent's
  # self-scoped `cap(:agent, Sandbox, :write_path)` is denied. The step-2
  # projection succeeds (§7.3) precisely because it carries the agent's OWN
  # caps (read from its :identity sibling), not the step-1 manager's caps —
  # the manager holds only the manage-cap, which does NOT authorize
  # sandbox.write_path. This pair (this test + §7.3) proves the write is
  # authorized by the self-cap and nothing weaker.
  test "sandbox.write_path is denied to a caller lacking the agent's self-cap",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    # The manager holds ONLY the manage-cap — NOT Sandbox.write_path.
    manager = grant_manage_cap(agent, workspace)

    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.write_path"),
               mode: :call,
               args: %{
                 config_dir_path: "/tmp/x",
                 template_class: nil,
                 respawn_template_data: %{"flavor" => "cc"}
               },
               ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
             })
  end

  # ---- §7.5 boot reconciliation -------------------------------------------

  test "boot reconciliation re-projects when the Sandbox cache diverges from ConfigStore",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-recon-#{System.unique_integer([:positive])}"

    # Apply durably, but write a STALE cascade pointer directly into the
    # sandbox to simulate "step 1 committed, step 2 (the deferred dispatch)
    # never ran / was lost" — the crash window.
    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})
    force_sandbox_user_layer(agent, workspace, "stale://layer")
    assert sandbox_user_layer_uri(agent) == "stale://layer"

    want = URI.to_string(ConfigProjection.object_uri(workspace, cid))

    # Restart the agent → activate/2 self-defers reconcile_cascade → it
    # re-projects the durable pointer into the Sandbox cache.
    restart_agent(agent)

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "boot reconciliation never re-projected user_layer_uri to #{want}; " <>
             "got #{inspect(sandbox_user_layer_uri(agent))}"
  end

  # ========================================================================
  # Fixtures / helpers (ported from config_update_test.exs)
  # ========================================================================

  defp action_uri(agent, action) do
    Ezagent.URI.new!("#{URI.to_string(agent)}?action=config_evolve.#{action}")
  end

  # Mint the agent's manage-cap to a fresh manager principal and return
  # `%{uri, caps}` (the caps that authorize step-1 apply/repoint).
  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{System.unique_integer([:positive])}")
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    %{uri: manager, caps: MapSet.new([cap])}
  end

  # Dispatch step-1 apply carrying the delta in args (the agent has no turn
  # slice — PR-3's Turn rewire forwards the settled delta's fields the same
  # way). `subject_uri`/`workspace_uri`/`key`/`layer` default to the agent's
  # own user layer.
  defp apply_delta(agent, manager, turn_id, patch) do
    Invocation.dispatch(%Invocation{
      target: action_uri(agent, :apply_config_delta),
      mode: :call,
      args: %{turn_id: turn_id, patch: patch},
      ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
    })
  end

  # Seed the agent's sandbox with a cascade_resolution (the shape #17 stores
  # at create) so the step-2 projection has a cache to refresh.
  defp seed_sandbox_cascade(agent, workspace) do
    write_sandbox(agent, %{
      "flavor" => "cc",
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(User.admin_uri()),
        "workspace_uri" => URI.to_string(workspace),
        "user_layer_uri" => URI.to_string(User.admin_uri())
      }
    })
  end

  defp force_sandbox_user_layer(agent, workspace, layer_uri) do
    write_sandbox(agent, %{
      "flavor" => "cc",
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(User.admin_uri()),
        "workspace_uri" => URI.to_string(workspace),
        "user_layer_uri" => layer_uri
      }
    })
  end

  defp write_sandbox(agent, respawn_template_data) do
    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-ce-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: respawn_template_data
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defp sandbox_user_layer_uri(agent) do
    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    resolution =
      case Map.get(sandbox, :respawn_template_data) do
        %{} = rtd -> rtd["cascade_resolution"] || rtd[:cascade_resolution]
        _ -> nil
      end

    case resolution do
      %{} = res -> res["user_layer_uri"] || res[:user_layer_uri]
      _ -> nil
    end
  end

  defp restart_agent(agent) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(agent)

    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainInstanceMessage.AgentSupervisor,
        pid
      )

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent})
    :ok
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
end
