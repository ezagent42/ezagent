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
  @login_card_body """
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
        <input type="text" id="entity_uri" name="entity_uri" placeholder="admin or full user URI" required autofocus>
        <label for="secret">{{T_PASSWORD_OR_TOKEN}}</label>
        <input type="password" id="secret" name="secret" required>
        <button type="submit">{{T_SIGN_IN}}</button>
      </form>

      <div class="divider"><span>{{T_OR}}</span></div>

      <p class="section-label">{{T_WITH_EMAIL_MAGIC_LINK}}</p>
      {{EMAIL_SECTION}}

      <p class="hint">
        Bare handles (<code>admin</code>) resolve in the selected workspace.
        Full user or agent URIs are also accepted.
        First-time admin: <code>mix ezagent.user.set_password &lt;admin-user-uri&gt; --password X</code>.
      </p>

      <p class="hint" style="text-align:center;margin-top:8px;">
        <a href="?locale=en" style="color:var(--ink-dim);text-decoration:none;">English</a>
        ·
        <a href="?locale=zh_CN" style="color:var(--ink-dim);text-decoration:none;">中文</a>
      </p>
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
    # SPEC #324 rev 3 (Allen 2026-05-25): full entity:// URIs carry
    # workspace structurally; bare handles REQUIRE explicit workspace
    # param. workspace_param/2 returns `nil` (not "system") on missing —
    # canonicalize/2 raises ArgumentError on a bare handle without
    # :workspace, which we catch below to render the page with a
    # "select workspace" error.
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
    # ArgumentError covers (a) bare handle without :workspace (SPEC #324
    # rev 3), and (b) malformed URI/handle. Either way, same UX —
    # render the page with an inline error, no enumeration leak.
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

  @doc """
  2026-06-05 (Allen 批准) — loom 分享页轻量自助注册(开放,**跳过邮箱验证**)。

  建一个 `entity://user/<ws>/<username>` 用户(Bcrypt 密码 + User Kind 默认 caps)并
  **即登录**(`SessionPrincipal.put`)。仅供 loom preview 的登录/注册 modal 用。
  注意:这是故意的开放注册(不验邮箱),是 Allen 为内部测试场景批准的取舍。
  body: `%{"ws" => ws, "username" => u, "password" => p}` + `_csrf_token`。
  """
  def loom_signup(conn, %{"ws" => ws, "username" => username, "password" => password})
      when is_binary(ws) and is_binary(username) and is_binary(password) do
    ws = String.trim(ws)
    username = String.trim(username)

    cond do
      ws == "" or not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, username) or String.length(password) < 4 ->
        signup_json(conn, %{ok: false, error: "用户名只能含字母/数字/_/-,密码至少 4 位"})

      loom_user_exists?("entity://user/#{ws}/#{username}") ->
        signup_json(conn, %{ok: false, error: "用户名已被占用"})

      true ->
        uri = "entity://user/#{ws}/#{username}"

        case Ezagent.Users.create(uri, password, []) do
          {:ok, _} ->
            _ = loom_safe_spawn_user(uri)

            conn
            |> SessionPrincipal.put(uri)
            |> signup_json(%{ok: true, entity_uri: uri})

          {:error, reason} ->
            Logger.warning("loom_signup create failed for #{uri}: #{inspect(reason)}")
            signup_json(conn, %{ok: false, error: "注册失败,请换个用户名重试"})
        end
    end
  end

  def loom_signup(conn, _params), do: signup_json(conn, %{ok: false, error: "参数缺失"})

  defp loom_user_exists?(uri) do
    Ezagent.Users.get_by_uri(uri) != nil
  rescue
    _ -> false
  end

  defp loom_safe_spawn_user(uri) do
    Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(uri))
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signup_json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data))
  end

  # --- internals ----------------------------------------------------

  defp render_login_page(conn, opts) do
    notice = Keyword.get(opts, :notice, "")
    cred_error = Keyword.get(opts, :cred_error)
    workspace = Keyword.get(opts, :workspace)

    cred_error_html =
      if cred_error,
        do: ~s(<div class="error">) <> Plug.HTML.html_escape(cred_error) <> "</div>",
        else: ""

    # Allen 2026-05-24: surface Phoenix flash on /login so a redirect
    # like `put_flash(:error, ...) |> redirect(to: "/login")` actually
    # shows the user WHY they landed here. Mobile-visible styling
    # (`.flash-mobile` — sticky-top + larger + high-contrast). Prepend
    # to `notice` so it always appears at the top of the card.
    flash_html = AuthBoundaryLayout.flash_html(conn)
    notice = flash_html <> notice

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

    card_body =
      @login_card_body
      |> String.replace("{{NOTICE}}", notice)
      |> String.replace("{{CRED_ERROR}}", cred_error_html)
      |> String.replace("{{WORKSPACE_BANNER}}", workspace_banner)
      |> String.replace("{{WORKSPACE_HIDDEN}}", workspace_hidden)
      |> String.replace("{{EMAIL_SECTION}}", email_section)
      |> String.replace("{{T_SIGN_IN}}", esc(gettext("Sign in")))
      |> String.replace("{{T_WITH_PASSWORD}}", esc(gettext("With password")))
      |> String.replace("{{T_USERNAME_OR_URI}}", esc(gettext("Username or entity URI")))
      |> String.replace("{{T_PASSWORD_OR_TOKEN}}", esc(gettext("Password or token")))
      |> String.replace("{{T_OR}}", esc(gettext("or")))
      |> String.replace("{{T_WITH_EMAIL_MAGIC_LINK}}", esc(gettext("With email magic link")))
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

  # Reads the workspace context from form params (POST) or query string
  # (GET). Returns the requested workspace name as a string, or `nil`
  # if no workspace was requested.
  #
  # SPEC #324 rev 3 (Allen 2026-05-25): there is NO silent fallback to
  # `"system"` (or any workspace). Callers MUST handle nil:
  # - full `entity://` URIs ignore the workspace param (URI carries it)
  # - bare handles with nil workspace → `canonicalize/2` raises
  #   ArgumentError → caught by the credentials_create rescue clause,
  #   which renders the page with an inline error.
  #
  # Removing the silent `|| "system"` fallback fixes the bug where a
  # tenant user posting bare `/login/credentials` would silently land
  # in the admin workspace.
  defp workspace_param(conn, params) do
    Map.get(params, "workspace") || Map.get(conn.query_params, "workspace")
  end

  # Renders the workspace banner + hidden form field when a non-default
  # workspace is requested. Returns empty strings for `nil` / `"system"`
  # (the admin-login default) so the form is unchanged on the happy
  # path (direct /login visit).
  defp workspace_form_bits(nil), do: {"", ""}
  defp workspace_form_bits("system"), do: {"", ""}

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
  # accepted by at least one workspace's `magic_link_rule` (SPEC v2
  # PR-A, Allen 2026-05-24, codex round-1 HIGH-1 fix). `email_allowed?/1`
  # consults the new per-workspace rule path AND the legacy
  # `registration_domains` AppSetting (back-compat during PR-B
  # transition; PR-B removes the AppSetting consultation entirely).
  defp send_allowed?(email) do
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, _uri} -> true
      :none -> Ezagent.Registration.email_allowed?(email)
    end
  end

  # Caller guarantees `uri_str` is already canonical
  # (`entity://user/...` or `entity://agent/...`) — `SessionPrincipal`
  # validated it before we got here.
  defp authenticate(uri_str, secret) when is_binary(uri_str) and is_binary(secret) do
    case Entity.authenticate(Ezagent.URI.new!(uri_str), secret) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end
end
