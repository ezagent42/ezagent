defmodule EzagentPluginGithub.GitHubCallbackPlug do
  @moduledoc """
  OAuth callback HTTP endpoint for GitHub authorization.

  Receives GET `/github/callback?code=...&state=...` from GitHub's OAuth
  redirect, extracts the `code` and `state` query parameters, and dispatches
  them to `Ezagent.ProviderConnection.CallbackIngress.consume/3` for
  processing.

  ## Response

    - 200 with plain text success message on successful authorization
    - 400 with error description on authorization failure or missing params
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%{params: %{"code" => code, "state" => state}} = conn, _opts) do
    case callback_ingress().consume("github-oauth", state, %{code: code}) do
      {:ok, _receipt} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "GitHub authorization complete. You may close this page.")

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Authorization failed: #{reason}")
    end
  end

  @doc false
  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Missing code or state parameter")
  end

  defp callback_ingress do
    Application.get_env(
      :ezagent_plugin_github,
      :callback_ingress_module,
      Ezagent.ProviderConnection.CallbackIngress
    )
  end
end
