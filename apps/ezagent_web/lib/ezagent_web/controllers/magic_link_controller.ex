defmodule EzagentWeb.MagicLinkController do
  @moduledoc """
  Username & Auth M3 — magic-link consumption (`GET /auth/magic/:token`).

  Plain controller (not LiveView) — this is the auth boundary; it must
  not depend on a websocket. Consumes the single-use token, then either
  logs an existing principal in or starts registration.

  Uses the light `Phoenix.Controller` header (matching `SessionController`)
  — no layouts, no verified routes; just redirects + flash + session.
  """
  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn

  alias Ezagent.Entity.MagicLinkToken
  alias Ezagent.Registration
  alias EzagentWeb.SessionPrincipal

  def consume(conn, %{"token" => token}) do
    # task #87 — magic-link is now a LOGIN method for EXISTING accounts only
    # (purpose "login"). New-account creation goes through email+password
    # `/register`. The legacy onboarding/register-complete chain is retired.
    case MagicLinkToken.consume(token, "login") do
      {:ok, email} ->
        route_by_email(conn, email)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: "/login")
    end
  end

  defp route_by_email(conn, email) do
    case Registration.principal_for_email(email) do
      {:ok, uri} ->
        # task #87 (codex final-review HIGH) — magic-link login MUST also honor
        # the email_verified gate, otherwise an unconfirmed registrant could
        # log in via a magic link without ever confirming. (Belt-and-braces:
        # `send_allowed?/1` already refuses to send links to unverified
        # principals, but the consume path must not trust that alone.)
        if email_verified?(uri) do
          # Ensure the Kind is alive with hydrated caps, then store via the
          # validating principal funnel (also rotates the session).
          :ok = Ezagent.Entity.spawn_principal(uri)

          conn
          |> SessionPrincipal.put(URI.to_string(uri), workspace: nil)
          |> redirect(to: "/sessions")
        else
          conn
          |> put_flash(:error, gettext("Please confirm your email before signing in."))
          |> redirect(to: "/login")
        end

      :none ->
        # task #87 — no account for this email. Magic-link no longer creates
        # accounts; send the visitor to email+password registration.
        conn
        |> put_flash(:info, gettext("No account found for that email. Please create one."))
        |> redirect(to: "/register")
    end
  end

  defp email_verified?(uri) do
    case Ezagent.Users.get_by_uri(uri) do
      %{email_verified: true} -> true
      _ -> false
    end
  end

  defp error_message(:expired),
    do: gettext("That sign-in link has expired. Please request a new one.")

  defp error_message(:consumed),
    do: gettext("That sign-in link was already used. Please request a new one.")

  defp error_message(_), do: gettext("Invalid sign-in link. Please request a new one.")
end
