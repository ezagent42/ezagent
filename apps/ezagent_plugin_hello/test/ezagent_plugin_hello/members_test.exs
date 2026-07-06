defmodule EzagentPluginHello.MembersTest do
  @moduledoc """
  `Members.role_uri/2` resolves a hello session's team member by its `role_name`
  facet — the routing-stable handle now that the team is materialized by the
  framework `Definition.roles` path with PLANNED (UUID) member URIs (Task 4).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Agent.RecipeRegistry
  alias EzagentPluginHello.{App, Members}
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    # The team materialization resolves each role's recipe through the
    # RecipeRegistry (role-as-data). Boot seeds them, but that write is outside
    # this DataCase sandbox (and the ETS cache can be flushed) — reseed here.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(HelloApp.roles(), fn recipe ->
      {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    ws = "hello-members-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws, %{})

    %{ws: ws}
  end

  test "role_uri resolves a joined member by role_name", %{ws: ws} do
    {:ok, session_uri, orch_uri} = App.ensure_app(ws, "members-demo", defer_orchestrator: false)

    assert {:ok, ^orch_uri} = Members.role_uri(session_uri, "orchestrator")
    assert {:ok, %URI{}} = Members.role_uri(session_uri, "builder")
    assert {:ok, %URI{}} = Members.role_uri(session_uri, "concierge")
    assert :error = Members.role_uri(session_uri, "nope")
  end
end
