defmodule EzagentPluginLiveview.AutoService.Admin.Platform.PlatformSkillLive do
  @moduledoc """
  Platform Skill Manager — master admin page for L0/L1/L2 skill management.

  Accessible at `/admin/autoservice/platform/skills`. Uses `PlatformSkillStore`
  to list, read, write, and delete skill SKILL.md files across roles and layers.

  Layers: L0 (framework) | L1 (platform) | L2 (industry)
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Platform.PlatformSkillStore

  @impl true
  def mount(_params, _session, socket) do
    role = "customer"
    skills = list_skills(role)

    {:ok,
     assign(socket,
       page_title: "Platform Skill 管理",
       tab: "skills",
       role: role,
       skills: skills,
       viewing_skill: nil,
       viewing_content: nil,
       editing_skill: nil,
       editing_content: nil,
       new_skill_name: "",
       new_skill_body: "",
       creating_skill: false,
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab, saved_flash: nil)}
  end

  @impl true
  def handle_event("switch_role", %{"role" => role}, socket) do
    {:noreply,
     assign(socket,
       role: role,
       skills: list_skills(role),
       viewing_skill: nil,
       viewing_content: nil,
       editing_skill: nil,
       editing_content: nil,
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("view_skill", %{"name" => name}, socket) do
    role = socket.assigns.role

    content =
      case PlatformSkillStore.read_skill(role, name) do
        {:ok, c} -> c
        {:error, _} -> "(not found)"
      end

    {:noreply,
     assign(socket,
       viewing_skill: name,
       viewing_content: content,
       editing_skill: nil,
       editing_content: nil
     )}
  end

  @impl true
  def handle_event("edit_skill", %{"name" => name}, socket) do
    role = socket.assigns.role

    content =
      case PlatformSkillStore.read_skill(role, name) do
        {:ok, c} -> c
        {:error, _} -> ""
      end

    {:noreply,
     assign(socket,
       editing_skill: name,
       editing_content: content,
       viewing_skill: nil,
       viewing_content: nil
     )}
  end

  @impl true
  def handle_event("update_skill_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, editing_content: content)}
  end

  @impl true
  def handle_event("save_skill", _params, socket) do
    role = socket.assigns.role
    name = socket.assigns.editing_skill
    content = socket.assigns.editing_content

    case PlatformSkillStore.write_skill(role, name, content) do
      :ok ->
        {:noreply,
         assign(socket,
           saved_flash: "Skill #{name} 已保存",
           editing_skill: nil,
           editing_content: nil,
           skills: list_skills(role)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, saved_flash: "保存失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_skill: nil, editing_content: nil)}
  end

  @impl true
  def handle_event("delete_skill", %{"name" => name}, socket) do
    role = socket.assigns.role

    case PlatformSkillStore.delete_skill(role, name) do
      :ok ->
        {:noreply,
         assign(socket,
           saved_flash: "Skill #{name} 已删除",
           viewing_skill: nil,
           viewing_content: nil,
           skills: list_skills(role)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, saved_flash: "删除失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("new_skill", _params, socket) do
    {:noreply,
     assign(socket,
       creating_skill: true,
       new_skill_name: "",
       new_skill_body: "",
       viewing_skill: nil,
       editing_skill: nil
     )}
  end

  @impl true
  def handle_event("update_new_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, new_skill_name: name)}
  end

  @impl true
  def handle_event("update_new_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, new_skill_body: body)}
  end

  @impl true
  def handle_event("create_skill", _params, socket) do
    role = socket.assigns.role
    name = String.trim(socket.assigns.new_skill_name)
    body = socket.assigns.new_skill_body

    if name == "" do
      {:noreply, assign(socket, saved_flash: "Skill name is required")}
    else
      case PlatformSkillStore.write_skill(role, name, body) do
        :ok ->
          {:noreply,
           assign(socket,
             saved_flash: "Skill #{name} 已创建",
             creating_skill: false,
             new_skill_name: "",
             new_skill_body: "",
             skills: list_skills(role)
           )}

        {:error, reason} ->
          {:noreply, assign(socket, saved_flash: "创建失败: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply,
     assign(socket, creating_skill: false, new_skill_name: "", new_skill_body: "")}
  end

  @impl true
  def handle_event("close_view", _params, socket) do
    {:noreply, assign(socket, viewing_skill: nil, viewing_content: nil)}
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
        <a href="/admin/autoservice/platform/soul" class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
          <span>📝</span> Platform Soul
        </a>
        <a href="/admin/autoservice/platform/skills" class="flex items-center gap-2 px-2 py-1.5 rounded text-sm bg-gray-200 dark:bg-zinc-800 text-gray-900 dark:text-zinc-100 font-medium">
          <span>📚</span> Platform Skills
        </a>
      </nav>

      <main class="flex-1 p-6">
        <div class="max-w-5xl mx-auto">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">Platform Skill 管理</h1>
              <p class="text-sm text-gray-500 dark:text-zinc-400">
                L0/L1/L2 平台 Skill 管理 (Master Admin)
              </p>
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

          <%!-- Action bar --%>
          <div class="flex items-center justify-between mb-4">
            <span class="text-xs text-gray-500 dark:text-zinc-400">
              {length(@skills)} skill(s) for {@role}
            </span>
            <button
              phx-click="new_skill"
              class="rounded bg-blue-600 text-white px-3 py-1 text-xs font-medium hover:bg-blue-700 transition-colors"
            >
              + New Skill
            </button>
          </div>

          <%!-- Create Skill form --%>
          <%= if @creating_skill do %>
            <div class="rounded-xl border border-blue-300 dark:border-blue-700 bg-white dark:bg-zinc-900 p-4 mb-4 space-y-3">
              <h3 class="text-sm font-semibold text-gray-800 dark:text-zinc-200">Create New Skill</h3>
              <div>
                <label class="block text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">Name</label>
                <input
                  type="text"
                  name="name"
                  phx-change="update_new_name"
                  placeholder="my-skill"
                  class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">Content (SKILL.md)</label>
                <textarea
                  name="body"
                  phx-change="update_new_body"
                  rows="8"
                  placeholder="# Skill Name\n\n## Description\n..."
                  class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm font-mono bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 resize-y"
                ></textarea>
              </div>
              <div class="flex gap-2">
                <button
                  phx-click="create_skill"
                  class="rounded bg-green-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-green-700 transition-colors"
                >
                  Create
                </button>
                <button
                  phx-click="cancel_create"
                  class="rounded border border-gray-300 dark:border-zinc-600 px-4 py-1.5 text-sm font-medium text-gray-700 dark:text-zinc-300 hover:bg-gray-100 dark:hover:bg-zinc-800 transition-colors"
                >
                  Cancel
                </button>
              </div>
            </div>
          <% end %>

          <%!-- Edit Skill form --%>
          <%= if @editing_skill do %>
            <div class="rounded-xl border border-amber-300 dark:border-amber-700 bg-white dark:bg-zinc-900 p-4 mb-4 space-y-3">
              <h3 class="text-sm font-semibold text-gray-800 dark:text-zinc-200">
                Editing: {@editing_skill}
              </h3>
              <textarea
                name="content"
                phx-change="update_skill_content"
                rows="16"
                class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm font-mono bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-amber-400 resize-y"
              ><%= @editing_content %></textarea>
              <div class="flex gap-2">
                <button
                  phx-click="save_skill"
                  class="rounded bg-green-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-green-700 transition-colors"
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
          <% end %>

          <%!-- Skill list --%>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
              <h3 class="font-semibold text-sm">Skills — {@role}</h3>
            </div>

            <%= if @skills == [] do %>
              <div class="p-8 text-center">
                <p class="text-sm text-gray-400 dark:text-zinc-500">No skills found for {@role}</p>
                <p class="text-xs text-gray-300 dark:text-zinc-600 mt-1">
                  Create skills in priv/platform/skills/{@role}/&lt;name&gt;/SKILL.md
                </p>
              </div>
            <% else %>
              <table class="w-full text-sm">
                <thead class="bg-gray-50 dark:bg-zinc-950 border-b border-gray-200 dark:border-zinc-800">
                  <tr class="text-left text-xs uppercase tracking-wide text-gray-500 dark:text-zinc-400">
                    <th class="px-4 py-2">Name</th>
                    <th class="py-2">Role</th>
                    <th class="py-2">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={name <- @skills}
                    class="border-b border-gray-100 dark:border-zinc-800 last:border-0 hover:bg-gray-50 dark:hover:bg-zinc-900"
                  >
                    <td class="px-4 py-2 font-medium text-gray-800 dark:text-zinc-200 font-mono text-xs">
                      {name}
                    </td>
                    <td class="py-2">
                      <span class="text-xs bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400 rounded px-1.5 py-0.5">
                        {@role}
                      </span>
                    </td>
                    <td class="py-2 pr-4">
                      <div class="flex gap-2">
                        <button
                          phx-click="view_skill"
                          phx-value-name={name}
                          class="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-300"
                        >
                          View
                        </button>
                        <button
                          phx-click="edit_skill"
                          phx-value-name={name}
                          class="text-xs text-amber-600 dark:text-amber-400 hover:text-amber-800 dark:hover:text-amber-300"
                        >
                          Edit
                        </button>
                        <button
                          phx-click="delete_skill"
                          phx-value-name={name}
                          class="text-xs text-red-600 dark:text-red-400 hover:text-red-800 dark:hover:text-red-300"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>

          <%!-- View skill detail --%>
          <%= if @viewing_skill do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden mt-4">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
                <h3 class="font-semibold text-sm">{@viewing_skill}</h3>
                <button
                  phx-click="close_view"
                  class="text-xs bg-white/20 hover:bg-white/30 text-white rounded px-2 py-1 transition-colors"
                >
                  Close
                </button>
              </div>
              <div class="p-4">
                <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap bg-gray-50 dark:bg-zinc-950 rounded-lg p-5 max-h-[60vh] overflow-y-auto border border-gray-200 dark:border-zinc-800 text-gray-900 dark:text-zinc-100"><%= @viewing_content %></pre>
                <div class="text-xs text-gray-400 dark:text-zinc-500 mt-2">
                  {byte_size(@viewing_content)} bytes | {Enum.count(String.split(@viewing_content, "\n"))} lines
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp list_skills(role) do
    case PlatformSkillStore.list_skills(role) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end
end
