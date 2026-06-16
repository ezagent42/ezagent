defmodule EzagentPluginLiveview.AutoService.Admin.SoulEditorLive do
  @moduledoc """
  Soul Editor — edit customer soul templates with slot-aware editor,
  diff view against release, full CLAUDE.md preview, and AI Assist placeholder.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer, SoulSlotParser}
  alias EzagentPluginContent.Skill.SkillIndexer
  alias EzagentPluginContent.DiffEngine
  alias EzagentPluginCr.CrEngine

  @role "customer"

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    base_dir = TenantRuntime.base_dir()

    templates = SoulLoader.load(priv_dir, tid, @role)

    # Read sandbox soul content
    sandbox_soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
    sandbox_soul = read_file(sandbox_soul_path)

    # Read release soul content (for diff)
    release_soul_path = Path.join([TenantRuntime.current_release_path(tid), "souls", "#{@role}.md"])
    release_soul = read_file(release_soul_path)

    # Read slot values from YAML
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    slot_values = read_yaml(slots_path)

    # Current editable content: sandbox file or fallback to rendered templates
    soul_content = sandbox_soul || SoulRenderer.render(templates, slot_values)

    # Diff against release
    diff = DiffEngine.diff(release_soul, soul_content)

    # Parse slot keys from current content
    slot_sections = SoulSlotParser.parse_slots(soul_content)

    # Build skill index for preview
    skill_index = SkillIndexer.build(base_dir, tid, @role)

    # Full CLAUDE.md preview
    preview = SoulRenderer.full_claude_md(templates, slot_values, skill_index)

    {:ok,
     assign(socket,
       page_title: "Soul 编辑",
       tid: tid,
       role: @role,
       tab: "source",
       templates: templates,
       soul_content: soul_content,
       release_soul: release_soul,
       slot_sections: slot_sections,
       slot_values: slot_values,
       skill_index: skill_index,
       preview: preview,
       diff: diff,
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("update_content", %{"soul_content" => content}, socket) do
    slot_sections = SoulSlotParser.parse_slots(content)
    diff = DiffEngine.diff(socket.assigns.release_soul, content)

    {:noreply,
     assign(socket,
       soul_content: content,
       slot_sections: slot_sections,
       diff: diff,
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("save_soul", _params, socket) do
    tid = socket.assigns.tid
    sandbox_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])

    File.mkdir_p!(Path.dirname(sandbox_path))
    File.write!(sandbox_path, socket.assigns.soul_content)

    CrEngine.ensure_active_cr(tid)

    {:noreply, assign(socket, saved_flash: "Soul 已保存到 sandbox")}
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "保存失败: #{Exception.message(e)}")}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  @impl true
  def handle_event("insert_slot", %{"key" => key}, socket) do
    template = "{{#{key}}}"
    new_content = socket.assigns.soul_content <> template
    slot_sections = SoulSlotParser.parse_slots(new_content)
    diff = DiffEngine.diff(socket.assigns.release_soul, new_content)

    {:noreply,
     assign(socket,
       soul_content: new_content,
       slot_sections: slot_sections,
       diff: diff,
       saved_flash: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-gray-900">Soul 编辑</h1>
          <p class="text-sm text-gray-500">
            Tenant: <%= @tid %> / Role: <%= @role %>
          </p>
        </div>
        <a
          href={"/admin/autoservice/tenants/#{@tid}"}
          class="text-sm text-gray-500 hover:text-gray-700 underline"
        >
          &larr; 返回 Tenant Dashboard
        </a>
      </div>

      <%= if @saved_flash do %>
        <div class="text-sm text-green-700 bg-green-50 rounded px-3 py-2 mb-4">
          <%= @saved_flash %>
        </div>
      <% end %>

      <%!-- Tab bar --%>
      <div class="flex gap-0.5 mb-0">
        <button
          phx-click="switch_tab" phx-value-tab="source"
          class={[
            "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
            @tab == "source" && "bg-gray-800 text-white",
            @tab != "source" && "bg-gray-100 text-gray-600 hover:bg-gray-200"
          ]}
        >
          Source
        </button>
        <button
          phx-click="switch_tab" phx-value-tab="diff"
          class={[
            "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
            @tab == "diff" && "bg-gray-800 text-white",
            @tab != "diff" && "bg-gray-100 text-gray-600 hover:bg-gray-200"
          ]}
        >
          Diff
        </button>
        <button
          phx-click="switch_tab" phx-value-tab="preview"
          class={[
            "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
            @tab == "preview" && "bg-gray-800 text-white",
            @tab != "preview" && "bg-gray-100 text-gray-600 hover:bg-gray-200"
          ]}
        >
          Preview
        </button>
        <button
          phx-click="switch_tab" phx-value-tab="ai_assist"
          class={[
            "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
            @tab == "ai_assist" && "bg-gray-800 text-white",
            @tab != "ai_assist" && "bg-gray-100 text-gray-600 hover:bg-gray-200"
          ]}
        >
          AI Assist
        </button>
      </div>

      <%!-- Tab: Source --%>
      <%= if @tab == "source" do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden rounded-tl-none">
          <%!-- Layer info bar --%>
          <div class="px-4 py-2 bg-gray-50 border-b border-gray-200 flex items-center gap-3">
            <span class="text-xs text-gray-500">Layers:</span>
            <span class="text-xs font-medium text-gray-700">
              <%= length(@templates) %> template(s) loaded (L0&ndash;L3 + tenant override)
            </span>
            <span :if={@templates == []} class="text-xs text-amber-600 font-medium">
              No templates found &mdash; sandbox only
            </span>
          </div>

          <%!-- Slot tags bar --%>
          <div :if={@slot_sections != []} class="px-4 py-2 bg-gray-50 border-b border-gray-200">
            <div class="flex flex-wrap gap-1.5 items-center">
              <span class="text-xs text-gray-500 mr-1">Slots:</span>
              <%= for section <- @slot_sections do %>
                <%= for key <- section.keys do %>
                  <button
                    phx-click="insert_slot"
                    phx-value-key={key}
                    class="text-xs bg-blue-50 text-blue-700 rounded px-1.5 py-0.5 hover:bg-blue-100 border border-blue-200 cursor-pointer transition-colors"
                    title={"Click to insert slot: #{key}"}
                  >
                    &lbrace;&lbrace;<%= key %>&rbrace;&rbrace;
                  </button>
                <% end %>
              <% end %>
            </div>
          </div>

          <%!-- Textarea editor --%>
          <div class="p-4">
            <textarea
              name="soul_content"
              phx-change="update_content"
              phx-debounce="300"
              rows="28"
              class="w-full rounded-lg border border-gray-300 px-4 py-3 text-sm font-mono leading-relaxed focus:outline-none focus:ring-2 focus:ring-blue-400 resize-y"
            ><%= @soul_content %></textarea>
          </div>

          <%!-- Save bar --%>
          <div class="px-4 py-3 bg-gray-50 border-t border-gray-200 flex items-center justify-between">
            <span class="text-xs text-gray-400 font-mono">
              sandbox/souls/<%= @role %>.md
            </span>
            <button
              phx-click="save_soul"
              class="rounded bg-blue-600 text-white px-5 py-1.5 text-sm font-medium hover:bg-blue-700 transition-colors"
            >
              保存
            </button>
          </div>
        </div>
      <% end %>

      <%!-- Tab: Diff --%>
      <%= if @tab == "diff" do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden rounded-tl-none">
          <div class="px-4 py-2.5 bg-gray-800 text-white">
            <h3 class="font-semibold text-sm">Sandbox vs Release</h3>
          </div>
          <EzagentPluginLiveview.AutoService.Admin.Components.SoulDiffView.soul_diff_view diff={@diff} />
          <div :if={@diff.added == [] and @diff.removed == []} class="px-4 py-8 text-center">
            <p class="text-sm text-gray-400">No differences between sandbox and release</p>
          </div>
        </div>
      <% end %>

      <%!-- Tab: Preview --%>
      <%= if @tab == "preview" do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden rounded-tl-none">
          <div class="px-4 py-2.5 bg-gray-800 text-white">
            <h3 class="font-semibold text-sm">Full CLAUDE.md Preview</h3>
          </div>
          <div class="p-4">
            <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap bg-gray-50 rounded-lg p-5 max-h-[70vh] overflow-y-auto border border-gray-200"><%= @preview %></pre>
          </div>
          <div :if={@preview == ""} class="px-4 py-8 text-center">
            <p class="text-sm text-gray-400">Preview is empty &mdash; no templates or content loaded</p>
          </div>
        </div>
      <% end %>

      <%!-- Tab: AI Assist --%>
      <%= if @tab == "ai_assist" do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden rounded-tl-none">
          <div class="px-4 py-2.5 bg-gray-800 text-white">
            <h3 class="font-semibold text-sm">AI Assist</h3>
          </div>
          <div class="p-8 text-center">
            <p class="text-sm text-gray-400">AI Assist 功能即将推出</p>
            <p class="text-xs text-gray-300 mt-1">使用 AI 辅助编写和优化 Soul 内容</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

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
