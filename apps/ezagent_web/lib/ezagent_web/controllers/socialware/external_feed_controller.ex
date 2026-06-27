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

  require Logger

  alias Ezagent.Socialware.{AnonBinding, AnonUser, ChatFeedAuth, ExternalFeed, PublicView}
  alias Ezagent.Uploads.DownloadToken
  alias EzagentWeb.Socialware.AnonCookie

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
      `resource://<ws>/uploads/<name>` URI;

  and `ExternalFeed.authorized_attachment_path/4` re-validates that the attachment
  is STILL an approved (committed, external-visible) item before resolving — so a
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
         {:ok, caller} <- ChatFeedAuth.verify(token, session_uri),
         {:ok, upload_uri} <- DownloadToken.verify(file_token),
         {:ok, path} <-
           ExternalFeed.authorized_attachment_path(
             session_uri,
             caller,
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

  # --- caller resolution (mirrors ChatFeedController) --------------------

  defp resolve_caller(conn, session_uri) do
    case optional_current_entity(conn) do
      %URI{} = principal_uri ->
        # Signed-in member — unchanged behaviour, no anon identity.
        render_spa(conn, session_uri, principal_uri)

      nil ->
        resolve_anonymous(conn, session_uri)
    end
  end

  defp resolve_anonymous(conn, session_uri) do
    # Cold-link revival: rehydrate a cold public session from its snapshot so the
    # `public_view?/1` gate sees a live slice instead of bouncing a still-public-
    # but-cold link to /login. ensure_live only wakes a session that HAS a
    # snapshot; access stays gated by public_view? below.
    _ = Ezagent.SpawnRegistry.ensure_live(session_uri)

    if PublicView.public_view?(session_uri) do
      case reuse_or_mint(conn, session_uri) do
        {:ok, conn, anon_uri} -> render_spa(conn, session_uri, anon_uri)
        {:error, _reason} -> bounce(conn)
      end
    else
      bounce(conn)
    end
  end

  # Returning visitor (valid cookie) → reuse; tampered/missing/reaping → mint fresh.
  defp reuse_or_mint(conn, session_uri) do
    case read_valid_cookie(conn, session_uri) do
      {:ok, anon_uri} ->
        case AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now()) do
          {:ok, _row} ->
            :ok = Ezagent.Entity.spawn_principal(anon_uri)
            {:ok, conn, anon_uri}

          {:error, {:reaping, _}} ->
            mint_fresh(conn, session_uri)

          {:error, _reason} ->
            mint_fresh(conn, session_uri)
        end

      :error ->
        mint_fresh(conn, session_uri)
    end
  end

  defp mint_fresh(conn, session_uri) do
    with {:ok, anon_uri} <- AnonUser.mint_for_public_session(session_uri),
         :ok <- Ezagent.Entity.spawn_principal(anon_uri),
         {:ok, _row} <- AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now()),
         :ok <- join_anon(session_uri, anon_uri),
         {:ok, cookie_value} <- AnonCookie.sign(anon_uri, session_uri) do
      {:ok, put_anon_cookie(conn, cookie_value), anon_uri}
    else
      other ->
        Logger.warning(
          "ExternalFeedController: anon mint/join failed for " <>
            "#{URI.to_string(session_uri)}: #{inspect(other)}"
        )

        {:error, other}
    end
  end

  # `session.join` dispatched AS THE ANON ITSELF — no `system://` principal. The
  # anon holds exactly one `cap(:session, Behavior.Session, :join,
  # instance: <session>)` whose `granted_by` is the session owner (Decision #154).
  # `:call` so membership is committed before we render the SPA (the live channel
  # re-reads it on connect).
  defp join_anon(session_uri, anon_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{member: anon_uri},
        ctx: %{caller: anon_uri, reply: :ignore}
      })

    case result do
      :ok -> mount_anon_participation(session_uri, anon_uri)
      {:ok, _} -> mount_anon_participation(session_uri, anon_uri)
      {:error, _} = err -> err
    end
  end

  # Mount the per-class participation tier on the anon AFTER a successful join
  # (the helper resolves `Users.confirmed?` and grants the UNCONFIRMED read-only
  # tier — no `:send`). Best-effort; returns `:ok` so `mint_fresh/2` continues.
  defp mount_anon_participation(%URI{} = session_uri, %URI{} = anon_uri) do
    _ =
      Ezagent.Behavior.Session.Membership.mount_participation_caps(
        session_uri,
        anon_uri
      )

    :ok
  end

  # --- the SPA shell -----------------------------------------------------

  defp render_spa(conn, session_uri, caller_uri) do
    token = ChatFeedAuth.issue_token(caller_uri, session_uri)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(session_uri, token))
  end

  # --- cookie + optional-auth helpers ------------------------------------

  # Recover a signed-in principal from the `:browser` session WITHOUT bouncing (the
  # public route has no RequireEntity). Same validation RequireEntity does (entity
  # scheme + user/agent type), but assign-or-nil. Mirrors ChatFeedController.
  defp optional_current_entity(conn) do
    case get_session(conn, :current_entity_uri) do
      uri_str when is_binary(uri_str) ->
        try do
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
      secure: secure_cookie?(conn),
      same_site: "Lax"
    )
  end

  defp secure_cookie?(conn), do: conn.scheme == :https

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

    """
    <!doctype html>
    <html lang="en" data-theme="viewer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
        <link rel="stylesheet" href="/assets/css/viewer.css">
        <script defer type="module" src="/assets/js/viewer_app.js"></script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content antialiased">
        <main id="socialware-viewer-root" class="block min-h-screen w-full" data-session-uri="#{session}" data-token="#{token}" data-socket-path="/socialware_external_socket" data-topic-prefix="socialware:external"></main>
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
