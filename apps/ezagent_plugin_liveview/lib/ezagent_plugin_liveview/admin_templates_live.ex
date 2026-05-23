defmodule EzagentPluginLiveview.AdminTemplatesLive do
  @moduledoc """
  `/admin/templates` — V0 stop-gap for G-1 + G-2 (audit 2026-05-23).

  Read-only list view of AgentTemplate + SessionTemplate Kinds, pulled
  from `Ezagent.Ecto.KindSnapshot.list_in_workspace/1` (per SPEC v3
  §7.2 — the standard workspace-scoped read path; `list_all/0` is
  a system-scope bypass we use only when the current_workspace_uri
  isn't bound).

  The audit calls this surface a **V0 stop-gap**: the full-fidelity
  CRUD LVs for AgentTemplate / SessionTemplate creation, fork, edit
  are V2 work. This page closes G-1 + G-2 just by making the Kinds
  visible — operators can see what templates exist, navigate into
  AutoDeriveLive for raw slice inspection, and confirm the
  cc-orchestrator seed populated correctly.

  G-7 partial — splits the `template://` axis into "agent templates"
  vs "session templates" tabs (the per-host filter the audit cited).

  ## Tier + layering

  Tier 3 (plugin LV). Reads `KindSnapshot` (Tier 1 primitive) via
  the standard workspace-scoped query — no direct domain or plugin
  imports. The detail link goes to the existing `/plugins/auto/:kind`
  LV (already understands `:agent_template` and `:session_template`).

  ## Workspace plumbing (P12)

  Lists templates from the caller's `current_workspace_uri`. Template
  Kinds are per-tenant per SPEC v3 §3 (3-segment authority); ALL
  template:// URIs carry a workspace segment. Cross-workspace listing
  is intentionally NOT exposed — operators who need it use
  `/admin/registry` (the global registry browser).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.Ecto.KindSnapshot

  @kind_types ~w(agent_template session_template)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:filter, normalize_filter(params["type"]))
     |> assign_templates()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filter, normalize_filter(params["type"]))
     |> assign_templates()}
  end

  defp normalize_filter(nil), do: "all"
  defp normalize_filter(s) when s in ["all" | @kind_types], do: s
  defp normalize_filter(_), do: "all"

  defp assign_templates(socket) do
    rows = list_template_snapshots(socket)
    counts = count_by_kind(rows)
    filtered = Enum.filter(rows, &matches_filter?(&1, socket.assigns.filter))

    socket
    |> assign(:templates, filtered)
    |> assign(:counts, counts)
  end

  # Per P12 / P17 — workspace-scoped read. If `current_workspace_uri` is
  # missing (LV mounted outside the standard `live_session :require_entity`
  # path — shouldn't happen in production), fall back to list_all so the
  # page still renders something instead of an empty table the operator
  # can't act on.
  defp list_template_snapshots(socket) do
    case Map.get(socket.assigns, :current_workspace_uri) do
      nil ->
        KindSnapshot.list_all()

      ws_uri ->
        KindSnapshot.list_in_workspace(ws_uri)
    end
    |> Enum.filter(fn row -> row.kind_type in @kind_types end)
    |> Enum.map(&decode_row/1)
    |> Enum.sort_by(& &1.uri)
  end

  defp decode_row(%KindSnapshot{} = row) do
    %{
      uri: row.uri,
      kind_type: row.kind_type,
      bytes: byte_size_or_zero(row.state_binary),
      version: row.version,
      updated_at: row.updated_at
    }
  end

  defp byte_size_or_zero(bin) when is_binary(bin), do: byte_size(bin)
  defp byte_size_or_zero(_), do: 0

  defp count_by_kind(rows) do
    rows
    |> Enum.group_by(& &1.kind_type)
    |> Enum.into(%{}, fn {k, list} -> {k, length(list)} end)
  end

  defp matches_filter?(_, "all"), do: true
  defp matches_filter?(%{kind_type: k}, k), do: true
  defp matches_filter?(_, _), do: false

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin")
        )
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
        <AdminShell.admin_shell current_path="/admin/templates" active_section={:templates}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Templates")}>
                <:subtitle>
                  {gettext(
                    "AgentTemplate + SessionTemplate Kinds in this workspace. Read-only V0 — full CRUD lands in a follow-up."
                  )}
                </:subtitle>
              </.page_header>

              <div
                id="template-type-filter"
                class="flex items-center gap-1 flex-wrap mb-4"
              >
                <span class="text-[10px] uppercase tracking-wide text-zinc-500 mr-2">
                  {gettext("Type")}
                </span>
                <.filter_chip filter={@filter} value="all" label={gettext("all (%{n})", n: total_count(@counts))} />
                <.filter_chip
                  filter={@filter}
                  value="agent_template"
                  label={gettext("AgentTemplate (%{n})", n: Map.get(@counts, "agent_template", 0))}
                />
                <.filter_chip
                  filter={@filter}
                  value="session_template"
                  label={gettext("SessionTemplate (%{n})", n: Map.get(@counts, "session_template", 0))}
                />
              </div>

              <.card id="templates-card">
                <p
                  :if={@templates == []}
                  id="templates-empty"
                  class="text-sm text-zinc-500 italic"
                >
                  {gettext(
                    "No templates of the selected type in this workspace. Seed runs at boot — check Boot diagnostics on /plugins."
                  )}
                </p>

                <table
                  :if={@templates != []}
                  id="templates-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">{gettext("URI")}</th>
                      <th class="text-left">{gettext("Type")}</th>
                      <th class="text-right">{gettext("Bytes")}</th>
                      <th class="text-left">{gettext("Updated")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={t <- @templates}
                      class="border-b border-zinc-100 dark:border-zinc-900"
                    >
                      <td class="px-1 py-1 font-mono text-[11px] text-zinc-700 dark:text-zinc-300 break-all">
                        {t.uri}
                      </td>
                      <td>
                        <.badge variant={type_badge_variant(t.kind_type)}>{t.kind_type}</.badge>
                      </td>
                      <td class="text-right font-mono text-[11px] text-zinc-500">{t.bytes}</td>
                      <td class="font-mono text-[11px] text-zinc-500">
                        {DateTime.to_iso8601(t.updated_at)}
                      </td>
                      <td class="text-right">
                        <a
                          href={"/plugins/auto/#{t.kind_type}/#{URI.encode_www_form(t.uri)}"}
                          class="text-xs text-sky-700 dark:text-sky-300 hover:underline"
                        >
                          {gettext("inspect")} →
                        </a>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <p class="text-[11px] text-zinc-500 mt-4">
                {gettext(
                  "V0 stop-gap (audit 2026-05-23 G-1/G-2). Form-driven create / edit / fork / version graph land in V2. For raw slice inspection use the inspect link (AutoDeriveLive)."
                )}
              </p>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  defp total_count(counts) do
    counts
    |> Map.values()
    |> Enum.sum()
  end

  defp type_badge_variant("agent_template"), do: "info"
  defp type_badge_variant("session_template"), do: "primary"
  defp type_badge_variant(_), do: "default"

  attr :filter, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp filter_chip(assigns) do
    ~H"""
    <a
      href={"/admin/templates?type=#{@value}"}
      class={[
        "px-3 py-1 text-xs rounded-md transition-colors border",
        (@filter == @value &&
           "bg-zinc-900 dark:bg-zinc-100 text-zinc-50 dark:text-zinc-900 border-zinc-900 dark:border-zinc-100") ||
          "bg-white dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-800"
      ]}
    >
      {@label}
    </a>
    """
  end
end
