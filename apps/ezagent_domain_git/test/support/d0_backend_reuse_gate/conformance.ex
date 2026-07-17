defmodule Ezagent.DomainGit.D0BackendReuseGate.Conformance do
  @moduledoc false

  import ExUnit.Assertions

  alias Ezagent.DomainGit.D0BackendReuseGate.Types

  @spec authorization_cases(map()) :: :ok
  def authorization_cases(descriptor) do
    invalid_subject_case(descriptor)
    acquisition_method_cases(descriptor)
    mismatch_cases(descriptor)
    social_login_case(descriptor)
    cancellation_case(descriptor)
    callback_expiry_case(descriptor)
    valid_and_single_consume_case(descriptor)
    reauthentication_case(descriptor)
    :ok
  end

  @spec credential_cases(map()) :: :ok
  def credential_cases(descriptor) do
    store_and_status_case(descriptor)
    cas_race_case(descriptor)
    scope_and_version_cases(descriptor)
    proof_cases(descriptor)
    lease_use_and_reuse_case(descriptor)
    lease_expiry_case(descriptor)
    revoke_case(descriptor)
    :ok
  end

  defp store_and_status_case(descriptor) do
    reset(descriptor)
    assert {:ok, record} = credential(descriptor).store(store_request())
    assert record == %{credential_ref: "cred-1", version: 1, status: :active}
    refute inspect(record) =~ "gho-D0-SENTINEL"

    assert {:ok, status} = credential(descriptor).status(status_request(record))
    assert status == %{status: :active, version: 1, expires_at: nil}
    assert Types.safe_envelope?(status)
    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end

  defp cas_race_case(descriptor) do
    reset(descriptor)
    {:ok, record} = credential(descriptor).store(store_request())
    request = replace_request(record, "gho-D0-ROTATED")

    results =
      1..2
      |> Task.async_stream(fn _ -> credential(descriptor).replace(request) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{version: 2}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :credential_version_conflict})) == 1
    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end

  defp scope_and_version_cases(descriptor) do
    for {change, error} <- [
          {{:owner_uri, Ezagent.URI.user("acme", "bob")}, :credential_scope_mismatch},
          {{:workspace_uri, Ezagent.URI.workspace("other")}, :credential_scope_mismatch},
          {{:provider_id, "gitlab"}, :credential_scope_mismatch},
          {{:governed_host, "git.example"}, :credential_host_mismatch}
        ] do
      reset(descriptor)
      {:ok, record} = credential(descriptor).store(store_request())
      {field, value} = change
      bad_scope = Map.put(scope(), field, value)

      assert {:error, ^error} =
               credential(descriptor).lease_for_operation(
                 lease_request(record, expected_scope: bad_scope)
               )

      assert Map.fetch!(descriptor, :provider_effect_count).() == 0
    end

    reset(descriptor)
    {:ok, record} = credential(descriptor).store(store_request())

    assert {:error, :credential_version_conflict} =
             credential(descriptor).lease_for_operation(
               lease_request(record, expected_version: 99)
             )
  end

  defp proof_cases(descriptor) do
    for {proof, error} <- [
          {nil, :operation_grant_missing},
          {%{}, :operation_grant_invalid},
          {%{receiver: :agent}, :operation_grant_invalid},
          {%{receiver: :provider_adapter, operation_class: :list_checks},
           :operation_not_permitted}
        ] do
      reset(descriptor)
      {:ok, record} = credential(descriptor).store(store_request())

      assert {:error, ^error} =
               credential(descriptor).lease_for_operation(
                 lease_request(record, operation_grant: proof)
               )

      assert Map.fetch!(descriptor, :provider_effect_count).() == 0
    end
  end

  defp lease_use_and_reuse_case(descriptor) do
    reset(descriptor)
    {:ok, record} = credential(descriptor).store(store_request())
    request = lease_request(record)
    assert {:ok, lease} = credential(descriptor).lease_for_operation(request)
    refute inspect(lease) =~ "gho-D0-SENTINEL"

    consume = consume_request(lease, record)
    assert {:ok, response} = adapter_probe(descriptor).request_with_lease(lease, consume)
    assert response == %{status: 200, body: %{"login" => "alice-gh"}}
    refute inspect(response) =~ "gho-D0-SENTINEL"
    assert Map.fetch!(descriptor, :provider_effect_count).() == 1

    assert {:error, :lease_already_consumed} =
             adapter_probe(descriptor).request_with_lease(lease, consume)

    assert Map.fetch!(descriptor, :provider_effect_count).() == 1
  end

  defp lease_expiry_case(descriptor) do
    reset(descriptor)
    {:ok, record} = credential(descriptor).store(store_request())
    {:ok, lease} = credential(descriptor).lease_for_operation(lease_request(record))
    Map.fetch!(descriptor, :advance_time).(31)

    assert {:error, :lease_expired} =
             adapter_probe(descriptor).request_with_lease(lease, consume_request(lease, record))

    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end

  defp revoke_case(descriptor) do
    reset(descriptor)
    {:ok, record} = credential(descriptor).store(store_request())
    assert {:ok, revoked} = credential(descriptor).revoke(revoke_request(record))
    assert revoked == %{credential_ref: "cred-1", version: 2, status: :revoked}

    assert {:error, :credential_revoked} =
             credential(descriptor).lease_for_operation(%{
               lease_request(record)
               | expected_version: 2
             })

    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end

  defp invalid_subject_case(descriptor) do
    invalid_subjects = [
      %{subject() | owner_uri: Ezagent.URI.workspace("acme")},
      %{subject() | owner_uri: Ezagent.URI.user("other", "alice")},
      %{subject() | owner_uri: Ezagent.URI.agent("acme", "alice")},
      %{subject() | workspace_uri: Ezagent.URI.workspace("other")},
      %{subject() | workspace_uri: Ezagent.URI.new!("workspace://acme?unexpected=true")}
    ]

    for invalid <- invalid_subjects do
      reset(descriptor)

      assert {:error, :invalid_authorization_subject} =
               authorization(descriptor).begin_authorization(begin_request(%{subject: invalid}))

      assert_no_effects(descriptor, authorization: true)
    end
  end

  defp acquisition_method_cases(descriptor) do
    for method <- ["social_login", "pat_import", "", "unknown"] do
      reset(descriptor)

      assert {:error, :invalid_acquisition_method} =
               authorization(descriptor).begin_authorization(
                 begin_request(%{acquisition_method: method})
               )

      assert_no_effects(descriptor, authorization: true)
    end
  end

  defp mismatch_cases(descriptor) do
    for {field, value, expected} <- [
          {:state, "wrong", :state_mismatch},
          {:pkce_digest, "wrong", :pkce_mismatch},
          {:governed_host, "git.example", :governed_host_mismatch},
          {:external_account_id, "other-user", :external_account_mismatch}
        ] do
      reset(descriptor)
      {:ok, started} = authorization(descriptor).begin_authorization(begin_request())
      envelope = Map.put(callback_envelope(started), field, value)

      assert {:error, ^expected} =
               authorization(descriptor).consume_callback(callback_request(started, envelope))

      assert_no_effects(descriptor)
    end

    reset(descriptor)
    {:ok, started} = authorization(descriptor).begin_authorization(begin_request())
    wrong_subject = %{subject() | connection_id: "conn-other"}

    assert {:error, :invalid_authorization_subject} =
             authorization(descriptor).consume_callback(
               callback_request(started, callback_envelope(started), wrong_subject)
             )

    assert_no_effects(descriptor)
  end

  defp social_login_case(descriptor) do
    reset(descriptor)
    {:ok, started} = authorization(descriptor).begin_authorization(begin_request())
    envelope = Map.put(callback_envelope(started), :acquisition_origin, :social_login)

    assert {:error, :callback_invalid} =
             authorization(descriptor).consume_callback(callback_request(started, envelope))

    assert_no_effects(descriptor)
  end

  defp cancellation_case(descriptor) do
    reset(descriptor)
    {:ok, started} = authorization(descriptor).begin_authorization(begin_request())

    assert :ok =
             authorization(descriptor).cancel_authorization(%{
               authorization_ref: started.authorization_ref,
               expected_subject: subject(),
               correlation_id: "corr-cancel-1"
             })

    assert {:error, :authorization_cancelled} =
             authorization(descriptor).consume_callback(
               callback_request(started, callback_envelope(started))
             )

    assert_no_effects(descriptor)
  end

  defp callback_expiry_case(descriptor) do
    reset(descriptor)
    {:ok, started} = authorization(descriptor).begin_authorization(begin_request())
    Map.fetch!(descriptor, :advance_time).(301)

    assert {:error, :callback_expired} =
             authorization(descriptor).consume_callback(
               callback_request(started, callback_envelope(started))
             )

    assert_no_effects(descriptor)
  end

  defp valid_and_single_consume_case(descriptor) do
    reset(descriptor)
    {:ok, started} = authorization(descriptor).begin_authorization(begin_request())
    request = callback_request(started, callback_envelope(started))

    assert {:ok, result} = authorization(descriptor).consume_callback(request)
    assert result.external_account_id == "github-user-42"
    assert result.display_login == "alice-gh"
    assert result.execution_identity.kind == :connected_user
    assert match?({:write_only_handoff, _}, result.credential_material)
    assert Types.safe_envelope?(Map.delete(result, :credential_material))

    assert {:error, :callback_already_consumed} =
             authorization(descriptor).consume_callback(request)

    assert_no_effects(descriptor)
  end

  defp reauthentication_case(descriptor) do
    reset(descriptor)

    assert {:ok, result} =
             authorization(descriptor).reauthenticate(%{
               subject: subject(),
               session_assurance_evidence: %{aal: :aal2},
               correlation_id: "corr-reauth-1"
             })

    assert Map.keys(result) |> Enum.sort() == [:expires_at, :reauth_ref]
    assert_no_effects(descriptor)
  end

  defp begin_request(overrides \\ %{}) do
    Map.merge(
      %{
        subject: subject(),
        acquisition_method: "oauth_user",
        requested_permissions_digest: "requested-digest-1",
        redirect_uri_id: "github-callback",
        correlation_id: "corr-auth-1"
      },
      overrides
    )
  end

  defp callback_request(started, envelope, expected_subject \\ subject()) do
    %{
      authorization_ref: started.authorization_ref,
      callback_envelope: envelope,
      expected_subject: expected_subject,
      correlation_id: "corr-callback-1"
    }
  end

  defp callback_envelope(started) do
    %{
      state: started.redirect["state"],
      pkce_digest: started.redirect["pkce_digest"],
      governed_host: "github.com",
      external_account_id: "github-user-42",
      acquisition_origin: :repository_consent
    }
  end

  defp subject do
    %{
      owner_uri: Ezagent.URI.user("acme", "alice"),
      workspace_uri: Ezagent.URI.workspace("acme"),
      provider_id: "github",
      governed_host: "github.com",
      connection_id: "conn-1",
      connection_version: 1
    }
  end

  defp scope do
    %{
      owner_uri: Ezagent.URI.user("acme", "alice"),
      workspace_uri: Ezagent.URI.workspace("acme"),
      provider_id: "github",
      governed_host: "github.com",
      connection_id: "conn-1"
    }
  end

  defp store_request do
    %{
      scope: scope(),
      credential_material: "gho-D0-SENTINEL",
      expected_absent: true,
      correlation_id: "corr-store-1"
    }
  end

  defp status_request(record) do
    %{
      credential_ref: record.credential_ref,
      expected_scope: scope(),
      correlation_id: "corr-status-1"
    }
  end

  defp replace_request(record, material) do
    %{
      credential_ref: record.credential_ref,
      expected_scope: scope(),
      expected_version: record.version,
      credential_material: material,
      correlation_id: "corr-replace-1"
    }
  end

  defp lease_request(record, overrides \\ []) do
    base = %{
      credential_ref: record.credential_ref,
      expected_scope: scope(),
      expected_version: record.version,
      operation_grant: valid_operation_grant(record),
      operation_class: :create_change_request,
      correlation_id: "corr-lease-1"
    }

    Enum.into(overrides, base)
  end

  defp valid_operation_grant(record) do
    %{
      receiver: :provider_adapter,
      credential_ref: record.credential_ref,
      expected_scope: scope(),
      expected_version: record.version,
      operation_class: :create_change_request
    }
  end

  defp consume_request(lease, record) do
    %{
      lease_id: lease.lease_id,
      expected_scope: scope(),
      expected_version: record.version,
      correlation_id: "corr-consume-1"
    }
  end

  defp revoke_request(record) do
    %{
      credential_ref: record.credential_ref,
      expected_scope: scope(),
      expected_version: record.version,
      correlation_id: "corr-revoke-1"
    }
  end

  defp authorization(descriptor), do: Map.fetch!(descriptor, :authorization)
  defp credential(descriptor), do: Map.fetch!(descriptor, :credential)
  defp adapter_probe(descriptor), do: Map.fetch!(descriptor, :adapter_probe)
  defp reset(descriptor), do: Map.fetch!(descriptor, :reset).()

  defp assert_no_effects(descriptor, opts \\ []) do
    if Keyword.get(opts, :authorization, false) do
      assert Map.fetch!(descriptor, :authorization_count).() == 0
    end

    assert Map.fetch!(descriptor, :credential_store_count).() == 0
    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end
end
