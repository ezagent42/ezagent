defmodule EzagentWeb.Socialware.ExternalFeedController do
  @moduledoc """
  Public entrypoint for the socialware customer SPA.

  The page authenticates the session-binding token before bootstrapping the
  browser app. Live updates then flow through `CustomerSocket`, which repeats
  the same scoped authorization.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.{ChatFeedAuth, CustomerAuth, ExternalFeed, PublicView}
  alias Ezagent.Uploads.DownloadToken

  # Back-compat 301: the retired `/socialware/customer[/download]` routes
  # permanently redirect to the renamed `/socialware/external[/download]`
  # surface, preserving the original query string so any shipped share-link
  # keeps working.
  def legacy_show(conn, _params), do: redirect_permanent(conn, "/socialware/external")

  def legacy_download(conn, _params),
    do: redirect_permanent(conn, "/socialware/external/download")

  defp redirect_permanent(conn, path) do
    target =
      case conn.query_string do
        "" -> path
        qs -> path <> "?" <> qs
      end

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target)
  end

  @doc """
  External customer-feed attachment download (Resource-unification P2a / OI-1).

  Public (no `RequireEntity`) — a feed viewer has no session/caps. Authorization
  is entirely capability-based:

    * `token` — the customer-feed session token (`CustomerAuth`), proving access
      to `session_uri`;
    * `file_token` — the signed `DownloadToken`, binding the exact ws-scoped
      `resource://<ws>/uploads/<name>` URI;

  and `ExternalFeed.authorized_attachment_path/4` re-validates that the attachment
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
           ExternalFeed.authorized_attachment_path(
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
         {:ok, _snapshot} <- ExternalFeed.snapshot(session_uri, token) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, page(session_uri, token, viewer_token(conn, session_uri)))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "unauthorized")
    end
  end

  # Tokenless anonymous self-serve for a `public_view` session: the ExternalFeed
  # shows the APPROVED SURFACE PAGE (the generated UI), so a public session is
  # meant to be viewable by anyone with no login/token. The server mints a
  # short-lived CustomerAuth token for the public session (the same trust the
  # chat-feed anon flow already grants for `public_view`) and renders. A NON-public
  # session falls through to the 400 below — no token, no view (fail-closed).
  def show(conn, %{"session_uri" => session_str}) do
    with {:ok, session_uri} <- parse_session(session_str),
         # Cold-link revival: a `public_view` session that has gone cold (no live
         # Kind since the last boot) would otherwise fail `public_view?/1` — it
         # reads the LIVE slice — and 400 even though it IS public. `ensure_live/1`
         # rehydrates it from its snapshot, but ONLY when a snapshot exists
         # (`{:error, :not_created}` otherwise), so an anon can wake an EXISTING
         # session, never conjure one. Access stays gated by `public_view?/1`
         # below: a revived NON-public session still falls through to the 400.
         # (Hardening follow-up: pre-gate the revive on the snapshot's persisted
         # public_view flag so non-public sessions are never even woken.)
         _ <- Ezagent.SpawnRegistry.ensure_live(session_uri),
         true <- PublicView.public_view?(session_uri),
         workspace_uri <- Ezagent.Capability.workspace_of(session_uri),
         token <- CustomerAuth.issue_token(session_uri, workspace_uri),
         {:ok, _snapshot} <- ExternalFeed.snapshot(session_uri, token) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, page(session_uri, token, viewer_token(conn, session_uri)))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "missing session_uri or token")
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

  # A signed identity token for the logged-in viewer (or "" for anonymous). The
  # customer URL `token` is identity-LESS (CustomerAuth binds only session+ws); the
  # bottom preview bar needs to know WHO is viewing to switch login/join/post. We
  # reuse `ChatFeedAuth` (binds a caller principal to a session) so the customer
  # socket recovers a TRUSTED principal — the live membership re-check at the
  # channel remains the authorization, exactly as the chat feed does.
  defp viewer_token(conn, %URI{} = session_uri) do
    case optional_current_entity(conn) do
      %URI{} = principal_uri -> ChatFeedAuth.issue_token(principal_uri, session_uri)
      nil -> ""
    end
  end

  # Recover a signed-in principal from the `:browser` session WITHOUT bouncing (the
  # public route has no RequireEntity). Same validation RequireEntity does (entity
  # scheme + user/agent type), but assign-or-nil. Mirrors ChatFeedController.
  defp optional_current_entity(conn) do
    case get_session(conn, :current_entity_uri) do
      uri_str when is_binary(uri_str) ->
        try do
          # `new!/1` returns a `%URI{}` or raises ArgumentError (caught below).
          uri = Ezagent.URI.new!(uri_str)

          if Ezagent.URI.scheme?(uri, :entity) and
               match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri)) do
            uri
          else
            nil
          end
        rescue
          ArgumentError -> nil
        end

      _ ->
        nil
    end
  end

  defp page(session_uri, token, viewer_token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)
    viewer_token = escape(viewer_token)

    """
    <!doctype html>
    <html lang="en" data-theme="viewer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware Customer</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
        <link rel="stylesheet" href="/assets/css/viewer.css">
        <script defer type="module" src="/assets/js/viewer_app.js"></script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content antialiased">
        <main id="socialware-viewer-root" class="block min-h-screen w-full" data-session-uri="#{session}" data-token="#{token}" data-viewer-token="#{viewer_token}"></main>
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
