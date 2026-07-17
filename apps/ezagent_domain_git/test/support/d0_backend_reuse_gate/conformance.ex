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

  defp authorization(descriptor), do: Map.fetch!(descriptor, :authorization)
  defp reset(descriptor), do: Map.fetch!(descriptor, :reset).()

  defp assert_no_effects(descriptor, opts \\ []) do
    if Keyword.get(opts, :authorization, false) do
      assert Map.fetch!(descriptor, :authorization_count).() == 0
    end

    assert Map.fetch!(descriptor, :credential_store_count).() == 0
    assert Map.fetch!(descriptor, :provider_effect_count).() == 0
  end
end
