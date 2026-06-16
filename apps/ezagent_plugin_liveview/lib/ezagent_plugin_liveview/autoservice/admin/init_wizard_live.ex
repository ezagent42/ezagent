defmodule EzagentPluginLiveview.AutoService.Admin.InitWizardLive do
  @moduledoc """
  T2B — 3-step initialization wizard for a newly created tenant.

  Step 1: Brand Info → Soul auto-generation (L0-L2 templates + L3 sandbox).
  Step 2: KB knowledge base (optional: URL fetch, file upload, or manual entry).
  Step 3: Summary + Lint + Publish (draft → v1).
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer, SoulSlotParser}
  alias EzagentPluginContent.Kb.KbStore
  alias EzagentPluginCr.{CrEngine, CrLint}
  alias EzagentPluginAutoservice.Refresh

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     socket
     |> allow_upload(:kb_file,
       accept: ~w(.pdf .xlsx .txt .md),
       max_entries: 10,
       max_file_size: 50_000_000
     )
     |> assign(
       page_title: "初始化向导",
       tid: tid,
       step: 1,
       brand_name: "",
       industry: "零售电商",
       service_hours: "7×24小时",
       hotline: "",
       preview_content: nil,
       lint_results: nil,
       publish_result: nil,
       soul_content: nil,
       kb_entries: [],
       kb_flash: nil,
       kb_flash_type: nil,
       kb_count: 0
     )}
  end

  # Step 1 → Step 2: Brand Info → Soul auto-generation
  def handle_event(
        "step1_next",
        %{"brand_name" => brand, "industry" => ind, "service_hours" => sh, "hotline" => hl},
        socket
      ) do
    tid = socket.assigns.tid
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")

    templates = SoulLoader.load(priv_dir, tid, "customer")

    soul_content =
      SoulRenderer.render(templates, %{
        "brand_name" => brand,
        "industry" => ind,
        "service_hours" => sh,
        "hotline" => hl
      })

    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "customer.md"])
    File.mkdir_p!(Path.dirname(soul_path))
    File.write!(soul_path, soul_content)

    # Prefill slots from user input
    slot_keys = SoulSlotParser.parse_slots(soul_content)

    slot_values =
      Enum.reduce(slot_keys, %{}, fn section, acc ->
        Enum.reduce(section.keys, acc, fn key, acc2 ->
          val =
            case key do
              "brand_name" -> brand
              "industry" -> ind
              "service_hours" -> sh
              "hotline" -> hl
              _ -> ""
            end

          Map.put(acc2, key, val)
        end)
      end)

    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "customer.yaml"])
    File.mkdir_p!(Path.dirname(slots_path))
    File.write!(slots_path, EzagentPluginContent.YamlWriter.write(slot_values))

    # Copy fast_ack_prompt.md from skeleton
    skeleton_prompt = Path.join([priv_dir, "skeleton", "config", "fast_ack_prompt.md"])
    target_prompt = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])

    if File.exists?(skeleton_prompt) do
      File.mkdir_p!(Path.dirname(target_prompt))
      File.cp!(skeleton_prompt, target_prompt)
    end

    # Copy kb_search_mcp.py from skeleton to sandbox/kb/
    skeleton_kb_script = Path.join([priv_dir, "skeleton", "kb", "kb_search_mcp.py"])
    target_kb_script = Path.join([TenantRuntime.sandbox_path(tid), "kb", "kb_search_mcp.py"])

    if File.exists?(skeleton_kb_script) do
      File.mkdir_p!(Path.dirname(target_kb_script))
      File.cp!(skeleton_kb_script, target_kb_script)
    end

    # Create initial glossary.json with defaults
    glossary_path = Path.join([TenantRuntime.sandbox_path(tid), "kb", "glossary.json"])
    File.mkdir_p!(Path.dirname(glossary_path))

    default_glossary = [
      %{"term" => brand, "definition" => "#{brand} 是#{ind}行业的品牌，提供#{sh}的客户服务。热线电话: #{hl}"},
      %{"term" => "退货政策", "definition" => "客户可在购买后7天内申请退货，商品需保持原包装完好。退货审核通过后，退款将在3-5个工作日内原路返回。"},
      %{"term" => "配送时效", "definition" => "标准配送3-5个工作日，加急配送1-2个工作日。具体时效以订单确认页面为准。"},
      %{"term" => "售后服务", "definition" => "通过热线电话 #{hl} 联系客服，服务时间 #{sh}。也可通过在线客服渠道留言。"}
    ]

    File.write!(glossary_path, Jason.encode!(default_glossary))

    # Create default skill template in sandbox/skills/customer/
    platform_skill =
      Path.join([
        priv_dir,
        "platform",
        "skills",
        "customer",
        "customer-type-clarifier",
        "SKILL.md"
      ])

    default_skill_dir =
      Path.join([
        TenantRuntime.sandbox_path(tid),
        "skills",
        "customer",
        "customer-type-clarifier"
      ])

    if File.exists?(platform_skill) do
      File.mkdir_p!(default_skill_dir)
      File.cp!(platform_skill, Path.join(default_skill_dir, "SKILL.md"))
    end

    CrEngine.ensure_active_cr(tid)
    CrEngine.record_file_change(tid, "souls/customer.md")
    CrEngine.record_file_change(tid, "slots/customer.yaml")
    CrEngine.record_file_change(tid, "config/fast_ack_prompt.md")
    CrEngine.record_file_change(tid, "kb/kb_search_mcp.py")
    CrEngine.record_file_change(tid, "kb/glossary.json")
    CrEngine.record_file_change(tid, "skills/customer/customer-type-clarifier/SKILL.md")

    kb_count = count_kb_entries(tid)

    {:noreply,
     assign(socket,
       step: 2,
       brand_name: brand,
       industry: ind,
       service_hours: sh,
       hotline: hl,
       soul_content: soul_content,
       kb_count: kb_count
     )}
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "Soul 生成失败: #{Exception.message(e)}")}
  end

  def handle_event("step2_skip", _params, socket) do
    {:noreply, assign(socket, step: 3)}
  end

  def handle_event("step3_back", _params, socket) do
    {:noreply, assign(socket, step: 2, kb_flash: nil, kb_flash_type: nil)}
  end

  # --- Step 2: KB operations ---

  def handle_event("kb_fetch_url", %{"url" => url}, socket) do
    tid = socket.assigns.tid
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])

    case KbStore.fetch_url(kb_dir, url) do
      :ok ->
        CrEngine.ensure_active_cr(tid)
        CrEngine.record_file_change(tid, "kb/kb_entries.json")

        {:noreply,
         assign(socket,
           kb_flash: "URL 抓取成功，已添加到知识库",
           kb_flash_type: :success,
           kb_count: count_kb_entries(tid)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           kb_flash: "抓取失败: #{inspect(reason)}",
           kb_flash_type: :error
         )}
    end
  end

  def handle_event("kb_add_manual", %{"id" => id, "title" => title, "content" => content}, socket) do
    tid = socket.assigns.tid
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])
    KbStore.upsert(kb_dir, %{"id" => id, "title" => title, "content" => content})
    CrEngine.ensure_active_cr(tid)
    CrEngine.record_file_change(tid, "kb/kb_entries.json")

    {:noreply,
     assign(socket,
       kb_flash: "条目 \"#{title}\" 已添加",
       kb_flash_type: :success,
       kb_count: count_kb_entries(tid)
     )}
  end

  def handle_event("consume_kb_uploads", _params, socket) do
    tid = socket.assigns.tid
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])

    uploaded_paths =
      consume_uploaded_entries(socket, :kb_file, fn %{path: path}, entry ->
        dest = Path.join([System.tmp_dir!(), "#{entry.uuid}_#{entry.client_name}"])
        File.cp!(path, dest)
        {:ok, dest}
      end)

    results =
      Enum.map(uploaded_paths, fn {:ok, dest} ->
        case KbStore.ingest_file(kb_dir, dest) do
          :ok ->
            File.rm(dest)
            {:ok, Path.basename(dest)}

          {:error, reason} ->
            File.rm(dest)
            {:error, reason}
        end
      end)

    success_count = Enum.count(results, &(elem(&1, 0) == :ok))
    error_count = Enum.count(results, &(elem(&1, 0) == :error))

    flash_msg =
      cond do
        success_count > 0 and error_count == 0 ->
          {"成功上传 #{success_count} 个文件", :success}

        success_count > 0 and error_count > 0 ->
          {"上传 #{success_count} 个文件成功，#{error_count} 个失败", :error}

        error_count > 0 ->
          {"全部 #{error_count} 个文件上传失败", :error}

        true ->
          nil
      end

    if success_count > 0 do
      CrEngine.ensure_active_cr(tid)
      CrEngine.record_file_change(tid, "kb/kb_entries.json")
    end

    socket =
      if flash_msg do
        {msg, type} = flash_msg
        assign(socket, kb_flash: msg, kb_flash_type: type, kb_count: count_kb_entries(tid))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("step3_publish", _params, socket) do
    tid = socket.assigns.tid
    lint = CrLint.check(tid)

    result =
      case CrEngine.publish(tid) do
        {:ok, published} ->
          Refresh.refresh_agents(tid)
          {:ok, published["published_version"]}

        {:error, reason} ->
          {:error, reason}
      end

    {:noreply, assign(socket, lint_results: lint, publish_result: result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-3xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-2">初始化向导</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400 mb-4">Step {@step} of 3</p>

          <%!-- Progress bar --%>
          <div class="flex gap-2 mb-6">
            <div class={[
              "flex-1 h-1.5 rounded-full",
              @step >= 1 && "bg-gray-800 dark:bg-zinc-800",
              @step < 1 && "bg-gray-200 dark:bg-zinc-700"
            ]}>
            </div>
            <div class={[
              "flex-1 h-1.5 rounded-full",
              @step >= 2 && "bg-gray-800 dark:bg-zinc-800",
              @step < 2 && "bg-gray-200 dark:bg-zinc-700"
            ]}>
            </div>
            <div class={[
              "flex-1 h-1.5 rounded-full",
              @step >= 3 && "bg-gray-800 dark:bg-zinc-800",
              @step < 3 && "bg-gray-200 dark:bg-zinc-700"
            ]}>
            </div>
          </div>

          <%= if @step == 1 do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white rounded-t-lg">
                <h3 class="font-semibold text-sm">Step 1: Brand Info → Soul 生成</h3>
              </div>
              <div class="p-4">
                <form phx-submit="step1_next" class="space-y-3">
                  <div class="grid grid-cols-2 gap-3">
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">
                        Brand Name *
                      </label>
                      <input
                        type="text"
                        name="brand_name"
                        value={@brand_name}
                        required
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">
                        Industry *
                      </label>
                      <select
                        name="industry"
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      >
                        <option value="零售电商" selected={@industry == "零售电商"}>零售电商</option>
                        <option value="通讯" selected={@industry == "通讯"}>通讯</option>
                        <option value="金融" selected={@industry == "金融"}>金融</option>
                        <option value="教育" selected={@industry == "教育"}>教育</option>
                      </select>
                    </div>
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">
                        Service Hours
                      </label>
                      <input
                        type="text"
                        name="service_hours"
                        value={@service_hours}
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                    <div>
                      <label class="text-xs font-medium text-gray-700 dark:text-zinc-300">
                        Hotline
                      </label>
                      <input
                        type="text"
                        name="hotline"
                        value={@hotline}
                        class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5"
                      />
                    </div>
                  </div>
                  <div class="flex justify-between pt-3">
                    <a
                      href={"/admin/autoservice/tenants/#{@tid}"}
                      class="rounded border border-gray-300 dark:border-zinc-700 text-gray-700 dark:text-zinc-300 px-4 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-zinc-800"
                    >
                      跳过
                    </a>
                    <button
                      type="submit"
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                    >
                      下一步: KB 初始化 →
                    </button>
                  </div>
                </form>
              </div>
            </div>
          <% end %>

          <%= if @step == 2 do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white rounded-t-lg">
                <h3 class="font-semibold text-sm">Step 2: KB 知识库 (可选) — 当前 {@kb_count} 条目</h3>
              </div>
              <div class="p-4 space-y-4">
                <%!-- Flash message --%>
                <div
                  :if={@kb_flash}
                  class={[
                    "text-xs rounded px-3 py-1.5",
                    @kb_flash_type == :success &&
                      "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950",
                    @kb_flash_type == :error &&
                      "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950",
                    is_nil(@kb_flash_type) &&
                      "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"
                  ]}
                >
                  {@kb_flash}
                </div>

                <%!-- Sub-step 2a: URL fetch --%>
                <div class="border border-gray-200 dark:border-zinc-700 rounded-lg p-3">
                  <h4 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">URL 抓取</h4>
                  <form phx-submit="kb_fetch_url" class="flex gap-2">
                    <input
                      type="url"
                      name="url"
                      placeholder="https://docs.example.com"
                      class="flex-1 rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                    />
                    <button
                      type="submit"
                      class="rounded bg-emerald-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-emerald-700"
                    >
                      抓取
                    </button>
                  </form>
                </div>

                <%!-- Sub-step 2b: File upload --%>
                <div class="border border-gray-200 dark:border-zinc-700 rounded-lg p-3">
                  <h4 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">
                    文件上传 (PDF / XLSX / TXT / MD)
                  </h4>
                  <form phx-submit="consume_kb_uploads" phx-change="validate" class="space-y-2">
                    <div class="flex items-center gap-3">
                      <label class="text-xs cursor-pointer rounded bg-gray-100 dark:bg-zinc-800 hover:bg-gray-200 dark:hover:bg-zinc-700 border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-gray-700 dark:text-zinc-300 transition-colors">
                        选择文件 <.live_file_input upload={@uploads.kb_file} class="hidden" />
                      </label>
                      <span class="text-xs text-gray-400 dark:text-zinc-500">
                        {length(@uploads.kb_file.entries)} 个文件已选择
                      </span>
                    </div>

                    <%!-- Upload entries with progress --%>
                    <%= for entry <- @uploads.kb_file.entries do %>
                      <div class="flex items-center gap-2 text-xs">
                        <span class="text-gray-700 dark:text-zinc-300 truncate max-w-[200px]">
                          {entry.client_name}
                        </span>
                        <span class="text-gray-400 dark:text-zinc-500">{entry.progress}%</span>
                        <%!-- Progress bar --%>
                        <div class="flex-1 h-1 bg-gray-200 dark:bg-zinc-700 rounded-full overflow-hidden max-w-[120px]">
                          <div
                            class="h-full bg-blue-500 rounded-full transition-all"
                            style={"width: #{entry.progress}%"}
                          >
                          </div>
                        </div>
                        <%= if entry.valid? do %>
                          <span class="text-green-600 dark:text-green-400">✓</span>
                        <% else %>
                          <span class="text-red-600 dark:text-red-400">✗</span>
                        <% end %>
                      </div>
                    <% end %>

                    <%= for err <- upload_errors(@uploads.kb_file) do %>
                      <div class="text-xs text-red-600 dark:text-red-400">{err}</div>
                    <% end %>

                    <button
                      :if={@uploads.kb_file.entries != []}
                      type="submit"
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                    >
                      上传到知识库
                    </button>
                  </form>
                </div>

                <%!-- Sub-step 2c: Manual entry --%>
                <div class="border border-gray-200 dark:border-zinc-700 rounded-lg p-3">
                  <h4 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">手动添加条目</h4>
                  <form phx-submit="kb_add_manual" class="space-y-2">
                    <input
                      type="text"
                      name="id"
                      placeholder="条目 ID"
                      class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                    />
                    <input
                      type="text"
                      name="title"
                      placeholder="标题"
                      class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                    />
                    <textarea
                      name="content"
                      rows="2"
                      placeholder="内容"
                      class="w-full rounded border border-gray-300 dark:border-zinc-700 px-3 py-1.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                    ></textarea>
                    <button
                      type="submit"
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                    >
                      添加条目
                    </button>
                  </form>
                </div>

                <div class="flex justify-between pt-3">
                  <button
                    phx-click="step2_skip"
                    class="rounded border border-gray-300 dark:border-zinc-700 text-gray-700 dark:text-zinc-300 px-4 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-zinc-800"
                  >
                    跳过
                  </button>
                  <button
                    phx-click="step2_skip"
                    class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                  >
                    下一步: 预览发布 →
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @step == 3 do %>
            <div class="space-y-4">
              <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
                <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white rounded-t-lg">
                  <h3 class="font-semibold text-sm">Summary</h3>
                </div>
                <div class="p-4 text-sm space-y-1.5">
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span>
                    Soul: 已生成 (from {@brand_name} / {@industry} template)
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span>
                    Slots: 已预填 (brand_name, industry, service_hours, hotline)
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span>
                    Fast Prompt: 已从 skeleton 复制
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span> Glossary: 已创建默认词条
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span> Skill: 已创建默认模板
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span> KB: {@kb_count} 条目已索引
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-green-600 dark:text-green-400">✅</span> CR: 已创建 draft (所有文件已在追踪)
                  </div>
                </div>
              </div>

              <%= if @lint_results do %>
                <% lint_ok? = elem(@lint_results, 0) == :ok
                lint_data = elem(@lint_results, 1) %>
                <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
                  <div class="px-4 py-2.5 bg-gray-800 dark:bg-zinc-800 text-white rounded-t-lg">
                    <h3 class="font-semibold text-sm">Lint Results</h3>
                  </div>
                  <div class="p-4 text-xs font-mono space-y-1">
                    <%!-- Error items (red) --%>
                    <%= for {:error, msg} <- lint_data[:errors] || [] do %>
                      <div class="flex items-center gap-1.5">
                        <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200">
                          ERROR
                        </span>
                        <span class="text-red-700 dark:text-red-300">{msg}</span>
                      </div>
                    <% end %>
                    <%!-- Warning items (amber) --%>
                    <%= for {:warning, msg} <- lint_data[:warnings] || [] do %>
                      <div class="flex items-center gap-1.5">
                        <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                          WARN
                        </span>
                        <span class="text-amber-700 dark:text-amber-300">{msg}</span>
                      </div>
                    <% end %>
                    <%!-- OK items (green) --%>
                    <%= for {:ok, msg} <- lint_data[:ok] || [] do %>
                      <div class="flex items-center gap-1.5">
                        <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
                          OK
                        </span>
                        <span class="text-green-700 dark:text-green-300">{msg}</span>
                      </div>
                    <% end %>
                    <%!-- Empty state: no results --%>
                    <%= if (lint_data[:errors] || []) == [] and (lint_data[:warnings] || []) == [] and (lint_data[:ok] || []) == [] do %>
                      <div class="text-zinc-400 italic">No lint checks ran.</div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if @publish_result do %>
                <div class={[
                  "rounded-lg border p-4",
                  elem(@publish_result, 0) == :ok &&
                    "bg-green-50 dark:bg-green-950 border-green-300 dark:border-green-700",
                  elem(@publish_result, 0) == :error &&
                    "bg-red-50 dark:bg-red-950 border-red-300 dark:border-red-700"
                ]}>
                  <%= if elem(@publish_result, 0) == :ok do %>
                    <div class="text-green-800 dark:text-green-200 font-medium">
                      ✅ Published v{elem(@publish_result, 1)}
                    </div>
                  <% else %>
                    <div class="text-red-800 dark:text-red-200">
                      ❌ Publish failed: {inspect(elem(@publish_result, 1))}
                    </div>
                  <% end %>
                </div>
              <% end %>

              <div class="flex justify-between pt-3">
                <button
                  phx-click="step3_back"
                  class="rounded border border-gray-300 dark:border-zinc-700 text-gray-700 dark:text-zinc-300 px-4 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-zinc-800"
                >
                  ← 上一步
                </button>
                <%= if !@publish_result || elem(@publish_result, 0) == :error do %>
                  <button
                    phx-click="step3_publish"
                    class="rounded bg-emerald-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-emerald-700"
                  >
                    发布初始化 → v1
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # --- Private helpers ---

  defp count_kb_entries(tid) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "kb", "kb_entries.json"])

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, entries} when is_list(entries) -> length(entries)
        _ -> 0
      end
    else
      0
    end
  end
  defp map_to_yaml(map) when is_map(map), do: map |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end) |> Enum.join("\n")
end

