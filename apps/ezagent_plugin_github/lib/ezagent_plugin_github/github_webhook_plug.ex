defmodule EzagentPluginGithub.GitHubWebhookPlug do
  @moduledoc """
  HTTP entry point for GitHub App webhook deliveries.

  Reads the RAW request body, verifies the `X-Hub-Signature-256` HMAC against the
  configured `webhook_secret` (`EzagentPluginGithub.GitHubWebhookVerifier`), and
  acknowledges valid deliveries. Invalid or unsigned deliveries are rejected with
  `401` and the pipeline is halted.

  > This plug MUST run before any `Plug.Parsers` that would consume the body, so
  > the HMAC is computed over the exact bytes GitHub signed. When mounting it (via
  > `forward` in the host router, alongside the OAuth callback plug), place it
  > ahead of body parsing for its path.

  Event dispatch (acting on the verified payload) is intentionally out of scope
  here — this plug provides the signature-verification boundary; a verified
  delivery is acknowledged with `202 Accepted`.
  """
  import Plug.Conn

  alias EzagentPluginGithub.{Config, GitHubWebhookVerifier}

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    {:ok, raw_body, conn} = read_body(conn)
    signature = conn |> get_req_header("x-hub-signature-256") |> List.first()

    case GitHubWebhookVerifier.verify(raw_body, signature, Config.webhook_secret()) do
      :ok ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(202, "Accepted")

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Invalid signature")
        |> halt()
    end
  end
end
