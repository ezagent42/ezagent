defmodule Ezagent.Socialware.CustomerAuth do
  @moduledoc """
  Session-bound customer feed tokens.

  Tokens bind exactly one session URI and one workspace URI. Feed callers
  authorize before visibility gating.
  """

  @salt "socialware customer feed v1"
  @default_ttl_ms 60 * 60 * 1000

  @spec issue_token(URI.t(), URI.t() | String.t(), keyword()) :: String.t()
  def issue_token(%URI{} = session_uri, workspace_uri, opts \\ []) do
    now_ms = System.system_time(:millisecond)
    ttl_ms = Keyword.get(opts, :expires_in_ms, @default_ttl_ms)
    session_str = uri_to_string(session_uri)

    payload = %{
      "session_uri" => session_str,
      "workspace_uri" => uri_to_string(workspace_uri),
      "expires_at_ms" => now_ms + ttl_ms
    }

    Phoenix.Token.sign(secret_key_base!(), @salt, payload)
  end

  @spec authorize(String.t(), URI.t(), URI.t() | String.t()) :: :ok | {:error, :unauthorized}
  def authorize(token, %URI{} = session_uri, workspace_uri) when is_binary(token) do
    session_str = uri_to_string(session_uri)

    with {:ok, payload} <-
           Phoenix.Token.verify(secret_key_base!(), @salt, token, max_age: :infinity),
         true <- Map.fetch!(payload, "session_uri") == session_str,
         true <- Map.fetch!(payload, "workspace_uri") == uri_to_string(workspace_uri),
         true <- Map.fetch!(payload, "expires_at_ms") > System.system_time(:millisecond) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_token, _session_uri, _workspace_uri), do: {:error, :unauthorized}

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(uri) when is_binary(uri), do: uri

  defp secret_key_base! do
    :ezagent_web
    |> Application.fetch_env!(EzagentWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
