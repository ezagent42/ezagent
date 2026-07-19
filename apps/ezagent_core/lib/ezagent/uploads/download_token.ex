defmodule Ezagent.Uploads.DownloadToken do
  @moduledoc """
  Signed capability download token for chat uploads (Resource-unification
  SPEC §6 P2a / OI-1 DECISION).

  S3-presigned-URL style: a MAC-signed bearer token that encodes the **full
  ws-scoped** `resource://<ws>/uploads/<name>` URI plus its issue time and TTL.
  It is the SOLE authorization carrier for the `GET /uploads/download?token=`
  internal route, the public `GET /socialware/external/download` feed route, and
  the internal operator download links — replacing the retired
  participation-based `/files/:filename` route (no back-compat shim).

  ## Why this lives in `ezagent_core`

  `ezagent_web` download controllers and operator surfaces must mint/verify the
  SAME token. Per the three-tier boundary (`references/three-tier-structure.md`),
  a plugin MAY depend on `core` but MUST NOT depend on `ezagent_web` nor reach
  into web internals (Allen's north-star: plugin authors stay out of core/web).
  `core` already depends on `:phoenix` (for `Phoenix.Presence`/`Phoenix.Token`),
  so the mint/verify primitive is a legitimate shared `core` capability.

  ## Security properties (all REQUIRED by OI-1)

    * **short TTL** — `@default_ttl` (#{div(300, 60)} min) bounds the bearer-leak
      window. `mint!/2` rejects a non-positive TTL (no accidental infinite token)
      and a TTL above the **24h hard ceiling** (`@max_ttl`).
    * **bound to one URI** — the token payload carries the URI's `stable_key`, so
      a token minted for `resource://acme/uploads/f.pdf` verifies to *exactly*
      that URI and cannot be replayed against `resource://victim/uploads/f.pdf`
      (workspace isolation) or any other file.
    * **type-locked to `uploads`** — `mint!/2` refuses any URI whose type segment
      is not `uploads`, so a confused caller cannot turn the download surface into
      a generic file reader for config-dir / other registered FsResolver types.
    * **minted only after authorization** — this module does NOT itself authorize;
      every caller (the internal controller mint endpoint, the LiveView render
      after its in-workspace mount cap-check, the external-feed approved-only
      gate) MUST authorize before calling `mint!/2`. This module is a pure signer.
    * **REQUIRED person binding (`:grantee`, read-plane PR-3)** — every NEW token
      is bound to the ONE principal the issuing chokepoint authorized:
      `mint!/2` RAISES without a `grantee: <principal URI>` (structural — there
      is NO code path that mints an unbound token; codex PR-3 blocking). The
      serve paths (authenticated `UploadsController`, public
      `ExternalFeedController`) read the binding back via `verify_payload/1` and
      REJECT any serving caller `!= grantee` — a leaked/copied token cannot be
      replayed by someone else. Only OLD already-issued (pre-PR-3) tokens carry
      no grantee; for those the serve path's legacy authorization applies
      unchanged (zero-breakage — the absent-grantee recheck exists ONLY on the
      read/serve side, never reachable from a new mint).
    * **verify NEVER uses `:infinity`** — `verify/1` enforces the per-token TTL
      against the embedded `issued_at`, under a finite 24h outer `Phoenix.Token`
      `max_age` ceiling. A token is rejected the moment `now > issued_at + ttl`.

  The TTL is enforced **in this module** against the payload's `issued_at`/`ttl`
  rather than via `Phoenix.Token`'s own `max_age` (which cannot read the per-token
  TTL before verifying). `Phoenix.Token`'s `max_age` is used only as the coarse
  24h outer bound so no token — whatever its embedded TTL — outlives the ceiling.

  ## Signing secret

  The MAC key is the application `secret_key_base`, read at runtime from
  `config :ezagent_core, #{inspect(__MODULE__)}, secret_key_base: <string>`
  (wired in `config/{dev,test,runtime}.exs` to the same value the web endpoint
  uses). `core` owns this config key, so the module names neither `:ezagent_web`
  nor `EzagentWeb.Endpoint` — keeping the layer boundary clean.
  """

  alias Ezagent.URI, as: EzURI

  @salt "ezagent.upload.v1"

  # 5 min — short TTL bounds the bearer-leak window (OI-1.1).
  @default_ttl 300

  # 24h hard ceiling — no token (whatever its requested TTL) outlives this.
  @max_ttl 86_400

  @typedoc "Decoded token payload (`:grantee` present only on person-bound tokens)."
  @type payload :: %{
          optional(:grantee) => String.t(),
          uri: String.t(),
          issued_at: integer(),
          ttl: pos_integer()
        }

  @typedoc "The verified serve payload a download controller authorizes against."
  @type serve_payload :: %{uri: URI.t(), grantee: URI.t() | nil}

  @doc "The default token TTL in seconds."
  @spec default_ttl() :: pos_integer()
  def default_ttl, do: @default_ttl

  @doc "The hard outer TTL ceiling in seconds (24h)."
  @spec max_ttl() :: pos_integer()
  def max_ttl, do: @max_ttl

  @doc """
  Mint a signed token bound to `uri` (a `resource://<ws>/uploads/<name>` URI).

  Options:

    * `:ttl_seconds` — token lifetime; defaults to `default_ttl/0`. Must be in
      `1..#{86_400}` (the 24h ceiling) — a non-positive or over-ceiling value
      raises `ArgumentError` (no accidental infinite token).
    * `:grantee` — REQUIRED person binding (read-plane PR-3): the `%URI{}`
      principal the authorizing mint issued this token to (the authorized
      caller). The serve paths reject any caller `!= grantee`. A missing or
      `nil` value raises `ArgumentError` — there is NO production code path
      that mints an unbound token. A non-`%URI{}` value also raises — a
      confused minting caller must fail LOUD at mint, not silently issue an
      unbound token.
    * `:__test_allow_nonpositive__` — TEST-ONLY escape hatch to mint an
      already-expired token (for the expiry regression test). Never use in
      production code.
    * `:__test_allow_unbound__` — TEST-ONLY escape hatch to mint a legacy
      (absent-grantee) token, standing in for an OLD already-issued pre-PR-3
      token so the serve-side zero-breakage recheck can be exercised. Never
      use in production code — a NEW token is ALWAYS person-bound.

  **The caller MUST authorize before minting** — this function is a pure signer.
  """
  @spec mint!(URI.t(), keyword()) :: String.t()
  def mint!(%URI{scheme: "resource"} = uri, opts \\ []) do
    # Defense in depth (codex MEDIUM): a download token must only ever name an
    # uploads resource — never a config-dir / other registered FsResolver type —
    # so the uploads download surface cannot be turned into a generic file reader
    # by a confused minting caller.
    unless EzURI.type?(uri, "uploads") do
      raise ArgumentError,
            "upload token URI must be a workspace-scoped uploads resource " <>
              "(type segment \"uploads\"); got #{inspect(uri)}"
    end

    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)
    allow_nonpositive = Keyword.get(opts, :__test_allow_nonpositive__, false)
    allow_unbound = Keyword.get(opts, :__test_allow_unbound__, false)
    grantee = Keyword.get(opts, :grantee)

    # Structural person binding (codex PR-3 blocking): a NEW token ALWAYS
    # carries a grantee. The only exempt mint is the test-only legacy hatch
    # below, which stands in for an OLD already-issued pre-PR-3 token.
    cond do
      match?(%URI{}, grantee) ->
        :ok

      is_nil(grantee) and allow_unbound ->
        :ok

      is_nil(grantee) ->
        raise ArgumentError,
              "upload token mint REQUIRES a :grantee %URI{} principal (read-plane " <>
                "PR-3: every NEW token is person-bound to the authorized caller; " <>
                "unbound tokens exist only as legacy already-issued tokens)"

      true ->
        raise ArgumentError,
              "upload token :grantee must be a %URI{} principal; got #{inspect(grantee)}"
    end

    cond do
      ttl > @max_ttl ->
        raise ArgumentError,
              "upload token TTL #{inspect(ttl)} exceeds the #{@max_ttl}s (24h) ceiling"

      ttl <= 0 and not allow_nonpositive ->
        raise ArgumentError, "upload token TTL must be positive; got #{inspect(ttl)}"

      true ->
        payload =
          %{
            uri: EzURI.stable_key(uri),
            issued_at: System.system_time(:second),
            ttl: ttl
          }
          |> maybe_put_grantee(grantee)

        # Phoenix.Token signs (HMAC) over the payload + its own timestamp; we read
        # back our embedded issued_at/ttl at verify, so the signing timestamp is
        # only the coarse 24h outer bound.
        Phoenix.Token.sign(key_base(), @salt, payload)
    end
  end

  # The grantee rides in the signed payload as its canonical string form; only a
  # present (%URI{}) grantee adds the key, so legacy (unbound) tokens keep their
  # exact pre-PR-3 payload shape.
  defp maybe_put_grantee(payload, nil), do: payload

  defp maybe_put_grantee(payload, %URI{} = grantee),
    do: Map.put(payload, :grantee, URI.to_string(grantee))

  @doc """
  Verify a token at the current time and return the bound URI.

  Returns `{:ok, %URI{}}` only when the MAC is valid AND the token is unexpired
  (`now <= issued_at + ttl`) AND within the 24h outer ceiling. Otherwise
  `{:error, :expired}` (TTL elapsed) or `{:error, reason}` (tampered / malformed).

  This drops the person binding — serve paths that enforce the PR-3 grantee
  check MUST use `verify_payload/1` instead.
  """
  @spec verify(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    verify_at(token, System.system_time(:second))
  end

  @doc """
  Like `verify/1` but returns the FULL serve payload: the bound `resource://`
  URI plus the OPTIONAL `grantee` principal (read-plane PR-3 person binding,
  `nil` on a legacy unbound token).
  """
  @spec verify_payload(String.t()) :: {:ok, serve_payload()} | {:error, term()}
  def verify_payload(token) when is_binary(token) do
    verify_payload_at(token, System.system_time(:second))
  end

  @doc """
  Like `verify/1` but evaluates expiry against `now` (a Unix second). The clock
  seam used by the expiry tests; `verify/1` delegates here with the real clock.
  `max_age` is ALWAYS the finite 24h ceiling — never `:infinity`.
  """
  @spec verify_at(String.t(), integer()) :: {:ok, URI.t()} | {:error, term()}
  def verify_at(token, now) when is_binary(token) and is_integer(now) do
    case verify_payload_at(token, now) do
      {:ok, %{uri: uri}} -> {:ok, uri}
      {:error, _} = err -> err
    end
  end

  @doc """
  The `verify_payload/1` clock seam (same contract as `verify_at/2`).
  """
  @spec verify_payload_at(String.t(), integer()) :: {:ok, serve_payload()} | {:error, term()}
  def verify_payload_at(token, now) when is_binary(token) and is_integer(now) do
    case Phoenix.Token.verify(key_base(), @salt, token, max_age: @max_ttl) do
      {:ok, %{uri: key, issued_at: issued_at, ttl: ttl} = payload}
      when is_binary(key) and is_integer(issued_at) and is_integer(ttl) ->
        if now <= issued_at + ttl do
          with {:ok, uri} <- decode_uri(key),
               {:ok, grantee} <- decode_grantee(Map.get(payload, :grantee)) do
            {:ok, %{uri: uri, grantee: grantee}}
          end
        else
          {:error, :expired}
        end

      {:ok, _malformed_payload} ->
        {:error, :malformed_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether `caller` IS the person `grantee` (the PR-3 serve-time binding check).
  Structural identity comparison on the canonical string form (the same
  `URI.to_string/1` equality the session participant checks use). Anything that
  is not a `%URI{}` pair is false — fail closed.
  """
  @spec grantee_match?(URI.t() | term(), URI.t() | term()) :: boolean()
  def grantee_match?(%URI{} = grantee, %URI{} = caller),
    do: URI.to_string(grantee) == URI.to_string(caller)

  def grantee_match?(_, _), do: false

  defp decode_uri(key) do
    {:ok, EzURI.new!(key)}
  rescue
    ArgumentError -> {:error, :malformed_uri}
  end

  # Absent `:grantee` key (a pre-PR-3 token) → unbound (legacy); a present key
  # must decode to a principal URI or the token is malformed.
  defp decode_grantee(nil), do: {:ok, nil}

  defp decode_grantee(key) when is_binary(key) do
    {:ok, EzURI.new!(key)}
  rescue
    ArgumentError -> {:error, :malformed_grantee}
  end

  defp decode_grantee(_other), do: {:error, :malformed_grantee}

  # The MAC key base — the application `secret_key_base`, owned by core config.
  # A `Phoenix.Token` context can be a binary `secret_key_base` (>= 20 bytes),
  # which keeps this module free of any `EzagentWeb.Endpoint` reference.
  defp key_base do
    case Application.get_env(:ezagent_core, __MODULE__, []) |> Keyword.get(:secret_key_base) do
      base when is_binary(base) and byte_size(base) >= 20 ->
        base

      _ ->
        raise """
        no :secret_key_base configured for #{inspect(__MODULE__)}.

        Add to config (wired to the same value as the web endpoint):

            config :ezagent_core, #{inspect(__MODULE__)},
              secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
        """
    end
  end
end
