defmodule EzagentPluginLiveview.AutoService.Admin.SlotEditorLive do
  @moduledoc """
  Slot Editor — edit tenant slot values with key-value form editor,
  YAML raw editor toggle, and diff view against the current release.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.SoulSlotParser
  alias EzagentPluginContent.DiffEngine
  alias EzagentPluginCr.CrEngine

  @role "customer"

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    # Read sandbox slot values
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    slot_values = read_yaml(slots_path)

    # Read soul content and parse slot keys
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
    soul_content = read_file(soul_path) || ""
    slot_sections = SoulSlotParser.parse_slots(soul_content)
    all_keys = Enum.flat_map(slot_sections, & &1.keys) |> Enum.uniq()

    # Read release slot values for diff
    release_slots_path =
      Path.join([TenantRuntime.current_release_path(tid), "slots", "#{@role}.yaml"])

    release_values = read_yaml(release_slots_path)
    release_values = if release_values == %{}, do: nil, else: release_values

    # Compute diff
    release_content = if release_values, do: inspect(release_values, pretty: true), else: ""
    sandbox_content = inspect(slot_values, pretty: true)
    diff = DiffEngine.diff(release_content, sandbox_content)

    # ETag for concurrency control (raw file content)
    etag_content = read_file(slots_path) || ""
    etag = compute_etag(etag_content)

    {:ok,
     assign(socket,
       page_title: "Slot Editor",
       tid: tid,
       role: @role,
       slot_values: slot_values,
       all_keys: all_keys,
       slot_sections: slot_sections,
       release_values: release_values,
       diff: diff,
       show_yaml: false,
       yaml_content: sandbox_content,
       saved_flash: nil,
       etag: etag
     )}
  end

  @impl true
  def handle_event("save_slot", %{"key" => key, "value" => value}, socket) do
    tid = socket.assigns.tid

    case etag_guard(socket, tid) do
      {:conflict, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        new_values = Map.put(socket.assigns.slot_values, key, value)

        write_slots_file(tid, new_values)
        CrEngine.record_file_change(tid, "slots/customer.yaml")

        diff = recompute_diff(socket.assigns.release_values, new_values)
        new_etag = compute_etag(YamlElixir.write!(new_values))

        {:noreply,
         assign(socket,
           slot_values: new_values,
           yaml_content: inspect(new_values, pretty: true),
           diff: diff,
           saved_flash: "#{key} 已保存",
           etag: new_etag
         )}
    end
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "保存失败: #{Exception.message(e)}")}
  end

  @impl true
  def handle_event("add_slot", %{"key" => key, "value" => value}, socket) do
    tid = socket.assigns.tid

    cond do
      key == "" ->
        {:noreply, put_flash(socket, :error, "Slot key 不能为空")}

      Map.has_key?(socket.assigns.slot_values, key) ->
        {:noreply, put_flash(socket, :error, "Slot key '#{key}' 已存在")}

      true ->
        case etag_guard(socket, tid) do
          {:conflict, socket} ->
            {:noreply, socket}

          {:ok, socket} ->
            # Soft validation: check if slot key exists in soul template
            soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
            soul_content = read_file(soul_path) || ""
            template_slots = extract_template_slots(soul_content)

            warn_flash =
              if template_slots != [] and key not in template_slots do
                "⚠️ 槽位 '#{key}' 未在 Soul 模板中声明 ({{#{key}}})，已保存但可能无效"
              end

            new_values = Map.put(socket.assigns.slot_values, key, value)
            write_slots_file(tid, new_values)
            all_keys = Enum.uniq([key | socket.assigns.all_keys])
            CrEngine.record_file_change(tid, "slots/customer.yaml")

            diff = recompute_diff(socket.assigns.release_values, new_values)
            new_etag = compute_etag(YamlElixir.write!(new_values))

            flash_msg = warn_flash || "#{key} 已添加"

            {:noreply,
             assign(socket,
               slot_values: new_values,
               all_keys: all_keys,
               yaml_content: inspect(new_values, pretty: true),
               diff: diff,
               saved_flash: flash_msg,
               etag: new_etag
             )}
        end
    end
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "添加失败: #{Exception.message(e)}")}
  end

  @impl true
  def handle_event("delete_slot", %{"key" => key}, socket) do
    tid = socket.assigns.tid

    case etag_guard(socket, tid) do
      {:conflict, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        new_values = Map.delete(socket.assigns.slot_values, key)
        write_slots_file(tid, new_values)
        all_keys = List.delete(socket.assigns.all_keys, key)
        CrEngine.record_file_change(tid, "slots/customer.yaml")

        diff = recompute_diff(socket.assigns.release_values, new_values)
        new_etag = compute_etag(YamlElixir.write!(new_values))

        {:noreply,
         assign(socket,
           slot_values: new_values,
           all_keys: all_keys,
           yaml_content: inspect(new_values, pretty: true),
           diff: diff,
           saved_flash: "#{key} 已删除",
           etag: new_etag
         )}
    end
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "删除失败: #{Exception.message(e)}")}
  end

  @impl true
  def handle_event("toggle_yaml", _params, socket) do
    new_show_yaml = !socket.assigns.show_yaml
    yaml_content = YamlElixir.write!(socket.assigns.slot_values)

    {:noreply, assign(socket, show_yaml: new_show_yaml, yaml_content: yaml_content)}
  end

  @impl true
  def handle_event("update_yaml", %{"yaml_content" => content}, socket) do
    {:noreply, assign(socket, yaml_content: content)}
  end

  @impl true
  def handle_event("save_all_yaml", _params, socket) do
    tid = socket.assigns.tid

    case etag_guard(socket, tid) do
      {:conflict, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case YamlElixir.read_from_string(socket.assigns.yaml_content) do
          {:ok, new_values} when is_map(new_values) ->
            write_slots_file(tid, new_values)
            # Re-derive keys from soul content
            soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{@role}.md"])
            soul_content = read_file(soul_path) || ""
            slot_sections = SoulSlotParser.parse_slots(soul_content)
            all_keys = Enum.flat_map(slot_sections, & &1.keys) |> Enum.uniq()

            # Also include keys only in YAML but not in soul
            yaml_keys = Map.keys(new_values)
            all_keys = Enum.uniq(all_keys ++ yaml_keys)

            diff = recompute_diff(socket.assigns.release_values, new_values)
            CrEngine.record_file_change(tid, "slots/customer.yaml")
            new_etag = compute_etag(YamlElixir.write!(new_values))

            {:noreply,
             assign(socket,
               slot_values: new_values,
               all_keys: all_keys,
               slot_sections: slot_sections,
               diff: diff,
               saved_flash: "全部 slot 已保存",
               etag: new_etag
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "YAML 解析失败: #{reason}")}

          _ ->
            {:noreply, put_flash(socket, :error, "YAML 内容必须是一个 map")}
        end
    end
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "保存失败: #{Exception.message(e)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-5xl mx-auto">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">Slot Editor</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400">
            Tenant: <%= @tid %> / Role: <%= @role %>
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
          <%= @saved_flash %>
        </div>
      <% end %>

      <%!-- Key-Value Grid Editor --%>
      <div :if={!@show_yaml} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden mb-6">
        <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
          <h3 class="font-semibold text-sm">Slot 键值编辑</h3>
          <button
            phx-click="toggle_yaml"
            class="text-xs bg-gray-700 dark:bg-zinc-700 hover:bg-gray-600 dark:hover:bg-zinc-600 text-gray-200 dark:text-zinc-200 rounded px-2.5 py-1 transition-colors"
          >
            切换为 YAML 编辑
          </button>
        </div>

        <div class="p-4">
          <%= if @all_keys == [] do %>
            <p class="text-sm text-gray-400 dark:text-zinc-500 text-center py-8">
              暂无 slot 键 — 请在 Soul 中定义 slot 或通过下方表单添加
            </p>
          <% else %>
            <div class="grid grid-cols-2 gap-3">
              <%= for key <- @all_keys do %>
                <div class="flex items-start gap-2 p-3 rounded-lg border border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 group hover:border-blue-300 dark:hover:border-blue-700 transition-colors">
                  <div class="flex-1 min-w-0">
                    <label class="block text-xs font-medium text-gray-600 dark:text-zinc-400 mb-1 truncate" title={key}>
                      <%= key %>
                    </label>
                    <form
                      phx-submit="save_slot"
                      phx-change="noop"
                      class="flex gap-1.5"
                    >
                      <input type="hidden" name="key" value={key} />
                      <input
                        type="text"
                        name="value"
                        value={Map.get(@slot_values, key, "")}
                        class="flex-1 min-w-0 rounded border border-gray-300 dark:border-zinc-700 px-2.5 py-1 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent"
                      />
                      <button
                        type="submit"
                        class="rounded bg-blue-600 text-white px-3 py-1 text-xs font-medium hover:bg-blue-700 transition-colors shrink-0"
                      >
                        保存
                      </button>
                    </form>
                  </div>
                  <button
                    phx-click="delete_slot"
                    phx-value-key={key}
                    class="mt-5 text-gray-400 dark:text-zinc-500 hover:text-red-500 transition-colors shrink-0"
                    title={"删除 #{key}"}
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Add new slot form --%>
        <div class="px-4 py-3 bg-gray-50 dark:bg-zinc-950 border-t border-gray-200 dark:border-zinc-800">
          <h4 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">新增 Slot</h4>
          <form phx-submit="add_slot" class="flex gap-2">
            <input
              type="text"
              name="key"
              placeholder="key 名称"
              class="flex-1 rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent"
            />
            <input
              type="text"
              name="value"
              placeholder="value 值"
              class="flex-1 rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent"
            />
            <button
              type="submit"
              class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 transition-colors"
            >
              添加
            </button>
          </form>
        </div>
      </div>

      <%!-- YAML Raw Editor --%>
      <div :if={@show_yaml} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden mb-6">
        <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white flex items-center justify-between">
          <h3 class="font-semibold text-sm">YAML 编辑</h3>
          <button
            phx-click="toggle_yaml"
            class="text-xs bg-gray-700 dark:bg-zinc-700 hover:bg-gray-600 dark:hover:bg-zinc-600 text-gray-200 dark:text-zinc-200 rounded px-2.5 py-1 transition-colors"
          >
            切换为表单编辑
          </button>
        </div>

        <div class="p-4">
          <textarea
            name="yaml_content"
            phx-change="update_yaml"
            phx-debounce="300"
            rows="24"
            class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-4 py-3 text-sm font-mono leading-relaxed bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 resize-y"
          ><%= @yaml_content %></textarea>
        </div>

        <div class="px-4 py-3 bg-gray-50 dark:bg-zinc-950 border-t border-gray-200 dark:border-zinc-800 flex items-center justify-between">
          <span class="text-xs text-gray-400 dark:text-zinc-500 font-mono">
            sandbox/slots/<%= @role %>.yaml
          </span>
          <button
            phx-click="save_all_yaml"
            class="rounded bg-blue-600 text-white px-5 py-1.5 text-sm font-medium hover:bg-blue-700 transition-colors"
          >
            保存全部
          </button>
        </div>
      </div>

      <%!-- Diff Section --%>
      <div :if={@diff} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
        <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
          <h3 class="font-semibold text-sm">Sandbox vs Release</h3>
        </div>
        <div :if={@diff.added != [] or @diff.removed != []} class="p-4 space-y-3">
          <div :if={@diff.added != []}>
            <h4 class="text-xs font-semibold text-green-700 dark:text-green-300 mb-1.5">新增 / 修改</h4>
            <div class="space-y-1">
              <%= for line <- @diff.added do %>
                <div class="text-xs font-mono bg-green-50 dark:bg-green-950 text-green-800 dark:text-green-200 rounded px-2.5 py-1 border border-green-200 dark:border-green-800">
                  + <%= line %>
                </div>
              <% end %>
            </div>
          </div>
          <div :if={@diff.removed != []}>
            <h4 class="text-xs font-semibold text-red-700 dark:text-red-300 mb-1.5">删除</h4>
            <div class="space-y-1">
              <%= for line <- @diff.removed do %>
                <div class="text-xs font-mono bg-red-50 dark:bg-red-950 text-red-800 dark:text-red-200 rounded px-2.5 py-1 border border-red-200 dark:border-red-800">
                  - <%= line %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        <div :if={@diff.added == [] and @diff.removed == []} class="px-4 py-8 text-center">
          <p class="text-sm text-gray-400 dark:text-zinc-500">No differences between sandbox and release</p>
        </div>
      </div>
        </div>
      </main>
    </div>
    """
  end

  # --- Private Helpers ---

  defp compute_etag(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp etag_guard(socket, tid) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    current = read_file(path) || ""
    if compute_etag(current) != socket.assigns.etag do
      {:conflict, assign(socket, saved_flash: "⚠️ 文件已被他人修改，请刷新后重试")}
    else
      {:ok, socket}
    end
  end

  defp read_file(path) do
    if File.exists?(path), do: File.read!(path), else: nil
  end

  defp extract_template_slots(content) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(content)
    |> Enum.map(fn [_, key] -> key end)
    |> Enum.uniq()
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

  defp write_slots_file(tid, values) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{@role}.yaml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, YamlElixir.write!(values))
  end

  defp recompute_diff(nil, _new_values), do: nil

  defp recompute_diff(release_values, new_values) do
    release_content = inspect(release_values, pretty: true)
    sandbox_content = inspect(new_values, pretty: true)
    DiffEngine.diff(release_content, sandbox_content)
  end
end
