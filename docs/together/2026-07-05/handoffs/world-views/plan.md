# world 通用消费 SessionViewRegistry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 world 会话面板通用消费 `Ezagent.UI.SessionViewRegistry`——枚举 caller 可见的 SessionView 出动态 tab，按声明的 render mode 渲染内容，cap 门不绕过，chat/pty/page 现有面平滑迁到 registry 驱动。

**Architecture:** 两平面。枚举平面：world server 用 `applicable_views/2`（已含 `applies_to?` + `authorize_view/3` cap 门）出 tab 列表，序列化进 world_state；`switch_view` 白名单改成动态 id 集。渲染平面：每 view classify 成 `chat|pty|external|unsupported` mode，React 按 mode 分派到原生组件 / 外部 iframe / 占位。chat 注册一个 world-owned `ConversationView` 让它也进 registry。

**Tech Stack:** Elixir/OTP（`ezagent_plugin_world`）、Phoenix.Component（SessionView 契约）、React/TypeScript + Vite（world assets）、lucide-react（图标）、ExUnit、Playwright（真浏览器 e2e）。

## Global Constraints

- 分支 `feat/sw-world-views`；worktree `/home/yaosh/projects/ezagent-biz/.claude/worktrees/sw-world-views`。基线 `bf5e03e9`。
- **自包含边界**：只改 `apps/ezagent_plugin_world/`（+ registry owner `apps/ezagent_domain_ui/` 允许，但本计划 0 改动）。**禁止**碰 core / `ezagent_domain_session` / `ezagent_plugin_hello` / `ezagent_domain_socialware` / 其它 plugin。
- **不动** SessionView 契约（`session_view.ex`）、registry API（`session_view_registry.ex`）。
- registry `applicable_views/2` = `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex:92`（caller-aware，双过滤）。`external_render?/1` = `:134`。`authorize_view/3` = `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex:120`。
- 测试从 umbrella 根跑，不 `cd` 进 app：`mise exec -- mix test apps/ezagent_plugin_world/test/...`。先 `docker start ezagent-pg-compat-audit-postgres` + `mise exec -- mix ecto.migrate`。
- **别 git commit**（Allen 来 commit）；计划里 "Commit" step 保留为交付节奏标记，实施者按 dev-together 约定处理（或只 `git add` 暂存、不 push）。
- 不 silent 失败；`unsupported` view 出诚实占位，不静默隐藏。

---

## File Structure

- `apps/ezagent_plugin_world/mix.exs` — 加 `{:ezagent_domain_ui, in_umbrella: true}` dep。
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_view.ex`（新）— world-owned `Ezagent.World.ConversationView`（chat 进 registry）。
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex` — 加 `session_views/2`、`session_view_ids/2`、`render_mode/2`；`state_for/2` 出 `"views"`。
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex` — `switch_view/3` 改动态白名单。
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex` — `start/2` 注册 ConversationView（+ dev/test guard 下的 TestView）。
- `apps/ezagent_plugin_world/lib/ezagent/world/test_view.ex`（新，dev/test only）— e2e 用的通用 test SessionView。
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` — 动态 tab 条 + mode 分派 + `ExternalSurfaceView`。
- `apps/ezagent_plugin_world/assets/src/main.tsx` — `views` 类型（若有集中的 state 类型）。
- 测试：`apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs`（新）、`.../conversation_data_test.exs`（扩）、`.../conversation_actions_test.exs`（扩）。
- e2e：`e2e/2026-07-05/world-views/`（Playwright 脚本 + 截图）。

---

## Stage 1 — world server 读 registry 出动态 tab 数据

### Task 1: world 依赖 domain_ui + 注册 ConversationView（chat 进 registry）

**Files:**
- Modify: `apps/ezagent_plugin_world/mix.exs:40-56`
- Create: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_view.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:12-13`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs`

**Interfaces:**
- Produces: `Ezagent.World.ConversationView` implementing `Ezagent.UI.SessionView`（`id/0 → :conversation`, `label/0 → "Chat"`, `icon/0 → "message-square"`, `applies_to?/1 → true`, `view_behavior/0 → nil`, `render/1 → stub`）。注册后 `SessionViewRegistry.lookup(:conversation) == {:ok, Ezagent.World.ConversationView}`。

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs
defmodule Ezagent.World.ConversationViewTest do
  use ExUnit.Case, async: false

  alias Ezagent.UI.SessionViewRegistry
  alias Ezagent.World.ConversationView

  setup do
    :ok = SessionViewRegistry.init()
    :ok = SessionViewRegistry.register(ConversationView)
    :ok
  end

  test "declares the chat view contract" do
    assert ConversationView.id() == :conversation
    assert ConversationView.label() == "Chat"
    assert ConversationView.icon() == "message-square"
    assert ConversationView.view_behavior() == nil
    assert ConversationView.applies_to?(Ezagent.URI.session("acme", "default", "s1")) == true
  end

  test "is discoverable in the registry after registration" do
    assert {:ok, ConversationView} = SessionViewRegistry.lookup(:conversation)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs`
Expected: FAIL — `Ezagent.World.ConversationView` undefined (module not created; and `mix.exs` may not yet see `Ezagent.UI.*`).

- [ ] **Step 3a: Add the domain_ui dep**

In `apps/ezagent_plugin_world/mix.exs` deps list (after `{:ezagent_domain_session, in_umbrella: true},`), add:

```elixir
      {:ezagent_domain_ui, in_umbrella: true},
```

- [ ] **Step 3b: Create ConversationView**

```elixir
# apps/ezagent_plugin_world/lib/ezagent/world/conversation_view.ex
defmodule Ezagent.World.ConversationView do
  @moduledoc """
  world-owned `SessionView` for the chat stream, registered so the chat tab is
  enumerated through `Ezagent.UI.SessionViewRegistry` like every other view
  (rather than being a hard-coded world-native default).

  world renders the chat content in React (`Conversation.tsx`), NOT through this
  `render/1` — the HEEx below is a契约-satisfying stub for the (retired)
  admin_live host. Not cap-gated (`view_behavior/0 → nil`): chat is visible to
  any caller who can see the session.
  """
  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :conversation

  @impl true
  def label, do: "Chat"

  @impl true
  def icon, do: "message-square"

  @impl true
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false

  @impl true
  def view_behavior, do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="world-conversation-view" class="flex-1 min-h-0">
      <!-- world renders chat in React; this stub only satisfies the contract. -->
    </div>
    """
  end
end
```

- [ ] **Step 3c: Register it in world Application.start/2**

Replace `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:12-13`:

```elixir
  @impl Application
  def start(type, args) do
    with {:ok, pid} <- do_boot(type, args) do
      register_session_views()
      {:ok, pid}
    end
  end

  defp do_boot(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # world consumes the SessionView registry (owned by ezagent_domain_ui, which
  # boots first as a declared dep). Registering ConversationView here makes chat
  # a first-class registry view enumerated alongside pty/page/etc.
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok
  end
```

(If `Ezagent.Plugin.boot/1` returns bare `{:ok, pid}`, the `with` matches; if it can return `{:error, _}`, that短路 unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/mix.exs apps/ezagent_plugin_world/lib/ezagent/world/conversation_view.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex apps/ezagent_plugin_world/test/ezagent/world/conversation_view_test.exs
git commit -m "feat(world): register world-owned ConversationView so chat enumerates via SessionViewRegistry"
```

---

### Task 2: `ConversationData.session_views/2` + `render_mode/2` + `session_view_ids/2`

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:38-70`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`

**Interfaces:**
- Consumes: `Ezagent.UI.SessionViewRegistry.applicable_views(session_uri, caller)` → `[%{id,label,icon,module}]`; `SessionViewRegistry.external_render?(module) → boolean`.
- Produces: `ConversationData.session_views(session_uri, caller_uri) :: [%{"id"=>String,"label"=>String,"icon"=>String,"mode"=>String}]`; `ConversationData.session_view_ids(session_uri, caller_uri) :: [String]`. `mode ∈ {"chat","pty","external","unsupported"}`.

- [ ] **Step 1: Write the failing test**

```elixir
# append to apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs
describe "session_views/2 (registry-driven tabs)" do
  defmodule AlwaysView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component
    def id, do: :test_always
    def label, do: "Always"
    def icon, do: "sparkles"
    def applies_to?(%URI{}), do: true
    def applies_to?(_), do: false
    def view_behavior, do: nil
    def render(assigns), do: ~H""
  end

  defmodule ExternalView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component
    def id, do: :test_external
    def label, do: "Ext"
    def icon, do: "panel-top"
    def applies_to?(%URI{}), do: true
    def applies_to?(_), do: false
    def view_behavior, do: nil
    def external_render?, do: true
    def external_render(_uri), do: %{"type" => "text"}
    def render(assigns), do: ~H""
  end

  setup do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok = Ezagent.UI.SessionViewRegistry.register(AlwaysView)
    :ok = Ezagent.UI.SessionViewRegistry.register(ExternalView)
    %{session: Ezagent.URI.session("acme", "default", "s1")}
  end

  test "enumerates applicable views with classified mode", %{session: s} do
    views = Ezagent.World.ConversationData.session_views(s, nil)
    by_id = Map.new(views, &{&1["id"], &1})

    assert by_id["conversation"]["mode"] == "chat"
    assert by_id["conversation"]["label"] == "Chat"
    assert by_id["test_always"]["mode"] == "unsupported"
    assert by_id["test_external"]["mode"] == "external"
  end

  test "session_view_ids/2 returns just the id strings", %{session: s} do
    ids = Ezagent.World.ConversationData.session_view_ids(s, nil)
    assert "conversation" in ids
    assert "test_external" in ids
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
Expected: FAIL — `ConversationData.session_views/2` undefined.

- [ ] **Step 3: Implement in `conversation_data.ex`**

Add module attr near top (after `@message_limit 50`):

```elixir
  # world-native React renderers keyed by view id; other ids classify by target.
  @native_react_ids %{conversation: "chat", pty: "pty"}
```

Add public functions (near `state_for/2`):

```elixir
  @doc """
  The registry-driven view tabs for `session_uri` visible to `caller_uri`.

  Delegates enumeration + `applies_to?` + cap-gate to
  `Ezagent.UI.SessionViewRegistry.applicable_views/2`; world only classifies each
  view into a render `mode` the React side knows how to draw.
  """
  @spec session_views(URI.t(), URI.t() | nil) :: [map()]
  def session_views(%URI{} = session_uri, caller_uri) do
    session_uri
    |> Ezagent.UI.SessionViewRegistry.applicable_views(view_caller(caller_uri))
    |> Enum.map(fn %{id: id, label: label, icon: icon, module: mod} ->
      %{
        "id" => Atom.to_string(id),
        "label" => label,
        "icon" => icon,
        "mode" => render_mode(id, mod)
      }
    end)
  end

  @doc "The visible view id strings for `session_uri`/`caller_uri` (the switch_view whitelist source)."
  @spec session_view_ids(URI.t(), URI.t() | nil) :: [String.t()]
  def session_view_ids(%URI{} = session_uri, caller_uri) do
    session_uri |> session_views(caller_uri) |> Enum.map(& &1["id"])
  end

  defp render_mode(id, mod) do
    cond do
      Map.has_key?(@native_react_ids, id) -> Map.fetch!(@native_react_ids, id)
      id in [:page, :hello_page] -> "external"
      external_render_view?(mod) -> "external"
      true -> "unsupported"
    end
  end

  defp external_render_view?(mod) do
    Ezagent.UI.SessionViewRegistry.external_render?(mod)
  rescue
    _ -> false
  end

  defp view_caller(%URI{} = caller), do: caller
  defp view_caller(_), do: nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs
git commit -m "feat(world): ConversationData.session_views/2 — registry-driven tabs with render-mode classification"
```

---

### Task 3: `state_for/2` emits `"views"`, drops `"is_hello"`

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:38-63`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`

**Interfaces:**
- Consumes: `session_views/2` (Task 2).
- Produces: `state_for/2` result map has key `"views"` (list); no longer emits `"is_hello"`. `caller_uri` threaded from opts (already `Map.fetch!(opts, :caller_uri)` at `:32`).

- [ ] **Step 1: Write the failing test**

```elixir
# append to conversation_data_test.exs
test "state_for/2 exposes registry views and no longer emits is_hello" do
  :ok = Ezagent.UI.SessionViewRegistry.init()
  :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
  s = Ezagent.URI.session("acme", "default", "s2")

  state =
    Ezagent.World.ConversationData.state_for(s, %{
      caller_uri: nil,
      workspace_uri: Ezagent.URI.workspace("acme"),
      sessions: []
    })

  assert is_list(state["views"])
  assert Enum.any?(state["views"], &(&1["id"] == "conversation"))
  refute Map.has_key?(state, "is_hello")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
Expected: FAIL — state still has `"is_hello"`, no `"views"`.

- [ ] **Step 3: Edit `state_for/2`**

In the `%{ ... }` map returned by `state_for/2` (`conversation_data.ex:38-55`), replace the `"is_hello"` line (`:54`) with:

```elixir
      # Registry-driven view tabs (Ezagent.UI.SessionViewRegistry). Each entry is
      # %{"id","label","icon","mode"}; mode ∈ chat|pty|external|unsupported. This
      # replaces the hard-coded chat/pty segment + the `is_hello` page probe.
      "views" => session_views(session_uri, caller_uri)
```

Delete the now-dead `page_session?/1` + `has_surface_slice?/1` helpers (`:58-70`) IF no other caller remains
(grep first: `grep -rn "page_session?\|has_surface_slice?" apps/ezagent_plugin_world`). If a test references them,
update that test.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
Expected: PASS. Also run the whole file to catch `page_session?` fallout: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/`.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs
git commit -m "feat(world): state_for/2 emits registry \"views\", drops is_hello probe"
```

---

## Stage 2 — 内容渲染接线（React 侧）

### Task 4: React dynamic tab strip + mode dispatch + ExternalSurfaceView

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:60-75,134-141,424-464,632-636,896-958`
- Modify (types only, if a shared state type exists): `apps/ezagent_plugin_world/assets/src/main.tsx`
- Test: Playwright e2e (Stage 5) — React 无单测 runner（`package.json` 无 test script），逻辑正确性由 e2e + server 单测覆盖。

**Interfaces:**
- Consumes: `state.views: {id:string; label:string; icon:string; mode:string}[]`（Task 3）；`onSwitchView(sessionUri, id)`（已存在 `main.tsx:369`）。
- Produces: 会话面板按 `state.views` 渲染 tab 条；内容按 active view 的 `mode` 分派。

- [ ] **Step 1: Add the `views` type + derive active view/mode**

In `Conversation.tsx` Props/State type (near `active_view?: string | null` at `:66`), add:

```ts
  views?: {id: string; label: string; icon: string; mode: string}[]
```

Replace `activeView` derivation (`:134`) and `isHelloSession` (`:141`) with:

```ts
  const fallbackViews = [{id: "chat", label: "Chat", icon: "message-square", mode: "chat"}]
  const views = state.views && state.views.length > 0 ? state.views : fallbackViews
  const activeId =
    views.find((v) => v.id === state.active_view)?.id ?? views[0]?.id ?? "chat"
  const activeMode = views.find((v) => v.id === activeId)?.mode ?? "chat"
```

- [ ] **Step 2: Add an icon lookup**

Near the top imports, add a lucide-react icon map (reuse icons already imported — `MessageSquare`, `TerminalSquare`, plus add `Route`, `Link2`, `PanelTop`, `Sparkles`, `LayoutGrid`):

```ts
  const ICONS: Record<string, React.ComponentType<{className?: string; "aria-hidden"?: boolean}>> = {
    "message-square": MessageSquare,
    terminal: TerminalSquare,
    route: Route,
    link: Link2,
    "panel-top": PanelTop,
    sparkles: Sparkles,
  }
  const iconFor = (name: string) => ICONS[name] ?? LayoutGrid
```

- [ ] **Step 3: Replace the hard-coded tab segment (`:424-433`) with a generic strip**

```tsx
            <div className="inline-flex items-center rounded-[10px] border border-border bg-muted p-[3px]" aria-label="Session view">
              {orderViews(views).map((v) => {
                const Icon = iconFor(v.icon)
                return (
                  <button
                    key={v.id}
                    type="button"
                    className={segmentClass(activeId === v.id)}
                    onClick={() => sessionUri && onSwitchView(sessionUri, v.id)}
                    aria-label={`Show ${v.label}`}
                  >
                    <Icon aria-hidden={true} className="h-[15px] w-[15px]" />
                    {v.label}
                  </button>
                )
              })}
            </div>
```

Add a stable order helper (conversation first, pty second, rest by id):

```ts
  const orderViews = (vs: {id: string}[]) => {
    const rank = (id: string) => (id === "conversation" ? 0 : id === "pty" ? 1 : 2)
    return [...vs].sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id))
  }
```

- [ ] **Step 4: Dispatch content by `activeMode`**

Replace the `activeView === "pty" ? (...) : (...)` block (`:449-638`) so the top-level switch is on `activeMode`:
- `activeMode === "pty"` → existing `<div data-world-subcomponent="pty_terminal"><PtyTerminalSurface .../></div>` (`:454-464`).
- `activeMode === "external"` → `<ExternalSurfaceView sessionUri={sessionUri} onPublishTemplate={onPublishTemplate} />` (full-pane, replaces the old `isHelloSession` split-pane `:632-636`; DELETE that split-pane).
- `activeMode === "unsupported"` → placeholder:

```tsx
          <div className="flex flex-1 items-center justify-center p-8 text-sm text-muted-foreground">
            此视图暂无网页渲染器 / This view has no web renderer yet.
          </div>
```

- default (`"chat"`) → the existing chat stream JSX (the current `else` branch minus the hello split-pane).

- [ ] **Step 5: Generalize `HelloPagePreview` → `ExternalSurfaceView`**

Rename the `HelloPagePreview` function (`:896`) to `ExternalSurfaceView`; keep the iframe `src = /socialware/external?session_uri=…` (`:903`), the open-in-tab overlay, and the publish-as-template control (they're operator affordances, still valid). Remove hello-specific copy. Update the one call site (now in the `external` branch).

- [ ] **Step 6: Build the assets**

Run: `cd apps/ezagent_plugin_world/assets && npm run build` (or the project's Vite build task — check `package.json` scripts).
Expected: build succeeds, no TS errors.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_plugin_world/assets/src/components/Conversation.tsx apps/ezagent_plugin_world/assets/src/main.tsx
git commit -m "feat(world): React dynamic tab strip + render-mode dispatch (chat/pty/external/unsupported)"
```

---

## Stage 3 — 授权 cap 门（switch_view 动态门）

### Task 5: `switch_view/3` uses the dynamic, caller-aware view-id set

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:471-483`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`

**Interfaces:**
- Consumes: `ConversationData.session_view_ids/2` (Task 2); `socket.assigns.current_entity_uri`.
- Produces: `switch_view/3` sets `active_view` only when `view ∈ session_view_ids(session_uri, caller)`; else `error:bad_view`.

- [ ] **Step 1: Write the failing test**

```elixir
# append to conversation_actions_test.exs — build a socket stub with current_entity_uri set
test "switch_view accepts an enumerated view id and rejects an unknown one" do
  :ok = Ezagent.UI.SessionViewRegistry.init()
  :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
  session = Ezagent.URI.session("acme", "default", "sw1")
  socket = build_socket(current_entity_uri: Ezagent.URI.user("acme", "admin"))

  assert {:noreply, ok_socket} =
           Ezagent.World.ConversationActions.switch_view(socket, session, "conversation")
  assert ok_socket.assigns.world_state["active_view"] == "conversation"

  assert {:noreply, bad_socket} =
           Ezagent.World.ConversationActions.switch_view(socket, session, "does_not_exist")
  assert bad_socket.assigns.last_dispatch_status == "error:bad_view"
end
```

(Reuse the existing test's socket-builder helper; if none, add a minimal `build_socket/1` mirroring the file's existing socket stubs.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`
Expected: FAIL — old whitelist rejects `"conversation"` (only `chat|pty|page` allowed).

- [ ] **Step 3: Replace `switch_view/3`**

Replace `conversation_actions.ex:471-483`:

```elixir
  @doc "Switch the active session view. Whitelist is the caller-aware registry set."
  @spec switch_view(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def switch_view(socket, %URI{} = session_uri, view) when is_binary(view) do
    caller = socket.assigns.current_entity_uri

    if view in ConversationData.session_view_ids(session_uri, caller) do
      {:noreply, push_world_state(socket, %{"active_view" => view})}
    else
      {:noreply, assign(socket, :last_dispatch_status, "error:bad_view")}
    end
  end
```

(`ConversationData` alias already imported at `conversation_actions.ex:21`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs
git commit -m "feat(world): switch_view uses caller-aware registry view-id whitelist (cap gate, no bypass)"
```

---

## Stage 4 — 现有 view 迁移验证（不破坏现有行为）

### Task 6: Integration test — hello/pty/chat 迁 registry 后仍正确 + cap 门

**Files:**
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs` (new `describe`)

**Interfaces:**
- Consumes: `session_views/2`, `authorize_view/3` cap gate. Uses a cap-gated view (a test double with `view_behavior` returning a module whose `actions/0` declares a render action) to assert filtering.

- [ ] **Step 1: Write the failing test (cap-gated view filtered for uncapped caller)**

```elixir
describe "cap-gated view filtering (migration safety)" do
  defmodule GatedRender do
    def actions, do: [:some_render]
  end

  defmodule GatedView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component
    def id, do: :test_gated
    def label, do: "Gated"
    def icon, do: "panel-top"
    def applies_to?(%URI{}), do: true
    def applies_to?(_), do: false
    def view_behavior, do: GatedRender
    def render(assigns), do: ~H""
  end

  setup do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok = Ezagent.UI.SessionViewRegistry.register(GatedView)
    %{session: Ezagent.URI.session("acme", "default", "gated1")}
  end

  test "an uncapped caller does NOT see the gated view", %{session: s} do
    ids = Ezagent.World.ConversationData.session_view_ids(s, Ezagent.URI.user("acme", "nobody"))
    assert "conversation" in ids
    refute "test_gated" in ids
  end

  test "a nil (anon) caller does NOT see the gated view", %{session: s} do
    ids = Ezagent.World.ConversationData.session_view_ids(s, nil)
    refute "test_gated" in ids
  end
end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
Expected: PASS immediately IF Tasks 2–3 correctly delegate to `applicable_views/2` (the cap gate lives in
`authorize_view/3`, already implemented). This test is a **regression guard** proving world doesn't bypass the gate.
If it FAILS, world is not using `applicable_views/2` — fix Task 2.

- [ ] **Step 3: No new impl if green** — this task locks the contract; only fix if red.

- [ ] **Step 4: Run the whole world test dir**

Run: `mise exec -- mix test apps/ezagent_plugin_world/test`
Expected: PASS (no regressions in `conversation_data_visibility_test.exs` etc.).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs
git commit -m "test(world): lock cap-gate — uncapped/anon caller cannot see a gated view tab"
```

---

## Stage 5 — 真浏览器 Playwright e2e（禁 stub，每 stage 截图）

### Task 7: Dev-only TestView + Playwright e2e proving generic enumeration + cap gate

**Files:**
- Create: `apps/ezagent_plugin_world/lib/ezagent/world/test_view.ex` (dev/test env-guarded)
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex` (`register_session_views/0` — register TestView only in dev/test)
- Create: `e2e/2026-07-05/world-views/world_views_spec.mjs` (Playwright) + screenshots dir

**Interfaces:**
- Produces: `Ezagent.World.TestView`（id `:test_view`, label "Test", icon "sparkles", `applies_to? → true`, `view_behavior → nil` → mode `unsupported`）visible ONLY when `Mix.env() in [:dev, :test]` (guard at register site, NOT in the module).

- [ ] **Step 1: Create the TestView module**

```elixir
# apps/ezagent_plugin_world/lib/ezagent/world/test_view.ex
defmodule Ezagent.World.TestView do
  @moduledoc """
  Dev/test-only generic SessionView, registered behind a `Mix.env()` guard, used
  by the world-views e2e to prove world enumerates ANY registered view into a tab
  with NO world code change per-view. Not shipped in prod.
  """
  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :test_view
  @impl true
  def label, do: "Test"
  @impl true
  def icon, do: "sparkles"
  @impl true
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false
  @impl true
  def view_behavior, do: nil
  @impl true
  def render(assigns), do: ~H"<div id=\"world-test-view\">test view</div>"
end
```

- [ ] **Step 2: Register it behind a guard in `register_session_views/0`**

```elixir
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    if Mix.env() in [:dev, :test] do
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.TestView)
    end
    :ok
  end
```

- [ ] **Step 3: Bring up the real stack**

```bash
docker start ezagent-pg-compat-audit-postgres
mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
cd apps/ezagent_plugin_world/assets && npm run build && cd -
mise exec -- iex -S mix phx.server   # dev, port 10042
```

- [ ] **Step 4: Write the Playwright spec** (`e2e/2026-07-05/world-views/world_views_spec.mjs`)

Cover, screenshotting each meaningful step into `e2e/2026-07-05/world-views/`:
1. `page.goto("http://localhost:10042")`, log in `admin@ezagent.chat` / `worlddev`. Screenshot `01-login.png`.
2. Open/create a session, open `/sessions?session=…`. Assert a **"Test" tab** is present (`getByRole("button", {name: /Show Test/})`). Screenshot `02-test-tab-present.png`. Click it, assert `#world-test-view`-equivalent unsupported placeholder or test content. Screenshot `03-test-tab-content.png`.
3. Open a hello session (create from the hello template / the boot-published hello). Assert tabs include **Chat** and **Page** (`hello_page`), and PTY only if a PTY-backed member exists. Screenshot `04-hello-tabs.png`. Click **Page**, assert the iframe renders the real page (`iframe[title="Rendered page"]` with committed surface). Screenshot `05-page-rendered.png`.
4. **cap gate**: as an anon/non-member viewer of the SAME public hello session (separate browser context, the public share URL), assert **no Page tab** (or Page tab absent) — cap-gated `hello_page` dropped. Screenshot `06-anon-no-page-tab.png`. Back as owner, Page tab present. Screenshot `07-owner-page-tab.png`.
5. Switch Chat ↔ Page ↔ Test, asserting content swaps each time. Screenshot `08-switch-chat.png`, `09-switch-page.png`.

- [ ] **Step 5: Run the e2e**

Run: `npx playwright test e2e/2026-07-05/world-views/world_views_spec.mjs`
Expected: all assertions PASS; screenshots present in `e2e/2026-07-05/world-views/`.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/test_view.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex e2e/2026-07-05/world-views/
git commit -m "test(world): dev-only TestView + Playwright e2e — generic tab enumeration, page render, cap gate"
```

---

## Self-Review

- **Spec coverage:** §4 动态 tab → Tasks 1–3, 5. §5 内容渲染 → Task 4. §5.2/授权 → Tasks 5–6. §6 兼容迁移 → Tasks 1(chat)/3(page)/6(regression). §9.2 e2e → Task 7. §8 边界（只 world）→ all tasks touch `apps/ezagent_plugin_world/` only (mix.exs adds a domain_ui dep — an in-umbrella reference, not a domain_ui code change).
- **Placeholder scan:** every code step shows full code; no TBD/TODO.
- **Type consistency:** `session_views/2` returns `%{"id","label","icon","mode"}` used identically in Task 3 (`"views"`), Task 4 (`state.views` type), Task 5 (`session_view_ids/2`). `render_mode/2` values `chat|pty|external|unsupported` match React `activeMode` switch. `view_behavior/0 → nil` (not cap-gated) consistent across ConversationView/TestView; GatedView uses a backing module with `actions/0` matching `render_needed_caps/2` (`session_view.ex:154`).
- **Open items (§7 of spec):** routing/external_mirror `unsupported` tabs + double-Page are flagged for Allen, not silently resolved.
