defmodule EzagentPluginLiveview.IdentitiesLive do
  @moduledoc """
  Phase 8 polish (Allen 2026-05-20) — Identities "address book" at
  `/identities`.

  Per Allen's deliberation: Users + Agents are entity sub-types so
  they belong under the same Identities surface. This LV reads
  `Ezagent.KindRegistry.list_all/0` filtered to `entity://*`, groups
  by sub-type (user / agent flavor), and renders entity cards with
  avatar + URI + StatusDot + action links.

  Distinct from `/admin/registry` (the raw KindRegistry sysadmin view)
  — Identities is the user-facing directory.
  """
  use Phoenix.LiveView
  # i18n V1 (Allen 2026-05-21) — see admin_dashboard_live for rationale.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  alias Phoenix.LiveView.JS
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    # `handle_params` always fires after mount and sets the real filter
    # value; placeholder here is just to keep the assign defined for
    # the initial render.
    {:ok,
     socket
     |> assign(:filter, "all")
     |> assign_entities()}
  end

  # Filter resolution order (Phase 8c follow-up Allen 2026-05-20):
  #   1. explicit `?filter=` query param wins
  #   2. else, default by URI path — `/identities/agents` → "agents",
  #      `/identities/users` → "users", `/identities` → "all"
  # This lets us reuse a single LV for the two sibling list routes
  # without forking modules.
  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(:filter, params["filter"] || default_filter_for_path(uri))
     |> assign_entities()}
  end

  defp default_filter_for_path(uri) when is_binary(uri) do
    cond do
      String.contains?(uri, "/identities/agents") -> "agents"
      String.contains?(uri, "/identities/users") -> "users"
      true -> "all"
    end
  end

  defp default_filter_for_path(_), do: "all"

  defp assign_entities(socket) do
    # Task #55 (Allen 2026-05-27) — filter entities by the operator's
    # current workspace. Pre-fix this LV displayed user + agent rows
    # from every workspace, leaking cross-tenant directory data. The
    # filter is structural (URI workspace segment); a nil
    # `current_workspace_uri` (early-mount defensive path) falls
    # through to the unfiltered list.
    workspace_filter = workspace_name_filter(socket.assigns[:current_workspace_uri])

    rows =
      Ezagent.KindRegistry.list_all()
      |> Enum.flat_map(fn {uri_str, pid} ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue keeping the empty-list fallback for malformed
        # registry entries.
        case safe_parse_entity(uri_str) do
          {:ok, %URI{scheme: "entity", host: host, path: "/" <> rest} = uri}
          when host in ["user", "agent"] ->
            # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment;
            # extract workspace + entity_name for display + filter.
            {workspace_name, entity_name} =
              case String.split(rest, "/", parts: 2) do
                [ws, name] -> {ws, name}
                [name] -> {nil, name}
              end

            if entity_matches_workspace?(workspace_name, workspace_filter) do
              [
                %{
                  uri: uri,
                  uri_str: uri_str,
                  host: host,
                  name: entity_name,
                  flavor: flavor_for(host, entity_name),
                  pid: pid,
                  alive: is_pid(pid) and Process.alive?(pid)
                }
              ]
            else
              []
            end

          _ ->
            []
        end
      end)
      |> Enum.filter(&matches_filter?(&1, socket.assigns.filter))
      |> Enum.sort_by(& &1.uri_str)

    # Username & Auth UI Task 1 (Phase 8c PR-O) — batch-resolve display
    # names so each card shows a friendly primary label.
    display_map = Ezagent.EntityPresenter.display_many(Enum.map(rows, & &1.uri_str))
    rows = Enum.map(rows, fn r -> Map.put(r, :display_name, Map.get(display_map, r.uri_str, r.name)) end)

    flavors =
      rows
      |> Enum.filter(&(&1.host == "agent"))
      |> Enum.map(& &1.flavor)
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:entities, rows)
    |> assign(:agent_flavors, flavors)
  end

  # "cc_demo-builder" → "cc"; "echo_default" → "echo"; no underscore → ""
  defp flavor_for("agent", name) do
    case String.split(name, "_", parts: 2) do
      [flavor, _] -> flavor
      _ -> ""
    end
  end

  defp flavor_for(_, _), do: ""

  # Task #55 — workspace filter helpers.
  #
  # `workspace_name_filter/1` reduces the socket's current workspace
  # URI to a name string (or :all when the assign is missing / nil).
  # `:all` short-circuits the per-entry check below to keep the
  # legacy unfiltered render for cold-mount paths where LiveAuth has
  # not yet populated `current_workspace_uri`.
  defp workspace_name_filter(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "",
       do: name

  defp workspace_name_filter(_), do: :all

  defp entity_matches_workspace?(_workspace_name, :all), do: true
  defp entity_matches_workspace?(workspace_name, workspace_name), do: true
  defp entity_matches_workspace?(_, _), do: false

  defp matches_filter?(_, "all"), do: true
  defp matches_filter?(%{host: "user"}, "users"), do: true
  defp matches_filter?(%{host: "agent"}, "agents"), do: true
  defp matches_filter?(%{host: "agent", flavor: flavor}, "agent:" <> flavor), do: true
  defp matches_filter?(_, _), do: false

  defp safe_parse_entity(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || Ezagent.URI.new!("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/identities"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:resource_panel>
        <div class="p-3 flex flex-col gap-1">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-1">{gettext("Filters")}</div>
          <.filter_chip filter={@filter} value="all" label={gettext("All")} />
          <.filter_chip filter={@filter} value="users" label={gettext("Users")} />
          <.filter_chip filter={@filter} value="agents" label={gettext("Agents")} />
          <div :if={@agent_flavors != []} class="text-[10px] uppercase tracking-wide text-zinc-500 mt-3 mb-1">{gettext("By flavor")}</div>
          <.filter_chip
            :for={f <- @agent_flavors}
            filter={@filter}
            value={"agent:" <> f}
            label={"agent: " <> f}
          />
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mt-3 mb-1">{gettext("Manage")}</div>
          <a href="/identities/users" class="px-2 py-1 text-xs rounded text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800">{gettext("+ Users admin")}</a>
        </div>
      </:resource_panel>
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Identities")}>
            <:subtitle>
              {gettext(
                "The directory of every live entity — users and agents. Driven by %{registry} filtered to %{scheme}.",
                registry: "Ezagent.KindRegistry",
                scheme: "entity://*"
              )}
            </:subtitle>
            <:actions>
              <.button variant="primary" size="sm" type="button" phx-click={JS.navigate("/identities/agents/new")}>
                {gettext("+ New agent")}
              </.button>
            </:actions>
          </.page_header>

          <p :if={@entities == []} id="identities-empty" class="text-sm text-zinc-500 italic">
            {gettext("No entities match the current filter.")}
          </p>

          <div :if={@entities != []} class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <.identity_card :for={e <- @entities} entity={e} />
          </div>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  attr :filter, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp filter_chip(assigns) do
    ~H"""
    <a
      href={"/identities?filter=" <> URI.encode_www_form(@value)}
      class={[
        "px-2 py-1 text-xs rounded font-mono",
        @filter == @value && "bg-zinc-900 text-white" || "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
      ]}
    >{@label}</a>
    """
  end

  attr :entity, :map, required: true

  defp identity_card(assigns) do
    ~H"""
    <.card>
      <div class="flex items-start gap-3">
        <.avatar uri={@entity.uri_str} size="md" />
        <div class="flex-1 min-w-0">
          <%!-- Username & Auth UI Task 1 (PR-O) — display name primary,
                URI mono subtitle. status_dot moves up beside the name. --%>
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate">{Map.get(@entity, :display_name, @entity.name)}</span>
            <.status_dot color={(@entity.alive && "green") || "gray"} />
          </div>
          <div class="font-mono text-[10px] text-zinc-500 truncate">{@entity.uri_str}</div>
          <div class="text-[11px] text-zinc-500 mt-1">
            {(@entity.host == "user" && gettext("User")) ||
              gettext("Agent (%{flavor})", flavor: @entity.flavor)}
          </div>
          <div class="flex gap-3 mt-2 text-xs">
            <%= if @entity.host == "user" do %>
              <a
                href={"/identities/users/" <> URI.encode_www_form(@entity.uri_str) <> "/caps"}
                class="text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 underline"
              >{gettext("Caps")}</a>
            <% else %>
              <a
                href={"/identities/agents/" <> URI.encode_www_form(@entity.uri_str)}
                class="text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 underline"
              >{gettext("Status")}</a>
              <a
                href={"/identities/agents/" <> URI.encode_www_form(@entity.uri_str) <> "/caps"}
                class="text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 underline"
              >{gettext("Caps")}</a>
              <a
                href={"/identities/agents/" <> URI.encode_www_form(@entity.uri_str) <> "/api-keys"}
                class="text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 underline"
              >{gettext("API Keys")}</a>
            <% end %>
          </div>
        </div>
      </div>
    </.card>
    """
  end
end
