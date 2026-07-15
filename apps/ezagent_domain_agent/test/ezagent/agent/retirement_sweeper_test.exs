defmodule Ezagent.Agent.RetirementSweeperTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.{RetirementObligations, RetirementSweeper}

  test "retries persisted sandbox cleanup and resolves the obligation" do
    suffix = System.unique_integer([:positive])
    agent_uri = "entity://team-alpha/agent/retry-#{suffix}"
    config_dir = "/tmp/retirement-retry-#{suffix}"

    {:ok, obligation} =
      RetirementObligations.create_pending(%{
        agent_uri: agent_uri,
        workspace_uri: "workspace://team-alpha",
        provenance_root_uri: "entity://team-alpha/user/owner-#{suffix}",
        creation_attempt_id: "attempt-#{suffix}",
        retirement_reason: "rollback",
        pending_steps: %{
          "sandbox_cleanup" => %{
            "config_dir_path" => config_dir,
            "template_class" => inspect(__MODULE__.CleanupRecorder)
          }
        }
      })

    assert {:ok, :resolved} = RetirementSweeper.retry(obligation.id)
    assert_receive {:cleanup_retried, %URI{} = retried_uri, ^config_dir}
    assert URI.to_string(retried_uri) == agent_uri

    resolved = RetirementObligations.get!(obligation.id)
    assert resolved.status == :resolved
    assert resolved.attempts == 1
  end

  defmodule CleanupRecorder do
    def destroy_config_dir(agent_uri, config_dir) do
      send(self(), {:cleanup_retried, agent_uri, config_dir})
      :ok
    end
  end
end
