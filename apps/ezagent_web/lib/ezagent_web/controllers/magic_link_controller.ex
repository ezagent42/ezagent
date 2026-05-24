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

      {:error, :consumed} ->
        # Allen 2026-05-24 UX fix: a token marked `consumed_at` but
        # whose email never finished registration should LET THE USER
        # RE-ENTER `/register/complete`. The original consume already
        # delivered the email to /register/complete; if user closed
        # the tab / didn't fill the form, click-again should resume
        # the same registration session rather than the confusing
        # "already used" error → login bounce.
        consumed_fallback(conn, token)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: "/login")
    end
  end

  # Token is consumed but still within expires_at — recover email via
  # peek/1 + route based on registration state:
  # - Email has no principal → re-enter /onboarding/workspace (PR-B
  #   2026-05-24 — the user picks/creates a workspace first, then
  #   /register/complete collects the handle)
  # - Email HAS a principal → user already registered + logged in
  #   elsewhere; tell them so and bounce to /login for re-auth
  # - Token gone / truly expired → fall through to default error
  defp consumed_fallback(conn, token) do
    case MagicLinkToken.peek(token) do
      {:ok, email, :consumed} ->
        case Registration.principal_for_email(email) do
          :none ->
            # User clicked but never completed registration. Re-route
            # to /onboarding/workspace with a fresh pending-registration
            # session so they can resume from the workspace pick step.
            conn
            |> configure_session(renew: true)
            |> put_session(:pending_registration_email, email)
            |> redirect(to: "/onboarding/workspace")

          {:ok, _uri} ->
            # User IS registered — they probably clicked an older
            # email after already signing in elsewhere. Bounce to
            # /login with a clearer message.
            conn
            |> put_flash(
              :info,
              gettext("Your account is registered. Please sign in with your email or password.")
            )
            |> redirect(to: "/login")
        end

      _ ->
        conn
        |> put_flash(:error, error_message(:consumed))
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
        # PR-B 2026-05-24 (Allen, SPEC v2): new email → workspace
        # onboarding. The user picks an existing workspace to join
        # (matched by email rule) OR creates a new one. Then
        # /register/complete collects the handle.
        #
        # Codex round-1 HIGH-2 — `configure_session(renew: true)` plus
        # explicit `delete_session(:pending_workspace)` clears any
        # stale onboarding state from a prior magic-link click. A
        # subsequent /register/complete revalidates :pending_workspace
        # before any irreversible write (registration_controller.ex).
        conn
        |> configure_session(renew: true)
        |> put_session(:pending_registration_email, email)
        |> delete_session(:pending_workspace)
        |> redirect(to: "/onboarding/workspace")
    end
  end

  defp error_message(:expired),
    do: gettext("That sign-in link has expired. Please request a new one.")

  defp error_message(:consumed),
    do: gettext("That sign-in link was already used. Please request a new one.")

  defp error_message(_), do: gettext("Invalid sign-in link. Please request a new one.")
end
