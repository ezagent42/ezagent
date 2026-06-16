defmodule EzagentPluginLiveview.AutoService.Admin.SkillManagerLive do
  @moduledoc """
  Skill Manager — 4-layer skill grid with search, view, edit, create, delete.

  Layers: L0 (framework) shadowed | L1 (platform) read-only | L2 (industry) read-only | L3 (tenant) editable
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Skill.{SkillLoader, SkillStore}
  alias EzagentPluginCr.CrEngine

  @role "customer"

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    base_dir = TenantRuntime.base_dir()

    layers = load_all_layers(base_dir, tid, @role)
    skill_meta = load_all_skill_meta(base_dir, tid, @role)

    {:ok,
     assign(socket,
       page_title: "Skill 管理",
       tid: tid,
       role: @role,
       layers: layers,
       skill_meta: skill_meta,
       search_query: "",
       filtered_layers: layers,
       editing_skill: nil,
       editing_meta: %{},
       editing_body: nil,
       editing_etag: nil,
       creating_skill: false,
       new_skill_name: "",
       new_skill_description: "",
       new_skill_intent_trigger: "",
       new_skill_body: "",
       saved_flash: nil
     )}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered =
      if query == "" do
        socket.assigns.layers
      else
        Enum.map(socket.assigns.layers, fn {layer, entries} ->
          matched =
            Enum.filter(entries, fn e ->
              String.contains?(String.downcase(e.name), String.downcase(query))
            end)

          {layer, matched}
        end)
      end

    {:noreply, assign(socket, search_query: query, filtered_layers: filtered)}
  end

  @impl true
  def handle_event("view_skill", %{"name" => name}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid

    {meta, body} =
      case SkillStore.read(base_dir, tid, @role, name) do
        {:ok, content} -> parse_skill_frontmatter(content)
        :not_found -> {%{}, "(not found)"}
      end

    {:noreply, assign(socket, editing_skill: name, editing_meta: meta, editing_body: body)}
  end

  @impl true
  def handle_event("edit_skill", %{"name" => name}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid

    {meta, body, raw_content} =
      case SkillStore.read(base_dir, tid, @role, name) do
        {:ok, content} ->
          {m, b} = parse_skill_frontmatter(content)
          {m, b, content}
        :not_found -> {%{}, "", ""}
      end

    etag = compute_etag(raw_content)

    {:noreply,
     assign(socket,
       editing_skill: name,
       editing_meta: meta,
       editing_body: body,
       editing_etag: etag
     )}
  end

  @impl true
  def handle_event("save_skill", %{"name" => name, "meta_description" => desc, "meta_intent_trigger" => trigger, "body" => body}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid

    # ETag concurrency check
    current_raw =
      case SkillStore.read(base_dir, tid, @role, name) do
        {:ok, content} -> content
        :not_found -> ""
      end

    if compute_etag(current_raw) != socket.assigns.editing_etag do
      {:noreply, assign(socket, saved_flash: "⚠️ 文件已被他人修改，请刷新后重试")}
    else
      meta =
        socket.assigns.editing_meta
        |> Map.put("description", desc)
        |> Map.put("intent_trigger", trigger)

      content = build_skill_content(meta, body)

      SkillStore.write(base_dir, tid, @role, name, content)
      CrEngine.record_file_change(tid, "skills/customer/#{name}/SKILL.md")

      layers = load_all_layers(base_dir, tid, @role)
      skill_meta = load_all_skill_meta(base_dir, tid, @role)
      filtered = apply_search(layers, socket.assigns.search_query)

      {:noreply,
       assign(socket,
         layers: layers,
         skill_meta: skill_meta,
         filtered_layers: filtered,
         editing_skill: nil,
         editing_meta: %{},
         editing_body: nil,
         editing_etag: nil,
         saved_flash: "技能 #{name} 已保存到 sandbox"
       )}
    end
  end

  @impl true
  def handle_event("delete_skill", %{"name" => name}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid

    SkillStore.delete(base_dir, tid, @role, name)

    layers = load_all_layers(base_dir, tid, @role)
    skill_meta = load_all_skill_meta(base_dir, tid, @role)
    filtered = apply_search(layers, socket.assigns.search_query)

    {:noreply,
     assign(socket,
       layers: layers,
       skill_meta: skill_meta,
       filtered_layers: filtered,
       editing_skill: nil,
       editing_meta: %{},
       editing_body: nil,
       saved_flash: "技能 #{name} 已删除"
     )}
  end

  @impl true
  def handle_event("create_skill", %{"name" => name, "meta_description" => desc, "meta_intent_trigger" => trigger, "body" => body}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid

    meta = %{"name" => name, "description" => desc, "intent_trigger" => trigger}
    content = build_skill_content(meta, body)

    SkillStore.write(base_dir, tid, @role, name, content)
    CrEngine.record_file_change(tid, "skills/customer/#{name}/SKILL.md")

    layers = load_all_layers(base_dir, tid, @role)
    skill_meta = load_all_skill_meta(base_dir, tid, @role)
    filtered = apply_search(layers, socket.assigns.search_query)

    {:noreply,
     assign(socket,
       layers: layers,
       skill_meta: skill_meta,
       filtered_layers: filtered,
       creating_skill: false,
       new_skill_name: "",
       new_skill_description: "",
       new_skill_intent_trigger: "",
       new_skill_body: "",
       saved_flash: "技能 #{name} 已创建"
     )}
  end

  @impl true
  def handle_event("show_create_form", _params, socket) do
    {:noreply, assign(socket, creating_skill: true)}
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply,
     assign(socket,
       creating_skill: false,
       new_skill_name: "",
       new_skill_description: "",
       new_skill_intent_trigger: "",
       new_skill_body: ""
     )}
  end

  @impl true
  def handle_event("close_editor", _params, socket) do
    {:noreply,
     assign(socket, editing_skill: nil, editing_meta: %{}, editing_body: nil, editing_etag: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">Skill 管理</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400">
            Tenant: {@tid} / Role: {@role}
          </p>
        </div>
        <a
          href={"/admin/autoservice/tenants/#{@tid}"}
          class="text-sm text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-300 underline"
        >
          &larr; 返回 Tenant Dashboard
        </a>
      </div>

      <%= if @saved_flash do %>
        <div class="text-sm text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-3 py-2 mb-4">
          {@saved_flash}
        </div>
      <% end %>

      <%!-- Search bar + Create button --%>
      <div class="flex items-center gap-3 mb-4">
        <div class="flex-1 relative">
          <input
            type="text"
            name="query"
            value={@search_query}
            phx-change="search"
            phx-debounce="200"
            placeholder="搜索技能名称..."
            class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 pl-9 pr-3 py-2 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
          />
          <svg
            class="absolute left-3 top-2.5 w-4 h-4 text-gray-400 dark:text-zinc-500"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
            />
          </svg>
        </div>
        <button
          phx-click="show_create_form"
          class="rounded bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700 transition-colors whitespace-nowrap"
        >
          + 新建技能
        </button>
      </div>

      <%!-- Create form --%>
      <%= if @creating_skill do %>
        <div class="rounded-xl border border-blue-300 dark:border-blue-700 bg-blue-50 dark:bg-blue-950 p-4 mb-4">
          <h3 class="text-sm font-semibold text-gray-800 dark:text-zinc-200 mb-3">新建技能</h3>
          <form phx-submit="create_skill" class="space-y-3">
            <div>
              <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">技能名称</label>
              <input
                type="text"
                name="name"
                value={@new_skill_name}
                required
                placeholder="例如: refund-policy"
                class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
              />
            </div>
            <div>
              <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Description</label>
              <input
                type="text"
                name="meta_description"
                value={@new_skill_description}
                placeholder="技能描述"
                class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
              />
            </div>
            <div>
              <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Intent Trigger</label>
              <input
                type="text"
                name="meta_intent_trigger"
                value={@new_skill_intent_trigger}
                placeholder="触发词，逗号分隔"
                class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
              />
            </div>
            <div>
              <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Body (Markdown)</label>
              <textarea
                name="body"
                rows="10"
                required
                placeholder="# Skill Name\n\nDescription..."
                class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm font-mono bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
              ><%= @new_skill_body %></textarea>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="cancel_create"
                class="rounded border border-gray-300 dark:border-zinc-700 text-gray-700 dark:text-zinc-300 px-4 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-zinc-800"
              >
                取消
              </button>
              <button
                type="submit"
                class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
              >
                创建
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <%!-- Editor panel --%>
      <%= if @editing_skill do %>
        <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden mb-4">
          <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
            <h3 class="font-semibold text-sm">
              {@editing_skill}
              <span class="text-gray-400 dark:text-zinc-500 font-normal text-xs ml-2">SKILL.md</span>
            </h3>
            <button
              phx-click="close_editor"
              class="text-gray-300 dark:text-zinc-400 hover:text-white text-sm"
            >
              &times; 关闭
            </button>
          </div>
          <div class="p-4">
            <%= if skill_on_tenant_layer?(@layers, @editing_skill) do %>
              <form phx-submit="save_skill" class="space-y-3">
                <input type="hidden" name="name" value={@editing_skill} />
                <div>
                  <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Description</label>
                  <input
                    type="text"
                    name="meta_description"
                    value={@editing_meta["description"]}
                    class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                  />
                </div>
                <div>
                  <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Intent Trigger</label>
                  <input
                    type="text"
                    name="meta_intent_trigger"
                    value={@editing_meta["intent_trigger"]}
                    class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                  />
                </div>
                <div>
                  <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">Body (Markdown)</label>
                  <textarea
                    name="body"
                    rows="14"
                    class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-4 py-3 text-sm font-mono leading-relaxed bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 resize-y"
                  ><%= @editing_body %></textarea>
                </div>
                <div class="flex justify-between">
                  <button
                    type="button"
                    phx-click="delete_skill"
                    phx-value-name={@editing_skill}
                    class="rounded border border-red-300 dark:border-red-800 text-red-600 dark:text-red-400 px-3 py-1.5 text-sm hover:bg-red-50 dark:hover:bg-red-950"
                    onclick={"return confirm('确定要删除技能 #{@editing_skill} 吗？')"}
                  >
                    删除
                  </button>
                  <button
                    type="submit"
                    class="rounded bg-blue-600 text-white px-5 py-1.5 text-sm font-medium hover:bg-blue-700"
                  >
                    保存
                  </button>
                </div>
              </form>
            <% else %>
              <div class="space-y-3 mb-4">
                <%= if @editing_meta["description"] not in [nil, ""] do %>
                  <div>
                    <span class="text-xs font-medium text-gray-500 dark:text-zinc-400">Description:</span>
                    <p class="text-sm text-gray-900 dark:text-zinc-100"><%= @editing_meta["description"] %></p>
                  </div>
                <% end %>
                <%= if @editing_meta["intent_trigger"] not in [nil, ""] do %>
                  <div>
                    <span class="text-xs font-medium text-gray-500 dark:text-zinc-400">Intent Trigger:</span>
                    <p class="text-sm text-gray-900 dark:text-zinc-100"><%= @editing_meta["intent_trigger"] %></p>
                  </div>
                <% end %>
              </div>
              <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap bg-gray-50 dark:bg-zinc-950 rounded-lg p-5 max-h-[60vh] overflow-y-auto border border-gray-200 dark:border-zinc-800 text-gray-900 dark:text-zinc-100"><%= @editing_body %></pre>
              <p class="text-xs text-gray-400 dark:text-zinc-500 mt-2">只读 — 该技能属于上层 layer，无法在此编辑</p>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- 4-layer card grid --%>
      <div class="space-y-6">
        <%= for {layer, entries} <- @filtered_layers do %>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
              <div class="flex items-center gap-2">
                <h3 class="font-semibold text-sm">{layer_label(layer)}</h3>
                <span class="text-[10px] bg-gray-600 dark:bg-zinc-600 px-1.5 py-0.5 rounded">L{layer_num(layer)}</span>
                <span class="text-xs text-gray-400 dark:text-zinc-500">{length(entries)} skills</span>
              </div>
            </div>
            <div class="p-4">
              <%= if entries == [] do %>
                <p class="text-xs text-gray-400 dark:text-zinc-500 text-center py-4">暂无技能</p>
              <% else %>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                  <%= for entry <- entries do %>
                    <div
                      phx-click={if layer == :tenant, do: "edit_skill", else: "view_skill"}
                      phx-value-name={entry.name}
                    >
                      <EzagentPluginLiveview.AutoService.Admin.Components.SkillCard.skill_card
                        name={entry.name}
                        layer={card_layer(layer)}
                        description={get_in(@skill_meta, [entry.name, :description]) || ""}
                        safety_class={get_in(@skill_meta, [entry.name, :safety_class]) || "safe"}
                        shadowed={shadowed?(entry, layer, @filtered_layers)}
                        editable={layer == :tenant}
                      />
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Legend --%>
      <div
        :if={all_entries_count(@filtered_layers) > 0}
        class="mt-4 flex items-center gap-4 text-xs text-gray-400 dark:text-zinc-500"
      >
        <span class="flex items-center gap-1">
          <span class="w-3 h-3 rounded bg-gray-50 dark:bg-zinc-950 border border-gray-200 dark:border-zinc-800 inline-block"></span>
          overridden (被上层同名覆盖)
        </span>
        <span class="flex items-center gap-1">
          <span class="w-3 h-3 rounded border border-blue-300 dark:border-blue-700 inline-block"></span> 可编辑 (tenant layer)
        </span>
      </div>
        </div>
      </main>
    </div>
    """
  end

  # -- Private helpers --

  defp compute_etag(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp load_all_layers(base_dir, tid, role) do
    [
      framework: SkillLoader.list(base_dir, tid, role, :framework),
      platform: SkillLoader.list(base_dir, tid, role, :platform),
      industry: SkillLoader.list(base_dir, tid, role, :industry),
      tenant: SkillLoader.list(base_dir, tid, role, :tenant)
    ]
  end

  defp load_all_skill_meta(base_dir, tid, role) do
    all_entries =
      SkillLoader.list(base_dir, tid, role, :framework) ++
        SkillLoader.list(base_dir, tid, role, :platform) ++
        SkillLoader.list(base_dir, tid, role, :industry) ++
        SkillLoader.list(base_dir, tid, role, :tenant)

    Map.new(all_entries, fn entry ->
      content =
        case File.read(entry.path) do
          {:ok, c} -> c
          _ -> ""
        end

      {meta, _body} = parse_skill_frontmatter(content)

      {entry.name,
       %{
         description: Map.get(meta, "description", ""),
         safety_class: Map.get(meta, "safety_class", "safe"),
         intent_trigger: Map.get(meta, "intent_trigger", "")
       }}
    end)
  end

  defp parse_skill_frontmatter(content) do
    case String.split(content, "---\n", parts: 3) do
      [_, fm, body] ->
        case YamlElixir.read_from_string(fm) do
          {:ok, meta} -> {meta, String.trim(body)}
          _ -> {%{}, content}
        end
      _ -> {%{}, content}
    end
  end

  defp build_skill_content(meta, body) when is_map(meta) do
    meta_str =
      meta
      |> Enum.reject(fn {_k, v} -> is_nil(v) || v == "" end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")

    if meta_str == "" do
      body
    else
      "---\n#{meta_str}\n---\n#{body}"
    end
  end

  defp apply_search(layers, ""), do: layers

  defp apply_search(layers, query) do
    Enum.map(layers, fn {layer, entries} ->
      matched =
        Enum.filter(entries, fn e ->
          String.contains?(String.downcase(e.name), String.downcase(query))
        end)

      {layer, matched}
    end)
  end

  defp layer_label(:framework), do: "L0 Framework"
  defp layer_label(:platform), do: "L1 Platform"
  defp layer_label(:industry), do: "L2 Industry"
  defp layer_label(:tenant), do: "L3 Tenant (sandbox)"

  defp layer_num(:framework), do: "0"
  defp layer_num(:platform), do: "1"
  defp layer_num(:industry), do: "2"
  defp layer_num(:tenant), do: "3"

  defp card_layer(:framework), do: :l0
  defp card_layer(:platform), do: :l1
  defp card_layer(:industry), do: :l2
  defp card_layer(:tenant), do: :l3

  # A skill is shadowed if a higher-layer entry with the same name exists
  defp shadowed?(entry, layer, layers) do
    name = entry.name

    Enum.any?(layers, fn {l, entries} ->
      layer_order(l) > layer_order(layer) and Enum.any?(entries, &(&1.name == name))
    end)
  end

  defp layer_order(:framework), do: 0
  defp layer_order(:platform), do: 1
  defp layer_order(:industry), do: 2
  defp layer_order(:tenant), do: 3

  defp skill_on_tenant_layer?(layers, name) do
    Enum.any?(layers, fn
      {:tenant, entries} -> Enum.any?(entries, &(&1.name == name))
      _ -> false
    end)
  end

  defp all_entries_count(layers) do
    Enum.reduce(layers, 0, fn {_layer, entries}, acc -> acc + length(entries) end)
  end
end
