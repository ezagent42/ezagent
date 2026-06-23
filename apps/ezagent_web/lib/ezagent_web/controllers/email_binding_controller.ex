defmodule EzagentWeb.EmailBindingController do
  @moduledoc """
  #88 PR-2 (SPEC §4.4) — the email-binding verification confirm endpoint.

  `GET /auth/email/confirm/:token` — the human clicks the link in the
  verification email (a LINK, not a reply token: a reply would be rejected
  by the very `From == verified address` gate it is trying to open). A
  valid, unexpired, single-use token flips the binding to `verified`,
  activating outbound + inbound for that session↔email thread.

  Plain controller (auth boundary, no websocket dep), mirroring
  `RegistrationController.confirm`. Delegates the token logic to
  `Ezagent.Email.Verification.confirm/1` (the email plugin owns it; web is
  already an umbrella dep of `ezagent_plugin_email`).
  """
  use Phoenix.Controller, formats: [:html], layouts: []

  import Plug.Conn

  @doc "GET /auth/email/confirm/:token — verify the binding, set :verified."
  def confirm(conn, %{"token" => token}) do
    case Ezagent.Email.Verification.confirm(token) do
      {:ok, _row} ->
        respond(
          conn,
          200,
          "Email binding confirmed",
          "This email address is now bound to your ezagent session. " <>
            "Replies to messages from that session will be delivered to it."
        )

      {:error, :expired} ->
        respond(
          conn,
          410,
          "Link expired",
          "That verification link has expired. Re-bind the session to get a fresh link."
        )

      {:error, :invalid} ->
        respond(
          conn,
          404,
          "Invalid link",
          "That verification link is invalid or has already been used."
        )
    end
  end

  defp respond(conn, status, title, detail) do
    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>#{title}</title></head>
    <body style="font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem">
    <h1>#{title}</h1><p>#{detail}</p></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
