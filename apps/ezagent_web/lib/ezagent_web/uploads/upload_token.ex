defmodule EzagentWeb.Uploads.UploadToken do
  @moduledoc """
  Signed capability download token for chat uploads (Resource-unification
  SPEC §6 P2a / OI-1 DECISION).

  S3-presigned-URL style: a MAC-signed bearer token that encodes the **full
  ws-scoped** `resource://<ws>/uploads/<name>` URI plus its issue time and TTL.
  It replaces the participation-based `GET /files/:filename` authorization so the
  external React customer-feed (#601/#603) — whose viewers have NO session/caps —
  can be served attachments via a capability the operator/feed minted, while the
  internal operator/session path mints the same token after a live cap-check.

  ## Security properties (all REQUIRED by OI-1)

    * **short TTL** — `@default_ttl` (#{div(300, 60)} min) bounds the bearer-leak
      window. `mint!/2` rejects a non-positive TTL (no accidental infinite token)
      and a TTL above the **24h hard ceiling** (`@max_ttl`).
    * **bound to one URI** — the token payload carries the URI's `stable_key`, so
      a token minted for `resource://acme/uploads/f.pdf` verifies to *exactly*
      that URI and cannot be replayed against `resource://victim/uploads/f.pdf`
      (workspace isolation) or any other file.
    * **minted only after authorization** — this module does NOT itself authorize;
      the caller (controller mint endpoint / customer-feed) MUST authorize before
      calling `mint!/2`. See `EzagentWeb.UploadsController` (internal cap-check)
      and the customer-feed approved-only gate.
    * **verify NEVER uses `:infinity`** — `verify/1` enforces the per-token TTL
      against the embedded `issued_at`, under a finite 24h outer `Phoenix.Token`
      `max_age` ceiling. A token is rejected the moment `now > issued_at + ttl`.

  The TTL is enforced **in this module** against the payload's `issued_at`/`ttl`
  rather than via `Phoenix.Token`'s own `max_age` (which cannot read the per-token
  TTL before verifying). `Phoenix.Token`'s `max_age` is used only as the coarse
  24h outer bound so no token — whatever its embedded TTL — outlives the ceiling.
  """

  alias Ezagent.URI, as: EzURI

  @salt "ezagent.upload.v1"

  # 5 min — short TTL bounds the bearer-leak window (OI-1.1).
  @default_ttl 300

  # 24h hard ceiling — no token (whatever its requested TTL) outlives this.
  @max_ttl 86_400

  @typedoc "Decoded token payload."
  @type payload :: %{uri: String.t(), issued_at: integer(), ttl: pos_integer()}

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
    * `:__test_allow_nonpositive__` — TEST-ONLY escape hatch to mint an
      already-expired token (for the expiry regression test). Never use in
      production code.

  **The caller MUST authorize before minting** — this function is a pure signer.
  """
  @spec mint!(URI.t(), keyword()) :: String.t()
  def mint!(%URI{scheme: "resource"} = uri, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)
    allow_nonpositive = Keyword.get(opts, :__test_allow_nonpositive__, false)

    cond do
      ttl > @max_ttl ->
        raise ArgumentError,
              "upload token TTL #{inspect(ttl)} exceeds the #{@max_ttl}s (24h) ceiling"

      ttl <= 0 and not allow_nonpositive ->
        raise ArgumentError, "upload token TTL must be positive; got #{inspect(ttl)}"

      true ->
        payload = %{
          uri: EzURI.stable_key(uri),
          issued_at: System.system_time(:second),
          ttl: ttl
        }

        # Phoenix.Token signs (HMAC) over the payload + its own timestamp; we read
        # back our embedded issued_at/ttl at verify, so the signing timestamp is
        # only the coarse 24h outer bound.
        Phoenix.Token.sign(EzagentWeb.Endpoint, @salt, payload)
    end
  end

  @doc """
  Verify a token at the current time and return the bound URI.

  Returns `{:ok, %URI{}}` only when the MAC is valid AND the token is unexpired
  (`now <= issued_at + ttl`) AND within the 24h outer ceiling. Otherwise
  `{:error, :expired}` (TTL elapsed) or `{:error, reason}` (tampered / malformed).
  """
  @spec verify(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    verify_at(token, System.system_time(:second))
  end

  @doc """
  Like `verify/1` but evaluates expiry against `now` (a Unix second). The clock
  seam used by the expiry tests; `verify/1` delegates here with the real clock.
  `max_age` is ALWAYS the finite 24h ceiling — never `:infinity`.
  """
  @spec verify_at(String.t(), integer()) :: {:ok, URI.t()} | {:error, term()}
  def verify_at(token, now) when is_binary(token) and is_integer(now) do
    case Phoenix.Token.verify(EzagentWeb.Endpoint, @salt, token, max_age: @max_ttl) do
      {:ok, %{uri: key, issued_at: issued_at, ttl: ttl}}
      when is_binary(key) and is_integer(issued_at) and is_integer(ttl) ->
        if now <= issued_at + ttl do
          decode_uri(key)
        else
          {:error, :expired}
        end

      {:ok, _malformed_payload} ->
        {:error, :malformed_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_uri(key) do
    {:ok, EzURI.new!(key)}
  rescue
    ArgumentError -> {:error, :malformed_uri}
  end
end
