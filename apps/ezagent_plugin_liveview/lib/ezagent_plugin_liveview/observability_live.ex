defmodule EzagentPluginLiveview.ObservabilityLive do
  @moduledoc """
  Phase 8 阶段 D — Observability LV (`/admin/observability`).

  Aggregates Overview / Events / Audit Log / Bridges / Snapshots into
  one IDE-Shell-wrapped surface. Replaces the bottom DebugPanel that
  used to live inside admin_live; admin can stay focused on chat.

  v1 implementation: tab switcher with live counts. Detail panels
  display existing data (KindRegistry, CC bridges, audit invocations).
  """
  use Phoenix.LiveView
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:tab, :overview) |> assign_data()}
  end

  defp assign_data(socket) do
    socket
    |> assign(:kinds_total, length(Ezagent.KindRegistry.list_all()))
    |> assign(:bridges, list_bridges())
    |> assign(:audit_rows, list_recent_audit(50))
    |> assign(:snapshots, list_snapshots())
  end

  defp list_bridges do
    if Code.ensure_loaded?(EzagentPluginCc.BridgeRegistry) do
      EzagentPluginCc.BridgeRegistry.list_all()
    else
      []
    end
  end

  defp list_recent_audit(limit) do
    case EzagentCore.Repo.query(
           "SELECT target, action, authz, duration_us, inserted_at FROM invocations ORDER BY id DESC LIMIT ?1",
           [limit]
         ) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp list_snapshots do
    case EzagentCore.Repo.query(
           "SELECT uri, kind_type, version, length(state_binary), updated_at FROM kind_snapshots ORDER BY updated_at DESC LIMIT 50",
           []
         ) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  @impl true
  def handle_event("switch_tab", %{"key" => key}, socket) do
    {:noreply, socket |> assign(:tab, String.to_existing_atom(key)) |> assign_data()}
  end

  @impl true
  def render(assigns) do
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
        <AdminShell.admin_shell current_path="/admin/logs" active_section={:logs}>
          <:main>
            <div class="px-6 py-6">
          <%!-- Phase 8c PR-F: sub-section tabs (overview / events / audit
                / bridges / snapshots) live inline as a horizontal tab
                strip. The left sidebar holds the top-level sub-section
                nav (Overview / Logs & Audit / Registry / Snapshots);
                a second vertical nav would be redundant. --%>
          <nav class="flex items-center gap-1 mb-4 border-b border-zinc-200 dark:border-zinc-800 -mx-6 px-6 pb-0">
            <.tab_link tab={@tab} value={:overview} label="Overview" />
            <.tab_link tab={@tab} value={:events} label="Events" />
            <.tab_link tab={@tab} value={:audit} label="Audit Log" />
            <.tab_link tab={@tab} value={:bridges} label="Bridges" />
            <.tab_link tab={@tab} value={:snapshots} label="Snapshots" />
          </nav>
          {render_tab(assigns, @tab)}
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  attr(:tab, :atom, required: true)
  attr(:value, :atom, required: true)
  attr(:label, :string, required: true)

  defp tab_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_tab"
      phx-value-key={Atom.to_string(@value)}
      class={[
        "px-3 py-1.5 text-xs border-b-2 -mb-px transition-colors",
        (@tab == @value &&
           "border-zinc-900 dark:border-zinc-100 text-zinc-900 dark:text-zinc-100 font-medium") ||
          "border-transparent text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100"
      ]}
    >
      {@label}
    </button>
    """
  end

  defp render_tab(assigns, :overview) do
    ~H"""
    <.page_header title="Health Overview">
      <:subtitle>System pulse — KindRegistry, CC bridges, recent audit activity.</:subtitle>
    </.page_header>
    <div class="grid grid-cols-3 gap-3">
      <.stat label="Kinds alive" value={@kinds_total} />
      <.stat label="CC bridges" value={length(@bridges)} />
      <.stat label="Recent audit rows" value={length(@audit_rows)} />
    </div>
    """
  end

  defp render_tab(assigns, :events) do
    ~H"""
    <.page_header title="Events">
      <:subtitle>CC hook errors + runtime events. Per-event detail in audit log.</:subtitle>
    </.page_header>
    <.empty_state title="No live events" description="Live event stream wires in Phase 9." />
    """
  end

  defp render_tab(assigns, :audit) do
    ~H"""
    <.page_header title="Audit Log (last 50)">
      <:subtitle>Every Ezagent.Invocation.dispatch — target, action, authz, duration.</:subtitle>
    </.page_header>
    <.card class="p-0">
      <table class="w-full text-xs font-mono">
        <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 text-zinc-500">
          <tr>
            <th class="text-left px-3 py-2">Target</th>
            <th class="text-left">Action</th>
            <th class="text-left">Authz</th>
            <th class="text-right pr-3">μs</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={[target, action, authz, dur, _at] <- @audit_rows}
            class="border-b border-zinc-100 dark:border-zinc-900"
          >
            <td class="px-3 py-1 truncate max-w-md">{target}</td>
            <td>{action || "—"}</td>
            <td>
              <.badge variant={authz_variant(authz)}>{authz}</.badge>
            </td>
            <td class="text-right pr-3 tabular-nums">{dur || "—"}</td>
          </tr>
        </tbody>
      </table>
    </.card>
    """
  end

  defp render_tab(assigns, :bridges) do
    ~H"""
    <.page_header title="CC Bridges (v2)">
      <:subtitle>Active Phoenix.Channel connections to /cc_socket.</:subtitle>
    </.page_header>
    <.empty_state
      :if={@bridges == []}
      title="No connected bridges"
      description="A bridge connects when a cc.agent's claude PtyServer launches its Python MCP sidecar."
    />
    <.card :if={@bridges != []} class="p-0">
      <table class="w-full text-xs font-mono">
        <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 text-zinc-500">
          <tr>
            <th class="text-left px-3 py-2">agent_uri</th>
            <th class="text-left">status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{uri, _pid} <- @bridges} class="border-b border-zinc-100 dark:border-zinc-900">
            <td class="px-3 py-1">{URI.to_string(uri)}</td>
            <td>
              <.badge variant="success">connected</.badge>
            </td>
          </tr>
        </tbody>
      </table>
    </.card>
    """
  end

  defp render_tab(assigns, :snapshots) do
    ~H"""
    <.page_header title="Snapshots">
      <:subtitle>Persisted Kind state snapshots.</:subtitle>
    </.page_header>
    <.empty_state
      :if={@snapshots == []}
      title="No snapshots"
      description="Kinds with persistence: {:snapshot, :on_change} write here."
    />
    <.card :if={@snapshots != []} class="p-0">
      <table class="w-full text-xs font-mono">
        <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 text-zinc-500">
          <tr>
            <th class="text-left px-3 py-2">URI</th>
            <th class="text-left">kind</th>
            <th class="text-right">v</th>
            <th class="text-right">bytes</th>
            <th class="text-left pr-3">updated</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={[uri, kind, version, bytes, updated_at] <- @snapshots}
            class="border-b border-zinc-100 dark:border-zinc-900"
          >
            <td class="px-3 py-1 truncate max-w-xs">{uri}</td>
            <td>{kind || "—"}</td>
            <td class="text-right tabular-nums">{version || 0}</td>
            <td class="text-right tabular-nums">{bytes || 0}</td>
            <td class="pr-3 text-zinc-500">{updated_at || "—"}</td>
          </tr>
        </tbody>
      </table>
    </.card>
    """
  end

  defp authz_variant("granted"), do: "success"
  defp authz_variant("denied"), do: "danger"
  defp authz_variant(_), do: "default"
end
