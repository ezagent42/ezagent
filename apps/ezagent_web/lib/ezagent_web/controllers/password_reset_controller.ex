defmodule EzagentWeb.PasswordResetController do
  @moduledoc """
  task #87 — password reset via an emailed one-time link.

  - `GET  /auth/reset`        — request form (email).
  - `POST /auth/reset`        — mint a `:reset` purpose token + email the link;
    always renders the same generic response (anti-enumeration). Rate-limited.
  - `GET  /auth/reset/:token` — set-new-password form (the token rides in the URL;
    it is not consumed until POST, so a refresh/back doesn't burn it).
  - `POST /auth/reset/:token` — consume the `:reset` token, set the new password,
    redirect to `/login`. No session is created by the reset link itself.

  Plain controller (auth boundary, no websocket dep).
  """
  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn
  require Logger

  alias Ezagent.Entity.MagicLinkToken
  alias Ezagent.Registration
  alias EzagentWeb.AuthBoundaryLayout

  def new(conn, _params), do: render_request_form(conn, nil)

  def create(conn, params) do
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    cond do
      email == "" ->
        render_request_form(conn, gettext("Email is required."))

      {:error, :rate_limited} ==
          EzagentWeb.RateLimiter.check("reset_ip:" <> ip, limit: 10, window_ms: 60 * 60_000) ->
        render_sent(conn, email)

      true ->
        _ = maybe_send_reset(conn, email, ip)
        # Identical response whether or not the account exists (anti-enumeration).
        render_sent(conn, email)
    end
  end

  def edit(conn, %{"token" => token}), do: render_set_password_form(conn, token, nil)

  def update(conn, %{"token" => token, "password" => password}) when is_binary(password) do
    cond do
      String.length(password) < 8 ->
        render_set_password_form(
          conn,
          token,
          gettext("Password must be at least 8 characters.")
        )

      true ->
        case MagicLinkToken.consume(token, "reset") do
          {:ok, email} ->
            case Registration.principal_for_email(email) do
              {:ok, uri} ->
                {:ok, _} = Ezagent.Users.set_password(uri, password)

                conn
                |> put_flash(:info, gettext("Password updated — please sign in."))
                |> redirect(to: "/login")

              :none ->
                bounce_login(conn, gettext("Could not reset password — please try again."))
            end

          {:error, _reason} ->
            bounce_login(conn, gettext("That reset link is invalid or has expired."))
        end
    end
  end

  def update(conn, %{"token" => token}),
    do: render_set_password_form(conn, token, gettext("Password is required."))

  # --- internals ----------------------------------------------------------

  defp maybe_send_reset(conn, email, ip) do
    case Registration.principal_for_email(email) do
      {:ok, _uri} ->
        {:ok, raw} = MagicLinkToken.mint(email, purpose: "reset")
        link = EzagentWeb.UrlHelper.request_base_url(conn) <> "/auth/reset/" <> raw

        case EzagentWeb.Mailer.deliver_password_reset(email, link) do
          {:ok, _} ->
            Logger.info("password_reset sent email=#{email} ip=#{ip}")

          {:error, r} ->
            Logger.error("password_reset mailer_failed email=#{email} reason=#{inspect(r)}")
        end

      :none ->
        Logger.info("password_reset silent_drop reason=no_account email=#{email} ip=#{ip}")
    end

    :ok
  end

  defp bounce_login(conn, msg), do: conn |> put_flash(:error, msg) |> redirect(to: "/login")

  # --- rendering ----------------------------------------------------------

  defp render_request_form(conn, error) do
    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Reset your password"))}</h1>
        #{AuthBoundaryLayout.flash_html(conn)}
        #{error_block(error)}
        <form method="post" action="/auth/reset">
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
          <label for="email">#{esc(gettext("Email address"))}</label>
          <input type="email" id="email" name="email" placeholder="you@example.com" required autofocus>
          <button type="submit">#{esc(gettext("Send reset link"))}</button>
        </form>
        <p class="hint" style="text-align:center;margin-top:8px;">
          <a href="/login">#{esc(gettext("Back to sign in"))}</a>
        </p>
    """

    send_card(conn, gettext("Reset your password"), body)
  end

  defp render_sent(conn, email) do
    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Check your email"))}</h1>
        <div class="info">#{esc(gettext("If an account exists for"))} <code>#{esc(email)}</code>, #{esc(gettext("we've sent a password reset link."))}</div>
        <p class="hint" style="text-align:center;margin-top:8px;">
          <a href="/login">#{esc(gettext("Back to sign in"))}</a>
        </p>
    """

    send_card(conn, gettext("Check your email"), body)
  end

  defp render_set_password_form(conn, token, error) do
    body = """
        <p class="brand">ezagent</p>
        <h1>#{esc(gettext("Set a new password"))}</h1>
        #{error_block(error)}
        <form method="post" action="/auth/reset/#{esc(token)}">
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
          <label for="password">#{esc(gettext("New password"))}</label>
          <input type="password" id="password" name="password" required autofocus>
          <button type="submit">#{esc(gettext("Update password"))}</button>
        </form>
    """

    send_card(conn, gettext("Set a new password"), body)
  end

  defp error_block(nil), do: ""
  defp error_block(error), do: ~s(<div class="error">) <> esc(error) <> "</div>"

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
