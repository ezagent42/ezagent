# V1 UI — URI 选择器 + CmdK 接通

> **状态**: DRAFT rev 4 — 2026-05-22。作者: Claude，V1 验收期，按
> Allen Feishu 2026-05-22（item #1 + #3 + #6）。
> Implementation-ready: 过了 `codex:rescue` review（rev 3）+
> `codex adversarial-review`（rev 4）。
>
> - **rev 2**: Allen 对 §5 待决问题的决定 + Part C（member 栏）。
> - **rev 3**: Codex `rescue` review 修复 —— 3 BLOCKER + 7 MAJOR。
>   关键结构改动: (a) 依赖环修复 ——
>   `CommandSource`/`CommandPalette` 不调 `EzagentWeb.Router`；
>   nav 路由在 `ezagent_web` 里经新 `command_routes/0` 组装，经
>   `on_mount` assign **向下**流；(b) `UriOptions` workspace-scoped；
>   (c) `CommandSource` 是对注入候选项的纯排序函数；(d) JS open
>   触发器是 `app.js` 全局，不是无挂载点的 hook；(e) LiveComponent
>   事件全带 `phx-target={@myself}` + 规范事件表；(f) `uri_picker`
>   tag-input 子树 `phx-update="ignore"`；Tier-2 标注；`:kinds` attr；
>   `result()` `:key`；`allow_freetext` 契约；session 跳转 URL 契约。
> - **rev 4**: Codex **adversarial** review 修复 —— 2 HIGH + 2 MEDIUM，
>   都关于租户边界 + 失败可见性: (a) §1.3 —— `UriOptions` 从
>   `caller_uri` 参数**自己**强制 workspace 授权；删掉 rev-3 的
>   `cross_workspace: true` 调用方自觉逃生口；(b) §1.6 —— 提交的
>   picker URI 是 UNTRUSTED；每个改造的表单服务端重校验
>   （`UriOptions.valid_for?/4`）；hook `updated()`/重连清 stale
>   选择；(c) §2C.4 —— member 邀请用新的 `:call` handler，surface
>   `:unauthorized`/`:cross_workspace_denied`，不是静默 `:cast` 的
>   `add_floating_agent`；(d) §4 —— 验证清单重写（rev-3 留了断言旧
>   Tier-1 / Router-querying 架构的过期项）。

## 0. 为什么

两个 V1 验收项，根源同一数据源（`KindRegistry` +
`BehaviorRegistry` + Phoenix Router）:

- **#1** —— LiveView 有约 6 处要求人手输入裸 URI
  （`entity://user/system/admin`、`session://default/default/oncall`）。
  易错、无可发现性。需要选择器组件。
- **#3** —— CmdK 搜索栏（`command_palette/1` 组件存在但未接通）应
  让 operator 搜索 + 跳转。Allen: 注册 L1/L2 路由，搜索点击 ≡ 点链接。

Allen 的架构方向（Feishu 2026-05-22）: CmdK **不要**自己的 registry。
复用现有 `@interface` / `BehaviorRegistry` / Router 机制 —— CLI
（`tree_builder.ex`）派生的同一个源。CmdK 是这棵树的第二个投影。

### 修正 —— slash 命令不存在

ARCHITECTURE.md §D.3 把 LiveView slash 命令（`/agent:set-default`）
描述成设计。**从未实现** —— 没有 `SlashParser`，全代码库没有 slash
代码（`grep slash` → 只有 `uri.ex` 注释）。只有 CLI 侧
（`tree_builder.ex`）真实从 `@interface` 自动派生。所以 CmdK 是
`@interface` 的**第二个**真实消费者，不是第三个。（未来真做 slash
是第三个 —— 也读 §0 加的 `description:` 键。）

## 0. Part 0（前置）— 统一 action 描述

Allen Feishu 2026-05-22 Q1: 没有共享描述机制。`BehaviorRegistry` 是
裸 `{Kind, action} → Behavior` map。`@interface` 的 action schema 是
`%{args, returns, modes}` —— **没 `description`**。CLI 的
`tree_builder.action_about/2` 试图用 `Code.fetch_docs/1` 找名字等于
action 的函数 —— 但 Behavior 实现的是 `invoke(:action, ...)`，从来
没有 `def <action>`，所以 scrape 几乎总是 fallback 到泛型
`"<action> action on <Behavior>"`。

**修复**: 给 `@interface` action schema 加 `description:` 键。

```elixir
def interface do
  %{
    send: %{
      description: "Post a message into the session",
      args: %{message: message_schema()},
      returns: %{stored: :boolean},
      modes: [:cast]
    },
    # ...
  }
end
```

- `Ezagent.InterfaceValidator` 加一条可选的 `description` 是 string
  的检查。
- 现有每个 Behavior 的 `interface/0` 给每个 action 加一行
  `description:`（约 8 个 behavior × ~20 个 action）。
- `tree_builder.action_about/2` 改成读 `interface[action][:description]`
  （仅缺失时 fallback 泛型）。删掉脆弱的 `Code.fetch_docs` scrape。
- CmdK action 结果（§2.2 源 3）读同一个键。

这是 **PR-0** —— 在 PR-1/PR-2 之前落地。"这个 action 干什么" 单一
真相源，今天 CLI 用 + CmdK 接着用 + slash 建了也用。

## 1. Part A — `uri_picker` 统一组件 (#1)

### 1.1 6 处站点

| 站点 | 选什么 | 模式 |
|------|--------|------|
| `routing_live.ex` matcher arg | 一个 entity URI | 单选 |
| `routing/routing_view.ex` matcher arg | 一个 entity URI | 单选 |
| `routing_live.ex` receivers | entity + session URI | 多选 |
| `routing/routing_view.ex` receivers | entity + session URI | 多选 |
| `workspace_detail_live.ex` add member | 一个 entity URI | 单选 |
| `routing_live.ex` JSON combinator | freeform JSON（高级）| 保留 textarea |

JSON-combinator 高级模式保留 textarea —— power-user 逃生口。

### 1.2 组件: `EzagentDomainUi.Primitives.uri_picker/1`

**Tier-2** domain-ui atom —— 无状态 `Phoenix.Component`，在
`apps/ezagent_domain_ui/lib/ezagent_domain_ui/primitives.ex`。（Codex
review 2026-05-22: `primitives.ex` 是 Tier-2 domain-ui，**不是**
Tier-1 core —— Tier-1 是 `ezagent_core`，不含 UI 代码。）

```elixir
attr :name, :string, required: true          # form 字段名
attr :mode, :atom, default: :single          # :single | :multi
attr :options, :list, required: true         # [option()] — 见 1.3
attr :kinds, :list, default: [:entity, :session]  # caller 的 options 含
                                              # 哪些 URI kind；只用于
                                              # badge + 空状态文案。
                                              # caller 必须自己预过滤
                                              # options —— 组件不按
                                              # :kinds 过滤。
attr :value, :any, default: nil              # String（单）| [String]（多）
attr :placeholder, :string, default: nil
attr :allow_freetext, :boolean, default: false  # 高级 fallback — 见 1.4
attr :label, :string, default: nil
attr :required, :boolean, default: false
```

渲染（Allen 2026-05-22 决定 —— 两种都做，不推迟 V2）:
- **`:single`** → combobox: text input + 过滤下拉。打字过滤，点击/
  Enter 选中。隐藏 `<input type="hidden" name={@name}>` 携带选中 URI。
- **`:multi`** → **tag-input + autocomplete**: 选中的 URI 渲染成可删
  chip；下方 text input 过滤；选中加 chip。每个 chip 发隐藏
  `<input type="hidden" name={@name <> "[]"}>`，表单提交得到 list。
- 每个选项（两种模式）渲染 procedural `<.avatar>`（entity 选项）+
  `label`（人类显示名）+ `uri`（font-mono 小字）+ `kind`/`flavor` badge。

**JS hook + LiveView diff 防护（Codex review 2026-05-22）:**
- autocomplete 过滤 + chip 增删是 JS hook `uri_picker.js`
  （组件根 `<div>` 上 `phx-hook="UriPicker"` —— hook 必须有挂载点）。
- hook 拥有可变子树: 过滤下拉、chip 列表、隐藏 form input。该子树
  必须包 `phx-update="ignore"`，这样 LiveView 重渲染不会擦掉
  hook 改的 DOM。预渲染的 `options`（表单生命周期内不变）放在
  ignored 子树**外面**，在 `data-options` JSON attr 里，hook 挂载时读。
- 仅客户端过滤 —— 不每键击 server round-trip。V1 entity/session 数量
  小；选项集变大时再考虑服务端过滤。

组件是**纯的** —— 不查 registry。LV（Tier-3）算 `options` 传进来。
保持 atom 无 registry 依赖（3-layer 架构 invariant）。

### 1.3 选项数据源 — `Ezagent.UI.UriOptions`

新 **Tier-2** helper 模块
`apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex`。只依赖
`ezagent_core`（`KindRegistry`）+ `ezagent_domain_identity`
（`EntityPresenter`）—— 都在 Tier-2 及以下，所以 `ezagent_domain_ui`
可以放它，无依赖环。

**workspace 授权在 UriOptions 内部强制 —— 无调用方自觉逃生口
（Codex adversarial review rev 3 → rev 4，HIGH）。**
`KindRegistry.list_all/0` 是全局的；把每个 URI 返回给每个用户会泄漏
跨 workspace 实体。rev 3 把跨 workspace 安全做成 `cross_workspace:
true` opt，靠每个 caller "记得授权" —— 一个 landmine: 一个 picker/
CmdK call site 忘了就跨租户泄漏 label，而且这个读路径在 dispatch
step 5.6 之外（隔离通常在那强制）。

**rev 4 修复**: 每个公开函数收 **caller 的 entity URI**，**自己**解析
授权。没有 boolean 逃生口。

```elixir
@type option :: %{
        uri: String.t(),
        label: String.t(),
        kind: atom(),
        flavor: String.t() | nil
      }

# `caller_uri` —— 行动的 user/entity（LV 的 current_entity_uri）。
# `workspace_uri` —— 要列的 workspace。UriOptions 强制:
#   - caller 是 system member（跨 workspace 授权，跟 dispatch step
#     5.6 同一检查）→ 任意 workspace_uri 都允许；
#   - 否则 → workspace_uri 必须等于 caller 自己的 workspace，
#     否则 UriOptions 返回 []（永不泄漏；永不向用户抛 stack-trace）。
@doc "caller 在 workspace_uri 里能看到的 Entity URI（user + agent）。"
@spec entities(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]

@doc "caller 在 workspace_uri 里能看到的 Session URI。"
@spec sessions(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]

@doc "entity + session 都要 —— receiver 字段用。"
@spec entities_and_sessions(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]
```

每个函数: 解析 caller 授权 → 若对 `workspace_uri` 无授权，返回 `[]`
→ 否则 `KindRegistry.list_all/0` → 按 scheme 过滤 → 按 workspace 过滤
（3-segment URI 的 workspace 段，SPEC v3 §3）→ 把每个 `{uri, _pid}`
enrich 成 `option()`（`label` 经 `Ezagent.EntityPresenter.display/1`，
`kind`/`flavor` 从 URI 解析）。

**PR-1 必须加 invariant 测试**: 非 system 用户调
`UriOptions.entities(their_uri, other_workspace_uri)` 得 `[]`；
system member 得完整列表。这是读路径的租户隔离 gate。

> 注（Codex review）: `KindRegistry.list_all/0` 只返回
> `{uri_string, pid}` —— 无 label/kind/flavor/workspace。`UriOptions`
> 是 enrichment + **授权**层。不是"纯透传 query"。

### 1.4 Free-text fallback

`allow_freetext: true` 在 picker 下面加一个 `<details>` 折叠
（"or enter a URI manually"）含 plain text input。

**Param 契约（Codex review 2026-05-22 —— 之前欠规范）:**
- free-text input 用跟 picker 隐藏字段**相同**的 form param `name`
  （单选用 `@name`，多选用 `@name <> "[]"`）。
- 折叠**展开**时，JS hook **禁用** picker 的隐藏 input（`disabled`
  attr → 排除出表单提交），只提交 free-text 值。折叠**收起**时，
  free-text input `disabled`。恰好一个源提交 —— 无 merge，无需服务端
  优先级规则。
- 默认 `allow_freetext: false`。用于 operator 可能引用一个还没活的
  URI（如路由规则指向将来才创建的 agent）。

### 1.5 逐站点接入

5 个 picker 站点各自: LV 的 `mount`/`handle_params` 通过
`Ezagent.UI.UriOptions.*`（传 `current_entity_uri` +
`current_workspace_uri`）算 `options`，assign，模板把裸 `<input>`
换成 `<.uri_picker .../>`。表单提交 params 形态不变（单→string，
多→list）。

### 1.6 提交的 URI 是 UNTRUSTED —— 服务端重校验在 PR-1 范围内

**（Codex adversarial review rev 3 → rev 4，HIGH。）** picker 的 chip
状态 + 隐藏 input 在 JS 拥有的 `phx-update="ignore"` 子树下。隐藏
input 是**用户可控 DOM**: 用户能改；且 ignored 子树在 workspace 切换
或 LiveView 重连后会持有 **stale** 选项。rev 3 说"handler 几乎不用
改"是错的 —— 它把客户端状态当可信。

**rev 4 —— 每个改造的站点强制，在 PR-1 范围内:**
- 客户端过滤**只是 UX**。权威检查在服务端。
- 每个改造的表单 `handle_event` 必须在提交时重校验**每个**提交的
  URI: (a) 良构 + 字段对应的正确 scheme，(b) 属于当前 workspace
  （或 caller 有跨 workspace 授权），(c) 目标确实存在 / 该 action
  需要时 membership 有效。校验失败 → flash 错误，不 dispatch。
- 这跟 picker 的 `options` 构建用的是同一套校验（`UriOptions` §1.3）
  —— 抽成共享的 `UriOptions.valid_for?(caller_uri, workspace_uri,
  uri, kinds)`，让构建路径和提交重校验路径不会 drift。
- **hook `updated()` / 重连**: `uri_picker.js` hook 必须实现
  `updated()` —— LiveView 推新 `data-options`（workspace 切换、重
  渲染）时，hook 丢掉不在选项集里的选择。重连时 LiveView 从服务端
  assign 重渲染组件；hook 重读 `data-options` 清 stale chip。stale
  选择永不能静默活到提交。

## 2. Part B — CmdK 接通 (#3)

### 2.1 当前状态

`command_palette/1`（在 `ide_shell.ex`）是完整 modal 组件 ——
`@open`/`@query`/`@results`，事件 `command_query` /
`command_select_result`。但:
- 触发按钮 dispatch JS 事件 `ezagent:open-command-palette` —— **无 JS listener**
- ⌘K 快捷键 —— 没绑
- LV 没有 `command_query` / `command_select_result` handler
- results 无数据源

### 2.2 V1 数据源 —— nav + entity（不要新 registry）

按 Allen 方向，CmdK 结果 union 已存在的数据。V1 用两个源（源 3
action = V2，§2.7）。

**源 1 —— 导航（Phoenix Router）—— 在 `ezagent_web` 组装**

Router 路由是静态的（编译期已知）。`ezagent_web` 新 API:

```elixir
# apps/ezagent_web/lib/ezagent_web/router.ex（或同级模块）
@doc "可进 palette 的 nav 路由 —— enrich 过的，不是裸 route struct。"
@spec command_routes() :: [%{label: String.t(), path: String.t(),
                             icon: String.t(), group: String.t()}]
```

它把 `__routes__/0` 过滤到无 path 参数的 `live` 路由（L1/L2 页面:
`/sessions`、`/identities`、`/routing`、`/plugins`、`/admin`、
`/admin/logs`、`/workspaces`、`/profile`...）并按 path 从一个手维护
的 map 附上 curated 的 `label`/`icon`/`group`（裸 route struct 无
人类 label，Codex review 2026-05-22）。

**依赖环修复（Codex review 2026-05-22 —— BLOCKER）。**
`CommandSource` 和 `CommandPalette` LiveComponent 在 `ezagent_web`
**之下**的 tier，**不能**调 `EzagentWeb.Router`。改为:
`ezagent_web` 装一个 `on_mount` hook 调 `command_routes/0` 并把
`:cmdk_nav_routes` assign 到 socket。LV 继承这个 assign 传给
LiveComponent。nav 数据**向下**流（web → LV → component），从不向上。

**源 2 —— 实体/会话（`UriOptions`）**
`Ezagent.UI.UriOptions.entities_and_sessions(caller_uri, workspace_uri)`
（§1.3）—— **workspace-scoped**。每个 `option()` → 一个结果
`%{kind: :entity, label: <display>, target: <detail-url>, …}`。跟
`uri_picker` 用同一个 enrichment 层。

**目标 URL 契约（Codex review 2026-05-22 —— "跳到详情页"不可实现）。**
按 URI kind 的 `target`:
- `entity://agent/...` → `/identities/agents/<url-encoded-uri>` ——
  路由已存在（`AgentDetailLive`）。
- `entity://user/...` → 有 user 详情路由的话 `/identities/users/
  <url-encoded-uri>`；否则 `/identities`（列表）。实施者查 router。
- `session://...` → `/sessions?session=<url-encoded-uri>`。**这需要给
  `SessionsLive`/`AdminLive` 加一点东西**: 一个 `handle_params/3`
  子句读 `session` query param 并选中那个 session（今天切 session
  只有 `phx-click` 事件、无 URL 形式）。这个 `handle_params` 加在
  PR-2 范围内 —— 没它 CmdK 的 session 结果没落点。

### 2.3 `Ezagent.UI.CommandSource` —— 纯排序函数

新 **Tier-2** 模块（`ezagent_domain_ui`）。不是 registry，也不是对活
registry 的 query —— 是**对 caller 传入数据的纯函数**（这是依赖环
修复: 它从不去碰 `EzagentWeb.Router` 甚至 `KindRegistry`）。

```elixir
@type result :: %{
        key: String.t(),        # 稳定 id —— 用作 phx-value-key（Codex review）
        kind: :nav | :entity,   # V1 kind（:action = V2）
        label: String.t(),
        target: String.t(),     # push_navigate 的 URL
        icon: String.t(),
        group: String.t()
      }

@doc "对预组装的候选项按 query 排序 + 过滤。"
@spec search(query :: String.t(), candidates :: [result()]) :: [result()]
def search(query, candidates) do
  candidates
  |> Enum.filter(&fuzzy_match?(&1.label, query))
  |> Enum.sort_by(&match_rank(&1, query))
  |> Enum.take(20)
end
```

`CommandPalette` LiveComponent 把 `@cmdk_nav_routes`（来自 on_mount
assign）+ `UriOptions` 输出映射成 `result()` 形态来构建
`candidates`，然后调 `search/2`。每个结果带稳定 `:key`（如
`"nav:/sessions"`、`"entity:" <> uri`），这样现有 `phx-value-key`
markup 能用，选中是组件持有的 `%{key => result}` map 的 O(1) 查找。

### 2.4 JS 接通（Codex review 2026-05-22 —— BLOCKER 修复）

open 触发器是 **`app.js` 里的朴素全局 JS**，**不是** `phx-hook`
（hook 需要挂载点元素；open 行为是 app 全局的，不绑单个组件实例）:

```js
// apps/ezagent_web/assets/js/app.js —— 全局，liveSocket 设置之后
window.addEventListener("ezagent:open-command-palette", () =>
  liveSocket.execJS(document.body, /* JS.push "cmdk_open" 指向 palette */))
window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "k") {
    e.preventDefault()
    window.dispatchEvent(new CustomEvent("ezagent:open-command-palette"))
  }
})
```

现有触发按钮已 dispatch `ezagent:open-command-palette`。Esc 关闭留在
组件的 `phx-window-keydown`。push 指向 LiveComponent（见 §2.5）。

### 2.5 LV handler —— 共享 LiveComponent（Allen 2026-05-22 决定）

CmdK 做成 **`Phoenix.LiveComponent`**
（`EzagentPluginLiveview.CommandPaletteComponent`）—— Allen 选了这个
而非 on_mount。open-state + query + results + handler 全在一处；每个
`ide_shell` LV 渲染 `<.live_component module={CommandPaletteComponent}
id="cmdk" nav_routes={@cmdk_nav_routes}
workspace_uri={@current_workspace_uri}/>` 在 `:command_palette` slot。
无 13× handler 重复。

**组件 markup 里每个事件绑定必须带 `phx-target={@myself}`（Codex
review 2026-05-22 —— BLOCKER）。** 没有它，`phx-change` /
`phx-click` / `phx-window-keydown` 会路由到**父** LiveView，父 LV 没
对应 `handle_event` → 崩或静默 no-op。每个绑定都指向 `@myself`，
组件才真正拥有它的事件。

规范事件表（Codex review 2026-05-22 —— SPEC 里事件名曾不一致；这是
单一真相源）:

| 事件 | 触发 | handler 效果 |
|------|------|--------------|
| `cmdk_open` | 全局 JS push（§2.4）| `assign(:open, true)` |
| `cmdk_close` | overlay 点击 / Esc | `assign(:open, false)` |
| `cmdk_query` | 搜索 input `phx-change` | `assign(:results, search(q, candidates))` |
| `cmdk_select` | 结果行 `phx-click`（`phx-value-key`）| 按 `result.kind` 分支 |

`cmdk_select` → 用 `key` 在组件的 `%{key => result}` map 里查 →
对 `:nav` / `:entity` `push_navigate(to: result.target)`（V1）。
`ide_shell.ex` 里现有的 `command_palette/1` markup 在成为
LiveComponent 的 `render/1` 时改名/改指向这些事件名 + 每个绑定加
`phx-target={@myself}`。

### 2.6 CmdK V1 范围 = 只 nav + entity（Allen 2026-05-22 决定）

V1 CmdK 只发**源 1（nav）+ 源 2（entity/session）**。**源 3
（action）推迟 V2** —— Allen 决定。Allen 描述的高价值场景（"搜索→
点击 ≡ 点链接"）nav + entity 完全覆盖。action 需要无参数过滤 +
dispatch 路径 +（带参数 action 的）CmdK 内表单 —— 都 V2。

因此 PR-2 **不依赖** PR-0（`description:` 键）—— 那个依赖只为 action
结果。PR-0 仍然做（修 CLI 脆弱 doc-scrape + 备 V2 CmdK action + 将来
slash），但不再是 PR-2 的硬前置。

### 2.7 超出范围（V2）

- CmdK 源 3 —— action 结果（无参数 dispatch + 表单）
- LiveView slash 命令（`/agent:set-default`）—— Allen 2026-05-22:
  slash 是 V2。（从未实现；ARCHITECTURE.md §D.3 只是设计。）
- fuzzy-rank 调优 / recency 加权
- `uri_picker` 大选项集的服务端过滤

## 2C. Part C — member 栏重做（#6，Allen 2026-05-22）

### 2C.1 问题

`/sessions` 右侧栏有两个 section —— "MEMBERS" + 单独的 "FLOATING
AGENTS" 下拉。Allen: 这个分裂困惑；应合并成一个统一 member 列表。
floating agent 不再是 section；改为一个 **Invite** 按钮开 modal。

### 2C.2 实体头像 —— 已解决

Allen 问 entity Kind 有没有 avatar 属性 / "infos" 字段。**答: 头像
是 procedural，不存储。** `<.avatar uri={...}>` atom（Phase 8c PR-C）
从 entity URI 的 hash 派生唯一 2 色 conic gradient + monogram。任何
entity URI 都得到确定的头像 —— 无需存储。`entity_profiles` 有
`display_name` + `email`；没有通用 "infos"/metadata JSON 列。V2 想要
更丰富的 per-entity metadata，给 `entity_profiles` 加 `metadata` JSON
列是合适位置 —— 但 member 栏不需要新东西：`<.avatar>` +
`display_name` 够了。

### 2C.3 重做

`EzagentPluginLiveview.Admin.MemberPanel`（`member_panel.ex`）:

- **一个统一 member 列表**。每行: `<.avatar>` + 显示名 + URI
  （font-mono 小字）+ online `<.status_dot>` + per-row action（现有
  cc-agent PTY 按钮保留）。`members` + `floating_agents` 合并成一个
  渲染列表 —— floating agent 就是临时加进来的 member，渲染完全一样。
- **删掉 "FLOATING AGENTS" 下拉 section**。
- **加 "Invite" 按钮** → 开 modal:
  - section 1 — **Add existing**: `uri_picker`（`:single`，
    `kinds: [:entity]`）列出不在 session 里的实体 → 选 → 加为 member。
  - section 2 — **Create new agent**: 链接/按钮跳转现有
    `/identities/agents/new`（AgentNewLive）。不在 modal 里重建创建表单。
- modal 是 Tier-2 `<.modal>` atom（primitives.ex 已有）；picker 复用
  Part A 的 `uri_picker`。

### 2C.4 接线 —— 新 invite handler，不是静默 cast 路径

**（Codex adversarial review rev 3 → rev 4，MEDIUM。）** rev 3 说 modal
复用现有 `add_floating_agent` handler。那个 handler `:cast` dispatch
`chat.join` 且丢弃结果 —— `:unauthorized`、`:cross_workspace_denied`、
missing-session、invalid-target 失败被**静默丢**。这违反架构对用户
界面的 no-silent-drop 立场（Decision #134 —— 入站用户界面 `:call`
dispatch + surface 错误），而且单独的 floating-agent `<select>` 删掉
后没别的 affordance，静默失败完全不可见。

**rev 4 —— PR-3 加专门的 invite handler，不复用 `add_floating_agent`:**
- 新 `handle_event("invite_member", %{"member_uri" => uri}, socket)`:
  1. 按 §1.6 重校验 `uri`（良构 entity URI，在当前 workspace 或
     caller 有跨 workspace 授权）。
  2. `:call` dispatch `chat.join`（不是 `:cast`），让结果回来。
  3. 分解结果: `:ok` → 刷新 members + 关 modal；
     `{:error, :unauthorized}` → flash "you may not add members here"；
     `{:error, :cross_workspace_denied}` → flash 指明 workspace 边界；
     其它 `{:error, reason}` → flash `inspect(reason)`。
  4. members 列表**只在确认 `:ok` 时**刷新。
- `open_invite_modal` / `close_invite_modal` 控 modal 可见性。
- 旧 `add_floating_agent` handler + 它的 `<select>` 删除（modal 落地
  后没别的用它）。
- 合并列表就是 `members`（floating agent 即 member）。

这是 **PR-3**，依赖 PR-1（`uri_picker` + §1.6 的
`UriOptions.valid_for?/4` 共享校验器）。

## 3. PR 序列

| # | 标题 | 范围 |
|---|------|------|
| 0 | `@interface` 加 `description:` 键 + 回填所有 behavior + CLI 改读 | Part 0 |
| 1 | `uri_picker`（combobox + tag-input）+ `UriOptions`（caller-authorized）+ `valid_for?/4` + 5 站点服务端重校验 + 租户隔离 invariant 测试 | Part A |
| 2 | `CommandSource`（nav + entity）+ `CommandPalette` LiveComponent + JS hook + ⌘K | Part B |
| 3 | Member 栏重做 —— 统一列表 + Invite modal（专门的 `:call` invite handler）| Part C |

PR-0 独立发（修 CLI doc-scrape；备 V2 CmdK action + 将来 slash）。
PR-1 独立。PR-2 不依赖 PR-0（V1 CmdK = nav+entity，无 action 结果）
+ 复用 PR-1 的 `UriOptions`。PR-3 依赖 PR-1（`uri_picker` +
`valid_for?/4`）。

**PR-1 比 rev 3 暗示的更大** —— Codex rev 4 把服务端 URI 重校验
（§1.6）+ `UriOptions` caller-auth 模型（§1.3）+ 租户隔离 invariant
测试折进了 PR-1 的 definition of done。没有服务端 gate 的客户端
picker UX **不是**可交付的 PR-1。

## 4. 验证

> rev 4 重写 —— Codex adversarial review 发现 rev 3 的清单还断言旧的
> 被否架构（"Tier-1 atom"、"CommandSource queries Router +
> KindRegistry"）。那正是 rev 3 正文修掉的错误；过期清单可能把它们
> 重新放行。下面的清单匹配 rev 4 设计。

**功能**
1. `routing_live` matcher arg 渲染 `uri_picker` `:single` combobox，
   不是裸 text box
2. `routing_live` receivers 渲染 `uri_picker` `:multi` tag-input
   （chip + autocomplete），覆盖 entity + session
3. `workspace_detail` add-member 用 `:single` picker
4. 点 header 搜索栏或按 ⌘K 打开 CmdK modal
5. 输入 "sessions" → `:nav` 结果 → Enter → 跳 /sessions
6. 输入 agent 名 → `:entity` 结果 → 跳它的页面
7. JSON-combinator 高级模式不变（仍是 textarea）
8. `/sessions` 右侧栏一个统一 member 列表（带头像）；无单独
   "Floating Agents" section；Invite 按钮开 modal（add-existing
   picker + create-new-agent 链接）

**架构 / 分层（依赖边界测试）**
9. `uri_picker/1` 是 **Tier-2** `ezagent_domain_ui` 组件 —— 无
   `KindRegistry`/`Router`/LiveView import。（`primitives.ex` 是
   Tier-2；Tier-1 是 `ezagent_core`，不含 UI 代码。）
10. `UriOptions` 是本特性里**唯一**面向 registry 的 helper；只依赖
    `ezagent_core` + `ezagent_domain_identity`。
11. `CommandSource.search/2` 是**对注入候选项的纯函数** —— 无
    `EzagentWeb.Router` 也无 `KindRegistry` 依赖。nav 路由只经
    `ezagent_web` 的 on_mount assign 到达。（加测试断言
    `CommandSource` 的模块依赖排除 `EzagentWeb.*` 和
    `Ezagent.KindRegistry`。）
12. 不加新 "registry" 模块 —— `CommandSource` 什么都不注册；
    `command_routes/0` 在 `ezagent_web`。

**租户隔离（Codex rev 4 —— 读路径）**
13. `UriOptions.entities(非system用户, 别的workspace_uri)` 返回
    `[]`；system member 得完整列表。（invariant 测试 —— §1.3。）
14. 每个改造的 picker 表单服务端重校验提交的 URI（§1.6）—— 手改的
    隐藏 input 含越界 URI 被 flash 拒绝，永不 dispatch。
15. member 栏 Invite handler `:call` dispatch `chat.join`，把
    `:unauthorized` / `:cross_workspace_denied` 作为不同 flash
    surface —— 无静默 `:cast` 丢（§2C.4）。

## 5. 决策（Allen 2026-05-22 —— 待决问题全部解决）

- **uri_picker 模式**: 两种都做 —— `:single` combobox + `:multi`
  tag-input + autocomplete。（不推迟 V2。）
- **CmdK 结构**: 共享 `Phoenix.LiveComponent`（一处，无 13× 重复）。
- **CmdK V1 范围**: 只 nav + entity 结果。action 结果（源 3）→ V2。
- **slash 命令**: V2。（从未实现；CmdK 是 V1 搜索界面。）
- **Member 栏**（新 Part C）: 统一 member 列表 + Invite modal；头像
  是 procedural（`<.avatar>`），无需存储。
