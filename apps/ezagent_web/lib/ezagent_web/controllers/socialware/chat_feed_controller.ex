defmodule EzagentWeb.Socialware.ChatFeedController do
  @moduledoc """
  Entrypoint for the CHAT external SPA — reachable by an AUTHENTICATED member OR,
  for a session with an installed web-anonymous socialware, by an ANONYMOUS visitor.

  ## Two caller kinds (the route is NO LONGER behind `RequireEntity`)

  Pre-#51 this route sat under `EzagentWeb.Plugs.RequireEntity`, which bounced any
  request with no `current_entity_uri` session cookie to `/login`. #51 §4.1 moves it
  into the public `:browser` scope so an anonymous first-time visitor can VIEW a
  publicly-shared session. The controller now resolves the caller itself:

    * **Authenticated** — when the `:browser` session still carries a valid
      `current_entity_uri` (a signed-in member), `optional_current_entity/1` recovers
      it (the SAME validation `RequireEntity` does — entity scheme, user/agent type —
      but assign-or-nil instead of bounce). That principal gets a `ChatFeedAuth` token
      bound to it, exactly as before. No anon identity is minted for a signed-in user.

    * **Anonymous** — no `current_entity_uri`. The page is served ONLY if an
      installed socialware definition declares `web_anon_access: true`
      (`Ezagent.Socialware.PublicView.web_anon_access?/1`); a private session
      bounces to `/login` (preserving the pre-#51 anon-bounce). For a public
      session the controller mints / reuses a read-only anon-User
      (`Ezagent.Socialware.AnonUser`), joins it to the session, drops a signed
      `socialware_anon` cookie, and issues the anon's `ChatFeedAuth` token.

  ## The anonymous flow (§4.1, fail-closed)

  1. `PublicView.web_anon_access?/1` gate — a NON-public session never mints an anon and
     never becomes anon-accessible; it bounces to `/login` (security property #4).
  2. **Returning visitor** — read the signed `socialware_anon` cookie
     (`AnonCookie.verify/2`). The cookie is the integrity-checked handle: verify →
     reconstruct the anon `entity://` URI → `AnonBinding.touch/3` to refresh
     `last_seen_at`. A tampered/forged/stale/wrong-session cookie verifies to `:error`
     and is treated as no cookie (mint fresh) — an unsigned cookie can never resolve
     an identity (security property #6). If `touch/3` signals `{:error, {:reaping, _}}`
     — the binding was claimed by the GC sweeper — we do NOT resurrect it; we mint a
     FRESH anon identity (design §4.1a).
  3. **First open / fresh** — `AnonUser.mint_for_public_session/1` re-checks the
     public-view rule and mints a read-only anon-User in the session's workspace
     holding EXACTLY one narrow `cap(:session, Behavior.Session, :join,
     instance: <session>)` whose `granted_by` is the session owner (GLOSSARY
     Decision #154 — no unowned permissions, no `system://` principal);
     `Entity.spawn_principal/1` brings up its Kind AND hydrates that cap from
     caps_json into the live `:caps` slice (so it is a registered member-target for
     the join — Session `:join` requires a LIVE registered Kind, else
     `{:member_not_registered}` — AND holds the join authority); `AnonBinding.touch/3`
     records the binding; `session.join` is dispatched AS THE ANON ITSELF — step 5.5
     authorizes it from the anon's own slice cap, NO system principal. The signed
     cookie is set so the next visit reuses this identity.
  4. Either path mints `ChatFeedAuth.issue_token(caller_uri, session_uri)` and embeds
     it in the SPA shell. The token is NOT the authorization — the live membership
     read (`ChatFeed`, `SessionFeedChannel`) re-checks on every join/replay, so an
     ex-member's view clears.

  Read authority is UNCHANGED: the anon-User reads because it is a real session
  member, via the byte-unchanged `Ezagent.Session.Membership.authorize/2` predicate —
  there is no new "non-member can read" path (design §2). Write authority is a
  separate axis (the empty-caps anon cannot `chat.send`); the login-replacement hook
  (§4.4) and rate-limits (OQ-10) are separate later #51 units.
  """
  use EzagentWeb, :controller

  alias EzagentWeb.Socialware.AnonIngress

  @doc """
  Render the chat external SPA shell for `?session_uri=<session://...>`.

  Authenticated principal → token for that principal. Anonymous + public session →
  mint/reuse an anon-User, join it, set the cookie, token for the anon. Anonymous +
  private session → bounce to `/login`. Missing/invalid `session_uri` → 400.
  """
  def show(conn, %{"session_uri" => session_str}) do
    case parse_session(session_str) do
      {:ok, session_uri} -> resolve_caller(conn, session_uri, :chat)
      :error -> bad_request(conn, "missing or invalid session_uri")
    end
  end

  def show(conn, _params), do: bad_request(conn, "missing session_uri")

  @doc """
  Path-route hello pages: `GET /hello/:session_name` serves
  `session://<hello_workspace>/hello/<name>`.

  Works like `show/2` but builds the session URI from a fixed workspace
  (application config `:ezagent_web, :hello_workspace`, default `"demo"`)
  and the `:hello` template type. The full socialware anonymous-access
  pipeline runs unchanged — this is just a short URL entry.
  """
  def show_by_name(conn, %{"session_name" => name}) when is_binary(name) and name != "" do
    ws = Application.get_env(:ezagent_web, :hello_workspace, "demo")
    session_uri = Ezagent.URI.session(ws, :hello, name)
    resolve_caller(conn, session_uri, :external)
  end

  def show_by_name(conn, _params), do: bad_request(conn, "missing session_name")

  defp resolve_caller(conn, session_uri, feed) do
    case AnonIngress.resolve_caller(conn, session_uri) do
      {:ok, conn, %{caller: caller_uri}} -> render_spa(conn, session_uri, caller_uri, feed)
      {:error, :login_required} -> render_login_required(conn, session_uri)
      {:error, _reason} -> bounce(conn)
    end
  end

  # --- the SPA shell -----------------------------------------------------

  defp render_spa(conn, session_uri, caller_uri, feed) do
    token = Ezagent.Socialware.ChatFeedAuth.issue_token(caller_uri, session_uri)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(session_uri, token, feed))
  end

  # Render a friendly login-prompt page when the session requires login.
  # Unlike `bounce/1` (302 redirect), this shows a self-contained page with
  # a login link — the visitor sees what they're trying to access.
  defp render_login_required(conn, session_uri) do
    login_url = "/login?return_to=#{URI.encode_www_form(uri_to_string(session_uri))}"

    body = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Login Required</title>
        <style>
          body { font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f5; }
          .card { background: white; border-radius: 12px; padding: 48px; max-width: 400px; text-align: center; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
          h1 { font-size: 24px; margin: 0 0 12px; }
          p { color: #666; margin: 0 0 24px; line-height: 1.5; }
          a { display: inline-block; background: #111; color: white; padding: 12px 32px; border-radius: 8px; text-decoration: none; font-weight: 500; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Login Required</h1>
          <p>This page requires authentication. Please log in to view its content.</p>
          <a href="#{login_url}">Log in</a>
        </div>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
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

  # The SPA shell — the shared viewer_app.js pointed at the chat socket + topic.
  defp page(session_uri, token, feed) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)
    csrf = Plug.CSRFProtection.get_csrf_token() |> escape()

    {title, socket_path, topic_prefix, root_class} = feed_config(feed)

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
        <title>#{title}</title>
        <link rel="stylesheet" href="/assets/css/local_fonts.css">
        <link rel="stylesheet" href="/assets/css/viewer.css">
        <script defer type="module" src="/assets/js/viewer_app.js"></script>
      </head>
      <body class="min-h-screen bg-background text-foreground antialiased">
        <main id="socialware-viewer-root" class="#{root_class}" data-session-uri="#{session}" data-token="#{token}" data-socket-path="#{socket_path}" data-topic-prefix="#{topic_prefix}" data-csrf-token="#{csrf}"#{delegation_attr}></main>
      </body>
    </html>
    """
  end

  defp feed_config(:external) do
    {"Hello", "/socialware_external_socket", "socialware:external", "block min-h-screen w-full"}
  end

  defp feed_config(:chat) do
    {"Socialware Chat", "/socialware_chat_socket", "socialware:chat_feed",
     "block min-h-screen w-full px-4 py-8 sm:py-12"}
  end

  defp escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
