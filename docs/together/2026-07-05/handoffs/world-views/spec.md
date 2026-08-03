# Dev Spec — world 通用消费 SessionViewRegistry

> Branch: `feat/sw-world-views` · Baseline: `bf5e03e9` (skill `project-discussion-ezagent`)
> Owner tier: plugin (`ezagent_plugin_world`) + registry owner (`ezagent_domain_ui`, dep only)
> 关联缺口: ezagent-scout Q8 T15(b)（world 注册了 view 但不消费）+ 更广的 registry 消费

每条断言带 `file:line`（相对仓库根，worktree `.claude/worktrees/sw-world-views`）。

---

## §1 目标

让 world **通用地读取并渲染 socialware / domain 声明的 SessionView**——不是"再加一个 tab"，而是让 world
的会话面板 **消费 `Ezagent.UI.SessionViewRegistry`**：把任何 `applies_to?` 命中且 caller 有权看的
SessionView，通用地出成一条可切 tab，并按其声明的渲染目标把内容画出来。做完后，新注册一个 SessionView
（socialware 声明 view / 插件注册 view）**无需改 world 代码**就能在 world 冒出 tab + 渲染。

非目标（本 spec 不做，明确划走）：
- 不给 routing / external_mirror 两个 operator view 写 world React 专属渲染器（它们只有 HEEx `render/1`，
  world 是 React SPA，画不了 HEEx）——本 spec 让它们**以 registry 通用枚举出 tab**，内容落到 `unsupported`
  占位（诚实暴露，不静默隐藏），是否给它们建 React 渲染器留给 Allen 定后续。
- 不动 SessionView 契约本身（`session_view.ex`）、不动 registry 查询 API（`applicable_views/2` /
  `external_renderers/2` / `external_render?/1` / `authorize_view/3` 已齐，见 §3）。
- 不动 customer-delivery（ExternalFeed / ExternalFeedChannel）、不动 anon-ingress。

---

## §2 起点现状（现读核实，都带 file:line）

### 2.1 契约 + registry 齐（domain_ui，本 spec 不改）

- `Ezagent.UI.SessionView` 契约：`id/0`、`label/0`、`icon/0`、`applies_to?/1`、`render/1`（必选）；
  `external_render?/0`、`external_render/1`、`view_behavior/0`（`@optional_callbacks`
  `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex:99`）。
- 统一授权门 `authorize_view/3`（`session_view.ex:120`）：无 `view_behavior/0`（或 `nil`）→ 不 cap-gate → `true`；
  有 backing ActionSet → caller 必须持该 ActionSet 的 `<sw>_render` cap（读 `Ezagent.Identity.list_caps_for(caller)`
  `session_view.ex:185`；`nil` caller 对 gated view 一律拒 `session_view.ex:182`）。
- registry：`register/1`（`session_view_registry.ex:54`）、`applicable_views/1`（`:70`，无 caller、不过 cap 门）、
  **`applicable_views/2`（`:92`，caller-aware，`applies_to?` + `authorize_view/3` 双过滤）**、
  `external_render?/1`（`:134`，须同时 export `external_render?/0`+`external_render/1` 且返回 true）、
  `external_renderers/1,2`（`:159`/`:179`）、`lookup/1`（`:194`）。

### 2.2 已注册的 SessionView（现状）

- domain_ui 在 `Application.start/2` 注册三个 operator view（`apps/ezagent_domain_ui/lib/ezagent_domain_ui/application.ex:52-63`）：
  - `EzagentDomainUi.Pty.TerminalView`（id `:pty`，`applies_to?` = 有 member 活着 PTY，
    `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex:45-62`；无 `view_behavior` → 不 cap-gate；内部 HEEx render）
  - `EzagentDomainUi.Routing.RoutingView`（id `:routing`，`applies_to?(%URI{}) → true`
    `apps/ezagent_domain_ui/lib/ezagent_domain_ui/routing/routing_view.ex:56`；无 `view_behavior`；内部 HEEx，无 external）
  - `EzagentDomainUi.ExternalMirror.View`（id `:external_mirror`，`applies_to?(%URI{}) → true`
    `apps/ezagent_domain_ui/lib/ezagent_domain_ui/external_mirror/view.ex:51`；无 `view_behavior`；内部 HEEx，无 external）
- hello 注册 `EzagentPluginHello.PageView`（id `:hello_page`，label "Page"，icon "panel-top"，
  **cap-gated** `view_behavior → Ezagent.ActionSet.HelloRender`
  `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex:28`；`applies_to?` = hello session 且有 `:surface` slice
  `page_view.ex:40`；内部 HEEx `phx-hook="HelloRenderer"` `page_view.ex:85`，**未实现 external_render**）；
  注册点 `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:44`。
- `EzagentDomainSocialware.PageView`（id `:page`，`external_render?/0 → true`
  `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex:63`，
  `external_render/1 → Surface.external_tree` `:66`）**定义了但没注册**——registry 里查不到。
- **chat 没有任何注册的 SessionView**（grep 全仓无 `:conversation` view 注册）——chat 是 world React 原生默认面，不在 registry。

### 2.3 world 零消费（本 spec 要补的缺口）

- world 侧 `lib/` 对 `SessionViewRegistry` / `applicable_views` / `SessionView` **零引用**（grep 确认；仅两处 TODO 注释
  `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:475`、
  `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:136` 承认"proper home is Phase 3"）。
- tab 白名单硬编码：`switch_view` 只认 `view in ["chat","pty","page"]`
  （`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:477`）。
- "page" pane 靠 surface-slice 探测的布尔 `"is_hello"`：`ConversationData.state_for/2` 出
  `"is_hello" => page_session?(session_uri)`（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:54`，
  `page_session?` = 有 `:surface` slice 或 URI 含 `/hello/` `:61-63`）。
- React 侧 tab segment 硬编码只有 Chat + PTY 两颗（`Conversation.tsx:424-433`），`activeView` 由
  `state.active_view === "pty" ? "pty" : "chat"` 派生（`:134`）；"page" 不是 tab，是 `isHelloSession` 时挂的右侧
  分栏 `HelloPagePreview`（`:632-636`），内容是 **iframe** 到 `/socialware/external?session_uri=…`（`:903`/`:958`；
  该路由在 web `apps/ezagent_web/lib/ezagent_web/router.ex:159`，cap 在路由侧再核）。
- pty 内容由 React `PtyTerminalSurface`（`Conversation.tsx:455`）画，chat 内容由 `Conversation` 组件自身画——
  **world React 从不消费 SessionView `render/1`（HEEx）**。
- world 会话状态在 `world_live.ex` 的 `conversation_state/3`（`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:784`）
  组装，caller = `socket.assigns.current_entity_uri`，caps = `current_caps`（`:792-793`）。
- world **mix.exs 未声明 `ezagent_domain_ui` 依赖**（`apps/ezagent_plugin_world/mix.exs:40-56`）——要调 registry 需补这条 dep。

### 2.4 关键判定：为什么"通用渲染"是两平面，不是"world 直接渲 HEEx"

SessionView `render/1` 返回 HEEx / `Phoenix.Component`，是给已退役的 LiveView `admin_live` 宿主用的；world 是
React SPA，**结构上画不了 HEEx**。所以"通用消费 registry"在 world 落地 = 拆成两个平面：
- **枚举平面（真·通用）**：tab 列表 100% 由 registry 驱动（`applicable_views/2` 已含 `applies_to?` + cap 门）。
- **渲染平面（按声明的目标分派）**：每个 view 解析出一个 world React 认得的 **render mode**，见 §4。

---

## §3 registry 查询接口（本 spec 只消费，不改）

world 只用这几个已存在的函数（都在 `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex`）：

| 用途 | 函数 | file:line | 说明 |
|---|---|---|---|
| 枚举 caller 可见 view | `applicable_views(session_uri, caller)` | `:92` | 已 `applies_to?` + `authorize_view/3` 双过滤，返回 `[%{id,label,icon,module}]` sorted by id |
| 判定 view 有外部渲染目标 | `external_render?(module)` | `:134` | 用于把 view 归到 `external` mode |
| 单 view 反查 | `lookup(id)` | `:194` | 备用 |

**结论：registry 侧不缺查询 helper**——`applicable_views/2` + `external_render?/1` 已够 world 通用消费。因此
`apps/ezagent_domain_ui/` **本 spec 不改代码**（自包含边界表 §8 允许改它，但计划里不需要）。

---

## §4 动态 tab（枚举平面）

### 4.1 server 侧：world 用 `applicable_views/2` 出 tab 列表

`ConversationData.state_for/2` 用一个新的 `"views"` 数组**替换** `"is_hello"` 布尔
（`conversation_data.ex:54`）：

```elixir
# conversation_data.ex —— state_for/2 里
"views" => session_views(session_uri, caller_uri),
```

新增 `session_views/2`（读 registry，classify mode，序列化给 React）：

```elixir
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

# switch_view 的动态白名单来源（只要 id 集合，不需 mode）
@spec session_view_ids(URI.t(), URI.t() | nil) :: [String.t()]
def session_view_ids(%URI{} = session_uri, caller_uri) do
  session_uri |> session_views(caller_uri) |> Enum.map(& &1["id"])
end

defp view_caller(%URI{} = caller), do: caller
defp view_caller(_), do: nil
```

`caller_uri` 从 `state_for/2` 的 opts 取（world_live 已传 `caller_uri` `world_live.ex:792`）。
**cap 门不在 world 复算**——`applicable_views/2` 内部 `authorize_view/3` 读 identity caps，world 只传 caller URI。

### 4.2 render mode 分类（server 侧，`conversation_data.ex`）

```elixir
# world 认得四种 mode；unknown 内部-HEEx view → "unsupported"（占位，不静默隐藏）
@native_react_ids %{conversation: "chat", pty: "pty"}

defp render_mode(id, mod) do
  cond do
    Map.has_key?(@native_react_ids, id) -> Map.fetch!(@native_react_ids, id)
    id in [:page, :hello_page] -> "external"
    Ezagent.UI.SessionViewRegistry.external_render?(mod) -> "external"
    true -> "unsupported"
  end
end
```

- `"chat"` → world 原生 React 会话流（现有 `Conversation` 组件主体）
- `"pty"` → world 原生 `PtyTerminalSurface`
- `"external"` → 外部 json-render 面（iframe `/socialware/external?session_uri=…`，见 §5）；命中条件：
  `external_render?(mod)`（socialware `:page`）**或** id ∈ `[:page,:hello_page]`（hello page 内部 HEEx 但内容走外部面）
- `"unsupported"` → 无 world React 渲染器的内部-HEEx view（routing / external_mirror）→ React 出诚实占位

### 4.3 chat 也进 registry：注册 world-owned `ConversationView`

chat 现在不在 registry（§2.2）。为让 chat "也走 registry"，world 注册一个**极小** SessionView：

- 新模块 `Ezagent.World.ConversationView`（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_view.ex`）：
  `id → :conversation`、`label → "Chat"`、`icon → "message-square"`、`applies_to?(%URI{}) → true`、
  `view_behavior → nil`（不 cap-gate，人人可见 chat）、`render/1 → 极小 stub HEEx`（world React 不用它，
  moduledoc 注明"world renders chat via React；此 render 仅满足契约/给 admin_live"）。
- 在 world `Application.start/2` 里 `SessionViewRegistry.init()` + `register(Ezagent.World.ConversationView)`
  （镜像 hello `application.ex:44` 的写法）。

排序：registry `applicable_views` 按 id 字母序（`session_view_registry.ex:101`）。tab 顺序由 React 决定
（§5.3 给一个稳定 order：conversation → pty → 其余按 id）。

### 4.4 `switch_view` 改动态白名单（`conversation_actions.ex:477`）

```elixir
def switch_view(socket, %URI{} = session_uri, view) when is_binary(view) do
  caller = socket.assigns.current_entity_uri
  if view in ConversationData.session_view_ids(session_uri, caller) do
    {:noreply, push_world_state(socket, %{"active_view" => view})}
  else
    {:noreply, assign(socket, :last_dispatch_status, "error:bad_view")}
  end
end
```

删掉硬编码 `view in ["chat","pty","page"]`。gate 与 tab 可见性同源（`session_view_ids/2`）——一个 caller 看不到的
cap-gated view，既不冒 tab 也切不过去，**无绕过**。

---

## §5 内容渲染（渲染平面）

### 5.1 判定：world React 怎么消费"内部 vs 外部"

现读结论（§2.4）：world **不嵌 LiveView、不渲 HEEx**。落地方案：

- **内部 target（HEEx `render/1`）**：world React **不消费**。只有 chat / pty 两个 view 在 world 有原生 React 等价物
  （`Conversation` 流 / `PtyTerminalSurface`），按 view id 映射。其余内部-HEEx view（routing / external_mirror）
  → `unsupported` 占位。
- **外部 target（`external_render/1` json-render tree）**：这是 world 通用渲染器的天然落点。world 已有 json-render
  引擎（`apps/ezagent_plugin_world/assets/src/components/JsonRenderBubble.tsx`）。但 hello/socialware 的页面内容
  **已经**通过 iframe `/socialware/external` 的外部 SPA 渲出（`Conversation.tsx:903,958`），该路由已 cap-gate。
  **复用这条已工作的外部面**：`external` mode 的 view 内容 = iframe 到 `/socialware/external?session_uri=…`，
  只是**发现方式从 `is_hello` 布尔改成 registry 枚举**。

> 备选（本 spec 不做，记为后续）：把 `external_render/1` 的 json-render tree 直接 inline 用世界 json-render 引擎画，
> 省掉 iframe。当前 iframe 路径已工作且 cap 在路由再核，先不重写；spec §7 记为 open item。

### 5.2 授权在渲染平面同样不绕过

- tab 可见性：`applicable_views/2` 的 `authorize_view/3`（§3）。
- `external` 内容：iframe 命中 `/socialware/external`，该路由对匿名/登录/成员按 `<sw>_render` cap 分级
  （web `router.ex:159`；skill 记 anon 两层门 `Installation.web_anon_access?` + `anon_view_caps`）。
- 一个 caller 无 `hello_render` cap → hello_page tab 不枚举出来 → 连 iframe 都挂不上。cap 门在**枚举**处已生效，
  渲染处是二次防御。

### 5.3 React 侧改动（`Conversation.tsx` + `main.tsx` 类型）

- `Props`/state 类型加 `views?: {id:string;label:string;icon:string;mode:string}[]`；保留 `active_view?`。
- 删 `activeView = state.active_view === "pty" ? "pty" : "chat"`（`:134`）与 `isHelloSession`（`:141`）派生，改成：
  - `const views = state.views ?? fallbackViews`（`fallbackViews` = `[{id:"chat",...,mode:"chat"}]`，防 server 没送时退化到 chat）
  - `const activeId = views.find(v => v.id === state.active_view)?.id ?? views[0]?.id`
  - `const activeMode = views.find(v => v.id === activeId)?.mode ?? "chat"`
- tab 条：`views.map` 出按钮（`onSwitchView(sessionUri, v.id)`），图标由 `iconFor(v.icon)` 查
  lucide-react（`message-square/terminal/route/link/panel-top/sparkles` → 组件，缺省回退一个通用图标）。
  稳定排序：`conversation` 优先、`pty` 次之、其余按 id。
- 内容区按 `activeMode` 分派：`"chat"` → 现有会话流 JSX；`"pty"` → `PtyTerminalSurface`；
  `"external"` → 复用 `HelloPagePreview` 的 iframe（重命名 `ExternalSurfaceView`，通用化，去掉 hello 专属文案，
  保留 operator overlay: open-in-tab + publish-as-template）；`"unsupported"` → 占位块
  （"此视图暂无网页渲染器 / no web renderer yet"，可选一条到 admin 面的链接）。
- 删掉 `isHelloSession` 右侧分栏（`:632-636`）——page 现在是**一等 tab**（`external` mode），不再是 hello 专属分栏。

---

## §6 兼容 / 迁移（现有 view 平滑切到 registry 驱动）

| 现有 view | 现在怎么渲 | 切到 registry 后 | 行为 delta（需在 handoff/PR 标出） |
|---|---|---|---|
| chat | React 原生默认面，不在 registry | 注册 `Ezagent.World.ConversationView`（§4.3），mode `chat`，人人可见 | 无功能变化（chat 永远枚举出、永远第一颗） |
| pty | 硬编码 segment 永远显示 | registry `:pty`，`applies_to?` = 有活 PTY member（`terminal_view.ex:45`），mode `pty` | **PTY tab 变有条件**：没活 PTY member 的 session 不再显示 PTY tab（正确性修正，但可见 delta） |
| page（hello） | `is_hello` 布尔挂右侧 iframe 分栏 | registry `:hello_page`（cap-gated），mode `external`，一等 tab | page 从"右侧常驻分栏"变"可切 tab"；对无 `hello_render` cap 的 caller 不再出现 |
| routing | 内嵌在 chat 面（`routing_rules` 表单，`Conversation.tsx:795`） | registry `:routing`（always applies），mode `unsupported` | **新冒一颗 routing tab**（占位）——见 §7 open item，Allen 定是否建 React 渲染器/或过滤 |
| external_mirror | world 现在完全不显示 | registry `:external_mirror`（always applies），mode `unsupported` | **新冒一颗 bindings tab**（占位）——同上 |
| socialware `:page` | 未注册，world 不显示 | 若未来注册 → mode `external`（`external_render?/0 == true`），一等 tab | 本 spec 不注册它（保持现状）；注册与否是 socialware 域的事 |

role-slot #1180/#1185 已落地，**不影响本改动**（本 spec 不碰 Definition / recipe / role 路径，只读 registry + 会话 slice）。
registry P1/P2（#1173/#1176 versioned artifact / content-hash install）**与本 spec 无关**（那是 socialware
分发/安装侧，不是 UI view registry）。

---

## §7 Open items（标出等 Allen，不自作主张）

1. **routing / external_mirror 的 `unsupported` tab**：通用枚举会让这俩 operator view 在 world 冒 tab 但无 React
   渲染器。本 spec 选"诚实占位"（不静默隐藏，符合"通用消费"）。Allen 可选：(a) 建 world React 渲染器（更大改动，
   另开 handoff）；(b) 给 registry 加一个"world 可渲染"过滤维度。**先按占位落地**。
2. **hello_page(`:hello_page`) vs socialware `:page` 双 "Page" tab**：都 label "Page"/icon "panel-top"。当前
   socialware `:page` 没注册，不冲突；若将来两者都注册到同一 hello session，会出两颗 Page tab。建议后续 dedupe
   （优先 cap-gated 的 hello_page）。本 spec 不处理（现状不冲突）。
3. **external 内容 iframe vs inline json-render**：§5.1 备选。先复用 iframe。

---

## §8 自包含边界表

| app | 层 | 本 spec 动它吗 | 改什么 |
|---|---|---|---|
| `ezagent_plugin_world` | plugin（owner） | ✅ 改 | mix.exs 加 `ezagent_domain_ui` dep；Application 注册 ConversationView；ConversationData（views/session_views/render_mode）；ConversationActions（switch_view 动态门）；新模块 ConversationView；Conversation.tsx / main.tsx（tab 条 + mode 分派 + ExternalSurfaceView）；测试 |
| `ezagent_domain_ui` | domain（registry owner） | ⚠️ 允许但不需要 | `applicable_views/2` + `external_render?/1` 已够；**计划里 0 改动** |
| core / 其它 domain / 其它 plugin | — | ❌ 禁止 | 不碰 |

**硬边界**：只改 `apps/ezagent_plugin_world/`（+ 若真缺 helper 才 `apps/ezagent_domain_ui/`，现判定不缺）。
禁止碰 `ezagent_core`、`ezagent_domain_session`、`ezagent_plugin_hello`（其 PageView 已按"world 通用消费"写好，
moduledoc `page_view.ex:14-16` 明说"world renders any registered SessionView generically, so this needs no edit to
world"——正是本 spec 要兑现的前提，不用改 hello）、`ezagent_domain_socialware` 等。

---

## §9 测试策略

### 9.1 server 单元/集成（ExUnit，`apps/ezagent_plugin_world/test/`）

- `ConversationData.session_views/2`：注册一组 view（含 always-applies、cap-gated、external）后，断言返回的
  `[%{"id","label","icon","mode"}]` 命中/过滤/mode 分类正确；caller 无 cap → cap-gated view 不在结果。
- `ConversationData.session_view_ids/2`：与 `session_views/2` 同源。
- `render_mode/2`：`:conversation→"chat"`、`:pty→"pty"`、`:page/:hello_page/external_render?→"external"`、
  未知内部→`"unsupported"`。
- `ConversationActions.switch_view/3`：view id ∈ 动态集 → `active_view` 设置成功；∉ → `error:bad_view`；
  cap-gated view 对无 cap caller → `error:bad_view`。
- `Ezagent.World.ConversationView`：契约回调返回值 + `applies_to?` 恒真 + 注册后 `lookup(:conversation)` 命中。
- `state_for/2`：出 `"views"` 键、不再出 `"is_hello"`（或保留兼容——见 plan Task）。

### 9.2 真浏览器 Playwright e2e（禁 stub，每 stage 截图存 `e2e/2026-07-05/world-views/`）

dev server `10042` 真登录（`admin@ezagent.chat` / `worlddev`）。步骤：
1. 起栈（disposable Postgres + `mise exec -- mix ecto.migrate` + `mix phx.server`），登录，截图。
2. **注册一个 test SessionView**（dev/test env guard，从 world Application 注册一个
   `Ezagent.World.TestView`：id `:test_view`，label "Test"，icon "sparkles"，`applies_to? → true`，`view_behavior → nil`，
   mode 落 `unsupported`）——进任一 session，断言 world **冒出 "Test" tab**（证通用枚举无需改 world 渲染逻辑），
   点它出占位，截图。
3. 进一个 hello session：断言冒出 Chat / PTY(有 PTY 时) / Page(hello_page) tab；点 Page → iframe 渲出真页面内容，截图。
4. **cap 门控**：以无 `hello_render` cap 的 caller（匿名或非成员）看同一 public hello session → 断言 **Page tab 不出现**；
   以 owner 看 → Page tab 出现。两态各截图（证 cap 门真生效，非绕过）。
5. 切 tab（Chat↔Page↔Test）验证 `switch_view` 动态门 + 内容切换，每切一次截图。

e2e 覆盖：Stage 1（动态 tab 枚举）、Stage 2（内容渲染）、Stage 3（cap 门）、Stage 4（现有 view 迁移不破坏）。
