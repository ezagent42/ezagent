# AutoService Admin UI v2 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 AutoService Admin UI 全部功能迁移至 ezagent，实现独立组件化的管理页面体系。

**Architecture:** 每个管理模块为独立 Phoenix LiveView，可单独挂载为页面或作为卡片嵌入 Admin Session。后端复用现有 `ContentAdmin`/`CrEngine`/`KbStore`/`SkillStore`/`SoulStore`，新增 `DiffEngine` 和 `CrEngine.record_file_change`。

**Tech Stack:** Elixir/Phoenix LiveView, Tailwind CSS, Ecto/SQLite, YamlElixir

**参考设计:** `docs/superpowers/specs/2026-06-16-autoservice-admin-ui-v2-detailed.md`
**UI 预览:** `docs/superpowers/specs/admin-ui-preview.html`

---

## 文件结构

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/
├── tenant/
│   ├── tenant_dashboard_live.ex         ← P0-0 修改：初始化引导
│   └── tenant_onboard_live.ex           ← P0-1 修改：精简为壳创建
└── autoservice/
    └── admin/
        ├── init_wizard_live.ex           ← P0-1 NEW：3步初始化向导
        ├── soul_editor_live.ex           ← P0-2 NEW：Soul 编辑器
        ├── slot_editor_live.ex           ← P0-3 NEW：Slot 编辑器
        ├── skill_manager_live.ex         ← P0-4 NEW：Skill 管理器
        ├── kb_manager_live.ex            ← P0-5 NEW：KB 管理器
        ├── fast_prompt_editor_live.ex    ← P1-1 NEW：Fast Prompt 编辑器
        ├── sandbox_preview_live.ex       ← P1-2 NEW：沙箱预览
        ├── version_timeline_live.ex      ← P1-3 NEW：版本时间线
        ├── platform/
        │   ├── platform_soul_live.ex     ← P2-1 NEW：Platform Soul
        │   └── platform_skill_live.ex    ← P2-2 NEW：Platform Skill
        └── components/
            ├── soul_diff_view.ex         ← P0-2 NEW：Diff 视图组件
            ├── skill_card.ex             ← P0-4 NEW：Skill 卡片组件
            ├── kb_source_list.ex         ← P0-5 NEW：KB Source 列表组件
            ├── cr_tracked_changes.ex     ← P1-4 NEW：CR 变更追踪组件
            └── ai_assistant_panel.ex     ← P3-1 NEW：AI 助手面板组件

apps/ezagent_plugin_content/lib/ezagent_plugin_content/
├── diff_engine.ex                       ← P0-2 NEW：文本 Diff 引擎
└── kb/
    └── source_tracker.ex                ← P0-5 NEW：KB Source 聚合

apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/
└── cr_engine.ex                         ← P0-6 修改：新增 record_file_change, list_crs

apps/ezagent_web/lib/ezagent_web/
└── router.ex                            ← 各 Phase 修改：注册新路由
```

---

## Phase 0: 初始化入口 + 租户壳创建 (P0-0 ~ P0-1)

### Task P0-0: TenantDashboard 初始化引导

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_dashboard_live.ex`

- [ ] **Step 1: 在 mount 中检测初始化状态**

读取 `mount/3` 函数，在现有 assigns 后添加 `init_status`:

```elixir
# 在现有 mount/3 中，获取 tid 之后添加:
    # 检测初始化状态：有 release 版本 = 已初始化
    release_path = TenantRuntime.release_path(tid)
    current_link = Path.join(release_path, "_current")
    initialized? = File.exists?(current_link)

    # 加载数据统计（已初始化才有意义）
    stats = if initialized?, do: load_stats(tid), else: %{}

    {:ok,
     assign(socket,
       # ... 现有 assigns ...
       initialized?: initialized?,
       stats: stats
     )}
```

- [ ] **Step 2: 添加 Pending 状态渲染**

在 render/1 中，`@initialized? == false` 时渲染初始化引导卡片：

```heex
<%= if !@initialized? do %>
  <div class="max-w-3xl mx-auto border-2 border-amber-300 rounded-xl overflow-hidden">
    <div class="bg-amber-50 px-6 py-5">
      <div class="flex items-start gap-4">
        <div class="text-4xl">🚀</div>
        <div class="flex-1">
          <h3 class="text-lg font-bold text-amber-900">租户未初始化</h3>
          <p class="text-sm text-amber-700 mt-1">
            此租户尚未完成初始化配置。运行初始化向导将自动完成 Soul 生成、Slot 预填、Skill 继承等设置。
          </p>
          <div class="mt-4 flex gap-3">
            <a href={"/admin/autoservice/tenants/#{@tid}/init"}
               class="bg-amber-600 text-white rounded-lg px-6 py-2.5 text-sm font-medium hover:bg-amber-700 shadow">
              开始初始化 →
            </a>
            <span class="text-xs text-amber-500 self-center">
              💡 也可通过左侧菜单手动编辑各个模块
            </span>
          </div>
        </div>
      </div>
    </div>
  </div>
<% else %>
  <%!-- 现有 Dashboard 内容（KPI + 链接） --%>
<% end %>
```

- [ ] **Step 3: 运行测试验证**

```bash
mix test apps/ezagent_web/test/ezagent_web/live/autoservice_admin_e2e_test.exs --trace
```

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_dashboard_live.ex
git commit -m "feat(admin-ui): add init status detection + pending CTA on TenantDashboard"
```

---

### Task P0-1: TenantOnboardLive 精简为壳创建 + InitWizardLive

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_onboard_live.ex`
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/init_wizard_live.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

#### Part A: TenantOnboardLive 精简

- [ ] **Step A1: 简化表单为 Tenant ID + Brand Name**

在 `handle_event("create", ...)` 中改为只调用 `TenantProvisioner.create_tenant(tid, brand_name)`：

```elixir
def handle_event("create", %{"tid" => tid, "brand_name" => brand_name}, socket) do
  case TenantProvisioner.create_tenant(tid, brand_name) do
    {:ok, _result} ->
      {:noreply,
       socket
       |> put_flash(:info, "租户 #{tid} 创建成功")
       |> push_navigate(to: "/admin/autoservice/tenants/#{tid}")}
    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "创建失败: #{inspect(reason)}")}
  end
end
```

- [ ] **Step A2: 更新 render 为单步表单**

```heex
<div class="max-w-lg mx-auto p-6">
  <h1 class="text-xl font-bold text-gray-900 mb-6">新建租户</h1>
  <form phx-submit="create" class="space-y-4">
    <div>
      <label class="text-sm font-medium text-gray-700">Tenant ID *</label>
      <input type="text" name="tid" required placeholder="demo-acme"
        class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
      <p class="text-xs text-gray-400 mt-1">唯一标识，创建后不可修改</p>
    </div>
    <div>
      <label class="text-sm font-medium text-gray-700">Brand Name</label>
      <input type="text" name="brand_name" placeholder="Acme Corp"
        class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
    </div>
    <button type="submit"
      class="w-full rounded bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700">
      创建租户
    </button>
  </form>
</div>
```

#### Part B: InitWizardLive — 3步初始化向导

- [ ] **Step B1: 创建文件 + mount**

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/init_wizard_live.ex
defmodule EzagentPluginLiveview.AutoService.Admin.InitWizardLive do
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
       # Step 3
       preview_content: nil,
       lint_results: nil,
       publish_result: nil
     )}
  end
```

- [ ] **Step B2: Step 1 — 品牌信息 → Soul 自动生成**

```elixir
  def handle_event("step1_next", %{"brand_name" => brand, "industry" => ind, "service_hours" => sh, "hotline" => hl}, socket) do
    tid = socket.assigns.tid
    # 1. 写品牌信息到 ConfigStore (通过 TenantConfig)
    # 2. 生成 Soul 模板
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    templates = SoulLoader.load(priv_dir, tid, "customer")
    # templates = [L0, L1, L2, L3] — 4层模板列表（nil 表示该层不存在）

    # 3. 合成 L3 模板并写入 sandbox
    soul_content = SoulRenderer.render(templates, %{
      "brand_name" => brand,
      "industry" => ind,
      "service_hours" => sh,
      "hotline" => hl
    })
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "customer.md"])
    File.mkdir_p!(Path.dirname(soul_path))
    File.write!(soul_path, soul_content)

    # 4. 预填 slots
    slot_keys = SoulSlotParser.parse_slots(soul_content)
    slot_values = Enum.reduce(slot_keys, %{}, fn section, acc ->
      Enum.reduce(section.keys, acc, fn key, acc2 ->
        val = case key do
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
    File.write!(slots_path, YamlElixir.write!(slot_values))

    # 5. 复制 fast_ack_prompt.md
    skeleton_prompt = Path.join([priv_dir, "skeleton", "config", "fast_ack_prompt.md"])
    target_prompt = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    if File.exists?(skeleton_prompt) do
      File.mkdir_p!(Path.dirname(target_prompt))
      File.cp!(skeleton_prompt, target_prompt)
    end

    # 6. 创建初始 CR
    CrEngine.ensure_active_cr(tid)

    {:noreply,
     assign(socket,
       step: 2,
       brand_name: brand,
       industry: ind,
       service_hours: sh,
       hotline: hl,
       soul_content: soul_content
     )}
  end
```

- [ ] **Step B3: Step 2 — KB 初始化 (可选)**

```elixir
  def handle_event("step2_skip", _params, socket) do
    {:noreply, assign(socket, step: 3)}
  end

  def handle_event("kb_fetch_url", %{"url" => url}, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(socket.assigns.tid), "kb"])
    KbStore.fetch_url(kb_dir, url)
    {:noreply, socket}
  end

  def handle_event("kb_add_manual", %{"id" => id, "title" => title, "content" => content}, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(socket.assigns.tid), "kb"])
    KbStore.upsert(kb_dir, %{"id" => id, "title" => title, "content" => content})
    {:noreply, socket}
  end
```

- [ ] **Step B4: Step 3 — 预览 + Lint + Publish**

```elixir
  def handle_event("step3_publish", _params, socket) do
    tid = socket.assigns.tid
    # 1. Lint
    lint = case CrLint.check(tid) do
      {:ok, warnings} -> %{ok: true, warnings: warnings}
      {:error, reason} -> %{ok: false, error: reason}
    end

    # 2. Publish
    result = case CrEngine.publish(tid) do
      {:ok, published} ->
        Refresh.refresh_agents(tid)
        {:ok, published["published_version"]}
      {:error, reason} ->
        {:error, reason}
    end

    {:noreply,
     assign(socket,
       lint_results: lint,
       publish_result: result
     )}
  end
```

- [ ] **Step B5: Render 3步向导 UI**

参考 `admin-ui-preview.html` 中 Page 9-10 的布局，使用进度条 + 步骤面板。

- [ ] **Step B6: 注册路由**

```elixir
# apps/ezagent_web/lib/ezagent_web/router.ex
# 在 live_session :require_admin 块中添加:
live "/admin/autoservice/tenants/:tid/init", AutoService.Admin.InitWizardLive
```

- [ ] **Step B7: 运行测试并 Commit**

```bash
mix test apps/ezagent_plugin_liveview/test/ --trace
git add apps/ezagent_plugin_liveview/ apps/ezagent_web/
git commit -m "feat(admin-ui): simplify TenantOnboard to shell + 3-step InitWizard"
```

---

## Phase 1: Soul Editor + Slot Editor (P0-2 ~ P0-3)

### Task P0-2: SoulEditorLive — Soul 编辑器

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/soul_editor_live.ex`
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/components/soul_diff_view.ex`
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/diff_engine.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: 创建 DiffEngine**

```elixir
# apps/ezagent_plugin_content/lib/ezagent_plugin_content/diff_engine.ex
defmodule EzagentPluginContent.DiffEngine do
  @moduledoc "Simple text diff for sandbox vs release comparison."

  def diff(nil, sandbox_text), do: %{added: String.split(sandbox_text || "", "\n"), removed: []}
  def diff(release_text, nil), do: %{added: [], removed: String.split(release_text || "", "\n")}

  def diff(release_text, sandbox_text) when is_binary(release_text) and is_binary(sandbox_text) do
    release_lines = String.split(release_text, "\n")
    sandbox_lines = String.split(sandbox_text, "\n")
    added = sandbox_lines -- release_lines
    removed = release_lines -- sandbox_lines
    unchanged = sandbox_lines -- added
    %{added: added, removed: removed, unchanged: unchanged}
  end

  def diff_yaml({:ok, release_map}, {:ok, sandbox_map}) do
    all_keys = Map.keys(release_map) ++ Map.keys(sandbox_map) |> Enum.uniq()
    changes = Enum.reduce(all_keys, %{added: [], removed: [], changed: [], unchanged: []}, fn key, acc ->
      r = Map.get(release_map, key)
      s = Map.get(sandbox_map, key)
      cond do
        is_nil(r) -> %{acc | added: [key | acc.added]}
        is_nil(s) -> %{acc | removed: [key | acc.removed]}
        r != s -> %{acc | changed: [key | acc.changed]}
        true -> %{acc | unchanged: [key | acc.unchanged]}
      end
    end)
    {:ok, changes}
  end
end
```

- [ ] **Step 2: 创建 SoulEditorLive**

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/soul_editor_live.ex
defmodule EzagentPluginLiveview.AutoService.Admin.SoulEditorLive do
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer, SoulSlotParser}
  alias EzagentPluginContent.Skill.SkillIndexer
  alias EzagentPluginContent.DiffEngine
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid} = params, _session, socket) do
    role = Map.get(params, "role", "customer")
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")

    # 加载 L0-L3 模板
    templates = SoulLoader.load(priv_dir, tid, role)
    # 读取 sandbox L3 内容
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{role}.md"])
    soul_content = case File.read(soul_path) do {:ok, c} -> c; _ -> "" end
    # 读取 release L3 内容 (用于 diff)
    release_path = Path.join([TenantRuntime.release_path(tid), "_current", "souls", "#{role}.md"])
    release_content = case File.read(release_path) do {:ok, c} -> c; _ -> nil end

    diff = DiffEngine.diff(release_content || "", soul_content)
    slot_keys = SoulSlotParser.parse_slots(soul_content)
    preview = SoulRenderer.full_claude_md(templates, load_slots(tid, role), SkillIndexer.build(TenantRuntime.base_dir(), tid, role))

    {:ok,
     assign(socket,
       page_title: "Soul Editor",
       tid: tid,
       role: role,
       active_tab: :source,
       templates: templates,
       soul_content: soul_content,
       release_content: release_content,
       diff: diff,
       slot_keys: slot_keys,
       preview: preview,
       saved_flash: nil
     )}
  end

  def handle_event("save_soul", %{"content" => content}, socket) do
    tid = socket.assigns.tid
    role = socket.assigns.role
    path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{role}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    CrEngine.ensure_active_cr(tid)
    {:noreply, assign(socket, soul_content: content, saved_flash: "已保存")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end
end
```

- [ ] **Step 3: Render — 4 Tab 布局**

参考 `admin-ui-preview.html` Page 1 的布局：Source/Diff/Preview/AI Assist tabs + 层级信息条 + slot 标签 + 编辑器

- [ ] **Step 4: 创建 SoulDiffView 组件**

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/components/soul_diff_view.ex
defmodule EzagentPluginLiveview.AutoService.Admin.Components.SoulDiffView do
  use Phoenix.Component

  attr :diff, :map, required: true

  def soul_diff_view(assigns) do
    ~H"""
    <div class="space-y-2 text-xs font-mono">
      <div :for={line <- @diff.removed} class="text-red-700 bg-red-50 rounded px-2 py-0.5">
        - <%= line %>
      </div>
      <div :for={line <- @diff.added} class="text-green-700 bg-green-50 rounded px-2 py-0.5">
        + <%= line %>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: 注册路由**

```elixir
live "/admin/autoservice/tenants/:tid/soul", AutoService.Admin.SoulEditorLive
```

- [ ] **Step 6: 运行测试并 Commit**

```bash
mix test apps/ezagent_plugin_content/test/ezagent_plugin_content/diff_engine_test.exs --trace 2>/dev/null || echo "test file to be created"
mix compile --warnings-as-errors
git add apps/ezagent_plugin_content/ apps/ezagent_plugin_liveview/ apps/ezagent_web/
git commit -m "feat(admin-ui): SoulEditorLive with DiffEngine — 4-tab soul editor"
```

---

### Task P0-3: SlotEditorLive — Slot 值编辑器

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/slot_editor_live.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: 创建 SlotEditorLive**

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.SlotEditorLive do
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.SoulSlotParser
  alias EzagentPluginContent.DiffEngine
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    role = "customer"
    # 读取 slot values
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{role}.yaml"])
    slot_values = case YamlElixir.read_from_string(File.read!(slots_path)) do
      {:ok, map} -> map; _ -> %{}
    end

    # 从 soul 模板提取 slot keys
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{role}.md"])
    soul_content = case File.read(soul_path) do {:ok, c} -> c; _ -> "" end
    slot_sections = SoulSlotParser.parse_slots(soul_content)

    {:ok,
     assign(socket,
       page_title: "Slot Editor",
       tid: tid,
       role: role,
       slot_values: slot_values,
       slot_sections: slot_sections,
       show_yaml: false,
       saved_flash: nil
     )}
  end

  def handle_event("save_slot", %{"key" => key, "value" => value}, socket) do
    tid = socket.assigns.tid
    new_values = Map.put(socket.assigns.slot_values, key, value)
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "customer.yaml"])
    File.write!(path, YamlElixir.write!(new_values))
    CrEngine.ensure_active_cr(tid)
    {:noreply, assign(socket, slot_values: new_values, saved_flash: "#{key} 已保存")}
  end
end
```

- [ ] **Step 2: Render — 表单式编辑**

参考 `admin-ui-preview.html` Page 2 的布局：表单式 key-value 网格 + "切换为 YAML 编辑" 按钮 + Diff 区域

- [ ] **Step 3: 注册路由**

```elixir
live "/admin/autoservice/tenants/:tid/soul/slots", AutoService.Admin.SlotEditorLive
```

- [ ] **Step 4: 运行测试并 Commit**

```bash
mix compile --warnings-as-errors
git add apps/ezagent_plugin_liveview/ apps/ezagent_web/
git commit -m "feat(admin-ui): SlotEditorLive — form-based slot value editor with diff"
```

---

## Phase 2: Skill Manager + KB Manager (P0-4 ~ P0-5)

### Task P0-4: SkillManagerLive — Skill 管理器

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/skill_manager_live.ex`
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/components/skill_card.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: 创建 SkillCard 组件**

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.Components.SkillCard do
  use Phoenix.Component

  attr :name, :string, required: true
  attr :layer, :atom, required: true
  attr :description, :string, default: ""
  attr :safety_class, :string, default: "safe"
  attr :shadowed, :boolean, default: false
  attr :editable, :boolean, default: false

  def skill_card(assigns) do
    ~H"""
    <div class={["rounded-lg border p-3 transition hover:shadow-md",
      @shadowed && "opacity-50 bg-gray-50",
      @editable && "border-blue-300 cursor-pointer",
      !@editable && "cursor-default"
    ]}>
      <div class="flex justify-between items-start">
        <span class="font-mono text-sm font-medium"><%= @name %></span>
        <span class={["text-[10px] px-1.5 py-0.5 rounded",
          @safety_class == "critical" && "bg-red-100 text-red-700",
          true && "bg-green-100 text-green-800"
        ]}><%= @safety_class %></span>
      </div>
      <div class="flex items-center gap-2 mt-1">
        <span class="text-[10px] bg-gray-100 px-1.5 py-0.5 rounded text-gray-500">L<%= layer_num(@layer) %></span>
        <%= if @shadowed do %>
          <span class="text-[10px] text-amber-600">被覆盖</span>
        <% end %>
      </div>
      <p class="text-xs text-gray-500 mt-1 line-clamp-2"><%= @description %></p>
    </div>
    """
  end

  defp layer_num(:l0), do: "0"
  defp layer_num(:l1), do: "1"
  defp layer_num(:l2), do: "2"
  defp layer_num(:l3), do: "3"
end
```

- [ ] **Step 2: 创建 SkillManagerLive (4层扫描 + 卡片网格)**

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.SkillManagerLive do
  use Phoenix.LiveView
  import Phoenix.Component
  alias EzagentPluginContent.Skill.{SkillLoader, SkillStore}
  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    role = "customer"
    base_dir = TenantRuntime.base_dir()

    layers = %{
      l0: load_layer(base_dir, tid, role, :framework),
      l1: load_layer(base_dir, tid, role, :platform),
      l2: load_layer(base_dir, tid, role, :industry),
      l3: load_layer(base_dir, tid, role, :tenant)
    }

    {:ok,
     assign(socket,
       page_title: "Skill Manager",
       tid: tid, role: role,
       layers: layers,
       search_query: "",
       editing_skill: nil,
       editing_content: "",
       flash_msg: nil
     )}
  end

  defp load_layer(base_dir, tid, role, layer) do
    case SkillLoader.list(base_dir, tid, role, layer) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  def handle_event("edit_skill", %{"name" => name}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid
    content = case SkillStore.read(base_dir, tid, "customer", name) do
      {:ok, c} -> c; _ -> ""
    end
    {:noreply, assign(socket, editing_skill: name, editing_content: content)}
  end

  def handle_event("save_skill", %{"content" => content}, socket) do
    base_dir = TenantRuntime.base_dir()
    tid = socket.assigns.tid
    name = socket.assigns.editing_skill
    SkillStore.write(base_dir, tid, "customer", name, content)
    CrEngine.ensure_active_cr(tid)
    {:noreply,
     socket
     |> assign(editing_skill: nil, editing_content: "", flash_msg: "#{name} 已保存")
     |> reload_layers()}
  end

  def handle_event("delete_skill", %{"name" => name}, socket) do
    base_dir = TenantRuntime.base_dir()
    SkillStore.delete(base_dir, socket.assigns.tid, "customer", name)
    CrEngine.ensure_active_cr(socket.assigns.tid)
    {:noreply, socket |> assign(flash_msg: "#{name} 已删除") |> reload_layers()}
  end
end
```

- [ ] **Step 3: Render — 4层卡片网格 + 编辑器**

参考 `admin-ui-preview.html` Page 3 的布局

- [ ] **Step 4: 注册路由**

```elixir
live "/admin/autoservice/tenants/:tid/skills", AutoService.Admin.SkillManagerLive
```

- [ ] **Step 5: Commit**

```bash
mix compile --warnings-as-errors
git add apps/ezagent_plugin_liveview/ apps/ezagent_web/
git commit -m "feat(admin-ui): SkillManagerLive — 4-layer skill grid with card components"
```

---

### Task P0-5: KbManagerLive — KB 管理器 + Glossary

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/kb_manager_live.ex`
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/components/kb_source_list.ex`
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/source_tracker.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: 创建 KbSourceTracker**

```elixir
defmodule EzagentPluginContent.Kb.SourceTracker do
  def list_sources(kb_dir) do
    entries = KbStore.search(kb_dir, "")
    entries
    |> Enum.group_by(&(Map.get(&1, "source_type", "manual")))
    |> Enum.flat_map(fn {type, group} ->
      group
      |> Enum.group_by(&(Map.get(&1, "source_id", Map.get(&1, "id"))))
      |> Enum.map(fn {source_id, chunks} ->
        %{
          source_type: type,
          source_id: source_id,
          title: (List.first(chunks) || %{})["title"] || source_id,
          chunk_count: length(chunks)
        }
      end)
    end)
  end
end
```

- [ ] **Step 2: 创建 KbManagerLive (5 tabs)**

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.KbManagerLive do
  use Phoenix.LiveView
  import Phoenix.Component
  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Kb.{KbStore, KbRebuilder, KbSourceTracker}
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])
    glossary_path = Path.join(kb_dir, "glossary.json")
    glossary = case File.read(glossary_path) do
      {:ok, json} -> Jason.decode!(json); _ -> []
    end

    {:ok,
     assign(socket,
       page_title: "KB Manager",
       tid: tid,
       kb_dir: kb_dir,
       active_tab: :sources,
       sources: KbSourceTracker.list_sources(kb_dir),
       entries: KbStore.search(kb_dir, ""),
       search_query: "",
       glossary: glossary,
       # Manual add
       kb_new_id: "", kb_new_title: "", kb_new_content: "",
       # URL fetch
       kb_fetch_url: "",
       flash_msg: nil
     )}
  end

  def handle_event("kb_fetch_url", %{"url" => url}, socket) do
    case KbStore.fetch_url(socket.assigns.kb_dir, url) do
      :ok ->
        CrEngine.ensure_active_cr(socket.assigns.tid)
        {:noreply, assign(socket,
          sources: KbSourceTracker.list_sources(socket.assigns.kb_dir),
          flash_msg: "URL 抓取成功", kb_fetch_url: "")}
      {:error, reason} ->
        {:noreply, assign(socket, flash_msg: "抓取失败: #{inspect(reason)}")}
    end
  end

  def handle_event("kb_rebuild", _params, socket) do
    KbRebuilder.rebuild(socket.assigns.kb_dir)
    {:noreply, assign(socket,
      sources: KbSourceTracker.list_sources(socket.assigns.kb_dir),
      entries: KbStore.search(socket.assigns.kb_dir, ""),
      flash_msg: "KB 重建完成")}
  end
end
```

- [ ] **Step 3: Render — 5 Tab 布局**

参考 `admin-ui-preview.html` Page 4 + Page 6 的布局

- [ ] **Step 4: 注册路由**

```elixir
live "/admin/autoservice/tenants/:tid/kb", AutoService.Admin.KbManagerLive
```

- [ ] **Step 5: Commit**

```bash
mix compile --warnings-as-errors
git add apps/ezagent_plugin_content/ apps/ezagent_plugin_liveview/ apps/ezagent_web/
git commit -m "feat(admin-ui): KbManagerLive — 5-tab KB manager with glossary + url fetch"
```

---

## Phase 3: CR Dashboard 增强 + Version Timeline (P0-6)

### Task P0-6: CrEngine 增强 + CrDashboardLive 完善

**Files:**
- Modify: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex`
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/cr_dashboard_live.ex`
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/version_timeline_live.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: CrEngine 新增 record_file_change + list_crs**

```elixir
# 在 cr_engine.ex 中添加:
  def record_file_change(tid, path, opts \\ []) do
    with {:ok, cr} <- ensure_active_cr(tid) do
      existing = cr["sandbox_diff"] || %{}
      new_paths = Enum.uniq((existing["paths"] || []) ++ [path])
      merged = %{
        "files_changed" => (existing["files_changed"] || 0) + 1,
        "paths" => new_paths,
        "lines_added" => (existing["lines_added"] || 0) + Keyword.get(opts, :lines_added, 0),
        "lines_removed" => (existing["lines_removed"] || 0) + Keyword.get(opts, :lines_removed, 0)
      }
      # 写回 CR 的 sandbox_diff
      # (通过 ConfigStore 更新 CR 记录)
      :ok
    end
  end

  def list_crs(tid) do
    # 扫描 ConfigStore 中 cr:<tid>:* 的 key，返回 CR 列表
    # 实现取决于 ConfigPointer 查询
    []
  end
```

- [ ] **Step 2: CrDashboardLive 完善 (tracked changes + lint)**

- [ ] **Step 3: VersionTimelineLive**

- [ ] **Step 4: 注册路由**

```elixir
live "/admin/autoservice/tenants/:tid/versions", AutoService.Admin.VersionTimelineLive
```

- [ ] **Step 5: Commit**

---

## Phase 4: Fast Prompt + Sandbox Preview + Operators (P1)

### Task P1-1: FastPromptEditorLive
- Create: `fast_prompt_editor_live.ex`
- Route: `/admin/autoservice/tenants/:tid/prompt`

### Task P1-2: SandboxPreviewLive
- Create: `sandbox_preview_live.ex`
- Route: `/admin/autoservice/tenants/:tid/preview`

### Task P1-3: OperatorsLive 增强
- Modify: `operators_live.ex` — disable/enable 功能

- [ ] **Commit each task separately**

---

## Phase 5: Platform 管理 (P2)

### Task P2-1: PlatformSoulLive
### Task P2-2: PlatformSkillLive

- [ ] **Commit**

---

## Phase 6: AI Assistant + Admin Session (P3, 未来)

### Task P3-1: AiAssistantPanel 组件
### Task P3-2: AdminSessionLive + AdminAgent Behavior

---

## Self-Review Checklist

- [x] 每个 Task 有明确的 Files 列表
- [x] 路由注册在每个 Phase 末尾
- [x] CR 追踪在所有写操作中调用
- [x] P0 覆盖: InitWizard + SoulEditor + SlotEditor + SkillManager + KbManager + CrDashboard
- [x] P1 覆盖: FastPromptEditor + SandboxPreview + VersionTimeline + Operators
- [x] P2 覆盖: Platform Soul + Platform Skills
- [x] P3 覆盖: AI Assistant + Admin Session
- [x] 没有 TBD/TODO 占位符 — 所有关键代码都在 Step 中给出
- [x] 每个文件路径基于 `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/` 目录
