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
    case MagicLinkToken.consume(token) do
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
        # Existing principal -> log in. Ensure the Kind is alive with
        # hydrated caps, then store via the validating principal funnel
        # (also rotates the session — fixation defence).
        :ok = Ezagent.Entity.spawn_principal(uri)

        conn
        |> SessionPrincipal.put(URI.to_string(uri))
        |> redirect(to: "/sessions")

      :none ->
        # New email -> carry the verified email into a short-lived
        # pending-registration session, go collect handle + display name.
        conn
        |> configure_session(renew: true)
        |> put_session(:pending_registration_email, email)
        |> redirect(to: "/register/complete")
    end
  end

  defp error_message(:expired),
    do: gettext("That sign-in link has expired. Please request a new one.")

  defp error_message(:consumed),
    do: gettext("That sign-in link was already used. Please request a new one.")

  defp error_message(_), do: gettext("Invalid sign-in link. Please request a new one.")
end
