defmodule EzagentPluginLiveview.AutoService.Admin.SandboxPreviewLive do
  @moduledoc """
  Sandbox Preview — standalone full CLAUDE.md preview page.

  Renders the complete CLAUDE.md (preamble + soul + skill_index) for a
  tenant's customer role. Accessible at `/admin/autoservice/tenants/:tid/preview`.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer}
  alias EzagentPluginContent.Skill.SkillIndexer

  @role "customer"

  @impl true
  def mount(_params, %{"tid" => tid}, socket) do
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    base_dir = TenantRuntime.base_dir()

    templates = SoulLoader.load(priv_dir, tid, @role)

    # Read sandbox soul content
    sandbox_soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
    _sandbox_soul = read_file(sandbox_soul_path)

    # Read slot values from YAML
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    slot_values = read_yaml(slots_path)

    # Build skill index for preview
    skill_index = SkillIndexer.build(base_dir, tid, @role)

    # Full CLAUDE.md preview
    preview = SoulRenderer.full_claude_md(templates, slot_values, skill_index)
    preview_empty? = is_nil(preview) or preview == ""

    {:ok,
     assign(socket,
       page_title: "CLAUDE.md Preview",
       tid: tid,
       role: @role,
       preview: preview,
       preview_empty?: preview_empty?,
       line_count: if(preview_empty?, do: 0, else: Enum.count(String.split(preview, "\n"))),
       byte_size: if(preview_empty?, do: 0, else: byte_size(preview))
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    tid = socket.assigns.tid
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    base_dir = TenantRuntime.base_dir()

    templates = SoulLoader.load(priv_dir, tid, @role)
    sandbox_soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
    _sandbox_soul = read_file(sandbox_soul_path)
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    slot_values = read_yaml(slots_path)
    skill_index = SkillIndexer.build(base_dir, tid, @role)

    preview = SoulRenderer.full_claude_md(templates, slot_values, skill_index)
    preview_empty? = is_nil(preview) or preview == ""

    {:noreply,
     assign(socket,
       preview: preview,
       preview_empty?: preview_empty?,
       line_count: if(preview_empty?, do: 0, else: Enum.count(String.split(preview, "\n"))),
       byte_size: if(preview_empty?, do: 0, else: byte_size(preview))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="max-w-5xl mx-auto">
        <div class="flex items-center justify-between mb-4">
          <div>
            <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">CLAUDE.md Preview</h1>
            <p class="text-sm text-gray-500 dark:text-zinc-400">
              Tenant: {@tid} / Role: {@role}
            </p>
          </div>
          <div class="flex items-center gap-3">
            <button
              phx-click="refresh"
              class="text-sm rounded border border-gray-300 dark:border-zinc-600 px-3 py-1.5 text-gray-700 dark:text-zinc-300 hover:bg-gray-100 dark:hover:bg-zinc-800 transition-colors"
            >
              Refresh
            </button>
          </div>
        </div>

        <%= if @preview_empty? do %>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-8 text-center">
            <p class="text-sm text-gray-400 dark:text-zinc-500">
              Preview is empty &mdash; no templates or content loaded.
            </p>
            <p class="text-xs text-gray-300 dark:text-zinc-600 mt-2">
              Initialize this tenant via the Init Wizard or edit the soul to populate content.
            </p>
          </div>
        <% else %>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
              <h3 class="font-semibold text-sm">Full CLAUDE.md</h3>
              <span class="text-xs text-gray-300 dark:text-zinc-400 font-mono">
                {@line_count} lines / {@byte_size} bytes
              </span>
            </div>
            <div class="p-4">
              <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap bg-gray-50 dark:bg-zinc-950 rounded-lg p-5 max-h-[80vh] overflow-y-auto border border-gray-200 dark:border-zinc-800 text-gray-900 dark:text-zinc-100"><%= @preview %></pre>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_file(path) do
    if File.exists?(path), do: File.read!(path), else: nil
  end

  defp read_yaml(path) do
    if File.exists?(path) do
      case path |> File.read!() |> YamlElixir.read_from_string() do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    else
      %{}
    end
  end
end
