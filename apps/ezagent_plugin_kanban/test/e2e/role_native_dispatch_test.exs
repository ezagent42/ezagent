defmodule EzagentPluginKanban.E2E.RoleNativeDispatchTest do
  @moduledoc """
  K2 acceptance — the `kanban-manager` recipe's behaviors dispatch PER-INSTANCE
  on a generic `Entity.Agent` host (flavor `native`) via RF-1's
  `BehaviorSet.resolve_action`, even though `Entity.Agent` declares NOTHING
  kanban-specific.

  Proves:

    1. a role × native agent created with `behaviors: [Behavior.Kanban]`
       dispatches `kanban.add_node` (RF-1 per-instance fallback) AND the
       `:kanban` slice materializes (Entity.Agent snapshot);
    2. a SIBLING `Entity.Agent` WITHOUT the kanban recipe → `kanban.add_node`
       → `{:error, {:unknown_action, :add_node}}` (P1 subset-denial: a behavior
       absent from the instance's effective set does NOT dispatch; the runtime
       resolves the action BEFORE the cap check, so this is genuinely
       unknown-action, not an authz miss).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "k2-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "k2-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    # native-style direct-spawn flavor: the UNIFIED Agent Kind, NO
    # instance_behaviors thunk (a roleless spawn captures only the base set),
    # fail-closed cap policy granting exactly the recipe's requested caps.
    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    # The REAL kanban-manager recipe (K1) — registered so the create path wires it.
    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    {:ok, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "kanban-manager × native dispatches kanban.add_node + :kanban slice materializes",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kanban-mgr-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
                 admin_ctx
               )

      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

      # RF-1: kanban.add_node dispatches via per-instance resolution on the
      # generic Entity.Agent host (which declares NO kanban). Building a ROOT
      # node is admin-gated (per-node owner authz, R2), so dispatch as admin —
      # K2 is the dispatch/slice gate; the per-node owner gate is K3's subject.
      assert {:ok, %{id: "n1"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx),
             "kanban.add_node did NOT dispatch via per-instance resolution (RF-1)"

      # The :kanban slice materialized + persisted (Entity.Agent snapshot).
      assert {:ok, kanban_slice} = Ezagent.Kind.get_slice(agent_uri, :kanban),
             "the :kanban slice did not materialize on the Entity.Agent host"

      assert %{tree: %{nodes: nodes}} = kanban_slice
      assert map_size(nodes) == 1
    end)
  end

  @tag :integration
  test "a sibling Entity.Agent WITHOUT the kanban recipe → :unknown_action",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "plain-agent-#{System.unique_integer([:positive])}"

      # No role → the flavor base set only (no kanban behavior loaded).
      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, cwd: "", with_pty: false},
                 admin_ctx
               )

      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

      # resolve_action runs BEFORE authz in the runtime, so a kanban-less
      # instance surfaces :unknown_action (not a cap denial).
      assert {:error, {:unknown_action, :add_node}} =
               dispatch(agent_uri, :add_node, %{parent_id: "", title: "x"}, admin_ctx),
             "a kanban-less Entity.Agent must NOT resolve kanban.add_node (P1 subset-denial)"

      # And the :kanban slice never materializes on it (no kanban behavior in the
      # effective set → no slice; Entity.Agent returns {:ok, nil} for an absent
      # slice key, never an actual kanban tree).
      assert {:ok, nil} = Ezagent.Kind.get_slice(agent_uri, :kanban)
    end)
  end

  defp dispatch(agent_uri, action, args, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.with_action(agent_uri, :kanban, action)

    caps =
      if Ezagent.Identity.admin?(caller) do
        case Ezagent.Cap.issue_for_action({:admin, caller}, caller, target) do
          {:ok, cap} -> MapSet.new([cap])
          {:error, {:unknown_action, _action}} -> caps
        end
      else
        caps
      end

    cmd =
      Ezagent.Cmd.new(
        target,
        action,
        args,
        %{
          mode: :call,
          caller: caller,
          authenticated_principal: caller,
          caps: caps,
          reply: {:caller_inbox, self()}
        }
      )

    Ezagent.Router.dispatch(cmd)
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
