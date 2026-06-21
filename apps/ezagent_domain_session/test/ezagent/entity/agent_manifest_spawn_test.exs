defmodule Ezagent.Entity.AgentManifestSpawnTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentManifest
  alias Ezagent.Entity.Agent

  test "spawn_from_manifest tries executor flavors in order and treats adoption as success" do
    assert {:ok, manifest} =
             AgentManifest.load(%{
               name: "support",
               soul: "Help {{brand}}.",
               skills: [],
               caps: [],
               executor: %{
                 flavor: ["cc", "codex", "curl"],
                 params: %{
                   "project_cwd" => "/tmp/project",
                   "model" => "gpt-5"
                 }
               }
             })

    agent_uri = Ezagent.URI.agent("team-alpha", "support")
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    test_pid = self()

    spawn_fun = fn content, ^agent_uri, ^owner_uri, ^workspace_uri, _opts ->
      send(test_pid, {:attempt, content.flavor, content.agent_manifest_resolved.instructions})

      case content.flavor do
        "cc" -> {:error, :cc_unavailable}
        "codex" -> {:ok, %{workers: [agent_uri], fresh?: false}}
        other -> {:error, {:unexpected_attempt, other}}
      end
    end

    assert {:ok, %{workers: [^agent_uri], fresh?: false, chosen_flavor: "codex"}} =
             Agent.spawn_from_manifest(
               manifest,
               %{"brand" => "CINNOX"},
               agent_uri,
               owner_uri,
               workspace_uri,
               spawn_fun: spawn_fun
             )

    assert_received {:attempt, "cc", "Help CINNOX."}
    assert_received {:attempt, "codex", "Help CINNOX."}
    refute_received {:attempt, "curl", _}
  end
end
