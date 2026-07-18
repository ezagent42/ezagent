defmodule Ezagent.ProviderConnection.SchemaTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    Operation
  }

  alias EzagentCore.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "all five schemas use the shared repository and tenant column" do
    for schema <- [
          Connection,
          AuthorizationAttempt,
          Operation,
          Ezagent.ProviderConnection.Event,
          AuthorizationBackendRecord
        ] do
      assert schema.__schema__(:fields) |> Enum.member?(:workspace_uri)

      assert schema.__schema__(:source) in ~w(provider_connections provider_authorization_attempts provider_connection_operations provider_connection_events provider_authorization_backend_records)
    end
  end

  test "active binding uniqueness is a named PostgreSQL constraint" do
    attrs = connection_attrs()
    assert {:ok, _} = Repo.insert(Connection.create_changeset(attrs))

    assert {:error, changeset} =
             Repo.insert(
               Connection.create_changeset(%{attrs | connection_id: Ecto.UUID.generate()})
             )

    assert {"has already been taken",
            [constraint: :unique, constraint_name: "provider_connections_active_binding_index"]} =
             changeset.errors[:external_account_id]
  end

  test "operation command key and attempt correlation are unique" do
    op = Operation.create_changeset(operation_attrs())
    assert {:ok, _} = Repo.insert(op)
    assert {:error, cs} = Repo.insert(Operation.create_changeset(operation_attrs()))
    assert cs.errors[:correlation_id]

    attempt = attempt_attrs()
    assert {:ok, _} = Repo.insert(AuthorizationAttempt.create_changeset(attempt))

    duplicate_state = %{
      attempt
      | attempt_ref: Ecto.UUID.generate(),
        authorization_ref: "auth-ref-2"
    }

    assert {:error, cs} = Repo.insert(AuthorizationAttempt.create_changeset(duplicate_state))
    assert cs.errors[:state_digest]
  end

  test "backend records allow one committed consume per authorization ref" do
    attrs = backend_record_attrs()
    assert {:ok, _} = Repo.insert(AuthorizationBackendRecord.create_changeset(attrs))

    assert {:error, cs} =
             Repo.insert(
               AuthorizationBackendRecord.create_changeset(%{attrs | id: Ecto.UUID.generate()})
             )

    assert cs.errors[:authorization_ref]
  end

  defp base, do: %{workspace_uri: "workspace://acme/workspace/main", backend_pair_id: "pair-a"}

  defp connection_attrs,
    do:
      Map.merge(base(), %{
        connection_id: Ecto.UUID.generate(),
        owner_uri: "entity://acme/user/u1",
        provider_id: "fake",
        governed_host: "example.test",
        external_account_id: "acct-1",
        display_login: "alice",
        execution_identity: "human",
        acquisition_method: "oauth",
        authorization_backend_ref: "auth:a",
        credential_backend_ref: "cred:a",
        status: "active"
      })

  defp operation_attrs,
    do:
      Map.merge(base(), %{
        connection_id: Ecto.UUID.generate(),
        operation_class: "store",
        correlation_id: "corr-1",
        bound_input_digest: "digest",
        status: "prepared"
      })

  defp attempt_attrs,
    do:
      Map.merge(base(), %{
        attempt_ref: Ecto.UUID.generate(),
        authorization_ref: "auth-ref",
        connection_id: Ecto.UUID.generate(),
        bound_subject_digest: "subject",
        state_digest: "state",
        correlation_id: "corr",
        status: "pending",
        expires_at: DateTime.utc_now()
      })

  defp backend_record_attrs,
    do:
      Map.merge(base(), %{
        id: Ecto.UUID.generate(),
        authorization_ref: "auth-ref-committed",
        key_id: "k1",
        nonce: <<1>>,
        ciphertext: <<2>>,
        bound_input_digest: "digest",
        consume_status: "committed",
        expires_at: DateTime.utc_now()
      })
end
