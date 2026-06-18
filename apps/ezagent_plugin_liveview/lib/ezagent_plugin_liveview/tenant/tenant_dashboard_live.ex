defmodule EzagentPluginLiveview.Tenant.TenantDashboardLive do
  @moduledoc """
  T2A.2 — Tenant Admin Dashboard at `/autoservice/tenant/:tid`.

  Shows current version, active CRs, and a sandbox preview button.
  Reads tenant config via `EzagentPluginContent.Tenant.TenantConfig`.

  Mount reads the `:tid` param and loads config + CR state.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    config = load_tenant_config(tid)
    cr = load_active_cr(tid)
    initialized? = check_initialized?(tid)

    {:ok,
     socket
     |> assign(:page_title, gettext("Tenant: %{tid}", tid: tid))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, tid)
     |> assign(:config, config)
     |> assign(:cr, cr)
     |> assign(:initialized?, initialized?)
     |> assign(:version, (cr && cr["published_version"]) || gettext("none"))
     |> assign(:flash_info, nil)
     |> assign_metrics(tid, cr)}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Tenant Dashboard"))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, nil)
     |> assign(:config, nil)
     |> assign(:cr, nil)
     |> assign(:initialized?, false)
     |> assign(:version, gettext("n/a"))
     |> assign(:flash_info, gettext("No tenant ID provided."))
     |> assign_metrics(nil, nil)}
  end

  # ---- Overview metrics (skills/kb/slots counts + sandbox change counts) ----

  @role "customer"

  defp assign_metrics(socket, nil, _cr) do
    socket
    |> assign(skills_count: 0, kb_count: 0, slots_count: 0, fast_changes: 0, slow_changes: 0)
  end

  defp assign_metrics(socket, tid, cr) do
    {fast, slow} = sandbox_change_counts(cr)

    socket
    |> assign(:skills_count, count_skills(tid, @role))
    |> assign(:kb_count, count_kb(tid))
    |> assign(:slots_count, count_slots(tid, @role))
    |> assign(:fast_changes, fast)
    |> assign(:slow_changes, slow)
  end

  defp count_skills(tid, role) do
    [TenantRuntime.sandbox_path(tid), "skills", role]
    |> Path.join()
    |> File.ls()
    |> case do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp count_slots(tid, role) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{role}.yaml"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.count(&Regex.match?(~r/^[A-Za-z0-9_]+\s*:/, &1))

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp count_kb(tid) do
    kb_dir = Path.join(TenantRuntime.sandbox_path(tid), "kb")
    mod = EzagentPluginContent.Kb.SourceTracker

    if Code.ensure_loaded?(mod) and function_exported?(mod, :list_sources, 1) do
      case mod.list_sources(kb_dir) do
        sources when is_list(sources) -> length(sources)
        _ -> 0
      end
    else
      0
    end
  rescue
    _ -> 0
  end

  # Sandbox change counts split by owning agent: config/* → Fast, the rest
  # (souls/slots/skills/kb) → Slow. Reads the active CR's recorded diff.
  defp sandbox_change_counts(cr) do
    items = get_in(cr || %{}, ["sandbox_diff", "items"]) || []

    Enum.reduce(items, {0, 0}, fn item, {fast, slow} ->
      if String.starts_with?(item_path(item), "config/") do
        {fast + 1, slow}
      else
        {fast, slow + 1}
      end
    end)
  rescue
    _ -> {0, 0}
  end

  defp item_path(%{"path" => p}) when is_binary(p), do: p
  defp item_path(%{"file" => p}) when is_binary(p), do: p
  defp item_path(p) when is_binary(p), do: p
  defp item_path(_), do: ""

  defp load_tenant_config(tid) do
    mod = EzagentPluginContent.Tenant.TenantConfig

    if Code.ensure_loaded?(mod) and function_exported?(mod, :read_config, 1) do
      case apply(mod, :read_config, [tid]) do
        {:ok, body} -> body
        :none -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp check_initialized?(tid) do
    current = Path.join([TenantRuntime.release_path(tid), "_current"])
    File.exists?(current)
  rescue
    _ -> false
  end

  defp load_active_cr(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      case apply(mod, :ensure_active_cr, [tid]) do
        {:ok, cr} -> cr
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    tid = socket.assigns.tid
    cr = load_active_cr(tid)

    {:noreply,
     socket
     |> assign(:config, load_tenant_config(tid))
     |> assign(:cr, cr)
     |> assign_metrics(tid, cr)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
        <.page_header title={"📊 " <> (@tid || gettext("Tenant"))}>
          <:subtitle>
            {tenant_subtitle(@config, @version)}
          </:subtitle>
          <:actions>
            <a
              :if={@tid}
              href={"/admin/autoservice/tenants/#{@tid}/init"}
              class="rounded-lg border border-blue-300 dark:border-blue-700 text-blue-600 dark:text-blue-400 px-3 py-1.5 text-sm font-medium hover:bg-blue-50 dark:hover:bg-blue-950 transition"
            >
              🚀 {gettext("Init Wizard")}
            </a>
          </:actions>
        </.page_header>

        <p
          :if={@flash_info}
          class="mb-4 text-sm text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-950 p-3 rounded-md"
        >
          {@flash_info}
        </p>

        <%!-- Initialization CTA (shown when tenant is pending) --%>
        <div
          :if={!@initialized?}
          class="max-w-3xl mx-auto border-2 border-amber-300 rounded-xl overflow-hidden"
        >
          <div class="bg-amber-50 px-6 py-5">
            <div class="flex items-start gap-4">
              <div class="text-4xl">🚀</div>
              <div class="flex-1">
                <h3 class="text-lg font-bold text-amber-900">{gettext("Tenant Not Initialized")}</h3>
                <p class="text-sm text-amber-700 mt-1">
                  {gettext(
                    "This tenant has not completed initialization. The wizard will auto-generate the Soul template from your brand/industry info, prefill slot values, inherit platform skills, and create the initial release."
                  )}
                </p>
                <div class="mt-4 flex gap-3">
                  <a
                    href={"/admin/autoservice/tenants/#{@tid}/init"}
                    class="bg-amber-600 text-white rounded-lg px-6 py-2.5 text-sm font-medium hover:bg-amber-700 shadow"
                  >
                    {gettext("Start Initialization")} →
                  </a>
                  <span class="text-xs text-amber-500 self-center">
                    💡 {gettext("Or use the sidebar menu to manually edit each module first.")}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@initialized?} class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
            {gettext("Overview")}
          </h2>
          <button phx-click="refresh" class="text-xs underline text-zinc-500 hover:text-zinc-700">
            {gettext("Refresh")}
          </button>
        </div>

        <%!-- Publish Flow --%>
        <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-gradient-to-r from-blue-50 to-green-50 dark:from-blue-950 dark:to-green-950 p-4 mb-6">
          <h3 class="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">
            Publish Flow
          </h3>
          <div class="flex items-center gap-1.5 text-xs flex-wrap">
            <a
              href={"/admin/autoservice/tenants/#{@tid}/agent/slow"}
              class="px-3 py-1.5 rounded-lg bg-blue-100 text-blue-700 font-medium hover:bg-blue-200 transition"
            >
              📝 1. Config Agents
            </a>
            <span class="text-gray-300">→</span>
            <a
              href={"/admin/autoservice/tenants/#{@tid}/orchestrate"}
              class="px-3 py-1.5 rounded-lg bg-gray-100 text-gray-600 hover:bg-gray-200 transition"
            >
              🔀 2. Orchestrate
            </a>
            <span class="text-gray-300">→</span>
            <a
              href={"/admin/autoservice/tenants/#{@tid}/debug"}
              class="px-3 py-1.5 rounded-lg bg-gray-100 text-gray-600 hover:bg-gray-200 transition"
            >
              🧪 3. Test
            </a>
            <span class="text-gray-300">→</span>
            <a
              href={"/admin/autoservice/tenants/#{@tid}/cr"}
              class="px-3 py-1.5 rounded-lg bg-gray-100 text-gray-600 hover:bg-gray-200 transition"
            >
              🔄 4. Review & Publish
            </a>
          </div>
        </div>

        <%!-- Agent Cards (aligned to design vision) --%>
        <h2 class="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">Agents</h2>
        <div class="grid grid-cols-2 gap-4 mb-6">
          <%!-- Fast Agent --%>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 hover:shadow-md hover:border-amber-300 transition">
            <div class="flex items-center justify-between mb-2">
              <span class="text-base font-semibold">⚡ Fast Agent</span>
              <span class={live_badge_class(@initialized?)}>{live_badge_text(@initialized?)}</span>
            </div>
            <div class="text-xs text-gray-600 dark:text-zinc-400 space-y-1">
              <div>
                📄 Soul:
                <code class="bg-gray-100 dark:bg-zinc-800 px-1 rounded">fast_ack_prompt.md</code>
              </div>
              <div>🔄 Sandbox: <span class="text-amber-600">{changes_label(@fast_changes)}</span></div>
            </div>
            <div class="flex gap-2 mt-3">
              <a
                href={"/admin/autoservice/tenants/#{@tid}/agent/fast"}
                class="text-[10px] text-blue-600 hover:underline"
              >
                Configure
              </a>
              <span class="text-[10px] text-gray-300">|</span>
              <a
                href={"/admin/autoservice/tenants/#{@tid}/debug"}
                class="text-[10px] text-blue-600 hover:underline"
              >
                Debug
              </a>
            </div>
          </div>

          <%!-- Slow Agent --%>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 hover:shadow-md hover:border-purple-300 transition">
            <div class="flex items-center justify-between mb-2">
              <span class="text-base font-semibold">🧠 Slow Agent</span>
              <span class={live_badge_class(@initialized?)}>{live_badge_text(@initialized?)}</span>
            </div>
            <div class="text-xs text-gray-600 dark:text-zinc-400 space-y-1">
              <div>
                📄 Soul:
                <code class="bg-gray-100 dark:bg-zinc-800 px-1 rounded">souls/customer.md</code>
              </div>
              <div>
                📚 Skills: {@skills_count} · 🗄️ KB: {@kb_count} entries · 🏷️ Slots: {@slots_count}
              </div>
              <div>🔄 Sandbox: <span class="text-amber-600">{changes_label(@slow_changes)}</span></div>
            </div>
            <div class="flex gap-2 mt-3">
              <a
                href={"/admin/autoservice/tenants/#{@tid}/agent/slow"}
                class="text-[10px] text-blue-600 hover:underline"
              >
                Configure
              </a>
              <span class="text-[10px] text-gray-300">|</span>
              <a
                href={"/admin/autoservice/tenants/#{@tid}/debug"}
                class="text-[10px] text-blue-600 hover:underline"
              >
                Debug
              </a>
            </div>
          </div>
        </div>

        <%!-- Routeset flow (overview visualization) --%>
        <h2 class="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-3">Routeset</h2>
        <a
          href={"/admin/autoservice/tenants/#{@tid}/orchestrate"}
          class="block rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 mb-6 hover:shadow-md transition"
        >
          <div class="flex items-center justify-center gap-2 text-sm flex-wrap">
            <span class="bg-blue-100 text-blue-700 px-3 py-1.5 rounded-lg font-medium">
              💬 Customer
            </span>
            <span class="text-gray-300">→</span>
            <span class="bg-amber-100 text-amber-700 px-3 py-1.5 rounded-lg font-medium">⚡ Fast</span>
            <span class="text-gray-300">→</span>
            <span class="bg-purple-100 text-purple-700 px-3 py-1.5 rounded-lg font-medium">
              🧠 Slow
            </span>
            <span class="text-gray-300">→</span>
            <span class="bg-gray-100 text-gray-600 px-3 py-1.5 rounded-lg font-medium">
              👤 Operator
            </span>
          </div>
        </a>
      </div>
    """
  end

  # ---- Render helpers ----

  # Header subtitle: "<brand> · <industry> · v<N> published" (design vision),
  # degrading gracefully when fields are absent.
  defp tenant_subtitle(config, version) do
    brand = config && (config["brand_name"] || config["brand"])
    industry = config && config["industry"]

    [brand, industry, version_label(version)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> gettext("Tenant admin console")
      s -> s
    end
  end

  defp version_label(v) when is_binary(v) and v not in ["", "none", "n/a"], do: "v#{v} published"
  defp version_label(_), do: gettext("draft")

  # `live` badge — placeholder semantics for now: green when the tenant has a
  # published release, gray "draft" otherwise. (TODO: tie to real agent Kind
  # liveness once we read it on the overview.)
  defp live_badge_class(true),
    do: "text-[10px] bg-green-100 text-green-700 px-2 py-0.5 rounded-full"

  defp live_badge_class(_),
    do: "text-[10px] bg-gray-100 text-gray-600 px-2 py-0.5 rounded-full"

  defp live_badge_text(true), do: "live"
  defp live_badge_text(_), do: "draft"

  defp changes_label(0), do: "0 changes"
  defp changes_label(1), do: "1 file changed"
  defp changes_label(n) when is_integer(n), do: "#{n} files changed"
  defp changes_label(_), do: "0 changes"
end
