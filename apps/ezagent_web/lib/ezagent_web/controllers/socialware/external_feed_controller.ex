defmodule EzagentWeb.Socialware.ExternalFeedController do
  @moduledoc """
  Public entrypoint for the socialware external surface SPA (the agent-generated
  page projection).

  Reachable by an AUTHENTICATED member OR, for a `public_view` session, by an
  ANONYMOUS visitor — the SAME ingress shape `ChatFeedController` uses for the
  chat surface (issue #51 §4.1). There is NO identity-less token: a signed-in
  viewer uses their real principal; an anonymous visitor to a public session is
  minted a read-only **anon-User** (cookie-bound), joined to the session, and
  given that anon's `ChatFeedAuth` token. The token is NOT the authorization —
  the live `Ezagent.Session.Membership.authorize/2` read (`ExternalFeed`,
  `SessionFeedChannel`) re-checks on every read, so an ex-member's view clears.

  Live updates flow through `ExternalFeedSocket` / `SessionFeedChannel`, which
  recover the SAME principal from the token and repeat the live membership check.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.{ChatFeedAuth, ExternalFeed}
  alias Ezagent.Uploads.DownloadToken
  alias EzagentWeb.Socialware.AnonIngress

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
  External-feed attachment download (Resource-unification P2a / OI-1).

  Public (no `RequireEntity`). Authorization is capability-based:

    * `token` — the caller's `ChatFeedAuth` session token (the minted anon or the
      signed-in member), verified to a principal then live-membership checked;
    * `file_token` — the signed `DownloadToken`, binding the exact ws-scoped
      `resource://<ws>/uploads/<name>` URI, and — when minted person-bound
      (read-plane PR-3) — the ONE `grantee` principal it was issued to;

  plus the PR-3 person-binding check: a grantee-bound `file_token` serves ONLY
  its grantee (`caller == grantee`), so a leaked/copied token replayed by a
  non-grantee is rejected even when that principal is itself an authorized
  viewer of the session. An absent-grantee (legacy, pre-PR-3 already-issued)
  `file_token` carries no person binding; the approved-only re-validation
  below remains its check. NEW tokens are ALWAYS grantee-bound — the signer
  (`DownloadToken.mint!/2`) structurally refuses an unbound mint.

  ## Caller-derivation strength (codex Finding 1 — ACCEPTED RESIDUAL)

  The serving caller is derived from `token` via `ChatFeedAuth.verify/2` — a
  SERVER-SIGNED `Phoenix.Token` (HMAC over the application `secret_key_base`,
  bound to this session, TTL'd), NOT a raw/trustable URL param. This is the
  SAME strength class as the authenticated path's session cookie: a bearer
  credential. Consequently, if a viewer leaks BOTH a full download URL AND
  their own identity bearer (`token`), a holder of both can present the
  leaker's identity and pass `caller == grantee`. That is the inherent
  "leaking your session token = compromised" property of bearer auth — NOT a
  weaker check than the authenticated path — and is the accepted residual:
  the grantee binding exists to stop replay by anyone who does NOT also hold
  the grantee's identity bearer (the common copy/paste/log-scrape leak).
  Short TTLs on both tokens bound the window.

  And `ExternalFeed.authorized_attachment_path/4` re-validates that the attachment
  is STILL an approved (committed, external-visible) item before resolving — so a
  captured token stops working once an internal reviewer flips the message back
  to internal-only (serve-time revocation, codex HIGH). Fails closed on any
  missing/invalid input.
  """
  def download(conn, %{
        "session_uri" => session_str,
        "token" => token,
        "file_token" => file_token
      })
      when is_binary(token) and is_binary(file_token) do
    with {:ok, session_uri} <- parse_session(session_str),
         {:ok, caller} <- ChatFeedAuth.verify(token, session_uri),
         {:ok, payload} <- DownloadToken.verify_payload(file_token),
         :ok <- check_grantee(payload.grantee, caller),
         {:ok, path} <-
           ExternalFeed.authorized_attachment_path(
             session_uri,
             caller,
             payload.uri,
             &Ezagent.Uploads.resolve/2
           ),
         true <- File.regular?(path) do
      send_download(conn, {:file, path}, filename: download_name(payload.uri))
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

  # --- the PR-3 person binding -------------------------------------------------

  # A grantee-bound file_token serves ONLY its grantee; an absent-grantee
  # (legacy) token is unbound — the approved-only re-validation in
  # `ExternalFeed.authorized_attachment_path/4` is its whole check.
  defp check_grantee(nil, _caller), do: :ok

  defp check_grantee(%URI{} = grantee, caller) do
    if DownloadToken.grantee_match?(grantee, caller),
      do: :ok,
      else: {:error, :grantee_mismatch}
  end

  @doc """
  Render the external surface SPA shell for `?session_uri=<session://...>`.

  Authenticated principal → token for that principal. Anonymous + public session →
  mint/reuse an anon-User, join it, set the cookie, token for the anon. Anonymous +
  private session → bounce to `/login`. Missing/invalid `session_uri` → 400.
  """
  def show(conn, %{"session_uri" => session_str}) do
    case parse_session(session_str) do
      {:ok, session_uri} -> resolve_caller(conn, session_uri)
      :error -> bad_request(conn, "missing or invalid session_uri")
    end
  end

  def show(conn, _params), do: bad_request(conn, "missing session_uri")

  defp resolve_caller(conn, session_uri) do
    case AnonIngress.resolve_caller(conn, session_uri) do
      {:ok, conn, %{caller: caller_uri}} -> render_spa(conn, session_uri, caller_uri)
      {:error, _reason} -> bounce(conn)
    end
  end

  # --- the SPA shell -----------------------------------------------------

  defp render_spa(conn, session_uri, caller_uri) do
    token = ChatFeedAuth.issue_token(caller_uri, session_uri)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(session_uri, token))
  end

  # --- parsing + responses -----------------------------------------------

  defp parse_session(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session(_value), do: :error

  defp bad_request(conn, msg) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, msg)
  end

  defp bounce(conn) do
    conn
    |> redirect(to: "/login")
    |> halt()
  end

  defp page(session_uri, token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)
    csrf = Plug.CSRFProtection.get_csrf_token() |> escape()

    delegation_attr =
      if Ezagent.URI.type?(session_uri, :hello),
        do: ~s( data-hello-delegation-endpoint="/hello/delegate"),
        else: ""

    """
    <!doctype html>
    <html lang="en" data-theme="viewer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware</title>
        <link rel="stylesheet" href="/assets/css/local_fonts.css">
        <link rel="stylesheet" href="/assets/css/viewer.css">
        <script defer type="module" src="/assets/js/viewer_app.js"></script>
      </head>
      <body class="min-h-screen bg-background text-foreground antialiased">
        <main id="socialware-viewer-root" class="block min-h-screen w-full" data-session-uri="#{session}" data-token="#{token}" data-socket-path="/socialware_external_socket" data-topic-prefix="socialware:external" data-csrf-token="#{csrf}"#{delegation_attr}></main>
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
