defmodule EzagentWeb.HomeLive do
  @moduledoc """
  Root `/` LiveView — login gate + first-login wizard.

  ## Three-way mount

  - **No session cookie** (`current_entity_uri` absent) → redirect `/login`.
  - **Authenticated AND ≥1 session in the caller's workspace** →
    redirect `/sessions` (the default app surface, unchanged from Phase 8).
  - **Authenticated AND no sessions in the caller's workspace** → render
    the first-login wizard inline. The operator picks a short name and one
    caller-managed reusable `hello.llm` agent, then creates a Hello session
    through `Ezagent.Workspace.create_session/3`.

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

  ## Why the wizard requires an existing LLM agent

  Hello reuses an authenticated agent instead of creating a hidden replacement.
  The flavor field therefore drives a dependent selector populated by
  `EzagentPluginHello.ReusableLlmAgent`; creation stays disabled until an
  eligible selection is explicit. No workspace picker is needed because the
  wizard uses the same selected workspace as the `/sessions` surface.
  """
  use EzagentWeb, :live_view

  alias EzagentPluginHello.{App, ReusableLlmAgent}

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
    workspace_uri = landing_workspace_uri(session, entity_uri)

    sessions =
      case workspace_uri do
        %URI{scheme: "workspace"} = workspace_uri ->
          Ezagent.Workspace.WorkspaceReads.sessions(entity_uri, workspace_uri)

        _ ->
          []
      end

    case sessions do
      [] ->
        flavors = App.llm_flavors()
        flavor = List.first(flavors) || ""
        candidates = reusable_llm_candidates(entity_uri, workspace_uri, flavor)

        socket =
          socket
          |> assign(:current_entity_uri, entity_uri)
          |> assign(:current_entity_uri_str, URI.to_string(entity_uri))
          |> assign(:current_workspace_uri, workspace_uri)
          |> assign(:llm_flavors, flavors)
          |> assign_wizard_candidates(candidates, "")
          |> assign(:flash_error, nil)
          |> assign(
            :form,
            to_form(
              %{
                "short_name" => "main",
                "llm_flavor" => flavor,
                "llm_agent_uri" => ""
              },
              as: "wizard"
            )
          )

        {:ok, socket, layout: false}

      [_ | _] ->
        # At least one session exists → existing redirect behavior.
        {:ok, push_navigate(socket, to: "/sessions")}
    end
  end

  @impl true
  def handle_event("select_llm_flavor", %{"wizard" => params}, socket) do
    flavor = Map.get(params, "llm_flavor", "")

    candidates =
      reusable_llm_candidates(
        socket.assigns.current_entity_uri,
        socket.assigns.current_workspace_uri,
        flavor
      )

    selected_agent_uri =
      params
      |> Map.get("llm_agent_uri", "")
      |> keep_if_candidate(candidates)

    form_params = %{
      "short_name" => Map.get(params, "short_name", "main"),
      "llm_flavor" => flavor,
      "llm_agent_uri" => selected_agent_uri
    }

    {:noreply,
     socket
     |> assign(:form, to_form(form_params, as: "wizard"))
     |> assign_wizard_candidates(candidates, selected_agent_uri)
     |> assign(:flash_error, nil)}
  end

  @impl true
  def handle_event("create_default_session", %{"wizard" => params}, socket) do
    short_name = params |> Map.get("short_name", "main") |> String.trim()
    flavor = params |> Map.get("llm_flavor", "") |> String.trim()
    agent_uri_input = params |> Map.get("llm_agent_uri", "") |> String.trim()
    creator_uri = socket.assigns.current_entity_uri
    workspace_uri = socket.assigns.current_workspace_uri

    result =
      with :ok <- require_session_name(short_name),
           {:ok, agent_uri} <- parse_llm_agent_uri(agent_uri_input),
           {:ok, _candidate} <-
             ReusableLlmAgent.validate(creator_uri, workspace_uri, flavor, agent_uri),
           :ok <- ensure_bootstrap_workspace(workspace_uri, creator_uri),
           target <- Ezagent.URI.with_action(workspace_uri, :workspace, :create_session),
           {:ok, create_cap} <-
             Ezagent.Cap.issue_for_action(
               {:admin, Ezagent.Entity.User.admin_uri()},
               creator_uri,
               target
             ) do
        agent_uri_string = URI.to_string(agent_uri)

        Ezagent.Workspace.create_session(
          workspace_uri,
          %{
            short_name: short_name,
            template_name: "hello",
            template_options: %{
              "llm_flavor" => flavor,
              "llm_agent_uri" => agent_uri_string
            }
          },
          %{
            caller: creator_uri,
            authenticated_principal: creator_uri,
            caps: MapSet.new([create_cap])
          }
        )
      end

    case result do
      {:ok, %{session_uri: %URI{}}} ->
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

  defp require_session_name(""), do: {:error, :session_name_required}
  defp require_session_name(_short_name), do: :ok

  defp parse_llm_agent_uri(""), do: {:error, :llm_agent_required}

  defp parse_llm_agent_uri(agent_uri) do
    case Ezagent.URI.parse(agent_uri) do
      {:ok, %URI{} = parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_llm_agent_uri}
    end
  end

  defp reusable_llm_candidates(
         %URI{} = caller,
         %URI{scheme: "workspace"} = workspace_uri,
         flavor
       )
       when is_binary(flavor) do
    case ReusableLlmAgent.list(caller, workspace_uri, flavor) do
      {:ok, candidates} -> candidates
      {:error, _reason} -> []
    end
  end

  defp reusable_llm_candidates(_caller, _workspace_uri, _flavor), do: []

  defp keep_if_candidate(selected_agent_uri, candidates) when is_binary(selected_agent_uri) do
    if Enum.any?(candidates, fn %{agent_uri: agent_uri} ->
         URI.to_string(agent_uri) == selected_agent_uri
       end) do
      selected_agent_uri
    else
      ""
    end
  end

  defp assign_wizard_candidates(socket, candidates, selected_agent_uri) do
    options =
      Enum.map(candidates, fn %{agent_uri: agent_uri} ->
        agent_uri_string = URI.to_string(agent_uri)
        {agent_uri_string, agent_uri_string}
      end)

    socket
    |> assign(:llm_candidates, candidates)
    |> assign(:llm_candidate_options, options)
    |> assign(:submit_disabled?, selected_agent_uri == "")
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
          Ezagent.Kind.alive?(entity_uri)

      {:ok, "agent"} ->
        # Liveness via §2.2 `alive?/1` (C3, was KindRegistry.lookup) OR durable
        # existence via `read_durable/3` (C2, was SnapshotStore.latest): the
        # latter answers "a durable row exists" regardless of the probe slice key
        # (never spawns); `{:ok, _, _}` ⟺ the old `match?({:ok, _}, SnapshotStore.latest/1)`.
        Ezagent.Kind.alive?(entity_uri) or
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
    <Layouts.app flash={@flash}>
      <section class="mx-auto w-full max-w-lg text-foreground" aria-labelledby="hello-wizard-title">
        <header class="mb-8 text-center">
          <p class="mb-2 text-xs font-semibold uppercase tracking-[0.2em] text-primary">
            {gettext("Hello")}
          </p>
          <h1 id="hello-wizard-title" class="text-3xl font-semibold tracking-tight text-foreground">
            {gettext("Create your first session")}
          </h1>
          <p class="mt-3 text-sm leading-6 text-muted-foreground">
            {gettext("Choose an authenticated LLM agent you already manage.")}
          </p>
        </header>

        <div class="rounded-[var(--radius)] border border-border bg-card p-6 shadow-[var(--shadow-card)]">
          <.form
            for={@form}
            id="first-session-wizard"
            phx-change="select_llm_flavor"
            phx-submit="create_default_session"
            class="space-y-5"
          >
            <div>
              <.input
                field={@form[:short_name]}
                type="text"
                label={gettext("Session short name")}
                placeholder="main"
                autocomplete="off"
              />
              <p class="text-xs leading-5 text-muted-foreground">
                {gettext("The Hello session will be named")}
                <span class="font-mono text-foreground" id="short-name-preview">
                  {@form[:short_name].value}
                </span>.
              </p>
            </div>

            <.input
              field={@form[:llm_flavor]}
              type="select"
              label={gettext("LLM flavor")}
              options={Enum.map(@llm_flavors, &{&1, &1})}
            />

            <div>
              <.input
                field={@form[:llm_agent_uri]}
                type="select"
                label={gettext("Reusable LLM agent")}
                prompt={gettext("Select an eligible agent")}
                options={@llm_candidate_options}
                disabled={@llm_candidates == []}
              />

              <div
                :if={@llm_candidates == []}
                id="hello-llm-empty"
                class="rounded-[var(--radius)] border border-dashed border-border bg-muted/40 px-4 py-3 text-xs leading-5 text-muted-foreground"
              >
                {gettext(
                  "No eligible agent is available for this flavor. Create or authenticate a hello.llm agent you manage, then return here."
                )}
              </div>
            </div>

            <div :if={@flash_error} id="hello-wizard-error" class="text-sm text-destructive">
              {@flash_error}
            </div>

            <button
              id="first-session-submit"
              type="submit"
              disabled={@submit_disabled?}
              class="w-full rounded-full bg-primary px-4 py-2.5 text-sm font-medium text-primary-foreground shadow-[var(--shadow-soft)] transition-colors hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {gettext("Create Hello session")}
            </button>
          </.form>
        </div>

        <p class="mt-6 text-center text-xs text-muted-foreground">
          {gettext("Signed in as")} <span class="font-mono">{@current_entity_uri_str}</span>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
