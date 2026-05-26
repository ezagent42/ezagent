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
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    # Admin gate enforced upstream by `live_session :require_admin`
    # in `EzagentWeb.Router` (codex PR #305 round-2 HIGH fix).
    # Per-LV redirect removed — the central gate halts non-admins
    # before mount runs.
    {:ok, socket |> assign(:tab, :overview) |> assign_data()}
  end

  defp assign_data(socket) do
    # Notification + Log audit LOW fix (2026-05-24):
    # Phase 9 PR-6 added `workspace_uri` to `invocations` +
    # `kind_snapshots` for tenant isolation, but ObservabilityLive's
    # READ path never landed the filter — an admin viewing
    # `/admin/logs` saw EVERY tenant's audit rows, regardless of
    # their workspace scope.
    #
    # Filter rule:
    # - System admin (`is_admin?` AND `current_workspace_uri == :system`
    #   OR membership in system workspace) sees ALL rows
    # - Workspace admin sees only their workspace's rows
    # - Non-admins shouldn't reach this LV (router-level gate); for
    #   defence-in-depth the filter still applies if they do
    workspace_filter = workspace_filter_for(socket.assigns)

    socket
    |> assign(:kinds_total, length(Ezagent.KindRegistry.list_all()))
    |> assign(:bridges, list_bridges())
    |> assign(:audit_rows, list_recent_audit(50, workspace_filter))
    |> assign(:snapshots, list_snapshots(workspace_filter))
    |> assign(:workspace_filter, workspace_filter)
  end

  # Returns either `:all` (system-admin) or `{:scoped, workspace_uri_string}`.
  defp workspace_filter_for(%{is_system_member?: true}), do: :all

  defp workspace_filter_for(%{current_workspace_uri: %URI{} = wsu}),
    do: {:scoped, URI.to_string(wsu)}

  defp workspace_filter_for(%{current_workspace_uri: wsu}) when is_binary(wsu),
    do: {:scoped, wsu}

  # Fail-closed: if neither flag is present, scope to a nonexistent
  # workspace so the LV shows zero rows rather than leaking.
  defp workspace_filter_for(_), do: {:scoped, "workspace://__none__"}

  defp list_bridges do
    if Code.ensure_loaded?(EzagentPluginCc.BridgeRegistry) do
      EzagentPluginCc.BridgeRegistry.list_all()
    else
      []
    end
  end

  defp list_recent_audit(limit, :all) do
    case EzagentCore.Repo.query(
           "SELECT target, action, authz, duration_us, inserted_at FROM invocations ORDER BY id DESC LIMIT ?1",
           [limit]
         ) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp list_recent_audit(limit, {:scoped, workspace_uri}) do
    case EzagentCore.Repo.query(
           "SELECT target, action, authz, duration_us, inserted_at FROM invocations " <>
             "WHERE workspace_uri = ?1 ORDER BY id DESC LIMIT ?2",
           [workspace_uri, limit]
         ) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp list_snapshots(:all) do
    case EzagentCore.Repo.query(
           "SELECT uri, kind_type, version, length(state_binary), updated_at FROM kind_snapshots ORDER BY updated_at DESC LIMIT 50",
           []
         ) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp list_snapshots({:scoped, workspace_uri}) do
    case EzagentCore.Repo.query(
           "SELECT uri, kind_type, version, length(state_binary), updated_at FROM kind_snapshots " <>
             "WHERE workspace_uri = ?1 ORDER BY updated_at DESC LIMIT 50",
           [workspace_uri]
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
      workspace_name={@workspace_name}
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
            <.tab_link tab={@tab} value={:overview} label={gettext("Overview")} />
            <.tab_link tab={@tab} value={:events} label={gettext("Events")} />
            <.tab_link tab={@tab} value={:audit} label={gettext("Audit Log")} />
            <.tab_link tab={@tab} value={:bridges} label={gettext("Bridges")} />
            <.tab_link tab={@tab} value={:snapshots} label={gettext("Snapshots")} />
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
    <.page_header title={gettext("Health Overview")}>
      <:subtitle>{gettext("System pulse — KindRegistry, CC bridges, recent audit activity.")}</:subtitle>
    </.page_header>
    <div class="grid grid-cols-3 gap-3">
      <.stat label={gettext("Kinds alive")} value={@kinds_total} />
      <.stat label={gettext("CC bridges")} value={length(@bridges)} />
      <.stat label={gettext("Recent audit rows")} value={length(@audit_rows)} />
    </div>
    """
  end

  defp render_tab(assigns, :events) do
    ~H"""
    <.page_header title={gettext("Events")}>
      <:subtitle>{gettext("CC hook errors + runtime events. Per-event detail in audit log.")}</:subtitle>
    </.page_header>
    <.empty_state title={gettext("No live events")} description={gettext("Live event stream wires in Phase 9.")} />
    """
  end

  defp render_tab(assigns, :audit) do
    ~H"""
    <.page_header title={gettext("Audit Log (last 50)")}>
      <:subtitle>{gettext("Every Ezagent.Invocation.dispatch — target, action, authz, duration.")}</:subtitle>
    </.page_header>
    <.card class="p-0">
      <table class="w-full text-xs font-mono">
        <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 text-zinc-500">
          <tr>
            <th class="text-left px-3 py-2">{gettext("Target")}</th>
            <th class="text-left">{gettext("Action")}</th>
            <th class="text-left">{gettext("Authz")}</th>
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
    <.page_header title={gettext("CC Bridges (v2)")}>
      <:subtitle>{gettext("Active Phoenix.Channel connections to /cc_socket.")}</:subtitle>
    </.page_header>
    <.empty_state
      :if={@bridges == []}
      title={gettext("No connected bridges")}
      description={gettext("A bridge connects when a cc.agent's claude PtyServer launches its Python MCP sidecar.")}
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
              <.badge variant="success">{gettext("connected")}</.badge>
            </td>
          </tr>
        </tbody>
      </table>
    </.card>
    """
  end

  defp render_tab(assigns, :snapshots) do
    ~H"""
    <.page_header title={gettext("Snapshots")}>
      <:subtitle>{gettext("Persisted Kind state snapshots.")}</:subtitle>
    </.page_header>
    <.empty_state
      :if={@snapshots == []}
      title={gettext("No snapshots")}
      description={gettext("Kinds with persistence: {:snapshot, :on_change} write here.")}
    />
    <.card :if={@snapshots != []} class="p-0">
      <table class="w-full text-xs font-mono">
        <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 text-zinc-500">
          <tr>
            <th class="text-left px-3 py-2">{gettext("URI")}</th>
            <th class="text-left">{gettext("kind")}</th>
            <th class="text-right">v</th>
            <th class="text-right">{gettext("bytes")}</th>
            <th class="text-left pr-3">{gettext("updated")}</th>
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
