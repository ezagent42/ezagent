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

    assert {:ok, running} = RetirementObligations.mark_running(pending.id)
    assert running.status == :running
    assert running.attempts == 1

    assert {:ok, retryable} = RetirementObligations.record_failure(pending.id, :eacces)
    assert retryable.status == :pending
    assert retryable.last_error == ":eacces"

    assert {:ok, resolved} = RetirementObligations.resolve(pending.id)
    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at
  end
end
