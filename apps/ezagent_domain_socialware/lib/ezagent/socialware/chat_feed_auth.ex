defmodule Ezagent.Socialware.ChatFeedAuth do
  @moduledoc """
  P4 — caller-identity tokens for the chat-feed external SPA.

  Unlike `CustomerAuth` (which binds a customer to a socialware session with NO
  identity — the customer is anonymous-but-token-bound), a chat session's
  external viewers are its MEMBERS, so the chat-feed token carries the caller's
  **identity** (`entity://...` URI), signed by the server. The channel verifies
  the token to recover a TRUSTED caller `%URI{}`, then the LIVE chat membership
  predicate (`ChatMembership`, the SAME one as P3-3) decides whether that caller
  may read the session.

  The token only binds `{caller_uri, session_uri}` and proves the SERVER minted
  it for that caller on that session (an authenticated page mints it for its
  signed-in principal). It is NOT itself the authorization — membership is
  re-checked LIVE on every join/replay, so a token held by an ex-member is
  useless once they leave (no token revocation needed).
  """

  @salt "socialware chat feed caller v1"
  @default_ttl_ms 60 * 60 * 1000

  @doc """
  Mint a token binding `caller_uri` (the signed-in principal) to `session_uri`.
  The server is the only minter, so the token cannot be forged to impersonate
  another caller.
  """
  @spec issue_token(URI.t(), URI.t(), keyword()) :: String.t()
  def issue_token(%URI{} = caller_uri, %URI{} = session_uri, opts \\ []) do
    now_ms = System.system_time(:millisecond)
    ttl_ms = Keyword.get(opts, :expires_in_ms, @default_ttl_ms)
    caller_str = uri_to_string(caller_uri)
    session_str = uri_to_string(session_uri)

    payload = %{
      "caller_uri" => caller_str,
      "session_uri" => session_str,
      "expires_at_ms" => now_ms + ttl_ms
    }

    Phoenix.Token.sign(secret_key_base!(), @salt, payload)
  end

  @doc """
  Verify a token for `session_uri` and recover the TRUSTED caller `%URI{}` the
  server minted it for. Returns `{:ok, caller_uri}` | `{:error, :unauthorized}`.
  Does NOT decide membership — the caller authorization is the LIVE
  `ChatMembership` check the channel runs next.
  """
  @spec verify(String.t(), URI.t()) :: {:ok, URI.t()} | {:error, :unauthorized}
  def verify(token, %URI{} = session_uri) when is_binary(token) do
    session_str = uri_to_string(session_uri)

    with {:ok, payload} <-
           Phoenix.Token.verify(secret_key_base!(), @salt, token, max_age: :infinity),
         true <- Map.fetch!(payload, "session_uri") == session_str,
         true <- Map.fetch!(payload, "expires_at_ms") > System.system_time(:millisecond),
         {:ok, caller_uri} <- parse_caller(Map.fetch!(payload, "caller_uri")) do
      {:ok, caller_uri}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify(_token, _session_uri), do: {:error, :unauthorized}

  defp parse_caller(str) when is_binary(str) do
    case Ezagent.URI.new!(str) do
      %URI{} = uri -> {:ok, uri}
    end
  rescue
    ArgumentError -> {:error, :unauthorized}
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)

  defp secret_key_base! do
    :ezagent_web
    |> Application.fetch_env!(EzagentWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
