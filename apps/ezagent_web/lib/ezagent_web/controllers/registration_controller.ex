defmodule EzagentWeb.RegistrationController do
  @moduledoc """
  Username & Auth M3 — registration completion (`/register/complete`).

  Reached only after `MagicLinkController` verified the email and put
  `:pending_registration_email` in the session. The user picks a handle
  (the URI slug — editable HERE and only here; frozen once the principal
  exists) and a display name.

  Uses the light `Phoenix.Controller` header (matching `SessionController`).
  """
  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn

  alias Ezagent.Registration
  alias EzagentWeb.AuthBoundaryLayout

  # PR-E (SPEC v2 §G7): registration page reuses the
  # `AuthBoundaryLayout` chrome — same Geist font, same design tokens,
  # same card, same dark-mode rules, same mobile-visible flash — so
  # `/register/complete` looks like a sister page to `/login`. Only
  # the card body (the handle + display_name form) lives here.
  #
  # Built at RUNTIME via `card_body/0` so user-facing strings pass
  # through `gettext/1` (a compile-time `@card_body` module attribute
  # cannot interpolate macros). `{{...}}` placeholders are substituted
  # in `render_form/5`.
  defp card_body do
    """
        <p class="brand">ezagent</p>
        <h1>#{gettext("Complete your registration")}</h1>
        {{FLASH}}
        {{ERROR}}
        <form method="post" action="/register/complete">
          <input type="hidden" name="_csrf_token" value="{{CSRF}}">
          <label for="handle">#{gettext("Username (your permanent handle — entity://user/<handle>)")}</label>
          <input type="text" id="handle" name="handle" value="{{HANDLE}}" required autofocus>
          <label for="display_name">#{gettext("Display name (you can change this later)")}</label>
          <input type="text" id="display_name" name="display_name" value="{{DISPLAY}}" required>
          <button type="submit">#{gettext("Create my account")}</button>
        </form>
        <p class="hint">#{gettext("Signing up as")} <code>{{EMAIL}}</code></p>
    """
  end

  def complete_new(conn, _params) do
    case {get_session(conn, :pending_registration_email),
          get_session(conn, :pending_workspace)} do
      {email, workspace} when is_binary(email) and is_binary(workspace) ->
        # PR-B 2026-05-24: workspace MUST be set by the onboarding
        # controller. If it isn't, redirect back to onboarding.
        slug = Registration.suggest_slug(Registration.derive_slug(email), workspace)
        render_form(conn, email, slug, default_display(email), nil)

      {email, _} when is_binary(email) ->
        # Email but no workspace — back to onboarding.
        redirect(conn, to: "/onboarding/workspace")

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, %{"handle" => handle, "display_name" => display_name}) do
    case {get_session(conn, :pending_registration_email),
          get_session(conn, :pending_workspace)} do
      {email, workspace} when is_binary(email) and is_binary(workspace) ->
        # Codex PR-B round-1 HIGH-2: REVALIDATE at registration time
        # that the workspace still exists AND accepts this email.
        # Pre-fix: stale :pending_workspace from a since-deleted
        # workspace or a rule that was removed becomes permanent
        # tenant membership — irreversibly. Re-check immediately
        # before the user/member write.
        cond do
          not workspace_still_valid?(workspace, email) ->
            conn
            |> put_flash(
              :error,
              gettext("That workspace no longer accepts your email. Please pick again.")
            )
            |> delete_session(:pending_workspace)
            |> redirect(to: "/onboarding/workspace")

          true ->
            do_complete_create(conn, handle, display_name, email, workspace)
        end

      {email, _} when is_binary(email) ->
        redirect(conn, to: "/onboarding/workspace")

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, _params) do
    redirect(conn, to: "/register/complete")
  end

  defp workspace_still_valid?(workspace_name, email) do
    Ezagent.Workspace.accepts_email?("workspace://" <> workspace_name, email)
  end

  defp do_complete_create(conn, handle, display_name, email, workspace) do
    case Registration.principal_for_email(email) do
      {:ok, uri} ->
        # Concurrent-registration / re-entry guard (spec §7): the
        # email became a principal since the magic link was issued.
        # Email ownership was already proven by the link -> log in,
        # do NOT double-create.
        login_and_redirect(conn, uri)

      :none ->
        slug = handle |> String.trim() |> String.downcase()

        case Registration.create_principal(slug, display_name, email, workspace) do
          {:ok, uri} ->
            login_and_redirect(conn, uri)

          {:error, :slug_taken} ->
            suggestion = Registration.suggest_slug(slug, workspace)

            render_form(
              conn,
              email,
              suggestion,
              display_name,
              gettext("“%{slug}” is taken. Try “%{suggestion}”.",
                slug: slug,
                suggestion: suggestion
              )
            )

          {:error, reason} ->
            render_form(
              conn,
              email,
              slug,
              display_name,
              gettext("Could not register: %{reason}", reason: inspect(reason))
            )
        end
    end
  end

  defp login_and_redirect(conn, uri) do
    :ok = Ezagent.Entity.spawn_principal(uri)

    conn
    |> delete_session(:pending_registration_email)
    |> EzagentWeb.SessionPrincipal.put(URI.to_string(uri))
    |> redirect(to: "/sessions")
  end

  defp render_form(conn, email, handle, display, error) do
    error_block =
      if error,
        do: ~s(<div class="error">#{Plug.HTML.html_escape(error) |> safe_to_string()}</div>),
        else: ""

    card_body_html =
      card_body()
      |> String.replace("{{FLASH}}", AuthBoundaryLayout.flash_html(conn))
      |> String.replace("{{ERROR}}", error_block)
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
      |> String.replace("{{HANDLE}}", Plug.HTML.html_escape(handle) |> safe_to_string())
      |> String.replace("{{DISPLAY}}", Plug.HTML.html_escape(display) |> safe_to_string())
      |> String.replace("{{EMAIL}}", Plug.HTML.html_escape(email) |> safe_to_string())

    html =
      AuthBoundaryLayout.head_html(gettext("Complete registration")) <>
        AuthBoundaryLayout.body_open() <>
        AuthBoundaryLayout.card_open() <>
        card_body_html <>
        AuthBoundaryLayout.card_close() <>
        AuthBoundaryLayout.body_close()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp safe_to_string({:safe, iodata}), do: IO.iodata_to_binary(iodata)
  defp safe_to_string(s) when is_binary(s), do: s

  # Humanize the email local part as the default display name.
  defp default_display(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.split(~r/[._+-]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
