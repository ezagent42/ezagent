defmodule EzagentWeb.OnboardingController do
  @moduledoc """
  Username & Auth M3 — workspace onboarding (`/onboarding/workspace`).

  PR-B 2026-05-24 (Allen, SPEC v2). Reached only AFTER `MagicLinkController`
  verified the email + the email has NO existing principal. User picks:

  1. **Join existing workspace** — text input (workspace name); backend
     validates the workspace exists AND `email_allowed?(ws, email)`.
  2. **Create new workspace** — text input (workspace name + rule_type +
     rule_value); auto-defaults `rule_type=domain`, `rule_value=email's
     domain` for the easy path. Gated by OQ-V2-1 Option A
     (non-admins CAN self-serve).

  On submit, the chosen workspace is stored in the session and the user
  is redirected to `/register/complete` (which now uses the workspace
  to derive `entity://user/<workspace>/<slug>` instead of hardcoded
  default).

  Plain controller (not LV) — mirrors `RegistrationController` and
  `SessionController`. Auth-boundary pages avoid websocket deps.
  """

  use Phoenix.Controller, formats: [:html], layouts: []
  use Gettext, backend: EzagentWeb.Gettext

  import Plug.Conn

  alias EzagentWeb.AuthBoundaryLayout

  # The combined join + create form. Two `<form>` blocks on one page.
  defp card_body do
    """
        <p class="brand">ezagent</p>
        <h1>#{gettext("Pick a workspace")}</h1>
        {{FLASH}}
        {{ERROR}}
        <p class="hint">#{gettext("Signing in as")} <code>{{EMAIL}}</code></p>

        <div class="divider">#{gettext("Join existing")}</div>

        <form method="post" action="/onboarding/workspace">
          <input type="hidden" name="_csrf_token" value="{{CSRF}}">
          <input type="hidden" name="action" value="join">
          <label for="join_name">#{gettext("Workspace name")}</label>
          <input type="text" id="join_name" name="workspace_name" placeholder="acme" autofocus>
          <button type="submit">#{gettext("Join")}</button>
        </form>

        <div class="divider">#{gettext("Or create new")}</div>

        <form method="post" action="/onboarding/workspace">
          <input type="hidden" name="_csrf_token" value="{{CSRF}}">
          <input type="hidden" name="action" value="create">
          <label for="create_name">#{gettext("New workspace name")}</label>
          <input type="text" id="create_name" name="workspace_name" value="{{SUGGESTED_NAME}}" placeholder="acme">
          <label for="rule_type">#{gettext("Who can join?")}</label>
          <select id="rule_type" name="rule_type">
            <option value="domain">#{gettext("Anyone from email domain")} ({{SUGGESTED_DOMAIN}})</option>
            <option value="user_list">#{gettext("Just me for now")}</option>
            <option value="invite_only">#{gettext("Invite-only (admin invites people)")}</option>
          </select>
          <input type="hidden" name="rule_value_domain" value="{{SUGGESTED_DOMAIN}}">
          <input type="hidden" name="rule_value_email" value="{{EMAIL}}">
          <button type="submit">#{gettext("Create + join")}</button>
        </form>
    """
  end

  def show(conn, _params) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        render_form(conn, email, nil)

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def submit(conn, %{"action" => "join", "workspace_name" => workspace_name})
      when is_binary(workspace_name) and workspace_name != "" do
    email = get_session(conn, :pending_registration_email)

    cond do
      not is_binary(email) ->
        redirect(conn, to: "/login")

      true ->
        join_existing_workspace(conn, email, String.trim(workspace_name))
    end
  end

  def submit(
        conn,
        %{
          "action" => "create",
          "workspace_name" => workspace_name,
          "rule_type" => rule_type
        } = params
      )
      when is_binary(workspace_name) and workspace_name != "" do
    email = get_session(conn, :pending_registration_email)

    cond do
      not is_binary(email) ->
        redirect(conn, to: "/login")

      # Codex PR-B round-1 MEDIUM — one-workspace-per-pending-registration.
      get_session(conn, :pending_workspace) != nil ->
        render_form(
          conn,
          email,
          gettext(
            "You have already picked a workspace in this session. " <>
              "Please complete registration first, then sign in to create more."
          )
        )

      rule_type not in ["domain", "user_list", "invite_only"] ->
        render_form(conn, email, gettext("Invalid rule type."))

      true ->
        case canonicalize_workspace_name(workspace_name) do
          {:ok, canonical} ->
            rule_value = pick_rule_value(rule_type, email, params)
            create_workspace_and_join(conn, email, canonical, rule_type, rule_value)

          {:error, :invalid_workspace_name, msg} ->
            render_form(conn, email, msg)
        end
    end
  end

  def submit(conn, _params) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        render_form(conn, email, gettext("Please pick a workspace name."))

      _ ->
        redirect(conn, to: "/login")
    end
  end

  # --- internals ----------------------------------------------------------

  defp join_existing_workspace(conn, email, workspace_name) do
    case canonicalize_workspace_name(workspace_name) do
      {:error, :invalid_workspace_name, msg} ->
        render_form(conn, email, msg)

      {:ok, canonical} ->
        cond do
          not Ezagent.Workspace.accepts_email?("workspace://" <> canonical, email) ->
            render_form(
              conn,
              email,
              gettext(
                "Workspace “%{name}” does not accept your email. " <>
                  "Ask the admin to add a rule for your address, or create a new workspace.",
                name: canonical
              )
            )

          true ->
            conn
            |> put_session(:pending_workspace, canonical)
            |> redirect(to: "/register/complete")
        end
    end
  end

  # Codex PR-B round-1 CRITICAL: ONLY proceed if Workspace.create
  # returned {:ok, _} — i.e. the workspace was NEWLY created on this
  # call. An {:error, _} (typically unique-name conflict) means the
  # name was TAKEN; we MUST NOT proceed to add rules + join, otherwise
  # any non-admin user could submit workspace_name="system" or another
  # existing workspace's name to hijack it (system membership grants
  # cross-workspace authority per Ezagent.Capability.cross_workspace?).
  defp create_workspace_and_join(conn, email, workspace_name, rule_type, rule_value) do
    case Ezagent.Workspace.create(workspace_name, %{}) do
      {:ok, _} ->
        # Workspace did not exist; we own it. Now safe to add the
        # rule + mark the session.
        case Ezagent.Workspace.add_magic_link_rule(
               "workspace://" <> workspace_name,
               rule_type,
               rule_value
             ) do
          {:ok, _rule} ->
            conn
            |> put_session(:pending_workspace, workspace_name)
            |> redirect(to: "/register/complete")

          {:error, reason} ->
            render_form(
              conn,
              email,
              gettext("Could not add workspace rule: %{reason}", reason: inspect(reason))
            )
        end

      {:error, _reason} ->
        render_form(
          conn,
          email,
          gettext(
            "Workspace “%{name}” already exists. Use “Join existing” above, " <>
              "or pick a different name.",
            name: workspace_name
          )
        )
    end
  end

  # --- workspace name validation (codex PR-B round-1 HIGH-1 + CRITICAL) ---

  # Reserved names that operators must NOT be able to self-serve-create.
  # `system` is the bootstrap admin authority sink — membership in it
  # confers cross-workspace authority (capability.ex). `admin` /
  # `bootstrap` are reserved for future structural roles. Add to this
  # list when more structural workspaces are added.
  @reserved_workspace_names ~w(system admin bootstrap default)

  # Canonical form: lowercase, slug pattern, length-bounded.
  # Returns {:ok, canonical} or {:error, :invalid_workspace_name, message}.
  defp canonicalize_workspace_name(raw) when is_binary(raw) do
    trimmed = raw |> String.trim() |> String.downcase()

    cond do
      String.length(trimmed) < 2 ->
        {:error, :invalid_workspace_name,
         gettext("Workspace name too short (min 2 characters).")}

      String.length(trimmed) > 32 ->
        {:error, :invalid_workspace_name,
         gettext("Workspace name too long (max 32 characters).")}

      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, trimmed) ->
        {:error, :invalid_workspace_name,
         gettext(
           "Workspace name must contain only lowercase letters, digits, and " <>
             "hyphens; must start + end with a letter or digit."
         )}

      trimmed in @reserved_workspace_names ->
        {:error, :invalid_workspace_name,
         gettext("“%{name}” is a reserved workspace name.", name: trimmed)}

      true ->
        {:ok, trimmed}
    end
  end

  defp canonicalize_workspace_name(_),
    do:
      {:error, :invalid_workspace_name,
       gettext("Workspace name is required.")}

  defp pick_rule_value("domain", email, params) do
    Map.get(params, "rule_value_domain") || extract_domain(email)
  end

  defp pick_rule_value("user_list", email, _params), do: email
  defp pick_rule_value("invite_only", email, _params), do: email

  defp extract_domain(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> String.downcase(String.trim(domain))
      _ -> ""
    end
  end

  defp render_form(conn, email, error) do
    domain = extract_domain(email)
    suggested_name = domain |> String.replace(~r/\.[^.]+$/, "")

    error_block =
      if error,
        do: ~s(<div class="error">#{Plug.HTML.html_escape(error) |> safe_to_string()}</div>),
        else: ""

    card_body_html =
      card_body()
      |> String.replace("{{FLASH}}", AuthBoundaryLayout.flash_html(conn))
      |> String.replace("{{ERROR}}", error_block)
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
      |> String.replace("{{EMAIL}}", Plug.HTML.html_escape(email) |> safe_to_string())
      |> String.replace(
        "{{SUGGESTED_NAME}}",
        Plug.HTML.html_escape(suggested_name) |> safe_to_string()
      )
      |> String.replace(
        "{{SUGGESTED_DOMAIN}}",
        Plug.HTML.html_escape(domain) |> safe_to_string()
      )

    html =
      AuthBoundaryLayout.head_html(gettext("Pick a workspace")) <>
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
end
