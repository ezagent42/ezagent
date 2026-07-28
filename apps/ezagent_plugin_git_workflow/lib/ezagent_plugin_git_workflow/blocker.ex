defmodule EzagentPluginGitWorkflow.Blocker do
  @moduledoc """
  Stable blocker vocabulary, retry classification and leak-free presentation
  (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §7.1, §7.2).

  ## Why the mapping must be TOTAL

  §7.1 lists fifteen stable codes and says "**至少**包括" — at least these. The
  operative requirement is not the count but **totality**: every error term a
  port or adapter can hand the runner must land on a code. An unmapped term
  either crashes the runner or, worse, gets passed through into presentation —
  and a provider's raw reason is exactly the raw response detail §7.1 forbids
  from appearing there.

  `@codes` is therefore §7.1's fifteen plus the codes the ports actually
  produce that §7.1 did not enumerate:

    * from `Ezagent.Workspace.TaskWorkspace.ChangeCollector`'s closed returned
      set — `:workspace_read_failed`, `:invalid_change_limits_config`, and
      `:invalid_change_request` (the latter from its fallback `collect/1`
      clause, which its moduledoc's vocabulary list omits);
    * from `Ezagent.DomainGit.Error.t()` — `:repository_not_found`,
      `:base_ref_not_found`, `:invalid_ref`, `:invalid_file_change`,
      `:checks_unavailable`, `:provider_account_not_connected`,
      `:credential_backend_unavailable`, `:private_checkout_not_supported`;
    * `:internal_error`, the catch-all `from_error/1` produces for a term
      nothing else matched.

  Four finer-grained reasons DO appear inside `ChangeCollector`
  (`:binary_content`, `:executable_mode`, `:not_regular_file`,
  `:path_escapes_worktree`) and are deliberately absent here: its `read_one/6`
  normalizes every reason other than `:change_limit_exceeded` /
  `:workspace_read_failed` to `:unsupported_workspace_change` before it
  returns, so none of them can leave `collect/1`. If one ever does, that is a
  vocabulary change in the collector, not something to paper over here.

  `Ezagent.DomainGit.Error` is NOT extended by this module — design §4.4
  assigns that type to the GitHub owner and this app consumes it read-only.

  ## Retry classification (§7.2)

  `classify/1` answers `:terminal_blocker` for deterministic
  validation/conflict outcomes and `:retryable` for transient/provider ones.
  It has NO catch-all clause: a code added to `@codes` without a
  classification raises rather than silently defaulting, because a silent
  default is how a deterministic failure ends up in a retry loop.

  Two calls worth stating outright:

    * `:no_changes_collected` is **terminal**, not retryable. The intuitive
      reading ("retry and maybe the agent writes something this time") is
      wrong: re-running the same generation only ever yields the same empty
      diff (§7.1's 2026-07-26 amendment).
    * `:internal_error` is **terminal**. It is by construction a term nobody
      classified, so nothing justifies believing a retry changes it; stopping
      surfaces it to an operator, while retrying would spin the runner on a
      permanent bug.

  ## Presentation carries five fields and nothing else

  `present/4` returns exactly `code`, `stage`, `retryable`, `attempt`,
  `metadata` — §7.1's permitted set. `retryable` is derived from `classify/1`
  and can never be passed in, so presentation cannot disagree with policy.
  `metadata` admits only atom keys mapping to integers, booleans or atoms: a
  binary is how a response body, header, token or file path would arrive, so
  binaries are refused outright rather than filtered.
  """

  # Design §7.1's fifteen.
  @spec_codes [
    :authorization_unavailable,
    :not_authorized,
    :workspace_not_ready,
    :workspace_identity_mismatch,
    :unsupported_workspace_change,
    :change_limit_exceeded,
    :base_sha_mismatch,
    :head_ref_conflict,
    :change_request_conflict,
    :installation_scope_mismatch,
    :provider_permission_denied,
    :provider_rate_limited,
    :provider_unavailable,
    :observation_incomplete,
    :no_changes_collected
  ]

  # Produced by the ports but absent from §7.1's "至少" list — see moduledoc.
  @port_codes [
    :workspace_read_failed,
    :invalid_change_limits_config,
    :invalid_change_request,
    :repository_not_found,
    :base_ref_not_found,
    :invalid_ref,
    :invalid_file_change,
    :checks_unavailable,
    :provider_account_not_connected,
    :credential_backend_unavailable,
    :private_checkout_not_supported
  ]

  @codes @spec_codes ++ @port_codes ++ [:internal_error]

  # Deterministic validation/conflict — re-running the same generation against
  # the same inputs produces the same answer (§7.2 first bullet).
  @terminal_codes [
    :not_authorized,
    :workspace_identity_mismatch,
    :unsupported_workspace_change,
    :change_limit_exceeded,
    :base_sha_mismatch,
    :head_ref_conflict,
    :change_request_conflict,
    :installation_scope_mismatch,
    :invalid_ref,
    :invalid_file_change,
    :private_checkout_not_supported,
    :invalid_change_limits_config,
    :no_changes_collected,
    # Not in §7.2's two examples, decided here (moduledoc "no code may be
    # unclassified"): a denied permission, a repository or base ref that is
    # not there, a provider account nobody connected, and a malformed
    # collect request are all deterministic given the same run inputs —
    # nothing a bounded retry does changes them, and each needs an operator.
    :provider_permission_denied,
    :repository_not_found,
    :base_ref_not_found,
    :provider_account_not_connected,
    :invalid_change_request,
    :internal_error
  ]

  # Transient/provider — bounded retry (§7.2 second and fourth bullets).
  @retryable_codes [
    :provider_rate_limited,
    :provider_unavailable,
    :authorization_unavailable,
    :workspace_not_ready,
    :workspace_read_failed,
    :checks_unavailable,
    :credential_backend_unavailable,
    :observation_incomplete
  ]

  @type code ::
          :authorization_unavailable
          | :not_authorized
          | :workspace_not_ready
          | :workspace_identity_mismatch
          | :unsupported_workspace_change
          | :change_limit_exceeded
          | :base_sha_mismatch
          | :head_ref_conflict
          | :change_request_conflict
          | :installation_scope_mismatch
          | :provider_permission_denied
          | :provider_rate_limited
          | :provider_unavailable
          | :observation_incomplete
          | :no_changes_collected
          | :workspace_read_failed
          | :invalid_change_limits_config
          | :invalid_change_request
          | :repository_not_found
          | :base_ref_not_found
          | :invalid_ref
          | :invalid_file_change
          | :checks_unavailable
          | :provider_account_not_connected
          | :credential_backend_unavailable
          | :private_checkout_not_supported
          | :internal_error

  @type classification :: :retryable | :terminal_blocker

  @doc "The complete stable blocker vocabulary. Every member has a `classify/1` answer."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc """
  Classifies a stable code per §7.2.

  Raises `FunctionClauseError` for anything outside `codes/0` — deliberately.
  A catch-all here would let a newly added code default into one bucket
  without anyone deciding which, and the wrong default (retryable) puts a
  deterministic failure into a retry loop.
  """
  @spec classify(code()) :: classification()
  def classify(code) when code in @terminal_codes, do: :terminal_blocker
  def classify(code) when code in @retryable_codes, do: :retryable

  @doc """
  Maps a port/adapter error term to a stable code.

  The seam's and the collector's own atoms pass through unchanged.
  `Ezagent.DomainGit.Error.t()` members map by name, except that
  `:repository_read_denied`, `:repository_write_denied` and
  `:authentication_rejected` all collapse to `:provider_permission_denied` —
  which of the three a provider chose is provider-shaped detail the runner
  does not act on differently.

  `{:provider_request_failed, operation, status}` maps by status class and
  **drops the operation atom**: it names a provider API call, and §7.1's
  presentation may not carry provider-shaped detail.

  Anything else becomes `:internal_error` with the term **dropped entirely**.
  Not a crash — a crash inside a runner is worse than a safe generic. Not a
  passthrough — a passthrough is precisely the leak §7.1 forbids.
  """
  @spec from_error(term()) :: code()
  def from_error(code) when code in @codes, do: code

  def from_error(code)
      when code in [:repository_read_denied, :repository_write_denied, :authentication_rejected],
      do: :provider_permission_denied

  def from_error({:provider_request_failed, _operation, status}) when is_integer(status) do
    cond do
      status in [401, 403] -> :provider_permission_denied
      status == 429 -> :provider_rate_limited
      # Anything not otherwise recognised is treated as the provider being
      # unable to serve the request, rather than inventing a finer code the
      # runner has no different response to.
      true -> :provider_unavailable
    end
  end

  def from_error(_term), do: :internal_error

  @doc """
  Builds the presentation map for a blocked/failed attempt.

  Exactly `code`, `stage`, `retryable`, `attempt`, `metadata` (§7.1) —
  `retryable` derived from `classify/1`, never supplied.

  `safe_metadata` must be a map of atom keys to integers, booleans or atoms.
  A binary value raises: a binary is how a response body, header, token or
  file path would reach presentation, and refusing outright beats filtering
  (a filter has to be right about every shape; a whitelist only has to be
  right about the allowed ones).
  """
  @spec present(code(), atom(), non_neg_integer(), map()) :: map()
  def present(code, stage, attempt, safe_metadata)
      when is_atom(stage) and is_integer(attempt) and attempt >= 0 and is_map(safe_metadata) do
    %{
      code: code,
      stage: stage,
      retryable: classify(code) == :retryable,
      attempt: attempt,
      metadata: checked_metadata(safe_metadata)
    }
  end

  defp checked_metadata(metadata) do
    Enum.each(metadata, fn {key, value} ->
      # The key is validated BEFORE it is ever echoed: a non-atom key could
      # itself be the secret, so that branch names no value at all.
      if not is_atom(key) do
        raise ArgumentError, "blocker metadata keys must be atoms (design §7.1 safe metadata)"
      end

      if not safe_value?(value) do
        raise ArgumentError,
              "blocker metadata value for #{inspect(key)} must be an integer, boolean or atom; " <>
                "binaries are refused because that is how a response body, header, token or " <>
                "file path would arrive (design §7.1)"
      end
    end)

    metadata
  end

  # `is_atom/1` already covers booleans and `nil`.
  defp safe_value?(value), do: is_integer(value) or is_atom(value)
end
