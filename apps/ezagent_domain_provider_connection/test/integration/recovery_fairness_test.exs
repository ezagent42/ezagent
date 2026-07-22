Code.require_file(Path.expand("../support/recovery_fairness_recoverer.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RecoveryFairnessTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{Connection, Operation, Recovery}
  alias Ezagent.ProviderConnection.RecoveryFairnessRecoverer
  alias EzagentCore.Repo

  @now ~U[2026-07-20 12:00:00.000000Z]

  setup do
    connection_id = Ecto.UUID.generate()

    %{
      connection_id: connection_id,
      workspace_uri: "workspace://recovery-fairness",
      owner_uri: "entity://recovery-fairness/user/owner",
      provider_id: "recovery-provider",
      governed_host: "example.test",
      external_account_id: "recovery-account",
      display_login: "owner",
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

    clock = start_supervised!({Agent, fn -> @now end})

    %{clock: clock, connection_id: connection_id}
  end

  test "a permanent oldest failure does not block its phase or later phases", context do
    poison = operation_row(context.connection_id, "revoke", "poison", 0)
    later = operation_row(context.connection_id, "disconnect", "later-success", 1)

    refresh =
      operation_row(context.connection_id, "refresh", "later-phase-success", 2,
        status: "backend_committed",
        handoff_ref: "handoff-later-phase",
        provider_result_ref: "provider-result-later-phase",
        result_permission_digest: "permissions-later-phase",
        result_ref: "credential-result-later-phase",
        result_credential_version: 2
      )

    {3, nil} = Repo.insert_all(Operation, [poison, later, refresh])

    recovery = start_recovery!(context.clock, retry_base_ms: 1_000, retry_cap_ms: 8_000)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, "poison"}
    assert_receive {:attempted, "later-success"}
    assert_receive {:attempted, "later-phase-success"}
    assert_receive {:recovery_idle, ^recovery}

    assert %{status: "prepared", recovery_attempts: 1} = Repo.get!(Operation, poison.id)
    assert Repo.get!(Operation, later.id).status == "finalized"
    assert Repo.get!(Operation, refresh.id).status == "finalized"
  end

  test "durable retry uses exact bounded exponential backoff and remains due forever", context do
    poison = operation_row(context.connection_id, "revoke", "poison", 0)
    {1, nil} = Repo.insert_all(Operation, [poison])

    recovery =
      start_recovery!(context.clock,
        retry_base_ms: 1_000,
        retry_cap_ms: 4_000,
        idle_min_ms: 10,
        idle_max_ms: 10_000
      )

    assert_retry(recovery, poison.id, context.clock, @now, 1, 1_000)

    Agent.update(context.clock, fn _now -> DateTime.add(@now, 999, :millisecond) end)
    :ok = Recovery.start_pass(recovery)
    refute_receive {:attempted, "poison"}
    assert_receive {:recovery_idle, ^recovery}

    assert_retry(recovery, poison.id, context.clock, DateTime.add(@now, 1, :second), 2, 2_000)
    assert_retry(recovery, poison.id, context.clock, DateTime.add(@now, 3, :second), 3, 4_000)
    assert_retry(recovery, poison.id, context.clock, DateTime.add(@now, 7, :second), 4, 4_000)

    assert %{status: "prepared", recovery_attempts: 4} = Repo.get!(Operation, poison.id)
  end

  test "failure accounting and the next timer use a fresh clock after provider I/O", context do
    delayed_failure = operation_row(context.connection_id, "revoke", "clock-advance-failure", 0)
    {1, nil} = Repo.insert_all(Operation, [delayed_failure])

    recovery =
      start_recovery!(context.clock,
        retry_base_ms: 1_000,
        retry_cap_ms: 8_000,
        idle_min_ms: 100,
        idle_max_ms: 60_000
      )

    :ok = Recovery.start_pass(recovery)

    assert_receive {:advance_clock, recoverer, "clock-advance-failure"}
    completed_at = DateTime.add(@now, 30, :second)
    Agent.update(context.clock, fn _now -> completed_at end)
    send(recoverer, {:clock_advanced, "clock-advance-failure"})

    assert_receive {:recovery_idle, ^recovery}

    persisted = Repo.get!(Operation, delayed_failure.id)
    assert persisted.updated_at == completed_at
    assert persisted.next_recovery_at == DateTime.add(completed_at, 1, :second)
    assert_receive {:timer_scheduled, ^recovery, :due, 1_000}
  end

  test "autostart and manual start share one atomic pass transition", context do
    recovery = start_recovery!(context.clock, [])
    idle_state = :sys.get_state(recovery)

    {:noreply, running_state} = Recovery.handle_continue(:start_recovery_pass, idle_state)

    assert running_state.running?
    assert_receive :recover_batch

    {:noreply, unchanged_state} = Recovery.handle_cast(:start_pass, running_state)

    assert unchanged_state == running_state
    refute_receive :recover_batch
    refute_receive :start_recovery_pass
  end

  test "a failure cannot attach backoff to a newer operation stage", context do
    advanced = operation_row(context.connection_id, "revoke", "stage-advance-failure", 0)
    {1, nil} = Repo.insert_all(Operation, [advanced])

    recovery = start_recovery!(context.clock, retry_base_ms: 1_000, retry_cap_ms: 8_000)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, "stage-advance-failure"}
    assert_receive {:recovery_idle, ^recovery}

    persisted = Repo.get!(Operation, advanced.id)
    assert persisted.status == "backend_committed"
    assert persisted.recovery_attempts == 0
    assert persisted.last_recovery_error_code == nil
    assert persisted.next_recovery_at == @now
  end

  test "a successful fenced recovery preserves its durable retry schedule", context do
    operation = operation_row(context.connection_id, "revoke", "fenced-success", 0)
    {1, nil} = Repo.insert_all(Operation, [operation])

    recovery = start_recovery!(context.clock, [])
    monitor = Process.monitor(recovery)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, "fenced-success"}
    assert_receive {:recovery_idle, ^recovery}
    refute_receive {:DOWN, ^monitor, :process, ^recovery, _reason}

    assert %{status: "fenced", safe_error_code: "connection_terminal"} =
             persisted =
             Repo.get!(Operation, operation.id)

    assert persisted.next_recovery_at == @now
    assert Process.alive?(recovery)
  end

  test "an empty pass wakes at the earliest eligible phase due time without a zero delay",
       context do
    fenced =
      operation_row(context.connection_id, "revoke", "fenced", 0,
        status: "fenced",
        next_recovery_at: DateTime.add(@now, 1, :second)
      )

    termination =
      operation_row(context.connection_id, "disconnect", "future", 1,
        next_recovery_at: DateTime.add(@now, 9, :second)
      )

    refresh =
      operation_row(context.connection_id, "refresh", "future-refresh", 2,
        next_recovery_at: DateTime.add(@now, 2, :second),
        lease_until: DateTime.add(@now, 5, :second)
      )

    terminal =
      operation_row(context.connection_id, "disconnect", "terminal", 3,
        status: "finalized",
        next_recovery_at: nil
      )

    {4, nil} = Repo.insert_all(Operation, [fenced, termination, refresh, terminal])

    recovery =
      start_recovery!(context.clock,
        idle_min_ms: 100,
        idle_max_ms: 10_000
      )

    :ok = Recovery.start_pass(recovery)

    refute_receive {:attempted, _correlation_id}
    assert_receive {:recovery_idle, ^recovery}
    assert_receive {:timer_scheduled, ^recovery, :due, 5_000}
    refute_receive {:timer_scheduled, ^recovery, _kind, 0}
  end

  test "a recoverer crash becomes a closed observable error without leaking details", context do
    crashing = operation_row(context.connection_id, "revoke", "crash", 0)
    {1, nil} = Repo.insert_all(Operation, [crashing])

    recovery = start_recovery!(context.clock, retry_base_ms: 250, retry_cap_ms: 1_000)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, "crash"}
    assert_receive {:recovery_idle, ^recovery}

    persisted = Repo.get!(Operation, crashing.id)
    assert persisted.recovery_attempts == 1
    assert persisted.last_recovery_error_code == "backend_unavailable"
    assert persisted.next_recovery_at == DateTime.add(@now, 250, :millisecond)
    refute inspect(persisted) =~ "credential=must-not-leak"
  end

  test "an empty pass polls with a non-zero delay and later discovers newly due work", context do
    recovery =
      start_recovery!(context.clock,
        idle_min_ms: 100,
        idle_max_ms: 1_234
      )

    :ok = Recovery.start_pass(recovery)

    assert_receive {:recovery_idle, ^recovery}
    assert_receive {:timer_scheduled, ^recovery, :poll, 1_234}
    assert_receive {:timer_message, ^recovery, :poll, poll_message}
    refute_receive {:timer_scheduled, ^recovery, :poll, 0}

    newly_due = operation_row(context.connection_id, "revoke", "newly-due", 0)
    {1, nil} = Repo.insert_all(Operation, [newly_due])
    send(recovery, poll_message)

    assert_receive {:attempted, "newly-due"}
    assert_receive {:recovery_idle, ^recovery}
    assert Repo.get!(Operation, newly_due.id).status == "finalized"
  end

  test "the 500-row pass yield schedules a non-zero continuation", context do
    rows =
      for offset <- 0..499 do
        operation_row(context.connection_id, "revoke", "success-#{offset}", offset)
      end

    {500, nil} = Repo.insert_all(Operation, rows)

    recovery = start_recovery!(context.clock, yield_delay_ms: 5)
    :ok = Recovery.start_pass(recovery)

    for offset <- 0..499 do
      correlation_id = "success-#{offset}"
      assert_receive {:attempted, ^correlation_id}, 5_000
    end

    assert_receive {:recovery_pass_yielded, ^recovery, 500}
    assert_receive {:timer_scheduled, ^recovery, :yield, 5}
    refute_receive {:timer_scheduled, ^recovery, :yield, 0}
  end

  defp assert_retry(recovery, operation_id, clock, now, attempts, delay_ms) do
    Agent.update(clock, fn _prior -> now end)
    :ok = Recovery.start_pass(recovery)

    assert_receive {:attempted, "poison"}
    assert_receive {:recovery_idle, ^recovery}

    persisted = Repo.get!(Operation, operation_id)
    assert persisted.recovery_attempts == attempts
    assert persisted.last_recovery_error_code == "backend_unavailable"
    assert persisted.next_recovery_at == DateTime.add(now, delay_ms, :millisecond)
  end

  defp start_recovery!(clock, options) do
    test_pid = self()
    name = {:global, {__MODULE__, make_ref()}}

    timer = fn destination, message, delay ->
      {:scheduled_recovery_pass, kind, _token} = message
      send(test_pid, {:timer_scheduled, destination, kind, delay})
      send(test_pid, {:timer_message, destination, kind, message})
      make_ref()
    end

    pid =
      start_supervised!(
        {Recovery,
         [
           name: name,
           recoverer: RecoveryFairnessRecoverer,
           observer: self(),
           autostart: false,
           now: fn -> Agent.get(clock, & &1) end,
           timer: timer
         ] ++ options}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp operation_row(connection_id, operation_class, correlation_id, offset, overrides \\ []) do
    inserted_at = DateTime.add(@now, offset, :microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      workspace_uri: "workspace://recovery-fairness",
      connection_id: connection_id,
      backend_pair_id: "pair-recovery-v1",
      operation_class: operation_class,
      correlation_id: correlation_id,
      bound_input_digest: "digest-#{offset}",
      expected_connection_version: 1,
      expected_credential_version: 1,
      status: "prepared",
      recovery_attempts: 0,
      next_recovery_at: @now,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    row =
      if operation_class == "refresh" do
        Map.merge(row, %{
          expected_authorization_ref: "authorization-recovery",
          expected_authorization_version: 0
        })
      else
        row
      end

    Map.merge(row, Map.new(overrides))
  end
end
