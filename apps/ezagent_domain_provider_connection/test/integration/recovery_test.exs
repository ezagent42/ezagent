Code.require_file(Path.expand("../support/recovery_recorder.ex", __DIR__))
Code.require_file(Path.expand("../support/recovery_retry_recorder.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RecoveryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{AuthorizationAttempt, Connection, Operation, Recovery}
  alias Ezagent.ProviderConnection.{RecoveryRecorder, RecoveryRetryRecorder}
  alias EzagentCore.Repo

  @recovery_connection_id "10000000-0000-4000-8000-000000000001"

  setup do
    %{
      connection_id: @recovery_connection_id,
      workspace_uri: "workspace://recovery-test",
      owner_uri: "entity://recovery-test/user/recovery-owner",
      provider_id: "recovery-provider",
      governed_host: "example.test",
      external_account_id: "recovery-account",
      display_login: "recovery-owner",
      execution_identity: "connected_user",
      requested_execution_identity_class: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: "authorization-recovery",
      credential_backend_ref: "credential-recovery",
      backend_pair_id: "pair-recovery-v1",
      authorization_backend_id: "authorization-recovery-v1",
      credential_backend_id: "credential-recovery-v1",
      status: "active"
    }
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(connection_version: 1, credential_version: 1)
    |> Repo.insert!()

    :ok
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
    attempt_ref = Ecto.UUID.generate()

    insert_consumed_reauthorization_attempt!(attempt_ref, @recovery_connection_id, now)

    refresh =
      operation_row("refresh", 0,
        inserted_at: DateTime.add(now, -30, :second),
        lease_until: DateTime.add(now, -1, :second),
        status: "backend_committed",
        provider_result_ref: "provider-result-refresh",
        handoff_ref: "handoff-refresh",
        result_permission_digest: "permission-refresh",
        result_ref: "credential-result-refresh",
        result_credential_version: 2
      )

    termination =
      operation_row("disconnect", 1, inserted_at: DateTime.add(now, -20, :second))

    callback =
      operation_row("replace", 2,
        inserted_at: DateTime.add(now, -10, :second),
        status: "cleanup_pending",
        attempt_ref: attempt_ref,
        attempt_version: 1,
        attempt_claim_token: "claim-fence",
        handoff_ref: "handoff-ref",
        result_ref: "result-ref",
        result_credential_version: 2,
        result_external_account_id: "recovery-account",
        result_display_login: "recovery-owner",
        result_execution_identity: "connected_user",
        expected_authorization_ref: "authorization-#{attempt_ref}",
        expected_authorization_version: 0,
        result_authorization_ref: "authorization-#{attempt_ref}",
        result_authorization_version: 1,
        provider_result_ref: "provider-result-recovery",
        result_permission_digest: "permission-recovery",
        prior_credential_ref: "credential-recovery",
        prior_credential_version: 1,
        provider_cleanup_status: "pending",
        credential_cleanup_status: "pending",
        safe_error_code: "cleanup_pending"
      )

    {3, nil} = Repo.insert_all(Operation, [refresh, termination, callback])

    recovery = start_recovery!()
    :ok = Recovery.start_pass(recovery)

    assert_receive {:recovered, "replace", callback_id}
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
      operation_row("refresh", 1_000,
        lease_until: DateTime.add(DateTime.utc_now(), -1, :second),
        status: "backend_committed",
        provider_result_ref: "provider-result-partial-batch",
        handoff_ref: "handoff-partial-batch",
        result_permission_digest: "permission-partial-batch",
        result_ref: "credential-result-partial-batch",
        result_credential_version: 2
      )

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
    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end})
    failed = operation_row("revoke", 0, correlation_id: "retry-once")
    later = operation_row("revoke", 1, correlation_id: "later-success")
    {2, nil} = Repo.insert_all(Operation, [failed, later])

    recovery =
      start_recovery!(RecoveryRetryRecorder,
        now: fn -> Agent.get(clock, & &1) end,
        timer: fn _destination, _message, _delay -> make_ref() end
      )

    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, failed_id, 1}
    assert failed_id == failed.id
    assert_receive {:attempted, later_id, 1}
    assert later_id == later.id
    assert_receive {:recovery_idle, ^recovery}

    next_recovery_at = Repo.get!(Operation, failed.id).next_recovery_at
    Agent.update(clock, fn _now -> next_recovery_at end)
    :ok = Recovery.start_pass(recovery)

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
        workspace_uri: "workspace://acme",
        attempt_ref: attempt_ref,
        attempt_version: 1,
        attempt_claim_token: "expired-claim",
        expected_connection_version: 0,
        expected_authorization_ref: "authorization-#{attempt_ref}",
        expected_authorization_version: 0,
        expected_credential_version: 0,
        prior_credential_ref: nil,
        prior_credential_version: nil
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

  defp start_recovery!(recoverer \\ RecoveryRecorder, options \\ []) do
    name = {:global, {__MODULE__, make_ref()}}

    pid =
      start_supervised!(
        {Recovery,
         [name: name, recoverer: recoverer, observer: self(), autostart: false] ++ options}
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
      connection_id: @recovery_connection_id,
      backend_pair_id: "pair-recovery-v1",
      operation_class: operation_class,
      correlation_id: "recovery-#{operation_class}-#{offset}",
      bound_input_digest: "digest-#{offset}",
      expected_connection_version: 1,
      expected_authorization_ref: "authorization-recovery",
      expected_authorization_version: 0,
      expected_credential_version: 1,
      status: "prepared",
      recovery_attempts: 0,
      next_recovery_at: inserted_at,
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
      requested_execution_identity_class: "connected_user",
      acquisition_method: "oauth_user",
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
      purpose: "initial_bind",
      reservation_digest: digest({:initial_bind, connection_id, attempt_ref}),
      requested_permission_digest: "permissions-v1",
      requested_execution_identity_class: "connected_user",
      redirect_uri_id: "recovery-callback",
      callback_artifact_digest: digest({:callback_artifact, attempt_ref}),
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

  defp insert_consumed_reauthorization_attempt!(attempt_ref, connection_id, now) do
    %{
      attempt_ref: attempt_ref,
      workspace_uri: "workspace://recovery-test",
      backend_pair_id: "pair-recovery-v1",
      authorization_ref: "authorization-#{attempt_ref}",
      connection_id: connection_id,
      connection_version: 1,
      purpose: "reauthorize",
      reservation_digest: digest({:reauthorize, connection_id, attempt_ref}),
      requested_permission_digest: "permissions-v1",
      requested_execution_identity_class: "connected_user",
      redirect_uri_id: "recovery-callback",
      callback_artifact_digest: digest({:callback_artifact, attempt_ref}),
      correlation_id: "callback-#{attempt_ref}",
      status: "consumed",
      expires_at: DateTime.add(now, 60, :second)
    }
    |> AuthorizationAttempt.create_changeset()
    |> Repo.insert!()
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
