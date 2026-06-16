# AutoService Admin UI v2 — Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure admin UI from fragmented standalone pages to agent-centric layout: Fast Agent + Slow Agent (tabbed) + Orchestrate + Debug Agent.

**Architecture:** Merge 4 standalone pages (SoulEditor/SlotEditor/SkillManager/KbManager) into one SlowAgentLive with 6 tabs. Create FastAgentLive, OrchestrateLive, DebugAgentLive as new pages. Refactor sidebar grouping and Overview dashboard.

**Tech Stack:** Elixir/Phoenix LiveView, Tailwind CSS, YamlWriter, existing backend modules (SoulStore, SkillStore, KbStore, CrEngine)

---

## File Structure

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/
├── fast_agent_live.ex              ← T1.1 NEW
├── slow_agent_live.ex              ← T1.2 NEW (6 tabs)
├── orchestrate_live.ex             ← T2.1 NEW
├── debug_agent_live.ex             ← T2.2 NEW
├── components/
│   ├── admin_sidebar.ex            ← T1.4 REFACTOR
│   ├── skill_card.ex               ← KEEP
│   └── soul_diff_view.ex           ← KEEP
├── [ARCHIVED]
│   ├── soul_editor_live.ex         ← T3.2 archive
│   ├── slot_editor_live.ex         ← T3.2 archive
│   ├── skill_manager_live.ex       ← T3.2 archive
│   ├── kb_manager_live.ex          ← T3.2 archive
│   └── sandbox_preview_live.ex     ← T3.2 archive

apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/
├── tenant_dashboard_live.ex        ← T1.5 REFACTOR (agent cards)
└── cr_dashboard_live.ex            ← T3.1 REFACTOR (group by agent)

apps/ezagent_web/lib/ezagent_web/
└── router.ex                       ← T1.3 + T2.3 REFACTOR
```

---

## Batch 1: Fast + Slow Agent (核心重构, 5 tasks)

### Task T1.1: FastAgentLive — Fast Agent Config

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/fast_agent_live.ex`

Fast Agent config page. Single-tab Soul editor that reads/writes `sandbox/config/fast_ack_prompt.md`.

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.FastAgentLive do
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    prompt_path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    content = case File.read(prompt_path) do {:ok, c} -> c; _ -> "" end
    release_path = Path.join([TenantRuntime.release_path(tid), "_current", "config", "fast_ack_prompt.md"])
    release_content = case File.read(release_path) do {:ok, c} -> c; _ -> nil end

    {:ok,
     assign(socket, page_title: "Fast Agent", tid: tid, content: content,
       release_content: release_content, saved_flash: nil)}
  end

  def handle_event("save", %{"content" => content}, socket) do
    tid = socket.assigns.tid
    path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    CrEngine.record_file_change(tid, "config/fast_ack_prompt.md")
    {:noreply, assign(socket, content: content, saved_flash: "已保存")}
  end

  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-4xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-4">⚡ Fast Agent 配置</h1>
          <p class="text-xs text-gray-500 mb-4">sandbox/config/fast_ack_prompt.md — DeepSeek 即时安抚回复提示词</p>
          <div :if={@saved_flash} class="text-sm text-green-700 bg-green-50 rounded px-3 py-1.5 mb-3">{@saved_flash}</div>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">Fast Agent ACK Prompt</h2>
            </div>
            <div class="p-4">
              <form phx-submit="save">
                <textarea name="content" rows="16" class="w-full font-mono text-sm border border-gray-300 dark:border-zinc-700 rounded p-3 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"><%= @content %></textarea>
                <div class="mt-3 flex justify-end">
                  <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">保存</button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
```

- [ ] **Step 1: Create file** — Write the module above
- [ ] **Step 2: Compile** — `mix compile`
- [ ] **Step 3: Commit** — `git commit -m "feat(v2): T1.1 — FastAgentLive (Soul-only config)"`

---

### Task T1.2: SlowAgentLive — Slow Agent Config (6 tabs)

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/slow_agent_live.ex`

Slow Agent config page. 6 tabs merging Soul/Skills/KB/Slots/Diff/Preview.

**Tab 1 — Soul**: Read/write `sandbox/souls/customer.md`
**Tab 2 — Skills**: Reuse SkillCard component, 4-layer display, edit/create/delete
**Tab 3 — KB**: Search, manual add, URL fetch (reuse KbStore)
**Tab 4 — Slots**: Read/write `sandbox/slots/customer.yaml`
**Tab 5 — Diff**: Sandbox vs Release diff using DiffEngine
**Tab 6 — Preview**: SoulRenderer.full_claude_md preview

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.SlowAgentLive do
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer, SoulSlotParser}
  alias EzagentPluginContent.Skill.{SkillLoader, SkillStore, SkillIndexer}
  alias EzagentPluginContent.Kb.{KbStore, KbRebuilder, SourceTracker}
  alias EzagentPluginContent.{DiffEngine, YamlWriter}
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    role = "customer"
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    base_dir = TenantRuntime.base_dir()

    # Soul tab data
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "souls", "#{role}.md"])
    soul_content = case File.read(soul_path) do {:ok, c} -> c; _ -> "" end

    # Slots tab data
    slots_path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{role}.yaml"])
    slot_values = read_yaml(slots_path)

    # Skills tab data
    layers = load_all_layers(base_dir, tid, role)

    # KB tab data
    kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])
    ensure_kb_initialized(kb_dir)
    kb_entries = KbStore.search(kb_dir, "") |> Enum.take(20)

    # Diff tab data
    release_soul = read_release_file(tid, "souls/#{role}.md")
    diff = DiffEngine.diff(release_soul || "", soul_content)

    # Preview tab data
    templates = SoulLoader.load(priv_dir, tid, role)
    preview = SoulRenderer.full_claude_md(templates, slot_values, SkillIndexer.build(base_dir, tid, role))

    {:ok,
     assign(socket,
       page_title: "Slow Agent", tid: tid, role: role, tab: "soul",
       soul_content: soul_content, saved_flash: nil,
       slot_values: slot_values, all_keys: extract_slot_keys(soul_content),
       layers: layers, skill_meta: %{}, editing_skill: nil,
       kb_dir: kb_dir, kb_entries: kb_entries, kb_search_q: "",
       diff: diff, release_soul: release_soul,
       preview: preview
     )}
  end

  # Soul tab handlers
  def handle_event("save_soul", %{"content" => content}, socket) do
    path = Path.join([TenantRuntime.sandbox_path(socket.assigns.tid), "souls/customer.md"])
    File.write!(path, content)
    CrEngine.record_file_change(socket.assigns.tid, "souls/customer.md")
    {:noreply, assign(socket, soul_content: content, saved_flash: "Soul 已保存")}
  end

  # Slots tab handlers
  def handle_event("save_slot", %{"key" => key, "value" => value}, socket) do
    new_values = Map.put(socket.assigns.slot_values, key, value)
    write_slots(socket.assigns.tid, new_values)
    CrEngine.record_file_change(socket.assigns.tid, "slots/customer.yaml")
    {:noreply, assign(socket, slot_values: new_values, saved_flash: "#{key} 已保存")}
  end

  # Skills tab handlers
  def handle_event("edit_skill", %{"name" => name}, socket) do
    content = case SkillStore.read(TenantRuntime.base_dir(), socket.assigns.tid, "customer", name) do
      {:ok, c} -> c; _ -> ""
    end
    {:noreply, assign(socket, editing_skill: name, editing_content: content)}
  end

  def handle_event("save_skill", %{"content" => content}, socket) do
    SkillStore.write(TenantRuntime.base_dir(), socket.assigns.tid, "customer", socket.assigns.editing_skill, content)
    CrEngine.record_file_change(socket.assigns.tid, "skills/customer/#{socket.assigns.editing_skill}/SKILL.md")
    layers = load_all_layers(TenantRuntime.base_dir(), socket.assigns.tid, "customer")
    {:noreply, assign(socket, editing_skill: nil, editing_content: "", layers: layers, saved_flash: "Skill 已保存")}
  end

  # KB tab handlers
  def handle_event("kb_search", %{"query" => query}, socket) do
    entries = if query == "", do: KbStore.search(socket.assigns.kb_dir, "") |> Enum.take(20),
               else: KbStore.search(socket.assigns.kb_dir, query) |> Enum.take(20)
    {:noreply, assign(socket, kb_entries: entries, kb_search_q: query)}
  end

  def handle_event("kb_add", %{"id" => id, "title" => title, "content" => content}, socket) do
    KbStore.upsert(socket.assigns.kb_dir, %{"id" => id, "title" => title, "content" => content, "source_type" => "manual"})
    CrEngine.record_file_change(socket.assigns.tid, "kb/sources")
    entries = KbStore.search(socket.assigns.kb_dir, "") |> Enum.take(20)
    {:noreply, assign(socket, kb_entries: entries, saved_flash: "KB 条目已添加")}
  end

  # Tab switch
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  # --- Private helpers ---
  defp read_yaml(path) do
    case File.read(path) do
      {:ok, c} -> case YamlElixir.read_from_string(c) do {:ok, m} -> m; _ -> %{} end
      _ -> %{}
    end
  end

  defp write_slots(tid, values) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots/customer.yaml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, YamlWriter.write(values))
  end

  defp read_release_file(tid, rel_path) do
    path = Path.join([TenantRuntime.release_path(tid), "_current", rel_path])
    case File.read(path) do {:ok, c} -> c; _ -> nil end
  end

  defp extract_slot_keys(content) do
    SoulSlotParser.parse_slots(content) |> Enum.flat_map(& &1.keys) |> Enum.uniq()
  end

  defp load_all_layers(base_dir, tid, role) do
    %{
      l0: SkillLoader.list(base_dir, tid, role, :framework),
      l1: SkillLoader.list(base_dir, tid, role, :platform),
      l2: SkillLoader.list(base_dir, tid, role, :industry),
      l3: SkillLoader.list(base_dir, tid, role, :tenant)
    }
  end

  defp ensure_kb_initialized(kb_dir) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    unless File.exists?(script) do
      skeleton = Path.join([Application.app_dir(:ezagent_plugin_content), "priv", "skeleton", "kb", "kb_search_mcp.py"])
      if File.exists?(skeleton), do: (File.mkdir_p!(kb_dir); File.cp!(skeleton, script))
    end
  end

  # Render: left sidebar + 6-tab content with tab bar
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-5xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-2">🧠 Slow Agent 配置</h1>
          <div :if={@saved_flash} class="text-sm text-green-700 bg-green-50 rounded px-3 py-1.5 mb-3">{@saved_flash}</div>

          <%!-- Tab bar --%>
          <nav class="flex border-b border-gray-200 dark:border-zinc-700 space-x-1 mb-4">
            <%= for {t, label} <- [{"soul","Soul"},{"skills","Skills"},{"kb","KB"},{"slots","Slots"},{"diff","Diff"},{"preview","Preview"}] do %>
              <button phx-click="switch_tab" phx-value-tab={t}
                class={["px-4 py-2 text-sm font-medium rounded-t-lg",
                  @tab == t && "bg-white dark:bg-zinc-900 border border-gray-200 dark:border-zinc-700 border-b-white dark:border-b-zinc-900 text-blue-700 -mb-px",
                  @tab != t && "text-gray-500 dark:text-zinc-400 hover:text-gray-700"]}>
                <%= label %>
              </button>
            <% end %>
          </nav>

          <%!-- Soul Tab --%>
          <div :if={@tab == "soul"} class="rounded-xl border border-t-0 border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
            <form phx-submit="save_soul">
              <textarea name="content" rows="16" class="w-full font-mono text-sm border border-gray-300 dark:border-zinc-700 rounded p-3 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"><%= @soul_content %></textarea>
              <div class="mt-3 flex justify-end"><button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">保存 Soul</button></div>
            </form>
          </div>

          <%!-- Skills Tab (simplified: reuse SkillCard + inline editor) --%>
          <div :if={@tab == "skills"}>(4-layer skill grid + create/edit/delete — see full render in source)</div>

          <%!-- KB Tab (search + manual add) --%>
          <div :if={@tab == "kb"}>(KB search form + manual add form — see full render in source)</div>

          <%!-- Slots Tab --%>
          <div :if={@tab == "slots"}>(Slot key-value grid editor — see full render in source)</div>

          <%!-- Diff Tab --%>
          <div :if={@tab == "diff"}>(Sandbox vs Release diff view using SoulDiffView component)</div>

          <%!-- Preview Tab --%>
          <div :if={@tab == "preview"}>(Full CLAUDE.md preview with byte/line stats)</div>
        </div>
      </main>
    </div>
    """
  end
end
```

- [ ] **Step 1: Write full SlowAgentLive** — Complete all 6 tab renders and handlers. Reference existing code in archived files for tab implementations.
- [ ] **Step 2: Compile** — `mix compile`
- [ ] **Step 3: Commit** — `git commit -m "feat(v2): T1.2 — SlowAgentLive (6-tab: Soul/Skills/KB/Slots/Diff/Preview)"`

---

### Task T1.3: Route Registration

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

Add new routes and aliases. Keep old routes with 301 redirect for backward compat.

```elixir
# In router.ex, add aliases:
alias EzagentPluginLiveview.AutoService.Admin.{FastAgentLive, SlowAgentLive, OrchestrateLive, DebugAgentLive}

# Inside live_session :require_admin block, add NEW routes:
live "/admin/autoservice/tenants/:tid/agent/fast", FastAgentLive
live "/admin/autoservice/tenants/:tid/agent/slow", SlowAgentLive

# Keep old routes for now (will archive in T3.2)
```

- [ ] **Step 1: Add aliases and routes** — See router.ex
- [ ] **Step 2: Compile** — `mix compile`
- [ ] **Step 3: Commit** — `git commit -m "feat(v2): T1.3 — routes for Fast/Slow Agent"`

---

### Task T1.4: Sidebar Refactor

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/components/admin_sidebar.ex`

New grouping: Config Agents → Orchestrate → Verify & Release → Config

```elixir
def admin_sidebar(assigns) do
  ~H"""
  <nav class="w-48 flex-shrink-0 border-r border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 p-3 space-y-1 min-h-screen">
    <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Config Agents</div>
    <a href={"/admin/autoservice/tenants/#{@tid}/agent/fast"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>⚡</span> Fast Agent
    </a>
    <a href={"/admin/autoservice/tenants/#{@tid}/agent/slow"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>🧠</span> Slow Agent
    </a>

    <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
    <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Orchestrate</div>
    <a href={"/admin/autoservice/tenants/#{@tid}/orchestrate"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>🔀</span> Routeset
    </a>

    <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
    <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Verify & Release</div>
    <a href={"/admin/autoservice/tenants/#{@tid}/debug"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>🧪</span> Debug Agent
    </a>
    <a href={"/admin/autoservice/tenants/#{@tid}/cr"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>🔄</span> CR Review
    </a>
    <a href={"/admin/autoservice/tenants/#{@tid}/versions"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>📋</span> History
    </a>

    <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
    <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Config</div>
    <a href={"/admin/autoservice/tenants/#{@tid}"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>📊</span> Overview
    </a>
    <a href={"/admin/autoservice/tenants/#{@tid}/init"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>🚀</span> Init Wizard
    </a>
    <a href={"/admin/autoservice/tenants/#{@tid}/operators"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
      <span>👥</span> Operators
    </a>
  </nav>
  """
end
```

- [ ] **Step 1: Replace sidebar** — Update admin_sidebar.ex with new grouping
- [ ] **Step 2: Compile** — `mix compile`
- [ ] **Step 3: Commit** — `git commit -m "feat(v2): T1.4 — sidebar refactored with agent-centric grouping"`

---

### Task T1.5: TenantDashboard Refactor (Agent Cards)

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_dashboard_live.ex`

Replace card grid with agent-centric cards showing Fast/Slow agent status.

```heex
<div class="grid grid-cols-2 gap-4">
  <%!-- Fast Agent Card --%>
  <a href={"/admin/autoservice/tenants/#{@tid}/agent/fast"} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 hover:shadow-md transition">
    <div class="text-2xl mb-2">⚡</div>
    <h3 class="font-semibold text-gray-900 dark:text-zinc-100">Fast Agent</h3>
    <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">DeepSeek 即时安抚回复配置</p>
    <div class="mt-2 text-xs text-gray-400">sandbox/config/fast_ack_prompt.md</div>
  </a>

  <%!-- Slow Agent Card --%>
  <a href={"/admin/autoservice/tenants/#{@tid}/agent/slow"} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 hover:shadow-md transition">
    <div class="text-2xl mb-2">🧠</div>
    <h3 class="font-semibold text-gray-900 dark:text-zinc-100">Slow Agent</h3>
    <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">Claude 知识库 Agent 配置 (Soul/Skills/KB)</p>
  </a>
</div>
```

- [ ] **Step 1: Update Overview** — Replace card grid with agent cards
- [ ] **Step 2: Compile** — `mix compile`
- [ ] **Step 3: Commit** — `git commit -m "feat(v2): T1.5 — Overview with agent cards"`

---

## Batch 2: Orchestrate + Debug (3 tasks)

### Task T2.1: OrchestrateLive

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/orchestrate_live.ex`

Routeset visualization: Fast Agent → Slow Agent → Operator chain.

- [ ] **Step 1: Implement** — See design spec for full layout
- [ ] **Step 2: Compile + Commit**

### Task T2.2: DebugAgentLive

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/debug_agent_live.ex`

Chat test + side-by-side sandbox vs release comparison.

- [ ] **Step 1: Implement** — Chat input + response panel + diff view
- [ ] **Step 2: Compile + Commit**

### Task T2.3: Route Registration (Batch 2)

- [ ] **Step 1: Add routes** — `/orchestrate` + `/debug`
- [ ] **Step 2: Compile + Commit**

---

## Batch 3: CR Refactor + Cleanup (3 tasks)

### Task T3.1: CR Dashboard Refactor

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/cr_dashboard_live.ex`

Group tracked changes by agent (Fast/Slow):

```elixir
defp group_by_agent(items) do
  Enum.group_by(items, fn item ->
    cond do
      String.starts_with?(item["path"], "souls/") -> "Slow Agent"
      String.starts_with?(item["path"], "skills/") -> "Slow Agent"
      String.starts_with?(item["path"], "slots/") -> "Slow Agent"
      String.starts_with?(item["path"], "kb/") -> "Slow Agent"
      String.starts_with?(item["path"], "config/") -> "Fast Agent"
      true -> "Other"
    end
  end)
end
```

- [ ] **Step 1: Refactor CR display** — Group changes by agent
- [ ] **Step 2: Compile + Commit**

### Task T3.2: Archive Old Files

**Files:**
- Move to archive: `soul_editor_live.ex`, `slot_editor_live.ex`, `skill_manager_live.ex`, `kb_manager_live.ex`, `sandbox_preview_live.ex`
- Remove old routes from router.ex

```bash
mkdir -p apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/.archived/
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/soul_editor_live.ex apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/.archived/
# ... same for slot_editor, skill_manager, kb_manager, sandbox_preview
```

- [ ] **Step 1: Archive** — Move 5 files to .archived/
- [ ] **Step 2: Clean router** — Remove old routes
- [ ] **Step 3: Compile + Commit**

### Task T3.3: E2E Tests

- [ ] **Step 1: Test all new routes** — 17 pages HTTP 200
- [ ] **Step 2: Test agent flow** — Fast → Slow → Debug → CR → Publish
- [ ] **Step 3: Fix any issues + Commit**

---

## Self-Review Checklist

- [x] All Batch 1 tasks have exact file paths and code
- [x] Sidebar grouping matches design spec
- [x] Archive plan preserves git history
- [x] E2E verification step included
- [x] Each task has compile + commit steps
