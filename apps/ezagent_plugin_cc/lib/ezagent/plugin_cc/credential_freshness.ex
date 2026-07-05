defmodule EzagentPluginCc.CredentialFreshness do
  @moduledoc """
  #17 (c) — PRODUCTION spawn-time OAuth credential freshness preflight.

  A cc agent authenticates to Anthropic via the Claude Max OAuth token in
  `<CLAUDE_CONFIG_DIR>/.credentials.json` (`claudeAiOauth.expiresAt`, epoch ms),
  which expires ~daily. When it is expired, claude receives channel messages but
  every reply fails `401 · Please run /login` — the agent looks alive (bridge
  joined, mentions delivered) but silently never replies.

  This preflight makes that failure VISIBLE at (re)spawn: it `check/2`s the token
  the agent is about to launch with and, on a stale one, `remind/3` emits a loud
  `Logger.warning` + telemetry + a `credential_stale` meta entry the spawn path
  surfaces to the owner (mirroring `role_degraded`). Per Allen 2026-06-15 it is a
  **reminder only** — it never refreshes the token and never blocks the spawn; the
  developer/user re-logins (`claude /login`) themselves.

  Distinct from `EzagentPluginCc.CredentialRefresh` (the TEST/E2E provisioner that
  refreshes + writes back): this module is read-only, does no network I/O, and is
  safe in production.

  ## Scope (v1) — precise to the expired-OAuth silent-mute cause

  Reminds only when a `.credentials.json` is PRESENT and carries an
  `claudeAiOauth.expiresAt` that is expired or within the skew window. A MISSING
  or non-OAuth-shaped cred (e.g. `api_key_helper`, or a pre-`/login` agent) is
  `:unknown` — not reminded — to avoid false alarms on agents that legitimately
  do not use an OAuth token file. Spawn-time only; a token that expires
  mid-run is out of scope (that would need a runtime monitor / refresh, which
  Allen scoped out as a non-goal).
  """

  require Logger

  @cred_relpath ".credentials.json"
  # Matches EzagentPluginCc.CredentialRefresh's @expiry_skew_ms — treat a token
  # dying within the next minute as already stale to avoid a mid-spawn race.
  @default_skew_ms 60_000

  @type stale_reason :: :expired | :expiring_soon
  @type status :: :fresh | :unknown | {:stale, stale_reason()}

  @doc """
  Classify the freshness of the OAuth token in `config_dir`'s `.credentials.json`.

  `opts`: `:now_ms` (epoch ms, default `System.os_time/1`), `:skew_ms` (default
  #{@default_skew_ms}). A `nil` `config_dir` (legacy host-login agent, no
  `CLAUDE_CONFIG_DIR`) is `:unknown`.
  """
  @spec check(String.t() | nil, keyword()) :: status()
  def check(config_dir, opts \\ [])

  def check(nil, _opts), do: :unknown

  def check(config_dir, opts) when is_binary(config_dir) do
    now = Keyword.get(opts, :now_ms, System.os_time(:millisecond))
    skew = Keyword.get(opts, :skew_ms, @default_skew_ms)

    case read_oauth(Path.join(config_dir, @cred_relpath)) do
      {:ok, %{"expiresAt" => exp}} when is_integer(exp) ->
        cond do
          exp <= now -> {:stale, :expired}
          exp <= now + skew -> {:stale, :expiring_soon}
          true -> :fresh
        end

      # present-but-no-expiresAt, non-OAuth shape, missing file, or unreadable:
      # cannot confidently say it is a dead OAuth token → do not remind.
      _ ->
        :unknown
    end
  end

  @doc """
  #160 (credential-status view) — freshness classification that DISTINGUISHES a
  MISSING credential file from an unclassifiable one.

  `check/2` deliberately collapses a missing `.credentials.json` into `:unknown`
  (to avoid false spawn-time alarms). The credential-status view needs the
  distinct "logged out / never `/login`" signal, so `status/2` layers a
  `File.exists?` probe over `check/2`:

    * file absent            → `:missing`
    * file present           → defers to `check/2` (`:fresh` | `{:stale, reason}`
                               | `:unknown`)

  Read-only, no network I/O, no activation — same guarantees as `check/2`.
  A `nil` `config_dir` (legacy host-login agent) is `:unknown`.
  """
  @spec status(String.t() | nil, keyword()) :: :missing | status()
  def status(config_dir, opts \\ [])

  def status(nil, _opts), do: :unknown

  def status(config_dir, opts) when is_binary(config_dir) do
    if File.exists?(Path.join(config_dir, @cred_relpath)) do
      check(config_dir, opts)
    else
      :missing
    end
  end

  @doc """
  The OAuth token's `expiresAt` (epoch ms) when present + readable, else `nil`.
  Powers the credential-status view's `expires_at` field. Read-only.
  """
  @spec expires_at(String.t() | nil) :: integer() | nil
  def expires_at(nil), do: nil

  def expires_at(config_dir) when is_binary(config_dir) do
    case read_oauth(Path.join(config_dir, @cred_relpath)) do
      {:ok, %{"expiresAt" => exp}} when is_integer(exp) -> exp
      _ -> nil
    end
  end

  @doc """
  Spawn-time reminder. On a stale OAuth token: log a loud warning, emit
  `[:ezagent, :cc, :credential_freshness, :stale]` telemetry, and return
  `%{credential_stale: true, credential_stale_reason: reason}` for the spawn path
  to merge into its meta (surfaced to the owner like `role_degraded`). Otherwise
  returns `%{}`. NEVER raises and NEVER blocks the spawn.
  """
  @spec remind(URI.t(), String.t() | nil, keyword()) :: map()
  def remind(%URI{} = agent_uri, config_dir, opts \\ []) do
    case check(config_dir, opts) do
      {:stale, reason} ->
        Logger.warning(
          "cc agent #{URI.to_string(agent_uri)} OAuth credential #{reason} " <>
            "(CLAUDE_CONFIG_DIR=#{config_dir}) — claude will receive messages but reply " <>
            "401 until re-login. Run `claude /login` in the agent's config dir to restore it."
        )

        :telemetry.execute(
          [:ezagent, :cc, :credential_freshness, :stale],
          %{count: 1},
          %{agent_uri: agent_uri, reason: reason, config_dir: config_dir}
        )

        %{credential_stale: true, credential_stale_reason: reason}

      _ ->
        %{}
    end
  end

  defp read_oauth(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw) do
      {:ok, oauth}
    else
      _ -> :error
    end
  end
end
