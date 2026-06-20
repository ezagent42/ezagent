defmodule EzagentWeb.HomeLive do
  @moduledoc """
  Root `/` LiveView — login gate + first-login wizard.

  ## Three-way mount

  - **No session cookie** (`current_entity_uri` absent) → redirect `/login`.
  - **Authenticated AND ≥1 session in `EzagentDomainInstanceMessage.list_sessions/0`** →
    redirect `/sessions` (the default app surface, unchanged from Phase 8).
  - **Authenticated AND no sessions exist** → render the first-login
    wizard inline. Operator picks a short name (default "main") and
    submits; we call `Ezagent.Workspace.create_session/3` (which spawns
    + binds workspace + joins admin) and then push_navigate to `/sessions`.

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
        mount_authenticated(entity_uri_str, socket)

      _ ->
        {:ok, push_navigate(socket, to: "/login")}
    end
  end

  defp mount_authenticated(entity_uri_str, socket) do
    case EzagentDomainInstanceMessage.list_sessions() do
      [] ->
        # No sessions yet — render the wizard.
        socket =
          socket
          |> assign(:current_entity_uri_str, entity_uri_str)
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
      creator_uri = parse_entity_uri(socket.assigns.current_entity_uri_str)

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
        with :ok <- ensure_bootstrap_workspace(workspace_uri, creator_uri) do
          Ezagent.Workspace.create_session(
            workspace_uri,
            %{short_name: short_name, template_name: "default"},
            %{caller: creator_uri, caps: caller_caps_for(creator_uri)}
          )
        end

      case result do
        {:ok, %{session_uri: session_uri} = result} ->
          # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A
          # + Invariant #9 (no silent drops at user-facing surfaces) —
          # surface the orchestrator status from `create_session`'s
          # new 3-tuple meta map. Silently discarding the meta would be
          # an Invariant #9 violation (the e2e flow's "did the
          # orchestrator come up?" question would be invisible).
          meta = session_create_meta(result)
          if with_echo?, do: join_echo_agent(session_uri, creator_uri)

          {:noreply,
           socket
           |> put_orchestrator_flash(meta)
           |> push_navigate(to: "/sessions")}

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

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A — render
  # the orchestrator status from `create_session`'s meta map so the
  # operator sees `:pending` / `:failed` BEFORE they land in /sessions
  # and wonder why their orchestrator card is empty.
  defp put_orchestrator_flash(socket, meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        socket

      :pending ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          gettext("Orchestrator pending — refresh in a moment.")
        )

      :failed ->
        reason = Map.get(meta, :orchestrator_error)

        Phoenix.LiveView.put_flash(
          socket,
          :error,
          gettext("Orchestrator failed: %{reason}; click Restart to retry.",
            reason: inspect(reason)
          )
        )

      _ ->
        socket
    end
  end

  defp put_orchestrator_flash(socket, _meta), do: socket

  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  # Phase 8c PR-J follow-up (Allen 2026-05-20) — wizard optionally
  # seeds an echo agent into the new session for first-time demo.
  # Echo's :receive action emits a chat reply (PR-J), so the user
  # gets a working ping-pong loop out of the box.
  defp join_echo_agent(session_uri, caller_uri) do
    echo_uri = Ezagent.URI.agent(:system, :echo_default)
    # Make sure the echo Kind is live (spawn is idempotent — returns
    # `{:error, {:already_started, _}}` if already up). Spawn happens
    # in the echo plugin's Application.start; this is a defensive
    # rehydrate in case the Kind was snapshot-restored stale.
    _ = Ezagent.SpawnRegistry.spawn(echo_uri)

    target = Ezagent.URI.with_action(session_uri, :session, :join)

    _ =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{member: echo_uri},
        # #154 — `system://session-internal` ELIMINATED. The wizard operator
        # (`caller_uri`) just created this session, so it is the OWNER and can
        # join a member: present an inline `session.join` cap granted_by the
        # operator itself (a real entity; owner authority), instead of borrowing
        # the deleted principal.
        ctx: %{
          caller: caller_uri,
          caps:
            MapSet.new([
              %Ezagent.Capability{
                Ezagent.Capability.cap(
                  :session,
                  :any,
                  :join,
                  Ezagent.URI.instance(session_uri),
                  Ezagent.Capability.workspace_of(session_uri)
                )
                | granted_by: caller_uri,
                  granted_at: DateTime.utc_now()
              }
            ]),
          reply: :ignore
        }
      })

    :ok
  end

  defp caller_caps_for(%URI{} = caller_uri) do
    caps = Ezagent.Identity.list_caps_for(caller_uri)

    if MapSet.size(caps) > 0 do
      caps
    else
      MapSet.new()
    end
  end

  defp session_create_meta(result) when is_map(result) do
    %{
      orchestrator_uri: Map.get(result, :orchestrator_uri),
      orchestrator_status: Map.get(result, :orchestrator_status),
      orchestrator_error: Map.get(result, :orchestrator_error)
    }
  end

  # Defensive parser — LiveAuth already validated this string at session
  # mount, but HomeLive lives outside the `:require_entity` live_session,
  # so re-parse here. Fall back to admin if the cookie is malformed
  # (LiveAuth would have caught it earlier on protected routes; here
  # we let the wizard proceed under admin caps so the operator isn't
  # locked out of their own setup).
  defp parse_entity_uri(uri_str) when is_binary(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the admin-fallback semantics for stale
    # cookies (LiveAuth catches these on protected routes; wizard runs
    # outside that live_session and tolerates them).
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity"} = uri -> uri
        _ -> Ezagent.Entity.User.admin_uri()
      end
    rescue
      ArgumentError -> Ezagent.Entity.User.admin_uri()
    end
  end

  defp parse_entity_uri(_), do: Ezagent.Entity.User.admin_uri()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 dark:bg-zinc-950 px-4">
      <div class="w-full max-w-md">
        <div class="text-center mb-8">
          <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">
            {gettext("Welcome to ezagent")}
          </h1>
          <p class="mt-2 text-sm text-zinc-500">
            {gettext("Let's set up your first session.")}
          </p>
        </div>

        <div class="bg-white dark:bg-zinc-900 rounded-md border border-zinc-200 dark:border-zinc-800 shadow-sm p-6">
          <.form
            for={@form}
            id="first-session-wizard"
            phx-submit="create_default_session"
            class="space-y-4"
          >
            <div>
              <label
                for="wizard_short_name"
                class="block text-sm font-medium text-zinc-700 dark:text-zinc-300 mb-1"
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
                class="w-full px-3 py-2 text-sm bg-white dark:bg-zinc-950 border border-zinc-300 dark:border-zinc-700 rounded-md text-zinc-900 dark:text-zinc-100 focus:outline-none focus:border-zinc-500 dark:focus:border-zinc-500"
              />
              <p class="mt-1 text-xs text-zinc-500">
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
                class="mt-0.5 rounded border-zinc-300 dark:border-zinc-700"
              />
              <span class="text-xs text-zinc-700 dark:text-zinc-300">
                {gettext("Include echo demo agent")}
                <span class="block text-zinc-500">
                  {gettext("Adds")}
                  {gettext(
                    "Adds the default echo agent as a session member so you can verify the chat round-trip works."
                  )}
                </span>
              </span>
            </label>

            <div :if={@flash_error} class="text-sm text-red-600 dark:text-red-400">
              {@flash_error}
            </div>

            <button
              type="submit"
              class="w-full px-4 py-2 text-sm font-medium bg-zinc-900 dark:bg-zinc-100 text-white dark:text-zinc-900 rounded-md hover:bg-zinc-800 dark:hover:bg-zinc-200 transition-colors"
            >
              {gettext("Create session")}
            </button>
          </.form>
        </div>

        <p class="mt-6 text-center text-xs text-zinc-500">
          {gettext("Signed in as")} <span class="font-mono">{@current_entity_uri_str}</span>
        </p>
      </div>
    </div>
    """
  end
end
