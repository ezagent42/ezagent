defmodule EzagentPluginKanban.E2E.DispatchVerbKanbanTest do
  @moduledoc """
  Phase 3 ③ T7f — the generic `mix ezagent dispatch` verb reaching a
  PER-INSTANCE ROLE-MOUNTED kanban behavior (the actual gap the verb closes).

  `Behavior.Kanban` is mounted via RF-1 on the generic `Entity.Agent` host by
  the `kanban-manager` role — it is NOT statically registered in
  `BehaviorRegistry` (`behaviors/0 == []`, K5), so the auto-derived CLI tree
  never exposes a `kanban` verb (`mix ezagent kanban.*` → "unrecognized
  arguments", evidence t7bact-03). The generic `dispatch` verb is the only CLI
  path that reaches it.

  This pins the verb through the FULL production CLI surface
  (`EzagentCli.Exec.exec/2`: token → authenticate → caller override →
  `run_dispatch/1` → Invocation.dispatch → CapBAC), against a REAL
  kanban-manager agent created via the sanctioned `Workspace.create_agent`
  role-create path:

    * a caller HOLDING the kanban member cap dispatches `kanban.add_node` /
      `kanban.claim_node` / `kanban.set_status` successfully (board persists on
      the agent's `:kanban` slice);
    * a least-priv caller with EMPTY caps is DENIED by the CapBAC gate
      (`:unauthorized`, non-zero exit) — proving the verb does NOT elevate.

  Mirrors the harness of `EzagentPluginKanban.E2E.RoleNativeCreateTest`.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.Workspace
  alias Ezagent.Entity.{Token, User}
  alias Ezagent.{AgentFlavorRegistry, Capability, Users}
  alias Ezagent.Agent.RecipeRegistry
  alias EzagentCli.Exec
  alias EzagentPluginKanban.Application, as: KanbanApp
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @flavor "t7f-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    ws_name = "t7f-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Capability.admin_genesis_cap()])
    }

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
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
  test "`mix ezagent dispatch` reaches the role-mounted kanban behavior; CapBAC gates the caller",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "t7f-mgr-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
                 admin_ctx
               )

      target = URI.to_string(agent_uri)

      # Admin seeds the root node (building a root = admin-only, per the kanban
      # handler's per-node authz; this is fixture, NOT the verb under test). Done
      # via direct dispatch with the admin ctx, like RoleNativeCreateTest.
      assert {:ok, %{id: node_id}} =
               admin_dispatch(agent_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      assert {:ok, %{tree: %{nodes: nodes}}} = Ezagent.Kind.get_slice(agent_uri, :kanban)
      assert map_size(nodes) == 1

      # A caller HOLDING the kanban member cap (:agent kind axis — the host is
      # Entity.Agent so the required-cap kind resolves to :agent).
      member_cap =
        Capability.cap(:agent, Ezagent.Behavior.Kanban, :any)
        |> Map.put(:granted_by, User.admin_uri())
        |> Map.put(:granted_at, DateTime.utc_now())

      member_uri_str = "entity://#{ws_name}/user/t7f_member_#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(member_uri_str, nil, [member_cap])
      member_uri = Ezagent.URI.new!(member_uri_str)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(member_uri)
      {member_token, _} = Token.mint(member_uri, label: "t7f-member")

      # (1) claim_node via the generic dispatch verb — REACHES the role-mounted
      #     kanban behavior (NOT in the static tree) and passes CapBAC (member
      #     holds the cap); the handler allows claiming an unclaimed node.
      claim =
        exec_dispatch(target, "kanban.claim_node", %{id: node_id}, member_token, member_uri_str)

      assert claim.exit_code == 0,
             "member-cap token must reach kanban.claim_node via dispatch. out=#{inspect(claim.output)}"

      # owner persisted = the member (board state on the agent's :kanban slice).
      assert {:ok, %{tree: %{nodes: after_claim}}} = Ezagent.Kind.get_slice(agent_uri, :kanban)
      assert after_claim[node_id].owner == member_uri_str

      # (2) set_status via the verb — the owner advances the status (with --args
      #     JSON decoded + atomized to the kanban handler).
      status =
        exec_dispatch(
          target,
          "kanban.set_status",
          %{id: node_id, status: "doing"},
          member_token,
          member_uri_str
        )

      assert status.exit_code == 0, "set_status via dispatch. out=#{inspect(status.output)}"

      # (3) CapBAC DENIES a least-priv (empty-caps) caller through the SAME verb.
      lp_uri_str = "entity://#{ws_name}/user/t7f_lp_#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(lp_uri_str, nil, [])
      lp_uri = Ezagent.URI.new!(lp_uri_str)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(lp_uri)
      {lp_token, _} = Token.mint(lp_uri, label: "t7f-lp")

      denied =
        exec_dispatch(
          target,
          "kanban.set_status",
          %{id: node_id, status: "done"},
          lp_token,
          lp_uri_str
        )

      assert denied.exit_code != 0,
             "least-priv (empty-caps) token must be CapBAC-denied via dispatch — " <>
               "the verb must NOT elevate. out=#{inspect(denied.output)}"
    end)
  end

  @tag :integration
  test "T7g Part A — pm's BOARD-SCOPED kanban cap drives ITS board (positive) but is denied on an UNRELATED board (越权)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      # Two boards (kanban-manager role agents). pm gets caps scoped to board_a ONLY.
      board_a = create_board(workspace_uri, admin_ctx, "a")
      board_b = create_board(workspace_uri, admin_ctx, "b")

      assert {:ok, %{id: node_a}} =
               admin_dispatch(board_a, :add_node, %{parent_id: "", title: "根A"}, admin_ctx)

      assert {:ok, %{id: node_b}} =
               admin_dispatch(board_b, :add_node, %{parent_id: "", title: "根B"}, admin_ctx)

      # "pm": a live caller granted board_a-scoped kanban caps via the PRODUCTION
      # grant path (GrantRecipeCaps + the T7g instance override). NOT self-scoped.
      pm_uri_str = "entity://#{ws_name}/user/t7g_pm_#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(pm_uri_str, nil, [])
      pm_uri = Ezagent.URI.new!(pm_uri_str)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(pm_uri)
      wait_ready(pm_uri)

      pm_recipe = %{
        name: "pm-coordinator",
        requested_caps:
          for action <- [:get_tree, :claim_node, :set_status] do
            %{behavior: Ezagent.Behavior.Kanban, action: action}
          end
      }

      assert :ok =
               GrantRecipeCaps.grant_recipe_caps(
                 pm_uri,
                 pm_recipe,
                 [:ezagent, :test, :t7g, :e2e],
                 %{Ezagent.Behavior.Kanban => board_a}
               )

      {pm_token, _} = Token.mint(pm_uri, label: "t7g-pm")

      # (positive) pm drives board_a: claim → set_status, board_a slice really changes.
      claim_a =
        exec_dispatch(
          URI.to_string(board_a),
          "kanban.claim_node",
          %{id: node_a},
          pm_token,
          pm_uri_str
        )

      assert claim_a.exit_code == 0,
             "board-scoped cap MUST reach board_a's kanban.claim_node. out=#{inspect(claim_a.output)}"

      status_a =
        exec_dispatch(
          URI.to_string(board_a),
          "kanban.set_status",
          %{id: node_a, status: "doing"},
          pm_token,
          pm_uri_str
        )

      assert status_a.exit_code == 0,
             "pm set_status on its board. out=#{inspect(status_a.output)}"

      # board_a state really mutated (positive proof — NOT a no-op :ok).
      assert {:ok, %{tree: %{nodes: nodes_a}}} = Ezagent.Kind.get_slice(board_a, :kanban)
      assert nodes_a[node_a].owner == pm_uri_str
      assert nodes_a[node_a].status == :doing

      # (越权 — instance axis) the SAME cap+token on board_b is CapBAC-denied: pm's
      # kanban cap instance == board_a ≠ board_b, so the instance axis no longer
      # matches. This is exactly the guarantee an `instance: :any` cap would forfeit.
      claim_b =
        exec_dispatch(
          URI.to_string(board_b),
          "kanban.claim_node",
          %{id: node_b},
          pm_token,
          pm_uri_str
        )

      assert claim_b.exit_code != 0,
             "board-scoped cap MUST be denied on an UNRELATED board (越权 by instance). " <>
               "out=#{inspect(claim_b.output)}"

      # board_b is untouched (the denial happened at the cap chokepoint, not the handler).
      assert {:ok, %{tree: %{nodes: nodes_b}}} = Ezagent.Kind.get_slice(board_b, :kanban)
      assert nodes_b[node_b].owner in [nil, ""]

      # (越权 — action axis) an action pm was NOT granted (add_node) on its OWN board
      # is also denied: the board-scope override does not widen the action set.
      add_a =
        exec_dispatch(
          URI.to_string(board_a),
          "kanban.add_node",
          %{parent_id: node_a, title: "x"},
          pm_token,
          pm_uri_str
        )

      assert add_a.exit_code != 0,
             "an ungranted action (add_node) MUST stay denied even on the scoped board. " <>
               "out=#{inspect(add_a.output)}"
    end)
  end

  defp create_board(workspace_uri, admin_ctx, suffix) do
    name = "t7g-board-#{suffix}-#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
               admin_ctx
             )

    agent_uri
  end

  defp wait_ready(uri, attempts \\ 200)
  defp wait_ready(_uri, 0), do: flunk("entity never became ready")

  defp wait_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && wait_ready(uri, attempts - 1)
    end
  end

  defp exec_dispatch(target, action, args, token, entity_uri) do
    Exec.exec(
      ["dispatch", target, "--action", action, "--args", Jason.encode!(args)],
      token: token,
      entity_uri: entity_uri
    )
  end

  # Direct admin dispatch (fixture seeding only — NOT the CLI verb under test),
  # mirroring RoleNativeCreateTest.
  defp admin_dispatch(agent_uri, action, args, %{caller: caller, caps: caps}) do
    cmd =
      Ezagent.Cmd.new(
        Ezagent.URI.with_action(agent_uri, :kanban, action),
        action,
        args,
        %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
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
