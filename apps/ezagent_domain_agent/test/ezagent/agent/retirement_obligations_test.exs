defmodule Ezagent.Agent.RetirementObligationsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RetirementObligations

  test "persists idempotent obligations and transitions retry state" do
    suffix = System.unique_integer([:positive])

    attrs = %{
      agent_uri: "entity://team-alpha/agent/retirement-#{suffix}",
      workspace_uri: "workspace://team-alpha",
      provenance_root_uri: "entity://team-alpha/user/owner-#{suffix}",
      creation_attempt_id: "attempt-#{suffix}",
      retirement_reason: "rollback",
      pending_steps: %{"config_dir_gc" => %{"path" => "/tmp/agent-#{suffix}"}}
    }

    assert {:ok, pending} = RetirementObligations.create_pending(attrs)
    assert pending.status == :pending
    assert pending.attempts == 0

    assert {:ok, duplicate} = RetirementObligations.create_pending(attrs)
    assert duplicate.id == pending.id

    assert {:ok, running} = RetirementObligations.claim(pending.id)
    assert running.status == :running
    assert running.attempts == 1

    assert {:ok, retryable} =
             RetirementObligations.record_failure(pending.id, :eacces, running.claim_token)

    assert retryable.status == :pending
    assert retryable.last_error == ":eacces"

    assert {:ok, resolved} = RetirementObligations.resolve(pending.id)
    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at

    assert {:ok, :already_resolved} = RetirementObligations.claim(resolved.id)
    assert RetirementObligations.get!(resolved.id).status == :resolved
  end

  test "claim is exclusive and an expired running lease is recoverable" do
    suffix = System.unique_integer([:positive])

    {:ok, pending} =
      RetirementObligations.create_pending(%{
        agent_uri: "entity://team-alpha/agent/claim-#{suffix}",
        workspace_uri: "workspace://team-alpha",
        provenance_root_uri: "entity://team-alpha/user/owner-#{suffix}",
        creation_attempt_id: "claim-attempt-#{suffix}",
        retirement_reason: "rollback",
        pending_steps: %{"sandbox_destroy" => %{}}
      })

    assert {:ok, claimed} = RetirementObligations.claim(pending.id, lease_seconds: 60)
    assert claimed.status == :running
    assert claimed.attempts == 1
    assert {:error, :already_claimed} = RetirementObligations.claim(pending.id)

    {:ok, _expired} =
      claimed
      |> Ezagent.Agent.RetirementObligation.transition_changeset(%{
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> EzagentCore.Repo.update()

    assert {:ok, reclaimed} = RetirementObligations.claim(pending.id)
    assert reclaimed.attempts == 2
    assert reclaimed.claim_token != claimed.claim_token
    assert {:error, :stale_claim} = RetirementObligations.resolve(pending.id, claimed.claim_token)

    assert {:error, :stale_claim} =
             RetirementObligations.record_failure(pending.id, :late_failure, claimed.claim_token)

    assert RetirementObligations.get!(pending.id).claim_token == reclaimed.claim_token
    assert {:ok, resolved} = RetirementObligations.resolve(pending.id, reclaimed.claim_token)
    assert resolved.status == :resolved
  end

  test "exhausted automatic retries require an explicit operator claim" do
    previous = Application.get_env(:ezagent_domain_agent, :retirement_max_attempts)
    Application.put_env(:ezagent_domain_agent, :retirement_max_attempts, 1)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ezagent_domain_agent, :retirement_max_attempts),
        else: Application.put_env(:ezagent_domain_agent, :retirement_max_attempts, previous)
    end)

    suffix = System.unique_integer([:positive])

    {:ok, pending} =
      RetirementObligations.create_pending(%{
        agent_uri: "entity://team-alpha/agent/exhausted-#{suffix}",
        workspace_uri: "workspace://team-alpha",
        provenance_root_uri: "entity://team-alpha/user/owner-#{suffix}",
        creation_attempt_id: "exhausted-attempt-#{suffix}",
        retirement_reason: "rollback",
        pending_steps: %{"sandbox_destroy" => %{}}
      })

    assert {:ok, running} = RetirementObligations.claim(pending.id)

    assert {:ok, failed} =
             RetirementObligations.record_failure(running.id, :eacces, running.claim_token)

    assert failed.status == :failed
    assert {:error, :failed} = RetirementObligations.claim(failed.id)
    assert {:ok, reopened} = RetirementObligations.claim(failed.id, allow_failed: true)
    assert reopened.status == :running
  end
end
