defmodule EzagentPluginHello.KanbanDelegationTest do
  use EzagentCore.DataCase, async: false

  alias EzagentPluginHello.KanbanDelegation

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)
    recipe = EzagentPluginKanban.Application.kanban_manager_recipe()
    {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)

    workspace_name = "hello-kanban-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})

    session = Ezagent.URI.session(workspace_name, :hello, "delegation")
    admin = Ezagent.Entity.User.admin_uri()

    %{
      workspace_name: workspace_name,
      workspace: Ezagent.Capability.workspace_of(session),
      session: session,
      admin: admin
    }
  end

  test "creates one canonical board, root task, and hello source artifact", ctx do
    assert {:ok, result} = KanbanDelegation.delegate(ctx.session, "Ship the homepage", ctx.admin)

    assert %URI{} = result.kanban_uri
    assert result.node_id == "n1"
    assert result.title == "Ship the homepage"
    assert result.status == :unassigned
    assert result.path =~ "/plugins/kanban/"

    assert {:ok, %{tree: tree}} = dispatch(result.kanban_uri, :get_tree, %{}, ctx.admin)
    node = tree.nodes[result.node_id]

    assert node.title == "Ship the homepage"
    assert [artifact] = node.artifacts
    assert artifact.kind == "hello_source"
    assert artifact.ref == URI.to_string(ctx.session)
    assert artifact.url == "/hello/delegation"

    assert %{
             "session_uri" => session_uri,
             "instruction" => "Ship the homepage",
             "page_summary" => "Hello page"
           } = Jason.decode!(artifact.content)

    assert session_uri == URI.to_string(ctx.session)
  end

  test "reuses the only workspace kanban-manager", ctx do
    assert {:ok, first} = KanbanDelegation.delegate(ctx.session, "Task A", ctx.admin)
    assert {:ok, second} = KanbanDelegation.delegate(ctx.session, "Task B", ctx.admin)

    assert first.kanban_uri == second.kanban_uri
    kanban_uri = first.kanban_uri

    assert [^kanban_uri] =
             Ezagent.Agent.RecipeResolver.list_by_recipe("kanban-manager", ctx.workspace)
  end

  test "an unauthorized caller creates neither board nor node", ctx do
    outsider = Ezagent.URI.user(ctx.workspace_name, "outsider")

    assert {:error, _reason} = KanbanDelegation.delegate(ctx.session, "Denied", outsider)
    assert [] == Ezagent.Agent.RecipeResolver.list_by_recipe("kanban-manager", ctx.workspace)
  end

  test "fails loudly when multiple boards exist without the canonical default", ctx do
    caller_ctx = %{
      caller: ctx.admin,
      caps: MapSet.new(Ezagent.Identity.read_entity_caps(ctx.admin))
    }

    for name <- ["product-a", "product-b"] do
      assert {:ok, _} =
               Ezagent.Workspace.create_agent(
                 ctx.workspace,
                 %{
                   flavor: "native",
                   name: name,
                   role: "kanban-manager",
                   cwd: "",
                   with_pty: false
                 },
                 caller_ctx
               )
    end

    assert {:error, :ambiguous_default_kanban} =
             KanbanDelegation.delegate(ctx.session, "Do not guess", ctx.admin)
  end

  defp dispatch(board_uri, action, args, caller) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(board_uri, :kanban, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps: MapSet.new(Ezagent.Identity.read_entity_caps(caller)),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
