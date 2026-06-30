defmodule Ezagent.Entity.AgentTemplateSpawnSandboxMaterializationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn

  defmodule PreinitializedSandboxTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.preinitialized_sandbox_agent"

    @impl true
    def config_dir_namespace, do: "cc"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
      config_dir = Map.fetch!(data, "allocated_config_dir")

      respawn_data =
        data
        |> Map.put("agent_config_dir", config_dir)
        |> Map.put("flavor", "preinit-sandbox")

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: agent_uri,
             config_dir_path: config_dir,
             template_class: __MODULE__,
             respawn_template_data: respawn_data
           }) do
        {:ok, _pid} ->
          :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)

          {:ok, [agent_uri],
           %{fresh?: true, config_dir_path: config_dir, respawn_template_data: respawn_data}}

        {:error, {:already_started, _pid}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  test "spawn skips sandbox.update_config dispatch when sandbox was initialized by Kind spawn args" do
    unique = System.unique_integer([:positive])
    flavor = "preinit-sandbox"
    agent_uri = Ezagent.URI.new!("entity://preinit-sandbox-#{unique}/agent/preinit_sandbox")
    owner_uri = Ezagent.URI.new!("entity://preinit-sandbox-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://preinit-sandbox-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: PreinitializedSandboxTemplate
      })

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "preinit-sandbox-source-#{unique}")
    }

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               owner_uri,
               workspace_uri
             )

    assert Ezagent.ReadyGate.status(agent_uri) == :not_ready
    assert {:ok, sandbox_slice} = Ezagent.Kind.get_slice(agent_uri, :sandbox)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)

    assert sandbox.config_dir_path =~ "preinit-sandbox-#{unique}/preinit_sandbox"
    assert sandbox.template_class == PreinitializedSandboxTemplate
    assert sandbox.respawn_template_data["agent_config_dir"] == sandbox.config_dir_path
  end
end
