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

  test "replays a termination that was persisted before dispatch" do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://system/agent/crash-window-#{suffix}")
    caller_uri = Ezagent.Entity.User.admin_uri()
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, Ezagent.URI.new!("workspace://system"))

    {:ok, obligation} =
      RetirementObligations.create_pending(%{
        agent_uri: URI.to_string(agent_uri),
        workspace_uri: "workspace://system",
        provenance_root_uri: URI.to_string(caller_uri),
        creation_attempt_id: "crash-window-#{suffix}",
        retirement_reason: "rollback",
        pending_steps: %{
          "sandbox_destroy" => %{
            "agent_uri" => URI.to_string(agent_uri),
            "caller_uri" => URI.to_string(caller_uri)
          }
        }
      })

    assert {:ok, :resolved} = RetirementSweeper.retry(obligation.id)
    assert RetirementObligations.get!(obligation.id).status == :resolved
    assert :gone = wait_until_gone(agent_uri)
  end

  test "an expired worker exception cannot overwrite a replacement claim" do
    suffix = System.unique_integer([:positive])
    agent_uri = "entity://team-alpha/agent/stale-worker-#{suffix}"

    {:ok, obligation} =
      RetirementObligations.create_pending(%{
        agent_uri: agent_uri,
        workspace_uri: "workspace://team-alpha",
        provenance_root_uri: "entity://team-alpha/user/owner-#{suffix}",
        creation_attempt_id: "attempt-#{suffix}",
        retirement_reason: "rollback",
        pending_steps: %{
          "sandbox_cleanup" => %{
            "config_dir_path" => "obligation:pending",
            "template_class" => inspect(__MODULE__.LeaseReplacingCleanup)
          }
        }
      })

    {:ok, obligation} =
      obligation
      |> Ezagent.Agent.RetirementObligation.transition_changeset(%{
        pending_steps: %{
          "sandbox_cleanup" => %{
            "config_dir_path" => "obligation:#{obligation.id}",
            "template_class" => inspect(__MODULE__.LeaseReplacingCleanup)
          }
        }
      })
      |> EzagentCore.Repo.update()

    assert {:error, {:rescue, %RuntimeError{message: "late cleanup failure"}}} =
             RetirementSweeper.retry(obligation.id)

    assert_receive {:replacement_claimed, replacement_token}

    current = RetirementObligations.get!(obligation.id)
    assert current.status == :running
    assert current.claim_token == replacement_token
    assert current.attempts == 2
  end

  defmodule CleanupRecorder do
    def destroy_config_dir(agent_uri, config_dir) do
      send(self(), {:cleanup_retried, agent_uri, config_dir})
      :ok
    end
  end

  defmodule LeaseReplacingCleanup do
    def destroy_config_dir(_agent_uri, "obligation:" <> obligation_id) do
      obligation_id = String.to_integer(obligation_id)
      running = RetirementObligations.get!(obligation_id)

      {:ok, _expired} =
        running
        |> Ezagent.Agent.RetirementObligation.transition_changeset(%{
          next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })
        |> EzagentCore.Repo.update()

      {:ok, replacement} = RetirementObligations.claim(obligation_id)
      send(self(), {:replacement_claimed, replacement.claim_token})
      raise RuntimeError, "late cleanup failure"
    end
  end

  defp wait_until_gone(uri, tries \\ 50)
  defp wait_until_gone(_uri, 0), do: :still_alive

  defp wait_until_gone(uri, tries) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        :gone

      {:ok, _pid} ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end
end
