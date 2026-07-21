defmodule Ezagent.Credential.Adopt do
  @moduledoc """
  One-time migration: adopt an existing per-agent credential as a user's default source
  (§5.2). Refuses ambiguity rather than guessing. Writes go through the SAME authorized,
  cap-checked, audited chokepoint (the `:set_default_credential_source` Behavior dispatch
  via `Ezagent.Credential.UserDefaultSource.set_via_dispatch/3`) — NOT a raw setter
  (codex CRIT: no unauthenticated side path).
  """

  alias Ezagent.Credential.UserDefaultSource

  @spec adopt(String.t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def adopt(owner, ws, flavor, candidates, opts) do
    operator = Keyword.fetch!(opts, :caller)
    authenticated_principal = Keyword.fetch!(opts, :authenticated_principal)
    caps = Keyword.fetch!(opts, :caps)

    case candidates do
      [single] ->
        case UserDefaultSource.set_via_dispatch(
               owner,
               %{flavor: flavor, source_uri: single, workspace: ws},
               %{
                 caller: operator,
                 authenticated_principal: authenticated_principal,
                 caps: caps
               }
             ) do
          {:ok, _} -> {:ok, single}
          err -> err
        end

      [] ->
        {:error, :no_candidate}

      many ->
        {:error, {:ambiguous, many}}
    end
  end
end
