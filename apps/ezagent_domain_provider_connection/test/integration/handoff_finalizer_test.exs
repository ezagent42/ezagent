defmodule Ezagent.ProviderConnection.HandoffFinalizerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{AuthorizationBackendRecord, HandoffFinalizer}
  alias EzagentCore.Repo

  test "prepare accepts only coherent consumed and exact idempotent successors" do
    consumed = record!("consumed", handoff_ref: "handoff-consumed", handoff_ciphertext: "sealed")

    assert :ok = HandoffFinalizer.prepare(consumed.authorization_ref)

    pending = Repo.get!(AuthorizationBackendRecord, consumed.id)
    assert pending.lifecycle_status == "handoff_finalization_pending"
    assert pending.handoff_ref == "handoff-consumed"
    assert pending.handoff_ciphertext == "sealed"
    assert is_nil(pending.shredded_at)
    assert :ok = HandoffFinalizer.prepare(consumed.authorization_ref)

    shredded =
      record!("shredded",
        handoff_ref: "handoff-shredded",
        handoff_ciphertext: nil,
        shredded_at: DateTime.utc_now()
      )

    assert :ok = HandoffFinalizer.prepare(shredded.authorization_ref)

    for lifecycle <- ["pending", "cancelled", "expired"] do
      row = record!(lifecycle)
      assert {:error, :credential_conflict} = HandoffFinalizer.prepare(row.authorization_ref)
      assert Repo.get!(AuthorizationBackendRecord, row.id).lifecycle_status == lifecycle
    end

    assert {:error, :credential_conflict} = HandoffFinalizer.prepare(Ecto.UUID.generate())
  end

  test "finalize accepts only coherent pending and exact shredded successor" do
    pending =
      record!("handoff_finalization_pending",
        handoff_ref: "handoff-pending",
        handoff_ciphertext: "sealed"
      )

    assert :ok = HandoffFinalizer.finalize(pending.authorization_ref)

    shredded = Repo.get!(AuthorizationBackendRecord, pending.id)
    assert shredded.lifecycle_status == "shredded"
    assert shredded.handoff_ref == "handoff-pending"
    assert is_nil(shredded.handoff_ciphertext)
    assert %DateTime{} = shredded.shredded_at
    assert :ok = HandoffFinalizer.finalize(pending.authorization_ref)

    for lifecycle <- ["pending", "consumed", "cancelled", "expired"] do
      row =
        record!(lifecycle,
          handoff_ref: if(lifecycle == "consumed", do: "handoff-#{lifecycle}"),
          handoff_ciphertext: if(lifecycle == "consumed", do: "sealed")
        )

      assert {:error, :credential_conflict} = HandoffFinalizer.finalize(row.authorization_ref)
      assert Repo.get!(AuthorizationBackendRecord, row.id).lifecycle_status == lifecycle
    end

    assert {:error, :credential_conflict} = HandoffFinalizer.finalize(Ecto.UUID.generate())
  end

  test "concurrent finalizers serialize to one exact shredded successor" do
    pending =
      run_unboxed(fn ->
        record!("handoff_finalization_pending",
          handoff_ref: "handoff-concurrent",
          handoff_ciphertext: "sealed-concurrent"
        )
      end)

    on_exit(fn ->
      run_unboxed(fn ->
        Repo.delete_all(from(row in AuthorizationBackendRecord, where: row.id == ^pending.id))
      end)
    end)

    parent = self()

    holder =
      spawn(fn ->
        result =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              AuthorizationBackendRecord
              |> where([row], row.id == ^pending.id)
              |> lock("FOR UPDATE")
              |> Repo.one!()

              send(parent, {:handoff_finalizer_lock_held, self()})
              receive do: (:release_handoff_finalizer_lock -> :ok)
            end)
          end)

        send(parent, {:handoff_finalizer_holder_done, self(), result})
      end)

    assert_receive {:handoff_finalizer_lock_held, ^holder}, 5_000

    workers =
      for _index <- 1..2 do
        spawn(fn ->
          result =
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
              send(parent, {:handoff_finalizer_worker_backend, self(), backend_pid})
              HandoffFinalizer.finalize(pending.authorization_ref)
            end)

          send(parent, {:handoff_finalizer_worker_done, self(), result})
        end)
      end

    backend_pids =
      Map.new(workers, fn worker ->
        assert_receive {:handoff_finalizer_worker_backend, ^worker, backend_pid}, 5_000
        {worker, backend_pid}
      end)

    Enum.each(backend_pids, fn {_worker, backend_pid} ->
      assert_backend_waiting_on_lock!(backend_pid, 1_000)
    end)

    send(holder, :release_handoff_finalizer_lock)
    assert_receive {:handoff_finalizer_holder_done, ^holder, {:ok, :ok}}, 5_000

    Enum.each(workers, fn worker ->
      assert_receive {:handoff_finalizer_worker_done, ^worker, :ok}, 5_000
    end)

    shredded = run_unboxed(fn -> Repo.get!(AuthorizationBackendRecord, pending.id) end)
    assert shredded.lifecycle_status == "shredded"
    assert shredded.handoff_ref == pending.handoff_ref
    assert is_nil(shredded.handoff_ciphertext)
    assert %DateTime{} = shredded.shredded_at
  end

  defp run_unboxed(fun) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      result = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
      send(parent, {ref, result})
    end)

    assert_receive {^ref, result}, 5_000
    result
  end

  defp assert_backend_waiting_on_lock!(backend_pid, attempts) when attempts > 0 do
    waiting? =
      run_unboxed(fn ->
        case Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock"]] -> true
          _other -> false
        end
      end)

    if waiting?, do: :ok, else: assert_backend_waiting_on_lock!(backend_pid, attempts - 1)
  end

  defp assert_backend_waiting_on_lock!(_backend_pid, 0),
    do: flunk("handoff finalizer did not block on the exact backend-record lock")

  defp record!(lifecycle, overrides \\ []) do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      workspace_uri: "workspace://acme",
      backend_pair_id: "pair-a",
      authorization_ref: Ecto.UUID.generate(),
      execution_identity: "connected_user",
      key_id: "test-v1",
      key_fingerprint: <<1>>,
      nonce: <<2>>,
      ciphertext: <<3>>,
      bound_input_digest: "digest",
      begin_correlation_id: Ecto.UUID.generate(),
      owner_uri: "entity://acme/user/alice",
      connection_id: Ecto.UUID.generate(),
      connection_version: 1,
      provider_id: "fake",
      governed_host: "example.test",
      acquisition_method: "oauth",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      handoff_ref: nil,
      handoff_ciphertext: nil,
      lifecycle_status: lifecycle,
      shredded_at: nil,
      expires_at: DateTime.add(now, 3_600, :second),
      inserted_at: now,
      updated_at: now
    }

    attrs = Map.merge(attrs, Map.new(overrides))

    %AuthorizationBackendRecord{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
