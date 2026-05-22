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
    case URI.new(uri_str) do
      {:ok, u} -> u
      _ -> nil
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
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/registry" active_section={:registry}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <header>
            <h1 style="font-size: 22px; font-weight: 600;">Entities (live registry)</h1>
            <p style="font-size: 13px; color: #666;">
              Every Kind currently registered in <code>Ezagent.KindRegistry</code> — users,
              agents, sessions, workspaces, templates, system sentinels.
            </p>
          </header>

          <%!-- Phase 8c PR-F: filter chips inlined above the table since
            the left rail is now the admin sub-section nav. --%>
          <div class="flex items-center gap-1 flex-wrap mt-3">
            <span class="text-[10px] uppercase tracking-wide text-zinc-500 mr-2">Filters</span>
            <.filter_chip filter={@filter} value="all" label="all" />
            <.filter_chip filter={@filter} value="user" label="entity://user" />
            <.filter_chip filter={@filter} value="agent" label="entity://agent" />
            <.filter_chip filter={@filter} value="session" label="session://" />
            <.filter_chip filter={@filter} value="workspace" label="workspace://" />
            <.filter_chip filter={@filter} value="template" label="template://" />
            <.filter_chip filter={@filter} value="system" label="system://" />
          </div>

          <section style="margin-top: 16px;">
            <p
              :if={@entities == []}
              id="entities-empty"
              style="font-size: 13px; color: #57606a; font-style: italic;"
            >
              No entities match the current filter.
            </p>

            <table
              :if={@entities != []}
              id="entities-table"
              style="width: 100%; font-size: 13px; border-collapse: collapse;"
            >
              <thead>
                <tr style="border-bottom: 2px solid #d1d5da;">
                  <th style="text-align: left; padding: 6px 4px;">scheme</th>
                  <th style="text-align: left;">host</th>
                  <th style="text-align: left;">path</th>
                  <th style="text-align: left;">pid</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={e <- @entities} style="border-bottom: 1px solid #eaeef2;">
                  <td style="padding: 6px 4px; font-family: monospace; font-size: 12px; color: #6f42c1;">
                    {e.scheme || "—"}
                  </td>
                  <td style="font-family: monospace; font-size: 12px;">{e.host || "—"}</td>
                  <td style="font-family: monospace; font-size: 12px;">{e.path || "—"}</td>
                  <td style="font-family: monospace; font-size: 11px; color: #57606a;">
                    {e.pid_str}
                  </td>
                  <td>
                    <a
                      :if={e.scheme}
                      href={"/plugins/auto/#{e.scheme}/#{URI.encode_www_form(e.uri_str)}"}
                      style="color: #0969da; font-size: 12px;"
                    >
                      detail →
                    </a>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>
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
      style={chip_style(@filter == @value)}
    >
      {@label}
    </a>
    """
  end

  defp chip_style(true),
    do:
      "padding: 4px 12px; background: #0969da; color: white; border-radius: 12px; " <>
        "font-size: 12px; text-decoration: none;"

  defp chip_style(false),
    do:
      "padding: 4px 12px; background: white; color: #0969da; border: 1px solid #d1d5da; " <>
        "border-radius: 12px; font-size: 12px; text-decoration: none;"
end
