defmodule EzagentPluginLiveview.AutoService.Admin.InitWizardLive do
  @moduledoc """
  T2B — 3-step initialization wizard for a newly created tenant.

  Step 1: Brand Info → Soul auto-generation (L0-L2 templates + L3 sandbox).
  Step 2: KB knowledge base (optional: URL fetch or manual entry).
  Step 3: Summary + Lint + Publish (draft → v1).
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.{TenantRuntime, TenantProvisioner}
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer, SoulSlotParser}
  alias EzagentPluginContent.Skill.SkillIndexer
  alias EzagentPluginContent.Kb.KbStore
  alias EzagentPluginCr.{CrEngine, CrLint}
  alias EzagentPluginAutoservice.Refresh

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     assign(socket,
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
       kb_flash: nil
     )}
  end

  # Step 1 → Step 2: Brand Info → Soul auto-generation
  def handle_event("step1_next", %{"brand_name" => brand, "industry" => ind, "service_hours" => sh, "hotline" => hl}, socket) do
    tid = socket.assigns.tid
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")

    templates = SoulLoader.load(priv_dir, tid, "customer")
    soul_content = SoulRenderer.render(templates, %{
      "brand_name" => brand, "industry" => ind,
      "service_hours" => sh, "hotline" => hl
    })
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "customer.md"])
    File.mkdir_p!(Path.dirname(soul_path))
    File.write!(soul_path, soul_content)

    # Prefill slots from user input
    slot_keys = SoulSlotParser.parse_slots(soul_content)
    slot_values = Enum.reduce(slot_keys, %{}, fn section, acc ->
      Enum.reduce(section.keys, acc, fn key, acc2 ->
        val = case key do
          "brand_name" -> brand; "industry" -> ind
          "service_hours" -> sh; "hotline" -> hl
          _ -> ""
        end
        Map.put(acc2, key, val)
      end)
    end)
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "customer.yaml"])
    File.mkdir_p!(Path.dirname(slots_path))
    File.write!(slots_path, YamlElixir.write!(slot_values))

    # Copy fast_ack_prompt.md from skeleton
    skeleton_prompt = Path.join([priv_dir, "skeleton", "config", "fast_ack_prompt.md"])
    target_prompt = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    if File.exists?(skeleton_prompt) do
      File.mkdir_p!(Path.dirname(target_prompt))
      File.cp!(skeleton_prompt, target_prompt)
    end

    CrEngine.ensure_active_cr(tid)

    {:noreply,
     assign(socket, step: 2, brand_name: brand, industry: ind,
       service_hours: sh, hotline: hl, soul_content: soul_content)}
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "Soul 生成失败: #{Exception.message(e)}")}
  end

  def handle_event("step2_skip", _params, socket) do
    {:noreply, assign(socket, step: 3)}
  end

  def handle_event("step3_back", _params, socket) do
    {:noreply, assign(socket, step: 2)}
  end

  def handle_event("kb_fetch_url", %{"url" => url}, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(socket.assigns.tid), "kb"])
    case KbStore.fetch_url(kb_dir, url) do
      :ok -> {:noreply, assign(socket, kb_flash: "URL 抓取成功")}
      {:error, reason} -> {:noreply, assign(socket, kb_flash: "抓取失败: #{inspect(reason)}")}
    end
  end

  def handle_event("kb_add_manual", %{"id" => id, "title" => title, "content" => content}, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(socket.assigns.tid), "kb"])
    KbStore.upsert(kb_dir, %{"id" => id, "title" => title, "content" => content})
    CrEngine.ensure_active_cr(socket.assigns.tid)
    {:noreply, socket}
  end

  def handle_event("step3_publish", _params, socket) do
    tid = socket.assigns.tid
    lint = case CrLint.check(tid) do
      {:ok, warnings} -> %{ok: true, warnings: warnings}
      {:error, reason} -> %{ok: false, error: reason}
    end
    result = case CrEngine.publish(tid) do
      {:ok, published} ->
        Refresh.refresh_agents(tid)
        {:ok, published["published_version"]}
      {:error, reason} -> {:error, reason}
    end
    {:noreply, assign(socket, lint_results: lint, publish_result: result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6">
      <h1 class="text-xl font-bold text-gray-900 mb-2">初始化向导</h1>
      <p class="text-sm text-gray-500 mb-4">Step <%= @step %> of 3</p>

      <%!-- Progress bar --%>
      <div class="flex gap-2 mb-6">
        <div class={["flex-1 h-1.5 rounded-full", @step >= 1 && "bg-gray-800", @step < 1 && "bg-gray-200"]}></div>
        <div class={["flex-1 h-1.5 rounded-full", @step >= 2 && "bg-gray-800", @step < 2 && "bg-gray-200"]}></div>
        <div class={["flex-1 h-1.5 rounded-full", @step >= 3 && "bg-gray-800", @step < 3 && "bg-gray-200"]}></div>
      </div>

      <%= if @step == 1 do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden">
          <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg"><h3 class="font-semibold text-sm">Step 1: Brand Info → Soul 生成</h3></div>
          <div class="p-4">
            <form phx-submit="step1_next" class="space-y-3">
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="text-xs font-medium text-gray-700">Brand Name *</label>
                  <input type="text" name="brand_name" value={@brand_name} required
                    class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5" />
                </div>
                <div>
                  <label class="text-xs font-medium text-gray-700">Industry *</label>
                  <select name="industry" class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5">
                    <option value="零售电商" selected={@industry == "零售电商"}>零售电商</option>
                    <option value="通讯" selected={@industry == "通讯"}>通讯</option>
                    <option value="金融" selected={@industry == "金融"}>金融</option>
                    <option value="教育" selected={@industry == "教育"}>教育</option>
                  </select>
                </div>
                <div>
                  <label class="text-xs font-medium text-gray-700">Service Hours</label>
                  <input type="text" name="service_hours" value={@service_hours}
                    class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5" />
                </div>
                <div>
                  <label class="text-xs font-medium text-gray-700">Hotline</label>
                  <input type="text" name="hotline" value={@hotline}
                    class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 mt-0.5" />
                </div>
              </div>
              <div class="flex justify-between pt-3">
                <a href={"/admin/autoservice/tenants/#{@tid}"} class="rounded border border-gray-300 text-gray-700 px-4 py-1.5 text-sm hover:bg-gray-50">跳过</a>
                <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">下一步: KB 初始化 →</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @step == 2 do %>
        <div class="rounded-xl border border-gray-200 bg-white overflow-hidden">
          <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg"><h3 class="font-semibold text-sm">Step 2: KB 知识库 (可选)</h3></div>
          <div class="p-4 space-y-3">
            <div :if={@kb_flash} class="text-xs text-green-700 bg-green-50 rounded px-3 py-1.5">{@kb_flash}</div>
            <form phx-submit="kb_fetch_url" class="flex gap-2">
              <input type="url" name="url" placeholder="https://docs.example.com" class="flex-1 rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
              <button type="submit" class="rounded bg-emerald-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-emerald-700">抓取</button>
            </form>
            <form phx-submit="kb_add_manual" class="space-y-2">
              <input type="text" name="id" placeholder="条目 ID" class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
              <input type="text" name="title" placeholder="标题" class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
              <textarea name="content" rows="2" placeholder="内容" class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400"></textarea>
              <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">添加条目</button>
            </form>
            <div class="flex justify-between pt-3">
              <button phx-click="step2_skip" class="rounded border border-gray-300 text-gray-700 px-4 py-1.5 text-sm hover:bg-gray-50">跳过</button>
              <button phx-click="step2_skip" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">下一步: 预览发布 →</button>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @step == 3 do %>
        <div class="space-y-4">
          <div class="rounded-xl border border-gray-200 bg-white overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg"><h3 class="font-semibold text-sm">Summary</h3></div>
            <div class="p-4 text-sm space-y-1.5">
              <div class="flex items-center gap-2"><span class="text-green-600">✅</span> Soul: 已生成 (from <%= @brand_name %> / <%= @industry %> template)</div>
              <div class="flex items-center gap-2"><span class="text-green-600">✅</span> Slots: 已预填 (brand_name, industry, service_hours, hotline)</div>
              <div class="flex items-center gap-2"><span class="text-green-600">✅</span> Fast Prompt: 已从 skeleton 复制</div>
              <div class="flex items-center gap-2"><span class="text-green-600">✅</span> CR: 已创建 draft</div>
            </div>
          </div>

          <%= if @lint_results do %>
            <div class="rounded-xl border border-gray-200 bg-white overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg"><h3 class="font-semibold text-sm">Lint Results</h3></div>
              <div class="p-4 text-xs font-mono space-y-1">
                <%= if @lint_results.ok do %>
                  <div :for={w <- @lint_results.warnings} class="text-amber-700">⚠ <%= w %></div>
                  <div :if={@lint_results.warnings == []} class="text-green-700">✓ All checks passed</div>
                <% else %>
                  <div class="text-red-700">✗ <%= inspect(@lint_results.error) %></div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @publish_result do %>
            <div class={["rounded-lg border p-4",
              elem(@publish_result, 0) == :ok && "bg-green-50 border-green-300",
              elem(@publish_result, 0) == :error && "bg-red-50 border-red-300"]}>
              <%= if elem(@publish_result, 0) == :ok do %>
                <div class="text-green-800 font-medium">✅ Published v<%= elem(@publish_result, 1) %></div>
              <% else %>
                <div class="text-red-800">❌ Publish failed: <%= inspect(elem(@publish_result, 1)) %></div>
              <% end %>
            </div>
          <% end %>

          <div class="flex justify-between pt-3">
            <button phx-click="step3_back" class="rounded border border-gray-300 text-gray-700 px-4 py-1.5 text-sm hover:bg-gray-50">← 上一步</button>
            <%= if !@publish_result || elem(@publish_result, 0) == :error do %>
              <button phx-click="step3_publish" class="rounded bg-emerald-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-emerald-700">发布初始化 → v1</button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
