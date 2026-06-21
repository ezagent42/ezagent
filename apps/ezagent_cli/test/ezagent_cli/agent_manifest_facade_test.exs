defmodule EzagentCli.AgentManifestFacadeTest do
  use ExUnit.Case, async: false

  alias EzagentCli.{AgentManifestFacade, TreeBuilder}

  setup do
    Process.put(
      :ezagent_cli_caller_override,
      {Ezagent.Entity.User.admin_uri(), MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    on_exit(fn -> Process.delete(:ezagent_cli_caller_override) end)
    :ok
  end

  test "agent subcommand exposes spawn_manifest facade" do
    Application.ensure_all_started(:ezagent_cli)

    spec = TreeBuilder.build()
    agent_sub = Enum.find(spec.subcommands, fn sub -> sub.name == "agent" end)
    assert agent_sub

    action_names = agent_sub.subcommands |> Enum.map(& &1.name) |> MapSet.new()
    assert MapSet.member?(action_names, "spawn_manifest")
  end

  test "spawn_manifest facade loads manifest and tries executor fallbacks" do
    manifest_path =
      tmp_manifest("""
      name: support
      soul: "You support {{brand_name}}."
      executor:
        flavor: [cc, curl]
        params:
          project_cwd: /tmp/project
        fallback:
          - flavor: curl
            params:
              provider: test-provider
              api_url: https://api.example.invalid/chat
              model: test-model
      """)

    agent_uri = Ezagent.URI.new!("entity://system/agent/support")

    spawn_fun = fn content, ^agent_uri, _spawned_by, _workspace, _opts ->
      case content.flavor do
        "cc" ->
          {:error, :cc_unavailable}

        "curl" ->
          assert content.agent_manifest_resolved.instructions == "You support CINNOX."
          assert content.agent_manifest_params["provider"] == "test-provider"

          {:ok,
           %{
             workers: [agent_uri],
             fresh?: true
           }}
      end
    end

    parsed = %{
      options: %{
        manifest: manifest_path,
        agent: agent_uri,
        slots: ~s({"brand_name":"CINNOX"})
      },
      flags: %{}
    }

    assert {:ok,
            %{
              agent_uri: "entity://system/agent/support",
              chosen_flavor: "curl",
              fresh?: true,
              workers: ["entity://system/agent/support"]
            }} =
             AgentManifestFacade.spawn_manifest_facade(parsed, spawn_fun: spawn_fun)
  end

  defp tmp_manifest(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-manifest-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, body)
    path
  end
end
