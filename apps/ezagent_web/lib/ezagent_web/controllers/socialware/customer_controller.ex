defmodule EzagentWeb.Socialware.CustomerController do
  @moduledoc """
  Public entrypoint for the socialware customer SPA.

  The page authenticates the session-binding token before bootstrapping the
  browser app. Live updates then flow through `CustomerSocket`, which repeats
  the same scoped authorization.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.CustomerFeed
  alias Ezagent.Uploads.DownloadToken

  @doc """
  External customer-feed attachment download (Resource-unification P2a / OI-1).

  Public (no `RequireEntity`) — a feed viewer has no session/caps. Authorization
  is entirely capability-based:

    * `token` — the customer-feed session token (`CustomerAuth`), proving access
      to `session_uri`;
    * `file_token` — the signed `DownloadToken`, binding the exact ws-scoped
      `resource://<ws>/uploads/<name>` URI;

  and `CustomerFeed.authorized_attachment_path/4` re-validates that the attachment
  is STILL an approved (committed, customer-visible) item before resolving — so a
  captured token stops working once an operator flips the message back to
  operator-only (serve-time revocation, codex HIGH). Fails closed on any
  missing/invalid input.
  """
  def download(conn, %{
        "session_uri" => session_str,
        "token" => token,
        "file_token" => file_token
      })
      when is_binary(token) and is_binary(file_token) do
    with {:ok, session_uri} <- parse_session(session_str),
         {:ok, upload_uri} <- DownloadToken.verify(file_token),
         {:ok, path} <-
           CustomerFeed.authorized_attachment_path(
             session_uri,
             token,
             upload_uri,
             &Ezagent.Uploads.resolve/2
           ),
         true <- File.regular?(path) do
      send_download(conn, {:file, path}, filename: download_name(upload_uri))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "unauthorized")
    end
  end

  def download(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "missing session_uri, token or file_token")
  end

  def show(conn, %{"session_uri" => session_str, "token" => token}) do
    with {:ok, session_uri} <- parse_session(session_str),
         {:ok, _snapshot} <- CustomerFeed.snapshot(session_uri, token) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, page(session_uri, token))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "unauthorized")
    end
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "missing session_uri or token")
  end

  defp parse_session(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session(_value), do: :error

  defp page(session_uri, token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)

    """
    <!doctype html>
    <html lang="en" data-theme="customer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware Customer</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
        <link rel="stylesheet" href="/assets/css/customer.css">
        <script defer type="module" src="/assets/js/customer_app.js"></script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content antialiased">
        <main id="socialware-customer-root" class="block min-h-screen w-full px-4 py-8 sm:py-12" data-session-uri="#{session}" data-token="#{token}"></main>
      </body>
    </html>
    """
  end

  defp escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)

  # Content-Disposition filename for the download — the stored `<uuid>-<name>`
  # with the uuid prefix stripped.
  defp download_name(%URI{} = upload_uri) do
    case Ezagent.URI.name(upload_uri) do
      {:ok, <<_uuid::binary-size(36), "-", rest::binary>>} -> rest
      {:ok, name} -> name
      :error -> "download"
    end
  end
end
