defmodule EzagentPluginLiveview.AutoService.Admin.Platform.PlatformSoulLive do
  @moduledoc """
  Platform Soul Editor — master admin page for editing L1 platform soul files.

  Accessible at `/admin/autoservice/platform/soul`. Uses `PlatformSoulStore`
  to read/write soul.md files at the platform level. Master admins can view
  and edit framework (L0), platform (L1), and template soul files.

  Tabs: Platform | Framework | Template
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Platform.PlatformSoulStore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Platform Soul 管理",
       tab: "platform",
       role: "customer",
       platform_soul: load_soul(:platform, "customer"),
       framework_soul: load_soul(:framework, "customer"),
       template_soul: load_soul(:template, "customer"),
       editing_content: nil,
       editing_level: nil,
       saved_flash: nil,
       view_mode: "view"
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab, view_mode: "view", saved_flash: nil)}
  end

  @impl true
  def handle_event("switch_role", %{"role" => role}, socket) do
    {:noreply,
     assign(socket,
       role: role,
       platform_soul: load_soul(:platform, role),
       framework_soul: load_soul(:framework, role),
       template_soul: load_soul(:template, role),
       view_mode: "view",
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("edit", %{"level" => level}, socket) do
    content = get_soul_for_level(socket.assigns, level)
    {:noreply, assign(socket, editing_content: content, editing_level: level, view_mode: "edit")}
  end

  @impl true
  def handle_event("update_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, editing_content: content)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    level = socket.assigns.editing_level
    role = socket.assigns.role
    content = socket.assigns.editing_content
    level_atom = String.to_existing_atom(level)

    case PlatformSoulStore.write_soul(level_atom, role, content) do
      :ok ->
        {:noreply,
         assign(socket,
           saved_flash: "#{level} soul (#{role}) 已保存",
           view_mode: "view",
           platform_soul: if(level == "platform", do: content, else: socket.assigns.platform_soul),
           framework_soul: if(level == "framework", do: content, else: socket.assigns.framework_soul),
           template_soul: if(level == "template", do: content, else: socket.assigns.template_soul)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, saved_flash: "保存失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_content: nil, editing_level: nil, view_mode: "view")}
  end

  @impl true
  def handle_event("delete", %{"level" => level}, socket) do
    role = socket.assigns.role
    level_atom = String.to_existing_atom(level)

    case PlatformSoulStore.delete_soul(level_atom, role) do
      :ok ->
        {:noreply,
         assign(socket,
           saved_flash: "#{level} soul (#{role}) 已删除",
           platform_soul: if(level == "platform", do: nil, else: socket.assigns.platform_soul),
           framework_soul: if(level == "framework", do: nil, else: socket.assigns.framework_soul),
           template_soul: if(level == "template", do: nil, else: socket.assigns.template_soul)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, saved_flash: "删除失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <nav class="w-48 flex-shrink-0 border-r border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 p-3 space-y-1 min-h-screen">
        <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Platform</div>
        <a href="/admin/autoservice" class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
          <span>📊</span> Dashboard
        </a>
        <a href="/admin/autoservice/platform/soul" class="flex items-center gap-2 px-2 py-1.5 rounded text-sm bg-gray-200 dark:bg-zinc-800 text-gray-900 dark:text-zinc-100 font-medium">
          <span>📝</span> Platform Soul
        </a>
        <a href="/admin/autoservice/platform/skills" class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
          <span>📚</span> Platform Skills
        </a>
      </nav>

      <main class="flex-1 p-6">
        <div class="max-w-5xl mx-auto">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">Platform Soul 管理</h1>
              <p class="text-sm text-gray-500 dark:text-zinc-400">编辑 L0/L1/L3 平台 Soul 文件</p>
            </div>
            <a
              href="/admin/autoservice"
              class="text-sm text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-300 underline"
            >
              &larr; Dashboard
            </a>
          </div>

          <%= if @saved_flash do %>
            <div class="text-sm text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-3 py-2 mb-4">
              {@saved_flash}
            </div>
          <% end %>

          <%!-- Role selector --%>
          <div class="flex gap-2 mb-4">
            <span class="text-xs text-gray-500 dark:text-zinc-400 self-center">Role:</span>
            <%= for role <- ~w(customer operator) do %>
              <button
                phx-click="switch_role"
                phx-value-role={role}
                class={[
                  "text-xs rounded px-2.5 py-1 border transition-colors",
                  @role == role && "bg-blue-600 text-white border-blue-600",
                  @role != role && "border-gray-300 dark:border-zinc-600 text-gray-700 dark:text-zinc-300 hover:bg-gray-100 dark:hover:bg-zinc-800"
                ]}
              >
                {role}
              </button>
            <% end %>
          </div>

          <%!-- Tab bar --%>
          <div class="flex gap-0.5 mb-0">
            <button
              phx-click="switch_tab"
              phx-value-tab="platform"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "platform" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "platform" && "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              L1 Platform
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="framework"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "framework" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "framework" && "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              L0 Framework
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="template"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "template" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "template" && "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              L3 Template
            </button>
          </div>

          <%!-- Content area --%>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
            <%= for {level, label, soul} <- [
              {"platform", "L1 Platform", @platform_soul},
              {"framework", "L0 Framework", @framework_soul},
              {"template", "L3 Template", @template_soul}
            ], level == @tab do %>
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
                <h3 class="font-semibold text-sm">{label} — {@role}</h3>
                <div class="flex gap-2">
                  <button
                    :if={@view_mode != "edit" or @editing_level != level}
                    phx-click="edit"
                    phx-value-level={level}
                    class="text-xs bg-white/20 hover:bg-white/30 text-white rounded px-2 py-1 transition-colors"
                  >
                    Edit
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-level={level}
                    class="text-xs bg-red-500/30 hover:bg-red-500/50 text-white rounded px-2 py-1 transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </div>

              <%= if @view_mode == "edit" and @editing_level == level do %>
                <div class="p-4 space-y-3">
                  <textarea
                    name="content"
                    phx-change="update_content"
                    rows="24"
                    class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-4 py-3 text-sm font-mono leading-relaxed focus:outline-none focus:ring-2 focus:ring-blue-400 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 resize-y"
                  ><%= @editing_content %></textarea>
                  <div class="flex gap-2">
                    <button
                      phx-click="save"
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 transition-colors"
                    >
                      Save
                    </button>
                    <button
                      phx-click="cancel_edit"
                      class="rounded border border-gray-300 dark:border-zinc-600 px-4 py-1.5 text-sm font-medium text-gray-700 dark:text-zinc-300 hover:bg-gray-100 dark:hover:bg-zinc-800 transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              <% else %>
                <%= if soul do %>
                  <div class="p-4">
                    <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap bg-gray-50 dark:bg-zinc-950 rounded-lg p-5 max-h-[60vh] overflow-y-auto border border-gray-200 dark:border-zinc-800 text-gray-900 dark:text-zinc-100"><%= soul %></pre>
                    <div class="text-xs text-gray-400 dark:text-zinc-500 mt-2">
                      {byte_size(soul)} bytes | {Enum.count(String.split(soul, "\n"))} lines
                    </div>
                  </div>
                <% else %>
                  <div class="p-8 text-center">
                    <p class="text-sm text-gray-400 dark:text-zinc-500">
                      No soul file for {label} / {@role}
                    </p>
                    <button
                      phx-click="edit"
                      phx-value-level={level}
                      class="mt-3 text-sm rounded border border-gray-300 dark:border-zinc-600 px-3 py-1.5 text-gray-700 dark:text-zinc-300 hover:bg-gray-100 dark:hover:bg-zinc-800 transition-colors"
                    >
                      Create
                    </button>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_soul(level, role) do
    case PlatformSoulStore.read_soul(level, role) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp get_soul_for_level(assigns, "platform"), do: assigns.platform_soul || ""
  defp get_soul_for_level(assigns, "framework"), do: assigns.framework_soul || ""
  defp get_soul_for_level(assigns, "template"), do: assigns.template_soul || ""
  defp get_soul_for_level(_, _), do: ""
end
