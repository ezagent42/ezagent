defmodule EzagentWeb.Socialware.ChatFeedController do
  @moduledoc """
  Entrypoint for the CHAT external SPA — reachable by an AUTHENTICATED member OR,
  for a `public_view` session, by an ANONYMOUS visitor (issue #51 §4.1).

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

    * **Anonymous** — no `current_entity_uri`. The page is served ONLY if the
      session's Template declares `public_view: true`
      (`Ezagent.Socialware.PublicView.public_view?/1`); a private session bounces to
      `/login` (preserving the pre-#51 anon-bounce). For a public session the
      controller mints / reuses a read-only anon-User
      (`Ezagent.Socialware.AnonUser`), joins it to the session, drops a signed
      `socialware_anon` cookie, and issues the anon's `ChatFeedAuth` token.

  ## The anonymous flow (§4.1, fail-closed)

  1. `PublicView.public_view?/1` gate — a NON-public session never mints an anon and
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
     read (`ChatFeed`, `ChatFeedChannel`) re-checks on every join/replay, so an
     ex-member's view clears.

  Read authority is UNCHANGED: the anon-User reads because it is a real session
  member, via the byte-unchanged `Ezagent.Session.Membership.authorize/2` predicate —
  there is no new "non-member can read" path (design §2). Write authority is a
  separate axis (the empty-caps anon cannot `chat.send`); the login-replacement hook
  (§4.4) and rate-limits (OQ-10) are separate later #51 units.
  """
  use EzagentWeb, :controller

  require Logger

  alias Ezagent.Socialware.{AnonBinding, AnonUser, ChatFeedAuth, PublicView}
  alias EzagentWeb.Socialware.AnonCookie

  @doc """
  Render the chat external SPA shell for `?session_uri=<session://...>`.

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

  # --- caller resolution -------------------------------------------------

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
    # Cold-link revival (mirrors customer_controller): rehydrate a cold public
    # session from its snapshot so the `public_view?/1` gate sees a live slice
    # instead of bouncing a still-public-but-cold link to /login. ensure_live only
    # wakes a session that HAS a snapshot; access stays gated by public_view?
    # below (a revived non-public session still bounces).
    _ = Ezagent.SpawnRegistry.ensure_live(session_uri)

    # Public-view gate FIRST — a non-public session never mints an anon and never
    # becomes anon-accessible. Bounce exactly as the pre-#51 RequireEntity did.
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
            # Ensure the Kind is live (demand-spawn) so the live channel read works
            # and a returning visitor whose Kind was GC-terminated still reads.
            :ok = Ezagent.Entity.spawn_principal(anon_uri)
            {:ok, conn, anon_uri}

          {:error, {:reaping, _}} ->
            # The binding is being torn down by the GC sweeper — do NOT resurrect
            # it; mint a fresh anon identity (design §4.1a).
            mint_fresh(conn, session_uri)

          {:error, _reason} ->
            # Mismatch / write lost / non-anon — fail closed by minting fresh.
            mint_fresh(conn, session_uri)
        end

      :error ->
        mint_fresh(conn, session_uri)
    end
  end

  defp mint_fresh(conn, session_uri) do
    # `mint_for_public_session/1` re-checks `public_view?` and mints the anon
    # holding ITS OWN narrow `session.join` cap (granted_by the session owner —
    # Decision #154, no `system://` principal). `spawn_principal` then hydrates
    # that cap from caps_json into the live `:caps` slice BEFORE the join, so the
    # anon joins under its own authority.
    with {:ok, anon_uri} <- AnonUser.mint_for_public_session(session_uri),
         :ok <- Ezagent.Entity.spawn_principal(anon_uri),
         {:ok, _row} <- AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now()),
         :ok <- join_anon(session_uri, anon_uri),
         {:ok, cookie_value} <- AnonCookie.sign(anon_uri, session_uri) do
      {:ok, put_anon_cookie(conn, cookie_value), anon_uri}
    else
      other ->
        Logger.warning(
          "ChatFeedController: anon mint/join failed for " <>
            "#{URI.to_string(session_uri)}: #{inspect(other)}"
        )

        {:error, other}
    end
  end

  # `session.join` dispatched AS THE ANON ITSELF — no `system://` principal. The
  # anon was minted (`AnonUser.mint_for_public_session/1`) holding exactly one
  # `cap(:session, Behavior.Session, :join, instance: <session>)` whose
  # `granted_by` is the session owner (Decision #154). Step 5.5
  # (`granted_via_holds_cap?`) reads that cap from the anon's own `:caps` slice,
  # so the anon is a self-sufficient caller. `:call` so membership is committed
  # before we render the SPA (the live channel re-reads it on connect).
  defp join_anon(session_uri, anon_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{member: anon_uri},
        ctx: %{
          caller: anon_uri,
          reply: :ignore
        }
      })

    case result do
      :ok -> mount_anon_participation(session_uri, anon_uri)
      {:ok, _} -> mount_anon_participation(session_uri, anon_uri)
      {:error, _} = err -> err
    end
  end

  # #154 PR-甲-2 §A — mount the per-class participation tier on the anon AFTER a
  # successful join (caller-side; the helper resolves `Users.confirmed?` from the
  # DB and grants the UNCONFIRMED tier — `Publisher.SessionImpl.:subscribe_from`,
  # read-only, no `:send`). Best-effort: a failed mount degrades the anon to
  # "observe via membership", it does not break the page. Returns `:ok` so the
  # `with` chain in `mint_fresh/2` continues to cookie + render.
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

  # Recover a signed-in principal from the `:browser` session WITHOUT bouncing — the
  # public route has no RequireEntity to populate `assigns.current_entity_uri`, so we
  # validate the cookie here exactly as RequireEntity does (entity scheme + user/agent
  # type) but return the URI or nil instead of redirecting.
  defp optional_current_entity(conn) do
    case get_session(conn, :current_entity_uri) do
      uri_str when is_binary(uri_str) ->
        try do
          case Ezagent.URI.new!(uri_str) do
            %URI{} = uri ->
              if Ezagent.URI.scheme?(uri, :entity) and
                   match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri)) do
                uri
              else
                nil
              end

            _ ->
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

  # Secure flag follows the connection scheme so the cookie works over plain HTTP in
  # dev/test (where `conn.scheme == :http`) but is Secure in production HTTPS.
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

  # The SPA shell — the shared viewer_app.js pointed at the chat socket + topic.
  defp page(session_uri, token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)

    """
    <!doctype html>
    <html lang="en" data-theme="viewer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware Chat</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
        <link rel="stylesheet" href="/assets/css/viewer.css">
        <script defer type="module" src="/assets/js/viewer_app.js"></script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content antialiased">
        <main id="socialware-viewer-root" class="block min-h-screen w-full px-4 py-8 sm:py-12" data-session-uri="#{session}" data-token="#{token}" data-socket-path="/socialware_chat_socket" data-topic-prefix="socialware:chat_feed"></main>
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
end
