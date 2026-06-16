defmodule EzagentPluginLiveview.AutoService.Admin.KbManagerLive do
  @moduledoc """
  KB Manager — 5-tab knowledge base management.

  Tabs: Sources | URL抓取 | 文件上传 | 手动添加 | Glossary
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Kb.{KbStore, KbRebuilder, SourceTracker}
  alias EzagentPluginCr.CrEngine

  @role "customer"
  @allowed_exts ~w(.txt .md .csv .json .yaml )

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])
    ensure_kb_initialized(kb_dir)

    glossary = read_glossary(kb_dir)

    glossary =
      if glossary == [] or glossary == %{} do
        glossary_path = Path.join(kb_dir, "glossary.json")

        defaults = [
          %{"term" => "退换货流程", "definition" => "客户申请→生成单号→寄回→验收→退款"},
          %{"term" => "订单查询", "definition" => "提供订单号查询物流状态、预计送达时间"},
          %{"term" => "客服热线", "definition" => "工作时间拨打400-888-9999"}
        ]

        File.mkdir_p!(kb_dir)
        File.write!(glossary_path, Jason.encode!(defaults, pretty: true))
        defaults
      else
        glossary
      end

    {:ok,
     assign(socket,
       page_title: "KB 知识库管理",
       tid: tid,
       role: @role,
       tab: "sources",
       kb_dir: kb_dir,
       sources: SourceTracker.list_sources(kb_dir),
       entries: reload_entries(kb_dir),
       url_input: "",
       url_flash: nil,
       ingest_task: nil,
       upload_task: nil,
       manual_id: "",
       manual_title: "",
       manual_content: "",
       manual_flash: nil,
       glossary: glossary,
       glossary_term: "",
       glossary_definition: "",
       glossary_edit_idx: nil,
       glossary_flash: nil,
       rebuild_flash: nil,
       upload_flash: nil
     )
     |> allow_upload(:kb_file,
       accept: ~w(.txt .md .csv .json .pdf .xlsx),
       max_entries: 10,
       auto_upload: false
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    kb_dir = socket.assigns.kb_dir

    assigns =
      case tab do
        "sources" -> [sources: SourceTracker.list_sources(kb_dir)]
        _ -> []
      end

    {:noreply, assign(socket, Keyword.put(assigns, :tab, tab))}
  end

  # -- Sources tab: delete source --
  @impl true
  def handle_event("delete_source", %{"source_id" => source_id}, socket) do
    kb_dir = socket.assigns.kb_dir
    tid = socket.assigns.tid

    KbStore.delete(kb_dir, source_id)
    CrEngine.record_file_change(tid, "kb/sources")

    {:noreply,
     assign(socket,
       sources: SourceTracker.list_sources(kb_dir),
       entries: reload_entries(kb_dir),
       rebuild_flash: nil
     )}
  end

  # -- URL抓取 tab --
  @impl true
  def handle_event("fetch_url", %{"url" => url}, socket) do
    kb_dir = socket.assigns.kb_dir
    task = Task.async(fn -> {KbStore.fetch_url(kb_dir, url), url} end)
    {:noreply, assign(socket, ingest_task: task, url_flash: "抓取中...")}
  end

  # -- 手动添加 tab --
  @impl true
  def handle_event("manual_add", %{"id" => id, "title" => title, "content" => content}, socket) do
    kb_dir = socket.assigns.kb_dir
    tid = socket.assigns.tid

    KbStore.upsert(kb_dir, %{
      "id" => id,
      "title" => title,
      "content" => content,
      "source_type" => "manual",
      "source_id" => id
    })

    CrEngine.record_file_change(tid, "kb/sources")

    {:noreply,
     assign(socket,
       manual_id: "",
       manual_title: "",
       manual_content: "",
       manual_flash: "条目 #{id} 已添加",
       sources: SourceTracker.list_sources(kb_dir),
       entries: reload_entries(kb_dir)
     )}
  end

  # -- 文件上传 tab --
  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :kb_file, ref)}
  end

  @impl true
  def handle_event("upload_files", _params, socket) do
    kb_dir = socket.assigns.kb_dir
    tid = socket.assigns.tid

    entries =
      consume_uploaded_entries(socket, :kb_file, fn meta, _socket ->
        {:ok, meta}
      end)

    task =
      Task.async(fn ->
        {Enum.map(entries, fn meta ->
           case KbStore.ingest_file(kb_dir, meta.path) do
             :ok -> {:ok, meta.client_name}
             {:error, reason} -> {:error, meta.client_name, reason}
           end
         end), tid}
      end)

    {:noreply, assign(socket, upload_task: task, upload_flash: "处理中...")}
  end

  # -- Glossary tab --
  @impl true
  def handle_event("glossary_add", %{"term" => term, "definition" => definition}, socket) do
    kb_dir = socket.assigns.kb_dir
    glossary = socket.assigns.glossary || %{}

    updated = Map.put(glossary, term, definition)
    write_glossary(kb_dir, updated)
    CrEngine.record_file_change(socket.assigns.tid, "kb/sources")

    {:noreply,
     assign(socket,
       glossary: updated,
       glossary_term: "",
       glossary_definition: "",
       glossary_flash: "术语 #{term} 已添加"
     )}
  end

  @impl true
  def handle_event("glossary_edit", %{"idx" => idx}, socket) do
    glossary = socket.assigns.glossary || %{}
    terms = Map.to_list(glossary)
    idx_num = String.to_integer(idx)

    if idx_num < length(terms) do
      {term, definition} = Enum.at(terms, idx_num)

      {:noreply,
       assign(socket,
         glossary_edit_idx: idx_num,
         glossary_term: term,
         glossary_definition: definition
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("glossary_update", %{"term" => term, "definition" => definition}, socket) do
    kb_dir = socket.assigns.kb_dir
    glossary = socket.assigns.glossary || %{}
    old_idx = socket.assigns.glossary_edit_idx

    terms = Map.to_list(glossary)

    {old_term, _} =
      if old_idx && old_idx < length(terms), do: Enum.at(terms, old_idx), else: {nil, nil}

    # Remove old term, add new term
    updated =
      glossary
      |> if(old_term && Map.has_key?(glossary, old_term),
        do: Map.delete(glossary, old_term),
        else: & &1
      ).()
      |> Map.put(term, definition)

    write_glossary(kb_dir, updated)
    CrEngine.record_file_change(socket.assigns.tid, "kb/sources")

    {:noreply,
     assign(socket,
       glossary: updated,
       glossary_edit_idx: nil,
       glossary_term: "",
       glossary_definition: "",
       glossary_flash: "术语 #{term} 已更新"
     )}
  end

  @impl true
  def handle_event("glossary_delete", %{"term" => term}, socket) do
    kb_dir = socket.assigns.kb_dir
    glossary = socket.assigns.glossary || %{}
    updated = Map.delete(glossary, term)
    write_glossary(kb_dir, updated)
    CrEngine.record_file_change(socket.assigns.tid, "kb/sources")

    {:noreply,
     assign(socket,
       glossary: updated,
       glossary_flash: "术语 #{term} 已删除"
     )}
  end

  @impl true
  def handle_event("glossary_cancel_edit", _params, socket) do
    {:noreply,
     assign(socket,
       glossary_edit_idx: nil,
       glossary_term: "",
       glossary_definition: ""
     )}
  end

  # -- Rebuild --
  @impl true
  def handle_event("rebuild", _params, socket) do
    kb_dir = socket.assigns.kb_dir
    tid = socket.assigns.tid

    ensure_kb_initialized(kb_dir)

    case KbRebuilder.rebuild(kb_dir) do
      :ok ->
        CrEngine.record_file_change(tid, "kb/sources")

        {:noreply,
         assign(socket,
           rebuild_flash: "KB 重建成功",
           sources: SourceTracker.list_sources(kb_dir),
           entries: reload_entries(kb_dir)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, rebuild_flash: "重建失败: #{inspect(reason)}")}
    end
  end

  # -- Task.async result handlers --

  @impl true
  def handle_info({ref, {:ok, url}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    kb_dir = socket.assigns.kb_dir
    tid = socket.assigns.tid
    CrEngine.record_file_change(tid, "kb/sources")

    {:noreply,
     assign(socket,
       url_flash: "抓取完成",
       sources: SourceTracker.list_sources(kb_dir),
       entries: reload_entries(kb_dir)
     )}
  end

  @impl true
  def handle_info({ref, {{:error, reason}, url}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, url_flash: "抓取失败: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({ref, {results, tid}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    kb_dir = socket.assigns.kb_dir
    CrEngine.record_file_change(tid, "kb/sources")

    success_count =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    {:noreply,
     assign(socket,
       upload_flash: "#{success_count} 个文件已上传",
       sources: SourceTracker.list_sources(kb_dir),
       entries: reload_entries(kb_dir)
     )}
  end

  @impl true
  def handle_info({:DOWN, ref, _, _, _}, socket) do
    {:noreply, socket}
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
              <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">KB 知识库管理</h1>
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

          <%!-- Rebuild button (global) --%>
          <div class="flex items-center justify-between mb-4">
            <div></div>
            <button
              phx-click="rebuild"
              class="rounded bg-emerald-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-emerald-700 transition-colors"
            >
              重建 KB 索引
            </button>
          </div>
          <%= if @rebuild_flash do %>
            <div class={[
              "text-sm rounded px-3 py-2 mb-4",
              String.contains?(@rebuild_flash, "成功") &&
                "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950",
              String.contains?(@rebuild_flash, "失败") &&
                "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950"
            ]}>
              {@rebuild_flash}
            </div>
          <% end %>

          <%!-- Tab bar --%>
          <div class="flex gap-0.5 mb-0">
            <button
              phx-click="switch_tab"
              phx-value-tab="sources"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "sources" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "sources" &&
                  "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              Sources
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="url"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "url" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "url" &&
                  "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              URL抓取
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="upload"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "upload" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "upload" &&
                  "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              文件上传
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="manual"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "manual" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "manual" &&
                  "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              手动添加
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="glossary"
              class={[
                "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors",
                @tab == "glossary" && "bg-gray-800 dark:bg-zinc-800 text-white",
                @tab != "glossary" &&
                  "bg-gray-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-700"
              ]}
            >
              Glossary
            </button>
          </div>

          <%!-- Tab: Sources --%>
          <%= if @tab == "sources" do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
                <h3 class="font-semibold text-sm">KB Sources</h3>
              </div>
              <div class="overflow-x-auto">
                <%= if @sources == [] do %>
                  <div class="px-4 py-8 text-center">
                    <p class="text-sm text-gray-400 dark:text-zinc-500">暂无 KB 数据源</p>
                    <p class="text-xs text-gray-300 dark:text-zinc-600 mt-1">
                      通过 URL抓取、文件上传或手动添加来创建条目
                    </p>
                  </div>
                <% else %>
                  <table class="w-full text-sm">
                    <thead>
                      <tr class="border-b border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950">
                        <th class="text-left px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                          类型
                        </th>
                        <th class="text-left px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                          来源
                        </th>
                        <th class="text-left px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                          标题
                        </th>
                        <th class="text-right px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                          分块数
                        </th>
                        <th class="text-right px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                          操作
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for src <- @sources do %>
                        <tr class="border-b border-gray-100 dark:border-zinc-800 hover:bg-gray-50 dark:hover:bg-zinc-900">
                          <td class="px-4 py-2">
                            <span class="text-[10px] bg-gray-100 dark:bg-zinc-800 px-1.5 py-0.5 rounded text-gray-500 dark:text-zinc-400 font-mono">
                              {src.source_type}
                            </span>
                          </td>
                          <td
                            class="px-4 py-2 text-xs text-gray-500 dark:text-zinc-400 font-mono max-w-[200px] truncate"
                            title={src.source_id}
                          >
                            {src.source_id}
                          </td>
                          <td
                            class="px-4 py-2 text-xs text-gray-700 dark:text-zinc-300 max-w-[250px] truncate"
                            title={src.title}
                          >
                            {src.title}
                          </td>
                          <td class="px-4 py-2 text-right text-xs text-gray-500 dark:text-zinc-400">
                            {src.chunk_count}
                          </td>
                          <td class="px-4 py-2 text-right">
                            <button
                              phx-click="delete_source"
                              phx-value-source_id={src.source_id}
                              class="text-[10px] text-red-500 dark:text-red-400 hover:text-red-700 dark:hover:text-red-300 hover:underline"
                              onclick={"return confirm('确定要删除来源 #{src.source_id} 吗？')"}
                            >
                              删除
                            </button>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Tab: URL抓取 --%>
          <%= if @tab == "url" do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
                <h3 class="font-semibold text-sm">URL 抓取</h3>
              </div>
              <div class="p-4 space-y-3">
                <p class="text-xs text-gray-500 dark:text-zinc-400">
                  输入 URL 抓取网页内容作为 KB 条目。HTML 标签会被自动剥离，最多保留 5000 字符。
                </p>
                <%= if @url_flash do %>
                  <div class={[
                    "text-xs rounded px-3 py-1.5",
                    String.contains?(@url_flash, "成功") &&
                      "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950",
                    String.contains?(@url_flash, "失败") &&
                      "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950"
                  ]}>
                    {@url_flash}
                  </div>
                <% end %>
                <form phx-submit="fetch_url" class="flex gap-2">
                  <input
                    type="url"
                    name="url"
                    value={@url_input}
                    placeholder="https://docs.example.com"
                    required
                    class="flex-1 rounded border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                  />
                  <button
                    type="submit"
                    class="rounded bg-blue-600 text-white px-5 py-2 text-sm font-medium hover:bg-blue-700 transition-colors"
                  >
                    抓取
                  </button>
                </form>
              </div>
            </div>
          <% end %>

          <%!-- Tab: 文件上传 --%>
          <%= if @tab == "upload" do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
                <h3 class="font-semibold text-sm">文件上传</h3>
              </div>
              <div class="p-4 space-y-3">
                <p class="text-xs text-gray-500 dark:text-zinc-400">
                  支持格式: .txt / .md / .csv / .json / .yaml / 。文件将复制到 KB sources 目录并索引。
                </p>
                <%= if @upload_flash do %>
                  <div class={[
                    "text-xs rounded px-3 py-1.5",
                    String.contains?(@upload_flash, "失败") &&
                      "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950",
                    !String.contains?(@upload_flash, "失败") &&
                      "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"
                  ]}>
                    {@upload_flash}
                  </div>
                <% end %>

                <form phx-submit="upload_files" phx-change="validate_upload">
                  <.live_file_input
                    upload={@uploads.kb_file}
                    class="block w-full text-sm text-gray-500 dark:text-zinc-400 file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:text-sm file:font-medium file:bg-blue-50 dark:file:bg-blue-950 file:text-blue-700 dark:file:text-blue-300 hover:file:bg-blue-100 dark:hover:file:bg-blue-900"
                  />

                  <%= for entry <- @uploads.kb_file.entries do %>
                    <div class="flex items-center gap-2 mt-2 text-sm">
                      <span class="text-gray-600 dark:text-zinc-400">{entry.client_name}</span>
                      <span class="text-xs text-gray-400 dark:text-zinc-500">
                        {round(entry.client_size / 1024)} KB
                      </span>
                      <progress value={entry.progress} max="100" class="h-1 rounded">
                        {entry.progress}%
                      </progress>
                      <button
                        type="button"
                        phx-click="cancel_upload"
                        phx-value-ref={entry.ref}
                        class="text-xs text-red-500 dark:text-red-400 hover:text-red-700 dark:hover:text-red-300"
                      >
                        取消
                      </button>
                    </div>
                  <% end %>

                  <%= for err <- upload_errors(@uploads.kb_file) do %>
                    <div class="text-xs text-red-600 dark:text-red-400 mt-1">
                      {upload_error_to_string(err)}
                    </div>
                  <% end %>

                  <button
                    :if={@uploads.kb_file.entries != []}
                    type="submit"
                    class="mt-3 rounded bg-blue-600 text-white px-5 py-2 text-sm font-medium hover:bg-blue-700 transition-colors"
                  >
                    上传并索引
                  </button>
                </form>
              </div>
            </div>
          <% end %>

          <%!-- Tab: 手动添加 --%>
          <%= if @tab == "manual" do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
                <h3 class="font-semibold text-sm">手动添加条目</h3>
              </div>
              <div class="p-4">
                <%= if @manual_flash do %>
                  <div class="text-xs text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-3 py-1.5 mb-3">
                    {@manual_flash}
                  </div>
                <% end %>
                <form phx-submit="manual_add" class="space-y-3">
                  <div class="grid grid-cols-2 gap-3">
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">
                        条目 ID *
                      </label>
                      <input
                        type="text"
                        name="id"
                        value={@manual_id}
                        required
                        placeholder="例如: faq-returns"
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">标题 *</label>
                      <input
                        type="text"
                        name="title"
                        value={@manual_title}
                        required
                        placeholder="例如: 退货政策 FAQ"
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                  </div>
                  <div>
                    <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">内容 *</label>
                    <textarea
                      name="content"
                      rows="6"
                      required
                      placeholder="输入知识库条目内容..."
                      class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                    ><%= @manual_content %></textarea>
                  </div>
                  <button
                    type="submit"
                    class="rounded bg-blue-600 text-white px-5 py-2 text-sm font-medium hover:bg-blue-700 transition-colors"
                  >
                    添加条目
                  </button>
                </form>
              </div>
            </div>
          <% end %>

          <%!-- Tab: Glossary --%>
          <%= if @tab == "glossary" do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden rounded-tl-none">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white">
                <h3 class="font-semibold text-sm">Glossary (术语表)</h3>
              </div>
              <div class="p-4 space-y-4">
                <%= if @glossary_flash do %>
                  <div class="text-xs text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-3 py-1.5">
                    {@glossary_flash}
                  </div>
                <% end %>

                <%!-- Add / Edit form --%>
                <form
                  phx-submit={
                    if @glossary_edit_idx != nil, do: "glossary_update", else: "glossary_add"
                  }
                  class="space-y-2 p-3 bg-gray-50 dark:bg-zinc-950 rounded-lg border border-gray-200 dark:border-zinc-800"
                >
                  <div class="grid grid-cols-2 gap-3">
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">术语</label>
                      <input
                        type="text"
                        name="term"
                        value={@glossary_term}
                        required
                        placeholder="例如: SLA"
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">定义</label>
                      <input
                        type="text"
                        name="definition"
                        value={@glossary_definition}
                        required
                        placeholder="例如: Service Level Agreement"
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                  </div>
                  <div class="flex justify-end gap-2">
                    <%= if @glossary_edit_idx != nil do %>
                      <button
                        type="button"
                        phx-click="glossary_cancel_edit"
                        class="rounded border border-gray-300 dark:border-zinc-700 text-gray-700 dark:text-zinc-300 px-3 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-zinc-800"
                      >
                        取消
                      </button>
                    <% end %>
                    <button
                      type="submit"
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                    >
                      {if @glossary_edit_idx != nil, do: "更新", else: "添加术语"}
                    </button>
                  </div>
                </form>

                <%!-- Term list --%>
                <%= if @glossary != nil && map_size(@glossary) > 0 do %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                      <thead>
                        <tr class="border-b border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950">
                          <th class="text-left px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs w-1/3">
                            术语
                          </th>
                          <th class="text-left px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs">
                            定义
                          </th>
                          <th class="text-right px-4 py-2 font-medium text-gray-600 dark:text-zinc-400 text-xs w-24">
                            操作
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for {{term, definition}, idx} <- @glossary |> Map.to_list() |> Enum.with_index() do %>
                          <tr class="border-b border-gray-100 dark:border-zinc-800 hover:bg-gray-50 dark:hover:bg-zinc-900">
                            <td class="px-4 py-2 text-xs font-mono text-gray-800 dark:text-zinc-200">
                              {term}
                            </td>
                            <td class="px-4 py-2 text-xs text-gray-600 dark:text-zinc-400">
                              {definition}
                            </td>
                            <td class="px-4 py-2 text-right">
                              <div class="flex gap-1 justify-end">
                                <button
                                  phx-click="glossary_edit"
                                  phx-value-idx={idx}
                                  class="text-[10px] text-blue-500 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300 hover:underline"
                                >
                                  编辑
                                </button>
                                <button
                                  phx-click="glossary_delete"
                                  phx-value-term={term}
                                  class="text-[10px] text-red-500 dark:text-red-400 hover:text-red-700 dark:hover:text-red-300 hover:underline"
                                  onclick={"return confirm('确定要删除术语 #{term} 吗？')"}
                                >
                                  删除
                                </button>
                              </div>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% else %>
                  <div class="px-4 py-6 text-center">
                    <p class="text-sm text-gray-400 dark:text-zinc-500">暂无术语</p>
                    <p class="text-xs text-gray-300 dark:text-zinc-600 mt-1">使用上方表单添加术语定义</p>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # -- Private helpers --

  defp ensure_kb_initialized(kb_dir) do
    script_path = Path.join(kb_dir, "kb_search_mcp.py")

    unless File.exists?(script_path) do
      skeleton =
        Path.join([
          Application.app_dir(:ezagent_plugin_content),
          "priv",
          "skeleton",
          "kb",
          "kb_search_mcp.py"
        ])

      if File.exists?(skeleton) do
        File.mkdir_p!(kb_dir)
        File.cp!(skeleton, script_path)
      end
    end
  end

  defp reload_entries(kb_dir) do
    KbStore.search(kb_dir, "") |> Enum.take(20)
  end

  defp read_glossary(kb_dir) do
    path = Path.join(kb_dir, "glossary.json")

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp write_glossary(kb_dir, glossary) do
    path = Path.join(kb_dir, "glossary.json")
    File.mkdir_p!(kb_dir)
    File.write!(path, Jason.encode!(glossary, pretty: true))
  end

  defp upload_error_to_string(:too_large), do: "文件过大"
  defp upload_error_to_string(:not_accepted), do: "不支持的文件类型"
  defp upload_error_to_string(:too_many_files), do: "文件数量超限 (最多 10 个)"
  defp upload_error_to_string(_), do: "上传错误"
end
