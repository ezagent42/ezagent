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
  alias EzagentWeb.SessionPrincipal

  @login_html """
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <title>{{T_PAGE_TITLE}}</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
    <style>
      :root {
        --font-sans: 'Geist', ui-sans-serif, system-ui, -apple-system, sans-serif;
        --font-mono: 'JetBrains Mono', ui-monospace, Menlo, monospace;
        --ink: #0a0a0a;
        --ink-dim: #525252;
        --line: #e5e5e5;
        --accent: #1f883d;
        --accent-faint: #e6f4ea;
        --bg-page: #fafafa;
        --bg-card: #ffffff;
        --bg-input: #ffffff;
        --bg-code: #f4f4f5;
        --error-fg: #b91c1c;
        --error-bg: #fef2f2;
        --error-line: #fecaca;
        --info-fg: #047857;
        --info-bg: #ecfdf5;
        --info-line: #a7f3d0;
        --btn-fg: #ffffff;
      }
      /* Phase 8c PR-D — explicit theme + system-pref fallback. The
         login page renders before the LV WS, so we honor both
         data-theme=dark (set by the toggle JS) and the prefers-color-scheme. */
      :root[data-theme="dark"] {
        --ink: #fafafa;
        --ink-dim: #a3a3a3;
        --line: #27272a;
        --accent: #4ade80;
        --accent-faint: #052e16;
        --bg-page: #09090b;
        --bg-card: #18181b;
        --bg-input: #18181b;
        --bg-code: #27272a;
        --error-fg: #fca5a5;
        --error-bg: #450a0a;
        --error-line: #7f1d1d;
        --info-fg: #6ee7b7;
        --info-bg: #022c1e;
        --info-line: #064e3b;
        --btn-fg: #18181b;
      }
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) {
          --ink: #fafafa;
          --ink-dim: #a3a3a3;
          --line: #27272a;
          --accent: #4ade80;
          --accent-faint: #052e16;
          --bg-page: #09090b;
          --bg-card: #18181b;
          --bg-input: #18181b;
          --bg-code: #27272a;
          --error-fg: #fca5a5;
          --error-bg: #450a0a;
          --error-line: #7f1d1d;
          --info-fg: #6ee7b7;
          --info-bg: #022c1e;
          --info-line: #064e3b;
          --btn-fg: #18181b;
        }
      }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0;
        font-family: var(--font-sans);
        color: var(--ink);
        background:
          radial-gradient(circle at 0% 0%, rgba(31,136,61,0.04), transparent 40%),
          radial-gradient(circle at 100% 100%, rgba(10,10,10,0.03), transparent 40%),
          var(--bg-page);
        display: grid;
        place-items: center;
        padding: 24px;
      }
      .card {
        width: 100%;
        max-width: 380px;
        background: var(--bg-card);
        border: 1px solid var(--line);
        border-radius: 12px;
        padding: 32px 28px;
        box-shadow: 0 1px 0 rgba(0,0,0,0.02), 0 8px 24px -12px rgba(0,0,0,0.06);
      }
      .brand {
        font-family: var(--font-mono);
        font-size: 12px;
        letter-spacing: 0.12em;
        color: var(--ink-dim);
        text-transform: uppercase;
        margin: 0 0 4px;
      }
      h1 { font-size: 22px; font-weight: 600; margin: 0 0 24px; letter-spacing: -0.01em; }
      form { display: flex; flex-direction: column; gap: 10px; }
      label { font-size: 12px; color: var(--ink-dim); font-weight: 500; }
      input {
        padding: 10px 12px;
        border: 1px solid var(--line);
        border-radius: 8px;
        font-size: 14px;
        font-family: var(--font-mono);
        background: var(--bg-input);
        color: var(--ink);
        transition: border-color 120ms ease;
      }
      input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-faint); }
      button {
        margin-top: 4px;
        padding: 10px 14px;
        background: var(--ink);
        color: var(--btn-fg);
        border: none;
        border-radius: 8px;
        font-size: 14px;
        font-weight: 500;
        font-family: var(--font-sans);
        cursor: pointer;
        transition: opacity 120ms ease;
      }
      button:hover { opacity: 0.85; }
      button.secondary {
        background: var(--bg-input);
        color: var(--ink);
        border: 1px solid var(--line);
      }
      button.secondary:disabled {
        cursor: not-allowed;
        opacity: 0.5;
      }
      .error {
        color: var(--error-fg);
        font-size: 13px;
        padding: 10px 12px;
        background: var(--error-bg);
        border: 1px solid var(--error-line);
        border-radius: 8px;
        margin-bottom: 12px;
      }
      .info {
        color: var(--info-fg);
        font-size: 13px;
        padding: 10px 12px;
        background: var(--info-bg);
        border: 1px solid var(--info-line);
        border-radius: 8px;
        margin-bottom: 12px;
      }
      .divider {
        display: flex;
        align-items: center;
        gap: 10px;
        margin: 18px 0;
        color: var(--ink-dim);
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.1em;
      }
      .divider::before, .divider::after {
        content: '';
        flex: 1;
        height: 1px;
        background: var(--line);
      }
      .section-label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--ink-dim);
        margin: 0 0 8px;
        font-weight: 500;
      }
      .disabled-notice {
        font-size: 12px;
        color: var(--ink-dim);
        padding: 10px 12px;
        background: var(--bg-code);
        border: 1px dashed var(--line);
        border-radius: 8px;
      }
      .hint { color: var(--ink-dim); font-size: 12px; margin: 18px 0 0; line-height: 1.55; }
      code { font-family: var(--font-mono); font-size: 11px; background: var(--bg-code); padding: 1px 5px; border-radius: 3px; }
    </style>
  </head>
  <body>
    <div class="card">
      <p class="brand">ezagent</p>
      <h1>{{T_SIGN_IN}}</h1>

      {{WORKSPACE_BANNER}}

      {{NOTICE}}

      <p class="section-label">{{T_WITH_PASSWORD}}</p>
      {{CRED_ERROR}}
      <form method="post" action="/login/credentials">
        <input type="hidden" name="_csrf_token" value="{{CSRF}}">
        {{WORKSPACE_HIDDEN}}
        <label for="entity_uri">{{T_USERNAME_OR_URI}}</label>
        <input type="text" id="entity_uri" name="entity_uri" placeholder="admin   or   entity://user/system/admin" required autofocus>
        <label for="secret">{{T_PASSWORD_OR_TOKEN}}</label>
        <input type="password" id="secret" name="secret" required>
        <button type="submit">{{T_SIGN_IN}}</button>
      </form>

      <div class="divider"><span>{{T_OR}}</span></div>

      <p class="section-label">{{T_WITH_EMAIL_MAGIC_LINK}}</p>
      {{EMAIL_SECTION}}

      <p class="hint">
        Bare handles (<code>admin</code>) resolve to <code>entity://user/system/admin</code>.
        Full URIs (<code>entity://user/&lt;name&gt;</code> /
        <code>entity://agent/&lt;flavor&gt;_&lt;name&gt;</code>) also accepted.
        First-time admin: <code>mix ezagent.user.set_password entity://user/system/admin --password X</code>.
      </p>

      <p class="hint" style="text-align:center;margin-top:8px;">
        <a href="?locale=en" style="color:var(--ink-dim);text-decoration:none;">English</a>
        ·
        <a href="?locale=zh_CN" style="color:var(--ink-dim);text-decoration:none;">中文</a>
      </p>
    </div>
  </body>
  </html>
  """

  @email_form """
  <form method="post" action="/login">
    <input type="hidden" name="_csrf_token" value="{{CSRF}}">
    <label for="email">{{T_EMAIL_ADDRESS}}</label>
    <input type="email" id="email" name="email" placeholder="you@example.com" required>
    <button type="submit" class="secondary">{{T_EMAIL_ME_SIGN_IN_LINK}}</button>
  </form>
  """

  @email_disabled_notice """
  <p class="disabled-notice">{{T_EMAIL_SIGN_IN_DISABLED}}</p>
  """

  # GET /login — unified login page with both credential and email forms.
  # Phase 9 PR-5 (SPEC v3 §6.4 amended): accepts `?workspace=<name>` query
  # param. When present, the bare-handle path canonicalizes into that
  # workspace instead of `default`, and the page surfaces "Signing into
  # <name>" so the user understands the context they're about to enter.
  def new(conn, params) do
    render_login_page(conn, workspace: Map.get(params, "workspace"))
  end

  # POST /login — email magic-link submit. Renders the unified page with
  # an anti-enumeration "if that email can sign in, we've sent a link"
  # notice (identical response regardless of allowlist / rate-limit).
  def create(conn, %{"email" => email}) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    _ = maybe_send_magic_link(conn, email)

    notice =
      ~s(<div class="info">) <>
        esc(gettext("If that email can sign in, we've sent a link. Please check your inbox.")) <>
        "</div>"

    render_login_page(conn, notice: notice)
  end

  def create(conn, _params), do: new(conn, %{})

  # GET /login/credentials — back-compat alias for /login. Renders the
  # same unified page; kept so any cached bookmark / external link still
  # works rather than 404-ing.
  def credentials_new(conn, params) do
    render_login_page(conn, workspace: Map.get(params, "workspace"))
  end

  # POST /login/credentials — password submit. On success: canonical
  # entity:// URI stored in session, redirect to /sessions. On failure:
  # render unified page with inline error above the credentials form
  # (no separate page-bounce — that was the bug Allen reported
  # 2026-05-20).
  #
  # Phase 9 PR-5 (SPEC v3 §6.4 amended): `workspace` form param (or
  # query param) overrides the default workspace for bare-handle
  # canonicalization. Full `entity://` URIs ignore it (the URI already
  # carries its workspace segment).
  def credentials_create(conn, %{"entity_uri" => uri_str, "secret" => secret} = params) do
    workspace = workspace_param(conn, params)

    case SessionPrincipal.canonicalize(uri_str, workspace: workspace) do
      canonical ->
        case authenticate(canonical, secret) do
          :ok ->
            conn
            |> SessionPrincipal.put(canonical, workspace: workspace)
            |> redirect(to: "/sessions")

          :error ->
            render_login_page(conn,
              cred_error: gettext("Invalid URI or credentials."),
              workspace: workspace
            )
        end
    end
  rescue
    # User typed something that isn't a valid handle / URI at all
    # (e.g. "foo@bar.com" or whitespace) — same UX as bad credentials,
    # no enumeration leak.
    ArgumentError ->
      render_login_page(conn,
        cred_error: gettext("Invalid URI or credentials."),
        workspace: workspace_param(conn, params)
      )
  end

  def credentials_create(conn, params) do
    render_login_page(conn,
      cred_error: gettext("Username/URI and password/token are required."),
      workspace: workspace_param(conn, params)
    )
  end

  def delete(conn, params) do
    # Phase 9 PR-8 (SPEC v3 §6.4 amendment 3) — `return_to` lets the
    # workspace-switch denial page POST to /logout and land the user
    # on `/login?workspace=<ws>`. Restricted to local paths
    # (`String.starts_with?("/")` + no `//`) so it can't be a phishing
    # redirector to an external site.
    return_to = params |> Map.get("return_to", "/login") |> safe_return_to()

    conn
    |> SessionPrincipal.clear()
    |> redirect(to: return_to)
  end

  defp safe_return_to(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> "/login"
      # Reject protocol-relative redirects (`//evil.com/x`).
      String.starts_with?(path, "//") -> "/login"
      true -> path
    end
  end

  defp safe_return_to(_), do: "/login"

  # --- internals ----------------------------------------------------

  defp render_login_page(conn, opts) do
    notice = Keyword.get(opts, :notice, "")
    cred_error = Keyword.get(opts, :cred_error)
    workspace = Keyword.get(opts, :workspace)

    cred_error_html =
      if cred_error,
        do: ~s(<div class="error">) <> Plug.HTML.html_escape(cred_error) <> "</div>",
        else: ""

    # Phase 9 PR-5 (SPEC v3 §6.4): show "Signing into <workspace>" banner
    # when the login form was reached via the workspace switcher
    # (logout-and-redirect with ?workspace=<name>). Bare-handle inputs
    # will canonicalize into this workspace instead of `default`.
    {workspace_banner, workspace_hidden} = workspace_form_bits(workspace)

    # Resolve i18n strings on the controller side (the login heredoc
    # is raw HTML, not a HEEx template, so we cannot inline gettext
    # macros — instead we placeholder-substitute pre-translated strings).
    # Locale is set by EzagentWeb.Plugs.Locale earlier in the pipeline.
    email_section =
      if Ezagent.AppSettings.smtp_configured?() do
        @email_form
        |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
        |> String.replace("{{WORKSPACE_HIDDEN}}", workspace_hidden)
        |> String.replace("{{T_EMAIL_ADDRESS}}", esc(gettext("Email address")))
        |> String.replace(
          "{{T_EMAIL_ME_SIGN_IN_LINK}}",
          esc(gettext("Email me a sign-in link"))
        )
      else
        @email_disabled_notice
        |> String.replace(
          "{{T_EMAIL_SIGN_IN_DISABLED}}",
          esc(
            gettext("Email sign-in is not enabled. An admin can turn it on in Settings → SMTP.")
          )
        )
      end

    html =
      @login_html
      |> String.replace("{{NOTICE}}", notice)
      |> String.replace("{{CRED_ERROR}}", cred_error_html)
      |> String.replace("{{WORKSPACE_BANNER}}", workspace_banner)
      |> String.replace("{{WORKSPACE_HIDDEN}}", workspace_hidden)
      |> String.replace("{{EMAIL_SECTION}}", email_section)
      |> String.replace("{{T_PAGE_TITLE}}", esc(gettext("ezagent · sign in")))
      |> String.replace("{{T_SIGN_IN}}", esc(gettext("Sign in")))
      |> String.replace("{{T_WITH_PASSWORD}}", esc(gettext("With password")))
      |> String.replace("{{T_USERNAME_OR_URI}}", esc(gettext("Username or entity URI")))
      |> String.replace("{{T_PASSWORD_OR_TOKEN}}", esc(gettext("Password or token")))
      |> String.replace("{{T_OR}}", esc(gettext("or")))
      |> String.replace("{{T_WITH_EMAIL_MAGIC_LINK}}", esc(gettext("With email magic link")))
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())

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

  # Reads the workspace context from form params (POST) or query string
  # (GET). Returns the requested workspace name as a string, or "default"
  # as the safe fallback. The fallback matches `SessionPrincipal`'s
  # built-in default so behavior is identical when the param is absent.
  defp workspace_param(conn, params) do
    Map.get(params, "workspace") ||
      Map.get(conn.query_params, "workspace") ||
      "default"
  end

  # Renders the workspace banner + hidden form field when a non-default
  # workspace is requested. Returns empty strings for `nil` / "default"
  # so the form is unchanged on the happy path (direct /login visit).
  defp workspace_form_bits(nil), do: {"", ""}
  defp workspace_form_bits("default"), do: {"", ""}

  defp workspace_form_bits(workspace) when is_binary(workspace) do
    escaped = Plug.HTML.html_escape(workspace)

    banner =
      ~s(<div class="info">Signing into workspace <code>) <>
        escaped <>
        ~s(</code>.</div>)

    hidden =
      ~s(<input type="hidden" name="workspace" value=") <> escaped <> ~s(">)

    {banner, hidden}
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
      not Ezagent.AppSettings.smtp_configured?() ->
        Logger.warning(
          "magic_link silent_drop reason=smtp_not_configured email=#{email} ip=#{ip} — " <>
            "admin must configure SMTP at /admin/settings before any sign-in email can send"
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
        do_send_magic_link(email, ip)
    end
  end

  defp do_send_magic_link(email, ip) do
    {:ok, raw} = Ezagent.Entity.MagicLinkToken.mint(email)
    link = EzagentWeb.Endpoint.url() <> "/auth/magic/" <> raw

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
  # on the registration domain allowlist.
  defp send_allowed?(email) do
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, _uri} -> true
      :none -> Ezagent.Registration.domain_allowed?(email)
    end
  end

  # Caller guarantees `uri_str` is already canonical
  # (`entity://user/...` or `entity://agent/...`) — `SessionPrincipal`
  # validated it before we got here.
  defp authenticate(uri_str, secret) when is_binary(uri_str) and is_binary(secret) do
    case Entity.authenticate(URI.parse(uri_str), secret) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end
end
