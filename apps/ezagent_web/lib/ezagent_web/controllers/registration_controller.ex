defmodule EzagentWeb.RegistrationController do
  @moduledoc """
  task #87 Decision 10 — email+password self-registration (`/register`) +
  email confirmation (`/auth/confirm/:token`).

  Registration is **closed by default** (`AppSettings.registration_open?`). When
  open, it optionally requires an invite code (`registration_require_invite?`).
  An invite code carries the authoritative target workspace; without one (open
  mode) the registrant gets a fresh random-suffixed workspace. The user is
  created `email_verified: false`; clicking the confirmation link (a `:confirm`
  purpose one-time token) flips `email_verified` and routes to `/login`.

  Plain controller (auth boundary, no websocket dep) — heredoc + placeholder
  substitution, matching `SessionController`.
  """
  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn
  require Logger

  alias Ezagent.Entity.{InviteCode, MagicLinkToken, RegistrationRequest}
  alias Ezagent.Registration
  alias EzagentWeb.AuthBoundaryLayout

  @doc "GET /register — closed notice, or the email+password form."
  def new(conn, params) do
    code = params |> Map.get("invite", "") |> String.trim()

    cond do
      Ezagent.AppSettings.registration_open?() ->
        render_form(conn, %{"invite_code" => code}, nil)

      valid_invite?(code) ->
        render_form(conn, %{"invite_code" => code}, nil)

      true ->
        error = if code == "", do: nil, else: gettext("That invite code is not valid.")
        render_closed(conn, error)
    end
  end

  @doc "POST /register — gated; create unconfirmed user + send confirmation."
  def create(conn, params) do
    cond do
      not registration_allowed?(params) ->
        render_closed(conn)

      rate_limited?(conn, params) ->
        # Generic — do not reveal which limiter tripped.
        render_form(conn, params, gettext("Too many attempts. Please try again later."))

      true ->
        do_create(conn, params)
    end
  end

  @doc "POST /register/request — record a closed-registration access request."
  def request_access(conn, params) do
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    if email != "" and not request_rate_limited?(ip, email) do
      case RegistrationRequest.request(email, ip) do
        {:ok, _request} ->
          :ok

        {:error, changeset} ->
          Logger.info(
            "registration request rejected email=#{email} errors=#{inspect(changeset.errors)}"
          )
      end
    else
      Logger.info(
        "registration request ignored email=#{email} ip=#{ip} reason=blank_or_rate_limited"
      )
    end

    render_request_received(conn)
  end

  @doc "GET /auth/confirm/:token — verify email ownership, set email_verified."
  def confirm(conn, %{"token" => token}) do
    case MagicLinkToken.consume(token, "confirm") do
      {:ok, email} ->
        case Registration.principal_for_email(email) do
          {:ok, uri} ->
            _ = Ezagent.Users.mark_email_verified(uri)

            conn
            |> put_flash(:info, gettext("Email confirmed — please sign in."))
            |> redirect(to: "/login")

          :none ->
            bounce_login(conn, gettext("Could not confirm — please register again."))
        end

      {:error, _reason} ->
        bounce_login(conn, gettext("That confirmation link is invalid or has expired."))
    end
  end

  # --- internals ----------------------------------------------------------

  defp do_create(conn, params) do
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
    password = Map.get(params, "password", "")
    display_name = params |> Map.get("display_name", "") |> String.trim()
    require_invite = Ezagent.AppSettings.registration_require_invite?()
    code = params |> Map.get("invite_code", "") |> String.trim()

    cond do
      email == "" or password == "" or display_name == "" ->
        render_form(conn, params, gettext("Email, password, and display name are required."))

      require_invite and code == "" ->
        render_form(conn, params, gettext("An invite code is required."))

      true ->
        opts = if code != "", do: [invite_code: code], else: [mode: :open_self_serve]

        case Registration.register_with_password(email, password, display_name, opts) do
          {:ok, uri} ->
            send_confirmation(conn, email, uri)
            # Identical response whether or not the email was new
            # (anti-enumeration, Codex #6): always "check your email".
            render_check_email(conn, email, uri)

          {:error, :email_taken} ->
            # Same response as success → does not reveal the email exists.
            render_check_email(conn, email, nil)

          {:error, {:invite, _reason}} ->
            render_form(conn, params, gettext("That invite code is not valid."))

          {:error, reason} ->
            Logger.warning("registration failed email=#{email} reason=#{inspect(reason)}")
            render_form(conn, params, gettext("Could not complete registration."))
        end
    end
  end

  defp send_confirmation(conn, email, _uri) do
    {:ok, raw} = MagicLinkToken.mint(email, purpose: "confirm")
    link = EzagentWeb.UrlHelper.request_base_url(conn) <> "/auth/confirm/" <> raw

    case EzagentWeb.Mailer.deliver_confirmation(email, link) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("confirmation email failed email=#{email} reason=#{inspect(reason)}")
    end
  end

  # Per-IP + per-email registration rate limits (anti-abuse, Codex #6).
  defp rate_limited?(conn, params) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()

    {:error, :rate_limited} ==
      EzagentWeb.RateLimiter.check("register_ip:" <> ip, limit: 10, window_ms: 60 * 60_000) or
      (email != "" and
         {:error, :rate_limited} ==
           EzagentWeb.RateLimiter.check("register_email:" <> email,
             limit: 5,
             window_ms: 15 * 60_000
           ))
  end

  defp request_rate_limited?(ip, email) do
    {:error, :rate_limited} ==
      EzagentWeb.RateLimiter.check("registration_request_ip:" <> ip,
        limit: 10,
        window_ms: 60 * 60_000
      ) or
      {:error, :rate_limited} ==
        EzagentWeb.RateLimiter.check("registration_request_email:" <> email,
          limit: 3,
          window_ms: 60 * 60_000
        )
  end

  defp registration_allowed?(params) do
    Ezagent.AppSettings.registration_open?() or
      valid_invite?(params |> Map.get("invite_code", "") |> String.trim())
  end

  defp valid_invite?(""), do: false
  defp valid_invite?(code), do: match?({:ok, _row}, InviteCode.validate(code))

  defp bounce_login(conn, msg) do
    conn |> put_flash(:error, msg) |> redirect(to: "/login")
  end

  # --- rendering ----------------------------------------------------------

  defp render_closed(conn, error \\ nil) do
    error_block = if error, do: ~s(<div class="error">) <> esc(error) <> "</div>", else: ""

    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Sign up"))}</h1>
        <div class="info">#{esc(gettext("Registration is currently closed."))}</div>
        #{error_block}
        <form id="registration-request-form" method="post" action="/register/request">
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
          <label for="request_email">#{esc(gettext("Request access"))}</label>
          <input type="email" id="request_email" name="email" placeholder="you@example.com" required>
          <button type="submit">#{esc(gettext("Submit request"))}</button>
        </form>
        <form id="invite-registration-form" method="get" action="/register">
          <label for="invite">#{esc(gettext("Already have an invite code?"))}</label>
          <input type="text" id="invite" name="invite" required>
          <button type="submit">#{esc(gettext("Continue with invite"))}</button>
        </form>
        <p class="hint" style="text-align:center;margin-top:8px;">
          <a href="/login">#{esc(gettext("Back to sign in"))}</a>
        </p>
    """

    send_card(conn, gettext("Sign up"), body)
  end

  defp render_request_received(conn) do
    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Request received"))}</h1>
        <div class="info">#{esc(gettext("We've received your request and will contact you when access is available."))}</div>
        <p class="hint" style="text-align:center;margin-top:8px;"><a href="/login">#{esc(gettext("Back to sign in"))}</a></p>
    """

    send_card(conn, gettext("Request received"), body)
  end

  defp render_check_email(conn, email, uri) do
    workspace_notice =
      case uri do
        %URI{} ->
          workspace = uri |> Ezagent.URI.entity_workspace_uri() |> Ezagent.URI.name!()

          "<p class=\"hint\">#{esc(gettext("Your workspace %{workspace} is ready. Confirm your email, then sign in to enter it.", workspace: workspace))}</p>"

        _ ->
          ""
      end

    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Check your email"))}</h1>
        <div class="info">#{esc(gettext("If your details are valid, we've sent a confirmation link to"))} <code>#{esc(email)}</code>.</div>
        #{workspace_notice}
        <p class="hint" style="text-align:center;margin-top:8px;">
          <a href="/login">#{esc(gettext("Back to sign in"))}</a>
        </p>
    """

    send_card(conn, gettext("Check your email"), body)
  end

  defp render_form(conn, params, error) do
    require_invite = Ezagent.AppSettings.registration_require_invite?()
    email = params |> Map.get("email", "") |> to_string()
    display_name = params |> Map.get("display_name", "") |> to_string()
    invite_code = params |> Map.get("invite_code", "") |> to_string()

    error_block =
      if error, do: ~s(<div class="error">) <> esc(error) <> "</div>", else: ""

    invite_field =
      if require_invite or invite_code != "" do
        readonly = if invite_code != "", do: " readonly", else: ""

        """
        <label for="invite_code">#{esc(gettext("Invite code"))}</label>
        <input type="text" id="invite_code" name="invite_code" value="#{esc(invite_code)}" required#{readonly}>
        """
      else
        ""
      end

    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Create your account"))}</h1>
        #{AuthBoundaryLayout.flash_html(conn)}
        #{error_block}
        <form method="post" action="/register">
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
          <label for="email">#{esc(gettext("Email address"))}</label>
          <input type="email" id="email" name="email" value="#{esc(email)}" placeholder="you@example.com" required autofocus>
          <label for="display_name">#{esc(gettext("Display name"))}</label>
          <input type="text" id="display_name" name="display_name" value="#{esc(display_name)}" required>
          <label for="password">#{esc(gettext("Password"))}</label>
          <input type="password" id="password" name="password" required>
          #{invite_field}
          <button type="submit">#{esc(gettext("Create account"))}</button>
        </form>
        <p class="hint" style="text-align:center;margin-top:8px;">
          <a href="/login">#{esc(gettext("Already have an account? Sign in"))}</a>
        </p>
    """

    send_card(conn, gettext("Create your account"), body)
  end

  defp send_card(conn, title, body) do
    html =
      AuthBoundaryLayout.head_html(gettext("ezagent · %{title}", title: title)) <>
        AuthBoundaryLayout.body_open() <>
        AuthBoundaryLayout.card_open() <>
        body <>
        AuthBoundaryLayout.card_close() <>
        AuthBoundaryLayout.body_close()

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp esc(text) do
    case Plug.HTML.html_escape(text) do
      bin when is_binary(bin) -> bin
      iodata -> IO.iodata_to_binary(iodata)
    end
  end
end
