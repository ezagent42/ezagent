defmodule EzagentWeb.Socialware.AnonCookie do
  @moduledoc """
  The signed `socialware_anon` visitor cookie for issue #51 (design §6 / §4.1).

  An anonymous visitor to a `public_view` socialware session is minted a read-only
  anon-User (`Ezagent.Socialware.AnonUser`). To recognise the SAME visitor on a
  return visit without a server-side session, the controller drops a cookie. The
  cookie is the integrity-checked *handle* to the visitor's anon identity — it is
  **not** itself the authorization (the live `ChatFeedAuth` token + membership read
  decide that; see `Ezagent.Socialware.ChatFeed`).

  ## What is signed

  The cookie value is a `Phoenix.Token.sign/4` payload (the endpoint
  `secret_key_base`, exactly the signing key `ChatFeedAuth` uses) carrying ONLY:

      %{"external_user_name" => <the anon-User's name segment>,
        "session_uri"        => <the public session it views>}

  It deliberately does NOT carry the full anon `entity://` URI or a stored token.
  The full URI is RECONSTRUCTED on verify from `{external_user_name, session_uri}`:
  the anon-User always lives in the viewed session's workspace
  (`Ezagent.Socialware.AnonUser.mint/1` derives the workspace from `session_uri`),
  so `entity://<workspace_of(session_uri)>/user/<external_user_name>` rebuilds the
  exact URI that was minted. The `AnonBinding` table is keyed by that `entity_uri`,
  so resolution is "verify cookie → reconstruct entity URI → look it up", with no
  cookie secret persisted (reconciling design OQ-4's `cookie_id_hash` sketch with §6).

  ## Fail-closed verification

  `verify/2` returns `{:ok, anon_user_uri}` ONLY when the signature is intact AND
  the cookie's bound `session_uri` equals the session being requested AND the
  reconstructed URI is a well-formed anon-User URI (`AnonUser.anon_uri?/1`). A
  tampered value, a value signed with another key, a stale value, a value bound to a
  DIFFERENT session, or a reconstructed-non-anon URI all return `:error` — the caller
  treats that as "no cookie" and mints a fresh anon identity. An unsigned/tampered
  cookie can therefore NEVER resolve to an identity (security property #6).

  ## Scope (this unit)

  One binding per cookie: `{external_user_name, session_uri}`. The multi-binding map
  (a visitor browsing several public sessions keeping one anon-User per session,
  design OQ-11) is a deliberate later #51 unit — NOT built here.
  """

  alias Ezagent.Socialware.AnonUser

  @cookie_name "socialware_anon"
  @salt "socialware anon visitor v1"

  @doc "The cookie name dropped on the response / read from the request."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @doc """
  Sign a `{external_user_name, session_uri}` cookie value for `anon_user_uri` on
  `session_uri`. `anon_user_uri` MUST be an anon-User URI minted for `session_uri`'s
  workspace; otherwise the call fails closed (`{:error, _}`) so a non-anon principal
  can never receive an anon cookie.
  """
  @spec sign(URI.t(), URI.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(%URI{} = anon_user_uri, %URI{scheme: "session"} = session_uri) do
    with true <- AnonUser.anon_uri?(anon_user_uri),
         {:ok, name} <- Ezagent.URI.name(anon_user_uri),
         :ok <- same_workspace(anon_user_uri, session_uri) do
      payload = %{
        "external_user_name" => name,
        "session_uri" => URI.to_string(session_uri)
      }

      {:ok, Phoenix.Token.sign(secret_key_base!(), @salt, payload)}
    else
      _ -> {:error, :not_anon_user}
    end
  end

  def sign(_anon_user_uri, _session_uri), do: {:error, :not_a_session}

  @doc """
  Verify a cookie `value` against the requested `session_uri` and recover the bound
  anon-User `%URI{}`.

  Returns `{:ok, anon_user_uri}` only on an intact signature whose `session_uri`
  matches the requested session and whose reconstructed URI is a well-formed
  anon-User; `:error` otherwise (treated as "no cookie" → mint fresh). Never raises.
  """
  @spec verify(term(), URI.t()) :: {:ok, URI.t()} | :error
  def verify(value, %URI{scheme: "session"} = session_uri) when is_binary(value) do
    session_str = URI.to_string(session_uri)

    with {:ok, payload} <-
           Phoenix.Token.verify(secret_key_base!(), @salt, value, max_age: :infinity),
         %{"external_user_name" => name, "session_uri" => ^session_str}
         when is_binary(name) <- payload,
         {:ok, anon_uri} <- reconstruct(name, session_uri),
         true <- AnonUser.anon_uri?(anon_uri) do
      {:ok, anon_uri}
    else
      _ -> :error
    end
  end

  def verify(_value, _session_uri), do: :error

  # Rebuild the anon-User URI from its name + the session's workspace. This MUST
  # mirror `AnonUser.mint/1` (workspace derived from the session) so the rebuilt URI
  # is byte-identical to the minted one — the AnonBinding PK.
  defp reconstruct(name, session_uri) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, workspace_name} ->
        {:ok, Ezagent.URI.entity(workspace_name, :user, name)}

      :error ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp same_workspace(anon_user_uri, session_uri) do
    with %URI{} = aws <- workspace_of(anon_user_uri),
         %URI{} = sws <- workspace_of(session_uri),
         true <- URI.to_string(aws) == URI.to_string(sws) do
      :ok
    else
      _ -> :error
    end
  end

  defp workspace_of(uri) do
    case Ezagent.URI.workspace_of(uri) do
      %URI{} = ws -> ws
      _ -> :error
    end
  end

  defp secret_key_base! do
    :ezagent_web
    |> Application.fetch_env!(EzagentWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
