defmodule EzagentPluginLiveview.EntitiesLive do
  @moduledoc """
  PR #149 (S-5, entity-agnostic reflection §4) — unified registry
  surface at `/admin/entities`.

  Lists every live Kind in `Ezagent.KindRegistry` regardless of URI
  scheme — entity://user/*, entity://agent/*, session://*,
  workspace://*, template://*, system://*. Replaces the pre-PR-149
  agent-only `/admin/agents` LV, which couldn't answer the operator's
  "what's alive right now?" question for non-agent Kinds.

  Filter chips along the top let the operator narrow by scheme/host.
  Clicking an entity opens the per-Kind detail view at
  `/plugins/auto/<kind>/<encoded-uri>` (Phase 6 PR 10's auto-derive LV).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:filter, params["filter"] || "all")
     |> assign_entities()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filter, params["filter"] || "all")
     |> assign_entities()}
  end

  defp assign_entities(socket) do
    entries =
      Ezagent.KindRegistry.list_all()
      |> Enum.map(&decode_entry/1)
      |> Enum.filter(&matches_filter?(&1, socket.assigns.filter))
      |> Enum.sort_by(& &1.uri_str)

    assign(socket, :entities, entries)
  end

  defp decode_entry({uri_str, pid}) do
    parsed = parse_or_nil(uri_str)

    %{
      uri_str: uri_str,
      scheme: parsed && parsed.scheme,
      host: parsed && parsed.host,
      path: parsed && parsed.path,
      pid: pid,
      pid_str: inspect(pid)
    }
  end

  defp parse_or_nil(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the nil-fallback display semantics.
    try do
      Ezagent.URI.new!(uri_str)
    rescue
      ArgumentError -> nil
    end
  end

  # Filter chips map to either a scheme ("session", "workspace",
  # "template", "system") OR an "entity://<host>" pair ("user", "agent").
  defp matches_filter?(_, "all"), do: true
  defp matches_filter?(%{scheme: "entity", host: host}, host), do: true
  defp matches_filter?(%{scheme: scheme}, scheme), do: true
  defp matches_filter?(_, _), do: false

  @impl true
  def render(assigns) do
    # Nested-shell PR-3: wrap in AppShell.app_shell (perspective :admin)
    # over AdminShell.admin_shell.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || Ezagent.URI.new!("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/registry" active_section={:registry}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Entities (live registry)")}>
                <:subtitle>
                  {gettext(
                    "Every Kind currently registered in %{registry} — users, agents, sessions, workspaces, templates, system sentinels.",
                    registry: "Ezagent.KindRegistry"
                  )}
                </:subtitle>
              </.page_header>

              <%!-- V-4 scrub (audit 2026-05-23): inline style="" purged.
                    Filter chips inlined above the table since the left
                    rail is now the admin sub-section nav. --%>
              <div class="flex items-center gap-1 flex-wrap mt-3 mb-4">
                <span class="text-[10px] uppercase tracking-wide text-zinc-500 mr-2">{gettext("Filters")}</span>
                <.filter_chip filter={@filter} value="all" label="all" />
                <.filter_chip filter={@filter} value="user" label="entity://user" />
                <.filter_chip filter={@filter} value="agent" label="entity://agent" />
                <.filter_chip filter={@filter} value="session" label="session://" />
                <.filter_chip filter={@filter} value="workspace" label="workspace://" />
                <.filter_chip filter={@filter} value="template" label="template://" />
                <.filter_chip filter={@filter} value="system" label="system://" />
              </div>

              <.card>
                <p
                  :if={@entities == []}
                  id="entities-empty"
                  class="text-sm text-zinc-500 italic"
                >
                  {gettext("No entities match the current filter.")}
                </p>

                <table
                  :if={@entities != []}
                  id="entities-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">scheme</th>
                      <th class="text-left">host</th>
                      <th class="text-left">path</th>
                      <th class="text-left">pid</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={e <- @entities}
                      class="border-b border-zinc-100 dark:border-zinc-900"
                    >
                      <td class="px-1 py-1 font-mono text-xs text-violet-700 dark:text-violet-400">
                        {e.scheme || "—"}
                      </td>
                      <td class="font-mono text-xs">{e.host || "—"}</td>
                      <td class="font-mono text-xs">{e.path || "—"}</td>
                      <td class="font-mono text-[11px] text-zinc-500">{e.pid_str}</td>
                      <td>
                        <a
                          :if={e.scheme}
                          href={"/plugins/auto/#{e.scheme}/#{URI.encode_www_form(e.uri_str)}"}
                          class="text-xs text-sky-700 dark:text-sky-300 hover:underline"
                        >
                          {gettext("detail")} →
                        </a>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  attr(:filter, :string, required: true)
  attr(:value, :string, required: true)
  attr(:label, :string, required: true)

  defp filter_chip(assigns) do
    ~H"""
    <a
      href={"/admin/registry?filter=#{@value}"}
      class={[
        "px-3 py-1 text-xs rounded-md transition-colors border",
        (@filter == @value &&
           "bg-zinc-900 dark:bg-zinc-100 text-zinc-50 dark:text-zinc-900 border-zinc-900 dark:border-zinc-100") ||
          "bg-white dark:bg-zinc-900 text-sky-700 dark:text-sky-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-800"
      ]}
    >
      {@label}
    </a>
    """
  end
end
