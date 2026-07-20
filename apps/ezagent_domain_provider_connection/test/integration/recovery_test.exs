defmodule Ezagent.ProviderConnection.RecoveryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{AuthorizationAttempt, Connection, Operation, Recovery}
  alias EzagentCore.Repo

  defmodule Recorder do
    @moduledoc false

    def recover(operation, _now, observer) do
      send(observer, {:recovered, operation.operation_class, operation.id})
      :ok
    end
  end

  defmodule RetryRecorder do
    @moduledoc false

    alias Ezagent.ProviderConnection.Operation
    alias EzagentCore.Repo

    def recover(operation, _now, observer) do
      attempts = Process.get({__MODULE__, operation.id}, 0)
      Process.put({__MODULE__, operation.id}, attempts + 1)
      send(observer, {:attempted, operation.id, attempts + 1})

      if operation.correlation_id == "retry-once" and attempts == 0 do
        {:error, :transient}
      else
        operation |> Ecto.Changeset.change(status: "finalized") |> Repo.update!()
        :ok
      end
    end
  end

  test "supervised recovery processes 50 rows per batch and yields after ten batches" do
    rows =
      for offset <- 0..500 do
        operation_row("revoke", offset)
      end

    {501, nil} = Repo.insert_all(Operation, rows)

    recovery = start_recovery!()
    :ok = Recovery.start_pass(recovery)

    recovered = collect_recovered(500, [])
    assert recovered == Enum.map(rows |> Enum.take(500), & &1.id)

    assert_receive {:recovery_pass_yielded, ^recovery, 500}
    assert_receive {:recovered, "revoke", last_id}
    assert last_id == List.last(rows).id
    assert_receive {:recovery_idle, ^recovery}
    refute_receive {:recovered, _, _}
  end

  test "recovery prioritizes callback completion then termination then expired refresh" do
    now = DateTime.utc_now()

    refresh =
      operation_row("refresh", 0,
        inserted_at: DateTime.add(now, -30, :second),
        lease_until: DateTime.add(now, -1, :second)
      )

    termination =
      operation_row("disconnect", 1, inserted_at: DateTime.add(now, -20, :second))

    callback =
      operation_row("store", 2,
        inserted_at: DateTime.add(now, -10, :second),
        status: "cleanup_pending",
        attempt_ref: Ecto.UUID.generate(),
        attempt_version: 1,
        attempt_claim_token: "claim-fence",
        handoff_ref: "handoff-ref",
        result_ref: "result-ref",
        result_credential_version: 2,
        prior_credential_ref: "prior-ref",
        prior_credential_version: 1,
        safe_error_code: "cleanup_pending"
      )

    {3, nil} = Repo.insert_all(Operation, [refresh, termination, callback])

    recovery = start_recovery!()
    :ok = Recovery.start_pass(recovery)

    assert_receive {:recovered, "store", callback_id}
    assert callback_id == callback.id
    assert_receive {:recovered, "disconnect", termination_id}
    assert termination_id == termination.id
    assert_receive {:recovered, "refresh", refresh_id}
    assert refresh_id == refresh.id
    assert_receive {:recovery_idle, ^recovery}
  end

  test "a partial tenth batch yields before recovery advances to the next phase" do
    termination_rows = for offset <- 0..450, do: operation_row("revoke", offset)

    refresh =
      operation_row("refresh", 1_000, lease_until: DateTime.add(DateTime.utc_now(), -1, :second))

    {452, nil} = Repo.insert_all(Operation, termination_rows ++ [refresh])

    recovery = start_recovery!()
    :ok = Recovery.start_pass(recovery)

    recovered = collect_recovered(451, [])
    assert recovered == Enum.map(termination_rows, & &1.id)
    assert_receive {:recovery_pass_yielded, ^recovery, 451}
    assert_receive {:recovered, "refresh", refresh_id}
    assert refresh_id == refresh.id
    assert_receive {:recovery_idle, ^recovery}
  end

  test "a failed obligation is retried instead of being skipped by the cursor" do
    failed = operation_row("revoke", 0, correlation_id: "retry-once")
    later = operation_row("revoke", 1, correlation_id: "later-success")
    {2, nil} = Repo.insert_all(Operation, [failed, later])

    recovery = start_recovery!(RetryRecorder)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, failed_id, 1}
    assert failed_id == failed.id
    assert_receive {:attempted, later_id, 1}
    assert later_id == later.id
    assert_receive {:attempted, failed_id, 2}
    assert failed_id == failed.id
    assert_receive {:recovery_idle, ^recovery}

    assert Repo.get!(Operation, failed.id).status == "finalized"
    assert Repo.get!(Operation, later.id).status == "finalized"
  end

  test "recovery resumes an expired prepared callback claim on an open connection" do
    now = DateTime.utc_now()
    owner = Ezagent.URI.user("acme", "recovery-owner")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()

    insert_connection!(connection_id, owner)
    insert_expired_attempt!(attempt_ref, connection_id, now)

    operation =
      operation_row("store", 0,
        connection_id: connection_id,
        attempt_ref: attempt_ref,
        attempt_version: 1,
        attempt_claim_token: "expired-claim",
        expected_connection_version: 0,
        expected_credential_version: 0,
        prior_credential_ref: "pending",
        prior_credential_version: 0
      )

    {1, nil} = Repo.insert_all(Operation, [operation])

    recovery = start_recovery!()
    :ok = Recovery.start_pass(recovery)

    assert_receive {:recovered, "store", operation_id}
    assert operation_id == operation.id
    assert_receive {:recovery_idle, ^recovery}
  end

  test "recovery exposes the fixed production bounds and application supervision" do
    assert Recovery.batch_size() == 50
    assert Recovery.max_batches_per_pass() == 10

    assert Enum.any?(
             Supervisor.which_children(EzagentDomainProviderConnection.Application),
             fn {id, pid, :worker, _modules} -> id == Recovery and is_pid(pid) end
           )
  end

  test "refresh and termination recovery re-enter owner-bound Store orchestration" do
    source =
      File.read!(Path.expand("../../lib/ezagent/provider_connection/recovery.ex", __DIR__))

    assert length(Regex.scan(~r/Store\.execute\(/, source)) == 3
    refute source =~ "Refresh.execute("
    refute source =~ "Termination.execute("
    assert source =~ "self_uri: Ezagent.URI.new!(connection.owner_uri)"
  end

  defp start_recovery!(recoverer \\ Recorder) do
    name = {:global, {__MODULE__, make_ref()}}

    pid =
      start_supervised!(
        {Recovery, name: name, recoverer: recoverer, observer: self(), autostart: false}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp collect_recovered(0, ids), do: Enum.reverse(ids)

  defp collect_recovered(count, ids) do
    assert_receive {:recovered, "revoke", id}, 5_000
    collect_recovered(count - 1, [id | ids])
  end

  defp operation_row(operation_class, offset, overrides \\ []) do
    inserted_at =
      Keyword.get(
        overrides,
        :inserted_at,
        DateTime.add(~U[2026-07-20 00:00:00.000000Z], offset)
      )

    %{
      id: Ecto.UUID.generate(),
      workspace_uri: "workspace://recovery-test",
      connection_id: Ecto.UUID.generate(),
      backend_pair_id: "pair-recovery-v1",
      operation_class: operation_class,
      correlation_id: "recovery-#{operation_class}-#{offset}",
      bound_input_digest: "digest-#{offset}",
      expected_connection_version: 1,
      expected_credential_version: 1,
      status: "prepared",
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
    |> Map.merge(Map.new(overrides))
  end

  defp insert_connection!(connection_id, owner) do
    %{
      connection_id: connection_id,
      workspace_uri: URI.to_string(Ezagent.Capability.workspace_of(owner)),
      owner_uri: URI.to_string(owner),
      provider_id: "recovery-provider",
      governed_host: "example.test",
      external_account_id: "pending:#{connection_id}",
      execution_identity: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: "pending",
      credential_backend_ref: "pending",
      status: "pending_authorization"
    }
    |> Connection.create_changeset()
    |> Repo.insert!()
  end

  defp insert_expired_attempt!(attempt_ref, connection_id, now) do
    %{
      attempt_ref: attempt_ref,
      workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
      backend_pair_id: "pair-recovery-v1",
      authorization_ref: "authorization-#{attempt_ref}",
      connection_id: connection_id,
      connection_version: 0,
      bound_subject_digest: "subject-digest",
      state_digest: "state-#{attempt_ref}",
      correlation_id: "callback-#{attempt_ref}",
      status: "consuming",
      expires_at: DateTime.add(now, 60, :second)
    }
    |> AuthorizationAttempt.create_changeset()
    |> Ecto.Changeset.change(
      attempt_version: 1,
      claim_token: "expired-claim",
      claim_until: DateTime.add(now, -1, :second)
    )
    |> Repo.insert!()
  end
end
