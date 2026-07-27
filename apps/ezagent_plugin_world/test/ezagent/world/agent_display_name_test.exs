defmodule Ezagent.World.AgentDisplayNameTest do
  # `mix test --no-start` avoids the unrelated World application boot failure;
  # start the Agent domain before DataCase checks out its repository connection.
  {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_agent)

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn
  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias Ezagent.World.AgentDisplayNameTemplate
  alias Ezagent.World.IdentityData

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes()

    unique = System.unique_integer([:positive])
    workspace_name = "world-agent-display-name-#{unique}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    agent_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
    flavor = "world-agent-display-name-#{unique}"

    {:ok, _workspace_pid} = Workspace.create(workspace_name, %{})

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: AgentDisplayNameTemplate
      })

    case Ezagent.Resource.FsResolver.register_type("cc-agents", %{
           backend_component: "cc-agents",
           authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
         }) do
      :ok ->
        on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type("cc-agents") end)

      {:error, {:already_registered, "cc-agents"}} ->
        :ok
    end

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    {:ok,
     agent_uri: agent_uri,
     workspace_uri: workspace_uri,
     admin_ctx: admin_ctx,
     content: %{
       name: "dispatcher",
       flavor: flavor,
       project_cwd: System.tmp_dir!(),
       config_dir: Path.join(System.tmp_dir!(), "world-agent-display-name-#{unique}")
     }}
  end

  test "a UUID Agent keeps its URI name while listing its profile display name", %{
    agent_uri: agent_uri,
    workspace_uri: workspace_uri,
    admin_ctx: admin_ctx,
    content: content
  } do
    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               admin_ctx.caller,
               workspace_uri
             )

    agent_uri_string = URI.to_string(agent_uri)

    row =
      IdentityData.list_entities(admin_ctx.caller, workspace_uri, "agents")
      |> Enum.find(&(&1["uri"] == agent_uri_string))

    assert row["name"] == Ezagent.URI.name!(agent_uri)
    assert row["display_name"] == "dispatcher"
    refute row["display_name"] == row["name"]

    assert {:ok, sandbox_slice} = Ezagent.Kind.read(agent_uri, :sandbox, spawn: :never)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)
    assert sandbox.respawn_template_data["flavor"] == content.flavor
  end
end
