defmodule Ezagent.Cap.ShareToken do
  @moduledoc """
  Signed **stateless pointer** to a shared target — URI-share unification (A1).

  A share link is just a tamper-resistant, expiring pointer at a `target` URI. It
  carries NO authority and NO grant intent: whether it grants anything, to whom,
  and what, is decided at claim time by the target's **sharing setting**
  (`Ezagent.Socialware.ShareSetting`), which only the target's owner can turn on.
  So the link is dumb (like a document URL); the resource-side setting is the
  authority and the on/off switch (codex M1 authority + D3 revocation both live
  there, not here).

  Sibling of `Ezagent.Uploads.DownloadToken`: same `Phoenix.Token` MAC signer +
  core-owned `secret_key_base` (so both `ezagent_web` claim controllers AND
  plugins mint/verify the SAME token without depending on `ezagent_web`), same
  safety envelope (short TTL, 30-day ceiling, one-target binding, expiry + tamper
  rejection). Reusable by design: any holder may claim until it expires or the
  target's sharing setting is turned off.

  ## Signing secret

  The MAC key is the application `secret_key_base`, read at runtime from
  `config :ezagent_core, #{inspect(__MODULE__)}, secret_key_base: <string>`
  (wired to the same value the web endpoint uses). `core` owns this key, so the
  module names neither `:ezagent_web` nor `EzagentWeb.Endpoint`.
  """

  alias Ezagent.URI, as: EzURI

  @salt "ezagent.share.v1"

  # 7 days default — a share link gets pasted into chat/email and re-opened
  # later. Still bounded (30-day ceiling).
  @default_ttl 604_800
  @max_ttl 2_592_000

  @typedoc "The verified pointer the claim landing resolves the target from."
  @type share_payload :: %{target: URI.t()}

  @doc "The default share-link TTL in seconds (7 days)."
  @spec default_ttl() :: pos_integer()
  def default_ttl, do: @default_ttl

  @doc "The hard outer TTL ceiling in seconds (30 days)."
  @spec max_ttl() :: pos_integer()
  def max_ttl, do: @max_ttl

  @doc """
  Mint a signed share link pointing at `target` (any URI). Options: `:ttl_seconds`
  (defaults to `default_ttl/0`; must be in `1..#{2_592_000}` — a non-positive or
  over-ceiling value raises `ArgumentError`).

  The link carries no authority — it only names the target. It grants nothing
  unless the target's `Ezagent.Socialware.ShareSetting` is enabled at claim time.
  """
  @spec mint_link!(URI.t(), keyword()) :: String.t()
  def mint_link!(%URI{} = target, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)

    cond do
      ttl > @max_ttl ->
        raise ArgumentError,
              "share token TTL #{inspect(ttl)} exceeds the #{@max_ttl}s (30d) ceiling"

      ttl <= 0 ->
        raise ArgumentError, "share token TTL must be positive; got #{inspect(ttl)}"

      true ->
        payload = %{
          target: EzURI.stable_key(target),
          issued_at: System.system_time(:second),
          ttl: ttl
        }

        Phoenix.Token.sign(Ezagent.Cap.TokenSecret.key_base!(__MODULE__), @salt, payload)
    end
  end

  @doc """
  Verify a share link at the current time. Returns `{:ok, %{target}}` only when
  the MAC is valid AND unexpired AND within the ceiling; otherwise
  `{:error, :expired}` or `{:error, reason}`.
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
      {:ok, %{target: target, issued_at: issued_at, ttl: ttl}}
      when is_binary(target) and is_integer(issued_at) and is_integer(ttl) ->
        if now <= issued_at + ttl do
          decode(target)
        else
          {:error, :expired}
        end

      {:ok, _malformed} ->
        {:error, :malformed_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(target_key) do
    {:ok, %{target: EzURI.new!(target_key)}}
  rescue
    ArgumentError -> {:error, :malformed_target}
  end
end
