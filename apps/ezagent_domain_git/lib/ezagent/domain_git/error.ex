defmodule Ezagent.DomainGit.Error do
  @moduledoc "Provider and adapter errors for Git operations."

  @type t ::
          :provider_account_not_connected
          | :credential_backend_unavailable
          | :repository_not_found
          | :repository_read_denied
          | :repository_write_denied
          | :private_checkout_not_supported
          | :base_ref_not_found
          | :base_sha_mismatch
          | :invalid_ref
          | :invalid_file_change
          | :change_limit_exceeded
          | :change_request_conflict
          | :checks_unavailable
          | :provider_unavailable
          | :authentication_rejected
          | :installation_scope_mismatch
          | :head_ref_conflict
          | :provider_rate_limited
          | {:provider_request_failed, operation :: atom(), status :: pos_integer()}
end
