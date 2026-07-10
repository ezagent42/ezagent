defmodule EzagentWeb.SessionController do
  @moduledoc """
  Phase 4-completion Spec 05 §A.2.3 — controller-rendered login.

  Why not LiveView for login itself: LV-on-login adds a websocket
  dependency to credential entry. If WS can't connect, blank screen.
  Plain POST form is the robust path for the auth boundary.

  Phase 8c follow-up (Allen 2026-05-20): unified login page. Previously
  /login (email) and /login/credentials (password) rendered as two
  separate pages, which was confusing — submit credentials then bounce
  to the email page made it look like login failed. Now ONE page at
  both URLs shows both forms (credentials primary, email secondary,
  with an inline notice when SMTP isn't configured).
  """
  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn

  require Logger

  alias Ezagent.Entity
  alias EzagentWeb.AuthBoundaryLayout
  alias EzagentWeb.SessionPrincipal

  # PR-E (SPEC v2 §G7): head + chrome moved to AuthBoundaryLayout so
  # `/register/complete` renders the same shell. Only the card body
  # (the credentials form + email section + hints) lives here.
  # task #87 — login is email+password (primary). Magic-link is kept as an
  # optional passwordless method, rendered only when SMTP is configured.
  @login_card_body """
      <p class="brand">ezagent</p>
      <h1>{{T_SIGN_IN}}</h1>

      {{NOTICE}}

      {{CRED_ERROR}}
      <form method="post" action="/login">
        <input type="hidden" name="_csrf_token" value="{{CSRF}}">
        {{RETURN_TO_FIELD}}
        <label for="email">{{T_EMAIL_ADDRESS}}</label>
        <input type="email" id="email" name="email" placeholder="you@example.com" required autofocus>
        <label for="password">{{T_PASSWORD}}</label>
        <input type="password" id="password" name="password" required>
        <button type="submit">{{T_SIGN_IN}}</button>
      </form>

      <p class="hint" style="text-align:center;margin-top:8px;">
        <a href="/auth/reset">{{T_FORGOT_PASSWORD}}</a>
        ·
        <a href="/register">{{T_CREATE_ACCOUNT}}</a>
      </p>

      {{EMAIL_SECTION}}

      <p class="hint" style="text-align:center;margin-top:8px;">
        <a href="?locale=en" style="color:var(--ink-dim);text-decoration:none;">English</a>
        ·
        <a href="?locale=zh_CN" style="color:var(--ink-dim);text-decoration:none;">中文</a>
      </p>
  """

  # Magic-link passwordless option — only shown when SMTP is configured
  # (Allen 2026-06-22). Posts to /login/magic (NOT /login, which is now
  # email+password).
  @email_form """
  <div class="divider"><span>{{T_OR}}</span></div>
  <p class="section-label">{{T_WITH_EMAIL_MAGIC_LINK}}</p>
  <form method="post" action="/login/magic">
    <input type="hidden" name="_csrf_token" value="{{CSRF}}">
    <label for="magic_email">{{T_EMAIL_ADDRESS}}</label>
    <input type="email" id="magic_email" name="email" placeholder="you@example.com" required>
    <button type="submit" class="secondary">{{T_EMAIL_ME_SIGN_IN_LINK}}</button>
  </form>
  """

  # GET /login — unified login page with both credential and email forms.
  # Phase 9 PR-5 (SPEC v3 §6.4 amended): accepts `?workspace=<name>` query
  # param. When present, the bare-handle path canonicalizes into that
  # workspace instead of `default`, and the page surfaces "Signing into
  # <name>" so the user understands the context they're about to enter.
  def new(conn, params) do
    render_login_page(conn,
      workspace: Map.get(params, "workspace"),
      return_to: Map.get(params, "return_to")
    )
  end

  # POST /login — email + password (task #87 primary login). Resolves the
  # email to its canonical entity URI, authenticates password-only (no
  # token-as-password), then gates on email_verified. Generic errors so the
  # form does not leak which emails exist.
  def create(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    email = email |> String.trim() |> String.downcase()
    # Phase 9 PR-8 pattern (see `delete/2`): honour a `return_to` so a visitor
    # who clicked "登录" from a socialware share page
    # (`/socialware/external?session_uri=…`) lands back there after signing in
    # instead of being dumped on `/sessions`. `safe_return_to/2` enforces
    # local-relative paths (rejects absolute + protocol-relative URLs), so it
    # can never be an open-redirect. Falls back to `/sessions` when absent.
    return_to = params |> Map.get("return_to") |> safe_return_to("/sessions")

    case resolve_and_auth(email, password) do
      {:ok, uri_str} ->
        if login_verified?(uri_str) do
          conn
          |> SessionPrincipal.put(uri_str, workspace: nil)
          |> redirect(to: return_to)
        else
          # Shown ONLY after a correct password, so it does not reveal which
          # emails are registered (anti-enumeration, Codex #7).
          render_login_page(conn,
            cred_error: gettext("Please confirm your email to finish signing in."),
            return_to: return_to
          )
        end

      :error ->
        render_login_page(conn,
          cred_error: gettext("Invalid email or password."),
          return_to: return_to
        )
    end
  end

  def create(conn, _params),
    do: render_login_page(conn, cred_error: gettext("Email and password are required."))

  # POST /login/magic — passwordless magic-link send (KEPT, SMTP-gated).
  # Anti-enumeration: identical response regardless of allowlist / rate-limit.
  def magic_create(conn, %{"email" => email}) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    _ = maybe_send_magic_link(conn, email)

    notice =
      ~s(<div class="info">) <>
        esc(gettext("If that email can sign in, we've sent a link. Please check your inbox.")) <>
        "</div>"

    render_login_page(conn, notice: notice)
  end

  def magic_create(conn, _params), do: new(conn, %{})

  # task #87 — the legacy handle/URI credentials path (`/login/credentials`,
  # `credentials_new`/`credentials_create`, workspace canonicalization, the
  # local `authenticate/2`) was REMOVED. Login is email+password only; see
  # `create/2` above.

  def delete(conn, params) do
    # Phase 9 PR-8 (SPEC v3 §6.4 amendment 3) — `return_to` lets the
    # workspace-switch denial page POST to /logout and land the user
    # on `/login?workspace=<ws>`. Restricted to local paths
    # (`String.starts_with?("/")` + no `//`) so it can't be a phishing
    # redirector to an external site.
    return_to = params |> Map.get("return_to", "/login") |> safe_return_to("/login")

    conn
    |> SessionPrincipal.clear()
    |> redirect(to: return_to)
  end

  # Open-redirect guard: only local-relative paths survive. Anything else
  # (absolute `http(s)://…`, protocol-relative `//evil.com`, backslash
  # `/\evil.com` which some browsers treat as protocol-relative) falls back
  # to the caller-supplied safe default. Used by both `delete/2` (logout,
  # default `/login`) and `create/2` (login, default `/sessions`).
  defp safe_return_to(path, fallback) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> fallback
      String.starts_with?(path, "//") -> fallback
      String.starts_with?(path, "/\\") -> fallback
      true -> path
    end
  end

  defp safe_return_to(_, fallback), do: fallback

  # --- internals ----------------------------------------------------

  defp render_login_page(conn, opts) do
    notice = Keyword.get(opts, :notice, "")
    cred_error = Keyword.get(opts, :cred_error)

    # Thread a validated `return_to` through the credential POST as a hidden
    # field so `create/2` can land the user back where they came from (e.g. a
    # socialware share page). Only emitted when it survives the open-redirect
    # guard; otherwise the form omits it and login uses its default landing.
    return_to_field =
      case Keyword.get(opts, :return_to) do
        rt when is_binary(rt) ->
          case safe_return_to(rt, nil) do
            nil -> ""
            safe -> ~s(<input type="hidden" name="return_to" value="#{esc(safe)}">)
          end

        _ ->
          ""
      end

    cred_error_html =
      if cred_error,
        do: ~s(<div class="error">) <> Plug.HTML.html_escape(cred_error) <> "</div>",
        else: ""

    # Allen 2026-05-24: surface Phoenix flash on /login so a redirect
    # like `put_flash(:error, ...) |> redirect(to: "/login")` actually
    # shows the user WHY they landed here. Prepend to `notice` so it
    # always appears at the top of the card.
    flash_html = AuthBoundaryLayout.flash_html(conn)
    notice = flash_html <> notice

    # Resolve i18n strings on the controller side (the login heredoc
    # is raw HTML, not a HEEx template, so we cannot inline gettext
    # macros — instead we placeholder-substitute pre-translated strings).
    # task #87: magic-link is shown ONLY when SMTP is configured (Allen),
    # otherwise the section is hidden entirely.
    email_section =
      if Ezagent.AppSettings.mail_configured?() do
        @email_form
        |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
        |> String.replace("{{T_OR}}", esc(gettext("or")))
        |> String.replace("{{T_WITH_EMAIL_MAGIC_LINK}}", esc(gettext("With email magic link")))
        |> String.replace("{{T_EMAIL_ADDRESS}}", esc(gettext("Email address")))
        |> String.replace(
          "{{T_EMAIL_ME_SIGN_IN_LINK}}",
          esc(gettext("Email me a sign-in link"))
        )
      else
        ""
      end

    card_body =
      @login_card_body
      |> String.replace("{{NOTICE}}", notice)
      |> String.replace("{{CRED_ERROR}}", cred_error_html)
      |> String.replace("{{RETURN_TO_FIELD}}", return_to_field)
      |> String.replace("{{EMAIL_SECTION}}", email_section)
      |> String.replace("{{T_SIGN_IN}}", esc(gettext("Sign in")))
      |> String.replace("{{T_EMAIL_ADDRESS}}", esc(gettext("Email address")))
      |> String.replace("{{T_PASSWORD}}", esc(gettext("Password")))
      |> String.replace("{{T_FORGOT_PASSWORD}}", esc(gettext("Forgot password?")))
      |> String.replace("{{T_CREATE_ACCOUNT}}", esc(gettext("Create account")))
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())

    html =
      AuthBoundaryLayout.head_html(gettext("ezagent · sign in")) <>
        AuthBoundaryLayout.body_open() <>
        AuthBoundaryLayout.card_open() <>
        card_body <>
        AuthBoundaryLayout.card_close() <>
        AuthBoundaryLayout.body_close()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  # html_escape across Plug versions returns either an iodata or a
  # binary; normalize to binary so `String.replace/3` accepts it.
  defp esc(text) do
    case Plug.HTML.html_escape(text) do
      bin when is_binary(bin) -> bin
      iodata -> IO.iodata_to_binary(iodata)
    end
  end

  # task #87 — resolve the typed email to its canonical entity URI, then
  # authenticate password-ONLY (no token-as-password on the form). Returns
  # `{:ok, uri_str}` or `:error`. Constant-time on a missing email so the
  # form does not leak which emails are registered.
  defp resolve_and_auth(email, password) do
    case Ezagent.Entity.Profile.by_email(email) do
      %{entity_uri: uri_str} when is_binary(uri_str) ->
        case Entity.authenticate(Ezagent.URI.new!(uri_str), password, allow_user_tokens: false) do
          {:ok, _} -> {:ok, uri_str}
          {:error, _} -> :error
        end

      _ ->
        Bcrypt.no_user_verify()
        :error
    end
  end

  # task #87 — form login is gated on email_verified (independent of the
  # `confirmed` anon flag). Checked AFTER a correct password (anti-enumeration).
  defp login_verified?(uri_str) do
    case Ezagent.Users.get_by_uri(uri_str) do
      %{email_verified: true} -> true
      _ -> false
    end
  end

  # Returns :ok always (caller ignores it — anti-enumeration: the HTTP
  # response is identical regardless of which path was taken, so an
  # attacker cannot enumerate "which emails / domains are allowed").
  # Per SKILL P27 — server-side observability is non-negotiable: each
  # silent-drop path logs WHY, so operators can debug "user reports no
  # email received" without code-spelunking. Logs reach
  # `~/.openclaw/logs/*.log` in production.
  defp maybe_send_magic_link(conn, email) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    cond do
      not Ezagent.AppSettings.mail_configured?() ->
        Logger.warning(
          "magic_link silent_drop reason=mail_not_configured email=#{email} ip=#{ip} — " <>
            "admin must configure mail (SMTP or REST) at /admin/settings before any sign-in email can send"
        )

        :ok

      {:error, :rate_limited} ==
          EzagentWeb.RateLimiter.check("login_email:" <> email,
            limit: 3,
            window_ms: 15 * 60_000
          ) ->
        Logger.info(
          "magic_link silent_drop reason=email_rate_limited email=#{email} ip=#{ip} " <>
            "limit=3/15min — user retried too quickly"
        )

        :ok

      {:error, :rate_limited} ==
          EzagentWeb.RateLimiter.check("login_ip:" <> ip,
            limit: 10,
            window_ms: 60 * 60_000
          ) ->
        Logger.warning(
          "magic_link silent_drop reason=ip_rate_limited email=#{email} ip=#{ip} " <>
            "limit=10/hour — possible enumeration probe OR shared NAT"
        )

        :ok

      not send_allowed?(email) ->
        Logger.warning(
          "magic_link silent_drop reason=send_not_allowed email=#{email} ip=#{ip} — " <>
            "email is neither an existing principal nor in `registration_domains` " <>
            "whitelist; add the domain at /admin/settings → Allowed email domains"
        )

        :ok

      true ->
        do_send_magic_link(conn, email, ip)
    end
  end

  defp do_send_magic_link(conn, email, ip) do
    {:ok, raw} = Ezagent.Entity.MagicLinkToken.mint(email)
    link = EzagentWeb.UrlHelper.request_base_url(conn) <> "/auth/magic/" <> raw

    case EzagentWeb.Mailer.deliver_magic_link(email, link) do
      {:ok, _} ->
        Logger.info("magic_link sent email=#{email} ip=#{ip}")
        :ok

      {:error, reason} ->
        Logger.error(
          "magic_link silent_drop reason=mailer_failed email=#{email} ip=#{ip} " <>
            "mailer_reason=#{inspect(reason)} — check SMTP config / connectivity / TLS"
        )

        :ok
    end
  end

  # Existing principal -> always allowed (login). New email -> must be
  # accepted by at least one workspace's `magic_link_rule` (SPEC v2
  # PR-A, Allen 2026-05-24, codex round-1 HIGH-1 fix). `email_allowed?/1`
  # consults the new per-workspace rule path AND the legacy
  # `registration_domains` AppSetting (back-compat during PR-B
  # transition; PR-B removes the AppSetting consultation entirely).
  # task #87 (codex final-review HIGH) — magic-link is now LOGIN-only and must
  # only ever reach an EXISTING, email-VERIFIED account. New emails register via
  # /register (not magic-link), and an unverified account must confirm first —
  # so we never send a login link that could bypass the email_verified gate.
  # Same generic response regardless (anti-enumeration).
  defp send_allowed?(email) do
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, uri} ->
        match?(%{email_verified: true}, Ezagent.Users.get_by_uri(uri))

      :none ->
        false
    end
  end
end
