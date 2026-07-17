defmodule Ezagent.DomainGit.D0BackendReuseGate.Types do
  @moduledoc false

  @authorization_errors [
    :authorization_backend_unavailable,
    :invalid_authorization_subject,
    :invalid_acquisition_method,
    :governed_host_mismatch,
    :state_mismatch,
    :pkce_mismatch,
    :callback_expired,
    :callback_already_consumed,
    :callback_invalid,
    :external_account_mismatch,
    :reauthentication_required,
    :reauthentication_failed,
    :authorization_cancelled,
    :provider_authorization_denied,
    :provider_protocol_error,
    :stale_connection_version
  ]

  @credential_errors [
    :credential_backend_unavailable,
    :credential_not_found,
    :credential_scope_mismatch,
    :credential_host_mismatch,
    :credential_revoked,
    :credential_expired,
    :credential_refresh_required,
    :credential_version_conflict,
    :operation_grant_missing,
    :operation_grant_invalid,
    :operation_not_permitted,
    :request_plan_invalid,
    :provider_response_invalid,
    :lease_not_found,
    :lease_expired,
    :lease_already_consumed,
    :lease_scope_mismatch,
    :lease_consume_failed,
    :credential_store_failed,
    :credential_replace_failed,
    :credential_revoke_failed
  ]

  @secret_keys MapSet.new(~w(
    access_token
    refresh_token
    social_login_token
    authorization
    callback_code
    pkce_verifier
    credential_material
    plaintext
    raw_body
  ))

  @type authorization_error :: unquote(Enum.reduce(@authorization_errors, &{:|, [], [&1, &2]}))
  @type credential_error :: unquote(Enum.reduce(@credential_errors, &{:|, [], [&1, &2]}))

  @type authorization_subject :: %{
          required(:owner_uri) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:provider_id) => String.t(),
          required(:governed_host) => String.t(),
          required(:connection_id) => String.t(),
          required(:connection_version) => non_neg_integer()
        }

  @type authorization_request :: %{
          required(:subject) => authorization_subject(),
          required(:acquisition_method) => String.t(),
          required(:requested_permissions_digest) => String.t(),
          required(:redirect_uri_id) => String.t(),
          required(:correlation_id) => String.t()
        }

  @type authorization_started :: %{
          required(:authorization_ref) => String.t(),
          required(:redirect) => map(),
          required(:expires_at) => DateTime.t()
        }

  @type callback_request :: %{
          required(:authorization_ref) => String.t(),
          required(:callback_envelope) => map(),
          required(:expected_subject) => authorization_subject(),
          required(:correlation_id) => String.t()
        }

  @type authorization_result :: %{
          required(:external_account_id) => String.t(),
          required(:display_login) => String.t(),
          required(:execution_identity) => map(),
          required(:credential_material) => term(),
          required(:granted_permissions_digest) => String.t(),
          required(:provider_metadata) => map()
        }

  @type reauthentication_request :: %{
          required(:subject) => authorization_subject(),
          required(:session_assurance_evidence) => term(),
          required(:correlation_id) => String.t()
        }

  @type reauthentication_result :: %{
          required(:reauth_ref) => String.t(),
          required(:expires_at) => DateTime.t()
        }

  @type cancellation_request :: %{
          required(:authorization_ref) => String.t(),
          required(:expected_subject) => authorization_subject(),
          required(:correlation_id) => String.t()
        }

  @type credential_scope :: %{
          required(:owner_uri) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:provider_id) => String.t(),
          required(:governed_host) => String.t(),
          required(:connection_id) => String.t()
        }

  @type store_request :: %{
          required(:scope) => credential_scope(),
          required(:credential_material) => term(),
          required(:expected_absent) => true,
          required(:correlation_id) => String.t()
        }

  @type replace_request :: %{
          required(:credential_ref) => String.t(),
          required(:expected_scope) => credential_scope(),
          required(:expected_version) => non_neg_integer(),
          required(:credential_material) => term(),
          required(:correlation_id) => String.t()
        }

  @type status_request :: %{
          required(:credential_ref) => String.t(),
          required(:expected_scope) => credential_scope(),
          required(:correlation_id) => String.t()
        }

  @type operation_lease_request :: %{
          required(:credential_ref) => String.t(),
          required(:expected_scope) => credential_scope(),
          required(:expected_version) => non_neg_integer(),
          required(:operation_grant) => term(),
          required(:operation_class) =>
            :resolve_repository
            | :create_change_request
            | :read_change_request
            | :list_checks
            | :list_reviews,
          required(:correlation_id) => String.t()
        }

  @type consume_lease_request :: %{
          required(:lease_id) => String.t(),
          required(:expected_scope) => credential_scope(),
          required(:expected_version) => non_neg_integer(),
          required(:correlation_id) => String.t()
        }

  @type revoke_request :: %{
          required(:credential_ref) => String.t(),
          required(:expected_scope) => credential_scope(),
          required(:expected_version) => non_neg_integer(),
          required(:correlation_id) => String.t()
        }

  @type credential_record :: %{
          required(:credential_ref) => String.t(),
          required(:version) => pos_integer(),
          required(:status) => :active | :revoked
        }

  @type credential_status :: %{
          required(:status) => :active | :refresh_required | :revoked,
          required(:version) => pos_integer(),
          optional(:expires_at) => DateTime.t() | nil
        }

  @type credential_lease :: %{
          required(:lease_id) => String.t(),
          required(:sensitive) => term(),
          required(:expires_at) => DateTime.t(),
          required(:observed_version) => non_neg_integer()
        }

  @spec authorization_errors() :: [authorization_error()]
  def authorization_errors, do: @authorization_errors

  @spec credential_errors() :: [credential_error()]
  def credential_errors, do: @credential_errors

  @spec safe_envelope?(term()) :: boolean()
  def safe_envelope?(value), do: safe_value?(value)

  defp safe_value?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> safe_key?(key) and safe_value?(value) end)
  end

  defp safe_value?(list) when is_list(list), do: Enum.all?(list, &safe_value?/1)
  defp safe_value?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> safe_value?()
  defp safe_value?(_value), do: true

  defp safe_key?(key) when is_atom(key), do: safe_key?(Atom.to_string(key))
  defp safe_key?(key) when is_binary(key), do: not MapSet.member?(@secret_keys, key)
  defp safe_key?(_key), do: true
end
