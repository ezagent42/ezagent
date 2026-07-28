defmodule Ezagent.Cap.ShareToken do
  @moduledoc """
  Signed **bearer** share token for the unified URI-share primitive (A1).

  Sibling of `Ezagent.Uploads.DownloadToken`: same `Phoenix.Token` MAC signer +
  core-owned `secret_key_base` (so both `ezagent_web` claim controllers AND
  plugins can mint/verify the SAME token without depending on `ezagent_web` —
  three-tier isolation), and the same safety envelope (short TTL, 24h ceiling,
  one-target binding, expiry + tamper rejection).

  It differs from `DownloadToken` in exactly the two ways a **share link** needs:

    * **bearer, not person-bound.** A share link is minted before the clicker is
      known, so — unlike `DownloadToken` (which REQUIRES a `:grantee` and rejects
      an unbound mint) — this token carries NO grantee. The `/socialware/claim`
      landing binds it: grantee = the authenticated clicker, then mints a
      grantee-bound cap via `CompositionCaps.mint_cap/4` (cap-as-truth `甲`:
      bearer → mint). The token is the share-time credential; authorization
      happens on the MINT side (the sharer must have access to sign a link) — this
      module is a pure signer, exactly like `DownloadToken`.
    * **URI-agnostic + intent-carrying.** The payload names ANY `target` URI
      (`entity://` agent, `session://`, `resource://` …) — NOT type-locked to
      `uploads` — plus the `behavior` (ActionSet) and `actions` (read / operate)
      the link grants, so the claim landing knows exactly which cap to mint.

  ## Signing secret

  The MAC key is the application `secret_key_base`, read at runtime from
  `config :ezagent_core, #{inspect(__MODULE__)}, secret_key_base: <string>`
  (wired to the same value the web endpoint uses). `core` owns this key, so the
  module names neither `:ezagent_web` nor `EzagentWeb.Endpoint`.
  """

  alias Ezagent.URI, as: EzURI

  @salt "ezagent.share.v1"

  # 7 days — a share link lives longer than a 5-min download token: it gets
  # pasted into chat/email and re-opened later. Still bounded (30-day ceiling).
  @default_ttl 604_800

  # 30-day hard ceiling — no share link (whatever its requested TTL) outlives it.
  @max_ttl 2_592_000

  @typedoc "The verified share payload the claim landing mints a cap from."
  @type share_payload :: %{
          target: URI.t(),
          behavior: module(),
          actions: [atom()],
          issuer: URI.t()
        }

  @doc "The default share-link TTL in seconds (7 days)."
  @spec default_ttl() :: pos_integer()
  def default_ttl, do: @default_ttl

  @doc "The hard outer TTL ceiling in seconds (30 days)."
  @spec max_ttl() :: pos_integer()
  def max_ttl, do: @max_ttl

  @doc """
  Mint a signed BEARER share link: `issuer` shares `target` (any URI), granting
  `behavior`'s `actions` to whoever claims it.

  `issuer` is the identity that authorized the link — carried in the signed
  payload so the claim side can verify the issuer actually held delegable
  authority on `target` (granter ≡ data_owner). A bearer token that names only
  `target`/`behavior`/`actions` (no issuer) would let any holder of a
  server-signed link mint authority its creator never held — so the issuer is
  REQUIRED and MAC-bound here.

  Options: `:ttl_seconds` — defaults to `default_ttl/0`; must be in
  `1..#{2_592_000}` (the 30-day ceiling; a non-positive or over-ceiling value
  raises).

  `actions` must be a non-empty list (a link with no intent is meaningless →
  raises). **The producer MUST verify `issuer` is authorized to delegate on
  `target` before calling this** (use `Ezagent.Socialware.Share.mint_link/4`,
  which does) — this function is a pure signer that only binds the issuer into
  the MAC; the claim side re-verifies against current authority.
  """
  @spec mint_link!(URI.t(), URI.t(), module(), [atom()], keyword()) :: String.t()
  def mint_link!(%URI{} = issuer, %URI{} = target, behavior, actions, opts \\ [])
      when is_atom(behavior) and is_list(actions) do
    if actions == [] do
      raise ArgumentError, "share token REQUIRES a non-empty actions list (the link's intent)"
    end

    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)

    cond do
      ttl > @max_ttl ->
        raise ArgumentError,
              "share token TTL #{inspect(ttl)} exceeds the #{@max_ttl}s (30d) ceiling"

      ttl <= 0 ->
        raise ArgumentError, "share token TTL must be positive; got #{inspect(ttl)}"

      true ->
        payload = %{
          issuer: EzURI.stable_key(issuer),
          target: EzURI.stable_key(target),
          behavior: Atom.to_string(behavior),
          actions: Enum.map(actions, &Atom.to_string/1),
          issued_at: System.system_time(:second),
          ttl: ttl
        }

        Phoenix.Token.sign(Ezagent.Cap.TokenSecret.key_base!(__MODULE__), @salt, payload)
    end
  end

  @doc """
  Verify a share link at the current time. Returns `{:ok, %{issuer, target,
  behavior, actions}}` only when the MAC is valid AND unexpired AND within the
  ceiling; otherwise `{:error, :expired}` or `{:error, reason}`. The `issuer`
  is the MAC-bound link author the claim side re-authorizes against `target`.
  """
  @spec verify_link(String.t()) :: {:ok, share_payload()} | {:error, term()}
  def verify_link(token) when is_binary(token) do
    verify_link_at(token, System.system_time(:second))
  end

  @doc "Like `verify_link/1` but evaluates expiry against `now` (a Unix second). Clock seam for tests."
  @spec verify_link_at(String.t(), integer()) :: {:ok, share_payload()} | {:error, term()}
  def verify_link_at(token, now) when is_binary(token) and is_integer(now) do
    case Phoenix.Token.verify(Ezagent.Cap.TokenSecret.key_base!(__MODULE__), @salt, token,
           max_age: @max_ttl
         ) do
      {:ok,
       %{
         issuer: issuer,
         target: target,
         behavior: behavior,
         actions: actions,
         issued_at: issued_at,
         ttl: ttl
       }}
      when is_binary(issuer) and is_binary(target) and is_binary(behavior) and is_list(actions) and
             is_integer(issued_at) and is_integer(ttl) ->
        if now <= issued_at + ttl do
          decode(issuer, target, behavior, actions)
        else
          {:error, :expired}
        end

      {:ok, _malformed} ->
        {:error, :malformed_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(issuer_key, target_key, behavior_str, action_strs) do
    with {:ok, issuer} <- decode_target(issuer_key),
         {:ok, target} <- decode_target(target_key),
         {:ok, actions} <- decode_actions(action_strs) do
      # Module.concat builds the ActionSet atom (same signed-payload convention as
      # kanban's share behavior); mint-side validates it against the real module.
      {:ok,
       %{
         issuer: issuer,
         target: target,
         behavior: Module.concat([behavior_str]),
         actions: actions
       }}
    end
  end

  defp decode_target(key) do
    {:ok, EzURI.new!(key)}
  rescue
    ArgumentError -> {:error, :malformed_target}
  end

  # actions were minted from real action atoms; `to_existing_atom` keeps a
  # tampered/unknown action from conjuring a new atom (the MAC already blocks
  # tampering, this is defense in depth).
  defp decode_actions(strs) do
    {:ok, Enum.map(strs, &String.to_existing_atom/1)}
  rescue
    ArgumentError -> {:error, :malformed_actions}
  end
end
