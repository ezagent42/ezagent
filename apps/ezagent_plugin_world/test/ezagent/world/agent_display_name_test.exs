defmodule Ezagent.World.AgentDisplayNameTest do
  # `mix test --no-start` avoids the unrelated World application boot failure;
  # start the Agent domain before DataCase checks out its repository connection.
  {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_agent)

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn
  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias Ezagent.World.IdentityData

  defmodule ProfileDisplayNameTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.world_profile_display_name"

    @impl true
    def config_dir_namespace, do: "cc"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
      config_dir = Map.fetch!(data, "allocated_config_dir")

      respawn_template_data =
        data
        |> Map.put("agent_config_dir", config_dir)
        |> Map.put("flavor", "world-profile-display-name")

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: agent_uri,
             config_dir_path: config_dir,
             template_class: __MODULE__,
             respawn_template_data: respawn_template_data
           }) do
        {:ok, _pid} ->
          :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)

          {:ok, [agent_uri],
           %{
             fresh?: true,
             config_dir_path: config_dir,
             respawn_template_data: respawn_template_data
           }}

        {:error, {:already_started, _pid}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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
        template_class: ProfileDisplayNameTemplate
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
  end
end
