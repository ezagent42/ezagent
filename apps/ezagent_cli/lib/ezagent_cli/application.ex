defmodule EzagentCli.Application do
  @moduledoc """
  EzagentCli Application — owns the `EzagentCli.FacadeRegistry` ETS table.

  No other children; the CLI itself is a one-shot mix task that builds
  its tree on each invocation.
  """

  use Application

  @impl true
  def start(_type, _args) do
    EzagentCli.FacadeRegistry.init_table()
    register_core_facade_ops()
    Supervisor.start_link([], strategy: :one_for_one, name: EzagentCli.Supervisor)
  end

  # CLI facade ops for operations that aren't Behavior actions.
  # Currently:
  # - workspace create — spawns a Workspace Kind (no instance exists
  #   yet to invoke an action on)
  defp register_core_facade_ops do
    EzagentCli.FacadeRegistry.register(:workspace, :create, &workspace_create_facade/1, %{
      args: [name: :string],
      opts: [members: {:list, :uri}],
      about: "Create a new Workspace (persists + spawns the Kind)"
    })

    EzagentCli.FacadeRegistry.register(
      :agent,
      :spawn_manifest,
      &EzagentCli.AgentManifestFacade.spawn_manifest_facade/1,
      %{
        opts: [
          manifest: :string,
          agent: :uri,
          slots: :string
        ],
        about: "Spawn an Agent from an AgentManifest YAML file"
      }
    )

    EzagentCli.SessionConfigFacade.register_all()

    :ok
  end

  defp workspace_create_facade(parsed) do
    name = parsed.args[:name]
    members = parsed.options[:members] || []

    case Ezagent.Workspace.create(name, %{members: members}) do
      {:ok, _pid} ->
        {:ok,
         %{
           name: name,
           uri: name |> Ezagent.URI.workspace() |> URI.to_string(),
           members: length(members)
         }}

      err ->
        err
    end
  end
end
