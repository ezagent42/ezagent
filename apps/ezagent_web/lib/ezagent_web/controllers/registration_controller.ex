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

  # i18n (Allen 2026-05-22) — the registration boundary page is a raw
  # self-contained heredoc (auth boundary — keeps its own <style>, no
  # app.css). Built at RUNTIME via `form_html/0` so its user-facing
  # strings can pass through `gettext/1` (a compile-time `@form_html`
  # module attribute cannot). `{{...}}` placeholders are still
  # substituted in `render_form/5`.
  defp form_html do
    """
    <!DOCTYPE html>
    <html><head><title>#{gettext("Complete registration")}</title><meta charset="utf-8">
    <style>
      body { font-family: -apple-system, sans-serif; max-width: 420px; margin: 80px auto; padding: 24px; }
      h1 { font-size: 22px; } form { display: flex; flex-direction: column; gap: 12px; }
      label { font-size: 13px; color: #666; }
      input { padding: 8px 10px; border: 1px solid #d1d5da; border-radius: 4px; font-size: 14px; }
      button { padding: 10px; background: #1f883d; color: white; border: none; border-radius: 4px; cursor: pointer; }
      .err { color: #cf222e; font-size: 13px; padding: 8px; background: #ffebe9; border-radius: 4px; }
      .hint { color: #57606a; font-size: 12px; }
    </style></head><body>
    <h1>#{gettext("Complete your registration")}</h1>
    {{ERROR}}
    <form method="post" action="/register/complete">
      <input type="hidden" name="_csrf_token" value="{{CSRF}}">
      <label for="handle">#{gettext("Username (your permanent handle — entity://user/<handle>)")}</label>
      <input type="text" id="handle" name="handle" value="{{HANDLE}}" required autofocus>
      <label for="display_name">#{gettext("Display name (you can change this later)")}</label>
      <input type="text" id="display_name" name="display_name" value="{{DISPLAY}}" required>
      <button type="submit">#{gettext("Create my account")}</button>
    </form>
    <p class="hint">#{gettext("Signing up as")} {{EMAIL}}</p>
    </body></html>
    """
  end

  def complete_new(conn, _params) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        slug = Registration.suggest_slug(Registration.derive_slug(email))
        render_form(conn, email, slug, default_display(email), nil)

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, %{"handle" => handle, "display_name" => display_name}) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        case Registration.principal_for_email(email) do
          {:ok, uri} ->
            # Concurrent-registration / re-entry guard (spec §7): the
            # email became a principal since the magic link was issued.
            # Email ownership was already proven by the link -> log in,
            # do NOT double-create.
            login_and_redirect(conn, uri)

          :none ->
            slug = handle |> String.trim() |> String.downcase()

            case Registration.create_principal(slug, display_name, email) do
              {:ok, uri} ->
                login_and_redirect(conn, uri)

              {:error, :slug_taken} ->
                suggestion = Registration.suggest_slug(slug)

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

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, _params) do
    redirect(conn, to: "/register/complete")
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
      if error, do: ~s(<div class="err">#{Plug.HTML.html_escape(error)}</div>), else: ""

    html =
      form_html()
      |> String.replace("{{ERROR}}", error_block)
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
      |> String.replace("{{HANDLE}}", Plug.HTML.html_escape(handle) |> safe_to_string())
      |> String.replace("{{DISPLAY}}", Plug.HTML.html_escape(display) |> safe_to_string())
      |> String.replace("{{EMAIL}}", Plug.HTML.html_escape(email) |> safe_to_string())

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
