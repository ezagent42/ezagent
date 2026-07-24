defmodule EzagentWeb.HomeLive do
  @moduledoc """
  Root `/` LiveView — login gate + first-login wizard.

  ## Three-way mount

  - **No session cookie** (`current_entity_uri` absent) → redirect `/login`.
  - **Authenticated AND ≥1 session in the caller's workspace** →
    redirect `/sessions` (the default app surface, unchanged from Phase 8).
  - **Authenticated AND no sessions in the caller's workspace** → render
    the first-login wizard inline. Operator picks a short name (default
    "main") and submits; we call `Ezagent.Workspace.create_session/3`
    (which spawns + binds workspace + joins admin) and then push_navigate
    to `/sessions`.

  ## W0 tenant-isolation (2026-07-03)

  The landing判据 MUST be workspace-scoped. The prior code called the
  GLOBAL `EzagentDomainInstanceMessage.list_sessions/0`
  (`KindRegistry.list_all()` across every tenant), so a freshly-logged-in
  operator whose OWN workspace had zero sessions was bounced to `/sessions`
  (and treated as a returning user) merely because SOME OTHER tenant had a
  session — a wrong landing AND a cross-tenant existence leak. We now scope
  to the operator's workspace via the caller-authorizing
  `Ezagent.Workspace.WorkspaceReads.sessions/2` chokepoint (Task #55's
  workspace scoping PLUS per-row caller visibility), matching what
  `/sessions` renders.

  Landing workspace = the session's SELECTED `current_workspace_uri` when
  present (so a system member who context-switched — §6.5/§13.2 — lands on
  the same workspace `/sessions` shows), else the caller entity's home
  workspace (`Ezagent.Capability.workspace_of/1`). A non-workspace result
  (`:any` for `system://`, or a malformed cookie) fails CLOSED to the
  wizard rather than a global scan.

  ## Phase 8c PR-J context

  Before PR-J, `session://default/system/main` was a static supervisor child of
  `EzagentDomainInstanceMessage.Application` — hardcoded outside the canonical
  creation flow (`Session.spawn_from_template/2` / `create_session/2`).
  That bypass forced two boot-time workarounds (workspace bind +
  admin-join post-boot dispatch). PR-J drops the static child; the
  wizard is the production creation path for the default session,
  and every session in the system flows through the same API.

  ## Why a single-input wizard

  Allen's brief 2026-05-20: "99% of users just press one button". The
  form pre-fills "main" so the default flow is literally one click.
  Power users can pick a different name. No workspace picker yet —
  the wizard's session is bound to the admin's structural workspace
  (`workspace://system` per SPEC #324), so the single admin flow
  doesn't need a picker. Tenant onboarding goes through a separate
  magic-link flow that creates the tenant's own workspace.
  """
  use EzagentWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    case session do
      %{"current_entity_uri" => entity_uri_str} when is_binary(entity_uri_str) ->
        with {:ok, entity_uri} <- parse_entity_uri(entity_uri_str),
             true <- entity_principal_exists?(entity_uri) do
          mount_authenticated(entity_uri, session, socket)
        else
          _ -> redirect_to_cleared_login(socket)
        end

      _ ->
        redirect_to_cleared_login(socket)
    end
  end

  defp redirect_to_cleared_login(socket) do
    {:ok, push_navigate(socket, to: "/login")}
  end

  defp mount_authenticated(entity_uri, session, socket) do
    # W0 — workspace-scoped landing判据 (see moduledoc), now routed through
    # the caller-authorizing chokepoint: `WorkspaceReads.sessions/2`
    # authorizes the caller for the workspace BEFORE reading and keeps only
    # the rows the caller may see (session owner/member OR public). A
    # non-workspace scope (`:any` / malformed) or an unauthorized caller
    # fails closed to `[]` so the operator sees the wizard — never a
    # cross-tenant redirect, a private-session existence leak, or a crash.
    sessions =
      case landing_workspace_uri(session, entity_uri) do
        %URI{scheme: "workspace"} = workspace_uri ->
          Ezagent.Workspace.WorkspaceReads.sessions(entity_uri, workspace_uri)

        _ ->
          []
      end

    case sessions do
      [] ->
        # No sessions yet — render the wizard.
        socket =
          socket
          |> assign(:current_entity_uri, entity_uri)
          |> assign(:current_entity_uri_str, URI.to_string(entity_uri))
          |> assign(:flash_error, nil)
          |> assign(
            :form,
            to_form(%{"short_name" => "main", "with_echo" => "true"}, as: "wizard")
          )

        {:ok, socket, layout: false}

      [_ | _] ->
        # At least one session exists → existing redirect behavior.
        {:ok, push_navigate(socket, to: "/sessions")}
    end
  end

  @impl true
  def handle_event("create_default_session", %{"wizard" => params}, socket) do
    short_name = params |> Map.get("short_name", "main") |> String.trim()
    with_echo? = params |> Map.get("with_echo") |> truthy?()

    if short_name == "" do
      {:noreply, assign(socket, :flash_error, gettext("Session name is required."))}
    else
      creator_uri = socket.assigns.current_entity_uri

      # SPEC #366 (Allen 2026-05-26) — create_session now requires an
      # explicit `:template_name`. The first-login
      # wizard's job is to create the bootstrap session with the
      # canonical `session://default/<workspace>/main` URI shape, so
      # we pass `template_name: "default"` literally. This preserves
      # the one-button flow Allen specified in 2026-05-20 ("99% of
      # users just press one button") — the wizard isn't a
      # template-selection surface; it's the platform's own boot
      # ceremony. Tenant-customized session creation happens in
      # AdminLive (`/sessions` → "+ New"), where the dropdown is
      # mandatory.
      workspace_uri = Ezagent.Capability.workspace_of(creator_uri)

      result =
        with :ok <- ensure_bootstrap_workspace(workspace_uri, creator_uri),
             target <- Ezagent.URI.with_action(workspace_uri, :workspace, :create_session),
             {:ok, create_cap} <-
               Ezagent.Cap.issue_for_action(
                 {:admin, Ezagent.Entity.User.admin_uri()},
                 creator_uri,
                 target
               ) do
          Ezagent.Workspace.create_session(
            workspace_uri,
            %{short_name: short_name, template_name: "default"},
            %{
              caller: creator_uri,
              authenticated_principal: creator_uri,
              caps: MapSet.new([create_cap])
            }
          )
        end

      case result do
        {:ok, %{session_uri: session_uri}} ->
          if with_echo?, do: join_echo_agent(session_uri, creator_uri)

          {:noreply, push_navigate(socket, to: "/sessions")}

        {:error, reason} ->
          {:noreply,
           assign(
             socket,
             :flash_error,
             gettext("Create failed: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  defp ensure_bootstrap_workspace(%URI{scheme: "workspace"} = uri, %URI{} = creator_uri) do
    unless Ezagent.URI.name?(uri, :system) do
      :ok
    else
      case Ezagent.Workspace.Store.get_by_name("system") do
        nil ->
          case Ezagent.Workspace.create("system", %{created_by: creator_uri}) do
            {:ok, _pid} -> :ok
            {:error, :workspace_exists} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, {:system_workspace_seed_failed, reason}}
          end

        _ ->
          :ok
      end
    end
  end

  defp ensure_bootstrap_workspace(_workspace_uri, _creator_uri), do: :ok

  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  # Phase 8c PR-J follow-up (Allen 2026-05-20) — wizard optionally
  # seeds the default demo agent into the new session for first-time
  # demo. P2: this is now `py_default` (the echo.py py-agent that
  # replaced the deleted echo default agent). Its :receive runs echo.py and
  # emits a chat reply, so the user gets a working ping-pong loop out
  # of the box.
  defp join_echo_agent(session_uri, caller_uri) do
    echo_uri = Ezagent.URI.agent(:system, :py_default)
    # Make sure the default agent Kind is live. `ensure_started/1` is
    # idempotent AND self-heals py_default's Python subprocess from the
    # installed script (`Behavior.PyAgent.activate/2`) — the seed runs
    # in the py plugin's `after_boot/0`; this is a defensive rehydrate
    # in case the Kind was snapshot-restored stale (or the boot seed
    # failed because uv was cold).
    _ = Ezagent.LocalRuntime.ensure_started(echo_uri)

    target = Ezagent.URI.with_action(session_uri, :session, :join)

    _ =
      with {:ok, signed_cap} <-
             Ezagent.Cap.issue_for_action(
               {:admin, Ezagent.Entity.User.admin_uri()},
               caller_uri,
               target
             ) do
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :cast,
          args: %{member: echo_uri},
          ctx: %{
            caller: caller_uri,
            authenticated_principal: caller_uri,
            caps: MapSet.new([signed_cap]),
            reply: :ignore
          },
          origin: :authenticated_external
        })
      end

    :ok
  end

  # HomeLive lives outside the `:require_entity` live_session, so its public
  # mount must validate the cookie itself. Invalid identity input is never
  # replaced with a more privileged principal.
  defp parse_entity_uri(uri_str) when is_binary(uri_str) do
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity"} = uri ->
          case Ezagent.URI.type(uri) do
            {:ok, type} when type in ["user", "agent"] -> {:ok, uri}
            _ -> {:error, :invalid_identity}
          end

        _ ->
          {:error, :invalid_identity}
      end
    rescue
      ArgumentError -> {:error, :invalid_identity}
    end
  end

  defp parse_entity_uri(_), do: {:error, :invalid_identity}

  defp entity_principal_exists?(%URI{} = entity_uri) do
    case Ezagent.URI.type(entity_uri) do
      {:ok, "user"} ->
        Ezagent.Users.get_by_uri(entity_uri) != nil or
          match?({:ok, _pid}, Ezagent.KindRegistry.lookup(entity_uri))

      {:ok, "agent"} ->
        # Durable existence via the §2.2 actor read surface (C2). `read_durable/3`
        # answers "a durable row exists" regardless of the probe slice key (never
        # spawns); `{:ok, _, _}` ⟺ the old `match?({:ok, _}, SnapshotStore.latest/1)`.
        match?({:ok, _pid}, Ezagent.KindRegistry.lookup(entity_uri)) or
          match?({:ok, _, _}, Ezagent.Kind.read_durable(entity_uri, :identity))

      _ ->
        false
    end
  end

  # W0 landing scope. Prefer the session's SELECTED workspace
  # (`current_workspace_uri`, the slot `/sessions` renders from — set by
  # `SessionPrincipal.put/3` and the workspace switcher; for a regular user
  # it equals the entity workspace per the §6.5 invariant, for a
  # context-switched system member it may differ). Fall back to the caller
  # entity's home workspace. Callers guard on `%URI{scheme: "workspace"}`,
  # so a nil/`:any` return fails closed.
  defp landing_workspace_uri(session, entity_uri) do
    selected =
      case session do
        %{"current_workspace_uri" => ws_str} when is_binary(ws_str) ->
          parse_workspace_uri(ws_str)

        _ ->
          nil
      end

    selected || Ezagent.Capability.workspace_of(entity_uri)
  end

  # Canonical parse (SPEC 2026-05-27-uri-canonicalization §3.3) tolerant of
  # a stale/malformed selected-workspace slot → nil (caller fails closed).
  defp parse_workspace_uri(str) when is_binary(str) do
    case Ezagent.URI.new!(str) do
      %URI{scheme: "workspace"} = uri -> uri
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_workspace_uri(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-background px-4 text-foreground">
      <div class="w-full max-w-md">
        <div class="text-center mb-8">
          <h1 class="text-2xl font-semibold text-foreground">
            {gettext("Welcome to ezagent")}
          </h1>
          <p class="mt-2 text-sm text-muted-foreground">
            {gettext("Let's set up your first session.")}
          </p>
        </div>

        <div class="bg-card rounded-[var(--radius)] shadow-[var(--shadow-card)] p-6">
          <.form
            for={@form}
            id="first-session-wizard"
            phx-submit="create_default_session"
            class="space-y-4"
          >
            <div>
              <label
                for="wizard_short_name"
                class="block text-sm font-medium text-foreground mb-1"
              >
                {gettext("Session short name")}
              </label>
              <input
                type="text"
                name="wizard[short_name]"
                id="wizard_short_name"
                value={@form[:short_name].value}
                placeholder="main"
                autocomplete="off"
                class="w-full px-3 py-2 text-sm bg-card border border-input rounded-full text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              />
              <p class="mt-1 text-xs text-muted-foreground">
                {gettext("Creates a system workspace session named")}
                <span class="font-mono" id="short-name-preview">{@form[:short_name].value}</span>.
              </p>
            </div>

            <%!-- Phase 8c PR-J follow-up (Allen 2026-05-20) — opt-in
                  echo demo seed so the first "send → see reply" flow
                  works end-to-end on a fresh DB. --%>
            <label class="flex items-start gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="wizard[with_echo]"
                value="true"
                checked={@form[:with_echo].value in ["true", "on", true]}
                class="mt-0.5 rounded border-input accent-primary"
              />
              <span class="text-xs text-foreground">
                {gettext("Include echo demo agent")}
                <span class="block text-muted-foreground">
                  {gettext("Adds")}
                  {gettext(
                    "Adds the default echo agent as a session member so you can verify the chat round-trip works."
                  )}
                </span>
              </span>
            </label>

            <div :if={@flash_error} class="text-sm text-destructive">
              {@flash_error}
            </div>

            <button
              type="submit"
              class="w-full px-4 py-2 text-sm font-medium bg-primary text-primary-foreground rounded-full shadow-[var(--shadow-soft)] hover:bg-primary/90 transition-colors"
            >
              {gettext("Create session")}
            </button>
          </.form>
        </div>

        <p class="mt-6 text-center text-xs text-muted-foreground">
          {gettext("Signed in as")} <span class="font-mono">{@current_entity_uri_str}</span>
        </p>
      </div>
    </div>
    """
  end
end
