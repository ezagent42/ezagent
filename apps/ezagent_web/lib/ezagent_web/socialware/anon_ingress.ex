defmodule EzagentWeb.Socialware.AnonIngress do
  @moduledoc """
  HTTP/cookie shim for anonymous socialware ingress.

  The domain admission primitive lives in `Ezagent.Socialware.AnonAdmission`.
  This module only handles web concerns: optional signed-in principal recovery,
  signed anon visitor cookies, cold session wake-up, and response cookie writing.
  """

  import Plug.Conn,
    only: [
      fetch_cookies: 1,
      get_session: 2,
      put_resp_cookie: 4
    ]

  alias Ezagent.Socialware.{AnonAdmission, ChatFeedAuth, PublicView}
  alias EzagentWeb.Socialware.AnonCookie

  @type source :: :authenticated | :anonymous_minted | :anonymous_reused
  @type result :: %{caller: URI.t(), source: source(), token: String.t()}

  @doc """
  Resolve the caller for a public socialware feed request.

  Signed-in users are returned unchanged. Anonymous visitors are admitted only
  when the session is public, using the signed anon cookie if it is valid and
  falling back to a fresh anon identity when reuse fails.
  """
  @spec resolve_caller(Plug.Conn.t(), URI.t(), keyword()) ::
          {:ok, Plug.Conn.t(), result()} | {:error, term()}
  def resolve_caller(conn, session_uri, opts \\ [])

  def resolve_caller(conn, %URI{scheme: "session"} = session_uri, opts) do
    case optional_current_entity(conn) do
      %URI{} = principal_uri ->
        {:ok, conn, result(principal_uri, session_uri, :authenticated)}

      nil ->
        resolve_anonymous(conn, session_uri, opts)
    end
  end

  def resolve_caller(_conn, other, _opts), do: {:error, {:not_a_session, other}}

  @doc """
  Recover a signed-in principal from a public route without redirecting.
  """
  @spec optional_current_entity(Plug.Conn.t()) :: URI.t() | nil
  def optional_current_entity(conn) do
    case get_session(conn, :current_entity_uri) do
      uri_str when is_binary(uri_str) ->
        parse_public_entity(uri_str)

      _ ->
        nil
    end
  end

  defp resolve_anonymous(conn, session_uri, opts) do
    _ = Ezagent.SpawnRegistry.ensure_live(session_uri)

    if PublicView.web_anon_access?(session_uri) do
      conn
      |> read_valid_cookie(session_uri)
      |> case do
        {:ok, anon_uri} -> reuse_or_mint(conn, session_uri, anon_uri, opts)
        :error -> mint_fresh(conn, session_uri, opts)
      end
    else
      {:error, :login_required}
    end
  end

  defp reuse_or_mint(conn, session_uri, anon_uri, opts) do
    case AnonAdmission.refresh_anonymous_participant(session_uri, anon_uri, opts) do
      {:ok, %{anon_uri: caller}} ->
        {:ok, conn, result(caller, session_uri, :anonymous_reused)}

      {:error, _reason} ->
        mint_fresh(conn, session_uri, opts)
    end
  end

  defp mint_fresh(conn, session_uri, opts) do
    with {:ok, %{anon_uri: anon_uri}} <-
           AnonAdmission.admit_anonymous_participant(session_uri, opts),
         {:ok, cookie_value} <- AnonCookie.sign(anon_uri, session_uri) do
      conn = put_anon_cookie(conn, cookie_value)
      {:ok, conn, result(anon_uri, session_uri, :anonymous_minted)}
    end
  end

  defp result(caller_uri, session_uri, source) do
    %{
      caller: caller_uri,
      source: source,
      token: ChatFeedAuth.issue_token(caller_uri, session_uri)
    }
  end

  defp parse_public_entity(uri_str) do
    case Ezagent.URI.new!(uri_str) do
      %URI{} = uri ->
        if Ezagent.URI.scheme?(uri, :entity) and
             match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri)) do
          uri
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp read_valid_cookie(conn, session_uri) do
    conn = fetch_cookies(conn)

    case Map.get(conn.cookies, AnonCookie.cookie_name()) do
      value when is_binary(value) -> AnonCookie.verify(value, session_uri)
      _ -> :error
    end
  end

  defp put_anon_cookie(conn, value) do
    put_resp_cookie(conn, AnonCookie.cookie_name(), value,
      http_only: true,
      secure: conn.scheme == :https,
      same_site: "Lax"
    )
  end
end
