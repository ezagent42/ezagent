defmodule Ezagent.Session.SocialwareInstallObligationsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Session.{
    SocialwareInstallObligation,
    SocialwareInstallObligations
  }

  test "ensure_pending is idempotent and claim transitions are fenced" do
    suffix = System.unique_integer([:positive])
    session_uri = Ezagent.URI.new!("session://team-alpha/hello/durable-#{suffix}")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    actor_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")

    assert {:ok, pending} =
             SocialwareInstallObligations.ensure_pending(
               session_uri,
               workspace_uri,
               actor_uri
             )

    assert pending.status == :pending
    assert pending.attempts == 0

    assert {:ok, duplicate} =
             SocialwareInstallObligations.ensure_pending(
               session_uri,
               workspace_uri,
               actor_uri
             )

    assert duplicate.id == pending.id

    assert {:ok, running} =
             SocialwareInstallObligations.claim(pending.id, lease_seconds: 60)

    assert running.status == :running
    assert running.attempts == 1
    assert is_binary(running.claim_token)

    assert {:error, :already_claimed} = SocialwareInstallObligations.claim(pending.id)

    assert {:error, :stale_claim} =
             SocialwareInstallObligations.resolve(pending.id, Ecto.UUID.generate())

    assert {:ok, resolved} =
             SocialwareInstallObligations.resolve(pending.id, running.claim_token)

    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at

    assert {:ok, duplicate_after_resolution} =
             SocialwareInstallObligations.ensure_pending(
               session_uri,
               workspace_uri,
               actor_uri
             )

    assert duplicate_after_resolution.id == pending.id
    assert duplicate_after_resolution.status == :resolved
    assert duplicate_after_resolution.attempts == 1
  end

  test "a pending obligation cannot be reclaimed before its backoff expires" do
    suffix = System.unique_integer([:positive])

    {:ok, pending} =
      SocialwareInstallObligations.ensure_pending(
        Ezagent.URI.new!("session://team-alpha/hello/backoff-#{suffix}"),
        Ezagent.URI.new!("workspace://team-alpha"),
        nil
      )

    assert {:ok, running} = SocialwareInstallObligations.claim(pending.id)

    assert {:ok, retryable} =
             SocialwareInstallObligations.record_failure(
               pending.id,
               :database_busy,
               running.claim_token
             )

    assert retryable.status == :pending
    assert DateTime.compare(retryable.next_attempt_at, DateTime.utc_now()) == :gt
    assert {:error, :not_due} = SocialwareInstallObligations.claim(pending.id)

    {:ok, _due} =
      retryable
      |> SocialwareInstallObligation.transition_changeset(%{
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> EzagentCore.Repo.update()

    assert {:ok, reclaimed} = SocialwareInstallObligations.claim(pending.id)
    assert reclaimed.attempts == 2
  end

  test "an expired running lease is due and can be reclaimed" do
    suffix = System.unique_integer([:positive])
    session_uri = Ezagent.URI.new!("session://team-alpha/hello/reclaim-#{suffix}")

    {:ok, pending} =
      SocialwareInstallObligations.ensure_pending(
        session_uri,
        Ezagent.URI.new!("workspace://team-alpha"),
        nil
      )

    assert {:ok, claimed} =
             SocialwareInstallObligations.claim(pending.id, lease_seconds: 60)

    {:ok, _expired} =
      claimed
      |> SocialwareInstallObligation.transition_changeset(%{
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> EzagentCore.Repo.update()

    assert Enum.any?(SocialwareInstallObligations.list_due(10), &(&1.id == pending.id))

    assert {:ok, reclaimed} = SocialwareInstallObligations.claim(pending.id)
    assert reclaimed.attempts == 2
    assert reclaimed.claim_token != claimed.claim_token

    assert {:error, :stale_claim} =
             SocialwareInstallObligations.record_failure(
               pending.id,
               :late_failure,
               claimed.claim_token
             )
  end
end
