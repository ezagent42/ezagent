defmodule Ezagent.DomainGit.Error do
  @moduledoc """
  Provider and adapter errors for Git operations.

  ## Two members that are easy to confuse

  `:provider_unavailable` and `:provider_response_unrecognized` both mean "this
  operation produced no usable facts", but they differ on the one question the
  workflow layer asks next — is retrying worth anything?

  `:provider_response_unrecognized` — the provider completed a **successful 2xx
  interaction** and its response carried something this code cannot normalize:
  an unknown enum value, a missing or renamed field, a body shape that does not
  match. Re-sending the same request gets the same answer, so a retry is pure
  delay. Someone has to look at whether the provider's API changed.
  `EzagentPluginGitWorkflow.Blocker` classifies it TERMINAL.

  `:provider_unavailable` — the residual bucket: the provider did not give us a
  usable answer at all. A transport failure, or an HTTP status this client does
  not specifically classify. `Blocker` classifies it RETRYABLE.

  The residual bucket is stated as a residue rather than defined as "no
  response", because that is not all it currently holds. Adapters also map some
  **deterministic 4xx** answers onto it — a request the provider understood and
  rejected as invalid, and whatever statuses an adapter's client does not
  classify by name. Those are deterministic and calling them retryable is
  inaccurate.

  That is not fixed by these two members and is deliberately not folded into
  `:provider_response_unrecognized`: "the provider understood the request and
  rejected it" is a different fact from "the response could not be read", and
  the right answer for it varies by operation. Tracked separately; see the
  2026-07-31 error-union amendment beside the V1-A/V1-B specs.
  """

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
          | :provider_response_unrecognized
          | :authentication_rejected
          | :installation_scope_mismatch
          | :head_ref_conflict
          | :provider_rate_limited
          | {:provider_request_failed, operation :: atom(), status :: pos_integer()}
end
