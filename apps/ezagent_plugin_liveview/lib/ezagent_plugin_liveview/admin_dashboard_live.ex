defmodule EzagentPluginLiveview.AdminDashboardLive do
  @moduledoc """
  Phase 8 polish (Allen 2026-05-20) — admin dashboard at `/admin`.

  Replaces the former `/admin = Sessions` mapping (Sessions moved to
  `/sessions`). `/admin` is now reserved for sysadmin: overview KPIs
  plus links to `/admin/logs` (renamed from `/admin/observability`),
  `/admin/registry` (the KindRegistry live view, moved from
  `/admin/entities`), and `/admin/snapshots`.

  Phase 8c PR-F (2026-05-20): rendered inside the admin settings-drawer
  perspective instead of the IDE Shell. The drawer has no Activity
  Bar — admin is not a peer workflow, it's a permission/role
  perspective opened from the avatar dropdown.

  Nested-shell PR-3 (SPEC §1, §6 row 3): now renders
  `AppShell.app_shell` (`perspective: :admin`) wrapping
  `AdminShell.admin_shell` — the page gains the universal chrome
  (avatar / notifications / search / ⌘K) the old chrome-less
  `AdminSettingsShell` lacked.
  """
  use Phoenix.LiveView
  # i18n V1 (Allen 2026-05-21): backend module reference is runtime —
  # EzagentWeb.Gettext lives in the host app but doesn't need a
  # compile-time dep here. Gettext macros expand to runtime calls
  # against the named backend.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_overview()
     |> assign(:cc_orchestrator_status, load_cc_orchestrator_status())}
  end

  # Moved from /plugins 2026-05-26 (Allen): system-level boot-health is
  # admin/dashboard scope, not per-plugin metadata. Per-session
  # orchestrator INSTANCE health goes in session detail UI; this card
  # is the *template/seed* status only.
  #
  # Soft-guarded via `Code.ensure_loaded?` so this LV stays decoupled
  # from the chat domain at compile time (the seed lives in
  # `ezagent_domain_chat`).
  defp load_cc_orchestrator_status do
    seed_module = Ezagent.Orchestrator.CcOrchestratorSeed

    if Code.ensure_loaded?(seed_module) and function_exported?(seed_module, :seed_status, 0) do
      seed_module.seed_status()
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  end

  # Bug 1 fix (Allen 2026-05-26) — count-vs-list collision.
  #
  # `:workspaces` is assigned by `EzagentWeb.LiveAuth.require_entity_mount/2`
  # as the LIST of visible workspaces (`[%{id, name, uri, ...}]`) for the
  # `AppShell` workspace-dropdown component. Previously this overview
  # rebound `:workspaces` to the per-perspective COUNT (an integer), which
  # then propagated to `AppShell.app_shell` → `outer_command_bar` →
  # `workspace_dropdown`'s `<%= for ws <- @workspaces do %>` and crashed
  # with `Protocol.UndefinedError: protocol Enumerable not implemented
  # for Integer.`
  #
  # KPI count assigns are renamed `_count` to avoid shadowing the list
  # assigns that the universal chrome reads. `:identities` likewise
  # could collide with future identity-list assigns — same suffix
  # treatment.
  defp assign_overview(socket) do
    kinds = Ezagent.KindRegistry.list_all()

    sessions_count =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "session://")
      end)

    workspaces_count =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "workspace://")
      end)

    identities_count =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "entity://")
      end)

    agents_count =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "entity://agent/")
      end)

    socket
    |> assign(:kinds_total, length(kinds))
    |> assign(:sessions_count, sessions_count)
    |> assign(:workspaces_count, workspaces_count)
    |> assign(:identities_count, identities_count)
    |> assign(:agents_count, agents_count)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || Ezagent.URI.parse!("entity://user/system/admin"))
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
        <AdminShell.admin_shell current_path="/admin" active_section={:overview}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Overview")}>
            <:subtitle>
              {gettext(
                "System layer (admin settings drawer). Workspace-layer surfaces — Sessions, Workspaces, Identities, Routing, Plugins — live on the main Activity Bar. Close this drawer to return."
              )}
            </:subtitle>
          </.page_header>

          <%!-- 2026-05-26 (Allen): Boot diagnostics card moved here
                from /plugins. The cc-orchestrator AgentTemplate seed
                is system-level boot-health — `template://agent/system/
                cc-orchestrator` must exist by the time the Generator
                tries to spawn an orchestrator instance. A silent seed
                failure used to leave operators grepping logs to find
                out; this card surfaces the status at a glance. Per-
                session orchestrator INSTANCE health goes in the
                session-detail UI (separate panel). --%>
          <.boot_diagnostics_card status={@cc_orchestrator_status} />

          <%!-- Phase 8c PR-D — animated KPIs. The value renders SSR-final
                (no flash of 0); the `CountUp` JS hook resets to 0 on
                mount and animates 0 → target over 800ms with an
                ease-out curve. Falls back gracefully to the static
                number if JS doesn't run. --%>
          <div class="grid grid-cols-4 gap-3 mb-6 mt-4">
            <.card><.kpi label={gettext("Sessions")} value={@sessions_count} id="kpi-sessions" /></.card>
            <.card><.kpi label={gettext("Workspaces")} value={@workspaces_count} id="kpi-workspaces" /></.card>
            <.card><.kpi label={gettext("Identities")} value={@identities_count} id="kpi-identities" /></.card>
            <.card><.kpi label={gettext("Kinds alive")} value={@kinds_total} id="kpi-kinds" /></.card>
          </div>

          <div class="grid grid-cols-3 gap-3">
            <a href="/admin/logs" class="block">
              <.card>
                <div class="font-medium text-sm">{gettext("Logs & Audit")} →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  {gettext("Dispatch audit log, events, bridges. Renamed from Observability.")}
                </div>
              </.card>
            </a>
            <a href="/admin/registry" class="block">
              <.card>
                <div class="font-medium text-sm">{gettext("Registry")} →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  {gettext("Live %{registry} snapshot — every Kind, every URI.",
                    registry: "Ezagent.KindRegistry"
                  )}
                </div>
              </.card>
            </a>
            <a href="/admin/snapshots" class="block">
              <.card>
                <div class="font-medium text-sm">{gettext("Snapshots")} →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  {gettext("Persisted Kind state per %{table} table.", table: "kind_snapshots")}
                </div>
              </.card>
            </a>
          </div>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  # --- boot diagnostics ----------------------------------------------------

  # Moved from /plugins 2026-05-26 (Allen): the cc-orchestrator
  # AgentTemplate seed status is system-level boot-health, not per-
  # plugin metadata. The card renders one row per check, with a colored
  # badge + a one-sentence operator-facing explanation. Always rendered
  # (even on all-green) so operators see "everything OK" at a glance
  # instead of wondering whether the page hides its diagnostics.
  attr :status, :any, required: true

  defp boot_diagnostics_card(assigns) do
    ~H"""
    <.card class="mb-4" id="boot-diagnostics">
      <:header>{gettext("Boot diagnostics")}</:header>
      <div class="flex items-start justify-between gap-3" id="cc-orchestrator-seed-row">
        <div class="min-w-0">
          <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">
            {gettext("cc-orchestrator AgentTemplate seed")}
          </div>
          <div class="text-xs text-zinc-500 mt-0.5">
            {cc_seed_subtitle(@status)}
          </div>
        </div>
        <div class="shrink-0">
          {cc_seed_badge(assigns)}
        </div>
      </div>
    </.card>
    """
  end

  defp cc_seed_badge(%{status: {:ok, _}} = assigns) do
    ~H"""
    <.badge variant="success">{gettext("seeded")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: {:partial, _}} = assigns) do
    ~H"""
    <.badge variant="warning">{gettext("partial")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: {:missing, _}} = assigns) do
    ~H"""
    <.badge variant="danger">{gettext("missing")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: :unavailable} = assigns) do
    ~H"""
    <.badge variant="default">{gettext("unavailable")}</.badge>
    """
  end

  defp cc_seed_subtitle({:ok, %{template_uri: uri}}),
    do: gettext("Populated at %{uri}.", uri: uri)

  defp cc_seed_subtitle({:partial, %{template_uri: uri}}),
    do:
      gettext(
        "Kind alive at %{uri} but template slice is empty — soft sandbox-files write may have failed. Check application logs.",
        uri: uri
      )

  defp cc_seed_subtitle({:missing, %{template_uri: uri}}),
    do:
      gettext(
        "No Kind registered at %{uri} — seed did not run or failed at boot. Generator-spawned orchestrators will fail.",
        uri: uri
      )

  defp cc_seed_subtitle(:unavailable),
    do:
      gettext(
        "Status unavailable — chat domain not loaded (test env) or seed module missing."
      )

  # --- kpi -----------------------------------------------------------------

  # Phase 8c PR-D — animated KPI tile.
  #
  # Renders the same visual shape as `Components.stat/1` but wraps the
  # numeric value in a `phx-hook="CountUp"` span so the JS hook animates
  # 0 → target on mount.
  #
  # `id` MUST be stable + unique on the page (LiveView hooks require it).
  # (`@doc` dropped — Elixir discards it on private functions.)
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:id, :string, required: true)

  defp kpi(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs uppercase tracking-wide text-zinc-500">{@label}</span>
      <span
        id={@id}
        phx-hook="CountUp"
        data-value={@value}
        class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"
      >
        {@value}
      </span>
    </div>
    """
  end
end
