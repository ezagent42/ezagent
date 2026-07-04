defmodule EzagentPluginCodex.CredentialFreshness do
  @moduledoc """
  #160 (credential-status view) — PRODUCTION read-only codex credential probe.

  A codex agent authenticates via `<CODEX_HOME>/auth.json` (OAuth tokens). Unlike
  cc, codex's `auth.json` has **no `expiresAt`** — it records `last_refresh` and the
  codex CLI self-refreshes the access token at runtime via the refresh token (see
  `EzagentPluginCodex.CredentialRefresh` moduledoc). So codex has no reliable
  read-only "expiring/expired" concept; this probe only distinguishes
  present / absent / unreadable:

    * `auth.json` absent            → `:missing`  (logged out / never `codex login`)
    * present + valid JSON object   → `:authenticated`  (the CLI self-refreshes)
    * present but unreadable/garbled → `:unknown`

  Read-only, NO network I/O, NO activation — mirrors
  `EzagentPluginCc.CredentialFreshness`. Distinct from
  `EzagentPluginCodex.CredentialRefresh` (the TEST/E2E provisioner that does
  network OAuth refresh + writes back).

  Deliberately NO `last_refresh`-age staleness heuristic (Allen 2026-07-04): the
  refresh-token TTL is a guess, and a false `:expired` on a still-valid codex
  login is worse than a plain `:authenticated`.
  """

  @auth_relpath "auth.json"

  @type status :: :authenticated | :missing | :unknown

  @doc """
  Classify the codex login state in `codex_home`'s `auth.json`. `opts` is accepted
  for signature parity with the cc probe (unused — codex has no expiry/skew). A
  `nil` `codex_home` (no CODEX_HOME) is `:unknown`.
  """
  @spec status(String.t() | nil, keyword()) :: status()
  def status(codex_home, opts \\ [])

  def status(nil, _opts), do: :unknown

  def status(codex_home, _opts) when is_binary(codex_home) do
    case File.read(Path.join(codex_home, @auth_relpath)) do
      {:error, :enoent} ->
        :missing

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{} = m} when map_size(m) > 0 -> :authenticated
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end
end
