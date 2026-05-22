# V1 UI — URI 选择器 + CmdK 接通

> **状态**: DRAFT — 2026-05-22。作者: Claude，V1 验收期，按 Allen
> Feishu 2026-05-22（item #1 + #3）。等 Allen review 后实施。

## 0. 为什么

两个 V1 验收项，根源同一个数据源（`KindRegistry` +
`BehaviorRegistry` + Phoenix Router）:

- **#1** — LiveView 有约 6 处要求人手输入裸 URI
  （`entity://user/system/admin`、`session://default/default/oncall`）。
  易错、无可发现性。需要选择器组件。
- **#3** — CmdK 搜索栏（`command_palette/1` 组件存在但没接通）应
  让 operator 搜索 + 跳转。Allen: 注册 L1/L2 路由，搜索点击 ≡ 点链接。

Allen 的架构方向（Feishu 2026-05-22）: CmdK **不要**自己的 registry。
复用现有 `@interface` / `BehaviorRegistry` / Router 机制 —— CLI
（`tree_builder.ex`）派生的同一个源。CmdK 是这棵树的第二个投影。

### 修正 — slash 命令不存在

ARCHITECTURE.md §D.3 把 LiveView slash 命令（`/agent:set-default`）
描述成设计。**从未实现** —— 没有 `SlashParser`，全代码库没有 slash
代码（`grep slash` → 只有 `uri.ex` 注释）。只有 CLI 侧
（`tree_builder.ex`）真实从 `@interface` 自动派生。所以 CmdK 是
`@interface` 的**第二个**真实消费者，不是第三个。（未来真做 slash
会是第三个 —— 也读 §0 加的 `description:` 键。）

## 0. Part 0（前置）— 统一 action 描述

Allen Feishu 2026-05-22 Q1: 没有共享的描述机制。`BehaviorRegistry`
是裸 `{Kind, action} → Behavior` map。`@interface` 的 action schema
是 `%{args, returns, modes}` —— **没 `description`**。CLI 的
`tree_builder.action_about/2` 试图用 `Code.fetch_docs/1` 找一个
**名字等于 action 的函数的 @doc** —— 但 Behavior 实现的是
`invoke(:action, ...)`，从来没有 `def <action>`，所以 scrape 几乎
总是 fallback 到泛型 `"<action> action on <Behavior>"`。

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

- `Ezagent.InterfaceValidator`（已存在，校验 `@interface` 形态）加一条
  可选的 `description` 是 string 的检查
- 现有每个 Behavior 的 `interface/0` 给每个 action 加一行
  `description:`（小工作量，约 8 个 behavior × ~20 个 action）
- `tree_builder.action_about/2` 改成读 `interface[action][:description]`
  （仅在缺失时 fallback 泛型）。删掉脆弱的 `Code.fetch_docs` scrape
- CmdK action 结果（§2.2 Source 3）读同一个键

这是 **PR-0** —— 在 PR-1/PR-2 之前落地。"这个 action 干什么" 单一
真相源，今天 CLI 用 + CmdK 接着用 + slash 将来建了也用。

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

JSON-combinator 高级模式保留 textarea —— 是 power-user 逃生口。

### 1.2 组件: `EzagentDomainUi.Primitives.uri_picker/1`

Tier-1 atom（无状态 `Phoenix.Component`），放 `primitives.ex`。

```elixir
attr :name, :string, required: true          # form 字段名
attr :mode, :atom, default: :single          # :single | :multi
attr :options, :list, required: true         # [%{uri, label, kind, flavor}]
attr :value, :any, default: nil              # String（单）| [String]（多）
attr :placeholder, :string, default: nil
attr :allow_freetext, :boolean, default: false  # 高级 fallback — 见 1.4
attr :label, :string, default: nil
attr :required, :boolean, default: false
```

渲染:
- **`:single`** → 样式化 `<select>`（选项很多时用 combobox；V1 发
  plain `<select>`，combobox 是 V2 polish）
- **`:multi`** → checklist（竖排 checkbox，每个 `name="<name>[]"`）。
  简单、可访问、零 JS。tag-input + autocomplete 是 V2 polish
- 每个选项渲染 `label`（人类可读）+ `uri`（font-mono 小字）+
  `kind`/`flavor` badge

组件是**纯的** —— 不查 registry。LV（Tier-3）算 `options` 传进来。
保持 atom 无 LV 依赖（3-layer 架构 invariant）。

### 1.3 选项数据源 — `Ezagent.UI.UriOptions`

新 Tier-2 helper 模块
`apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex`。

```elixir
@spec entities() :: [option()]        # 活的 entity URI（user + agent）
@spec sessions() :: [option()]        # 活的 session URI
@spec entities_and_sessions() :: [option()]  # 两者 —— receiver 字段用
```

`option()` = `%{uri, label, kind, flavor}`。`label` 是人类友好显示名
（有的话用 `Ezagent.EntityPresenter.display/1`，否则 URI 末段）。

### 1.4 Free-text fallback

`allow_freetext: true` 在 select/checklist 下面加一个 "or enter a URI
manually" 折叠（`<details>`）含 plain text input。用于 operator 可能
合法引用一个还没活的 URI（如路由规则指向将来才创建的 agent）。默认
`false` —— 大多数站点只从活选项里选。

### 1.5 逐站点接入

5 个 picker 站点各自: LV 的 `mount`/`handle_params` 通过
`Ezagent.UI.UriOptions.*` 算 `options`，assign，模板把裸 `<input>`
换成 `<.uri_picker .../>`。表单提交 params 形态不变（单→string，
多→list），现有 `handle_event` 几乎不用改。

## 2. Part B — CmdK 接通 (#3)

### 2.1 当前状态

`command_palette/1`（在 `ide_shell.ex`）是完整 modal 组件 —— `@open`/
`@query`/`@results`，事件 `command_query` / `command_select_result`。
但:
- 触发按钮 dispatch JS 事件 `ezagent:open-command-palette` —— **无 JS listener**
- ⌘K 快捷键 —— 没绑
- LV 没有 `command_query` / `command_select_result` handler
- results 无数据源

### 2.2 不要新 registry —— 三个已存在的源

按 Allen 方向，CmdK 结果 union 三个已存在的 registry:

**源 1 — 导航（Phoenix Router）**
`EzagentWeb.Router.__routes__/0` 列出每条路由。过滤到无 path 参数的
`live` 路由（L1/L2 页面: `/sessions`、`/identities`、`/routing`、
`/plugins`、`/admin`、`/admin/logs`、`/workspaces`、`/profile`...）。
每个 → `%{kind: :nav, label, target, icon}`。选中 → `push_navigate`。
这就是你说的 "L1/L2 URI 注册" —— 不用手动注册，Router 本身就是注册表。

**源 2 — 实体/会话（KindRegistry）**
`Ezagent.KindRegistry.list_all/0` → 每个活的 `entity://`/`session://`。
每个 → `%{kind: :entity, label: <display>, target: detail-page}`。
选中 → `push_navigate` 到该实体详情页。跟 `uri_picker` 用的同一份
数据（§1.3）—— **共享 `UriOptions` 源**。

**源 3 — Action（BehaviorRegistry + @interface）**
`Ezagent.BehaviorRegistry` 持 `{Kind, action} → Behavior`。每个
Behavior 的 `interface/0` 给 action schema —— 含 PR-0（§0）加的
`description:` 键。跟 `tree_builder.ex`（CLI）同源。结果 `label` 是
`interface[action][:description]`。
V1 只暴露**无参数** action（`@interface[:action].args` 为空，如 agent
`reset_conversation`）。带参数 action 需要表单 → V2；V1 选中带参数
action 就导航到那个表单所在页面。

### 2.3 `Ezagent.UI.CommandSource` — query 函数

新 Tier-2 模块。**不是 registry**（没东西要 register）—— 是上面 3 个
源的纯 query:

```elixir
@spec search(String.t()) :: [result()]
def search(query) do
  (nav_results() ++ entity_results() ++ action_results())
  |> Enum.filter(&fuzzy_match?(&1.label, query))
  |> Enum.sort_by(&match_rank(&1, query))
  |> Enum.take(20)
end
```

`result()` = `%{kind: :nav | :entity | :action, label, target | dispatch, icon, group}`。

### 2.4 JS 接通

新 JS hook `apps/ezagent_web/assets/js/hooks/command_palette.js`:
- 监听 window 事件 `ezagent:open-command-palette`（触发按钮已 dispatch）
  → push LV 事件 `open_command_palette`
- 全局绑 **⌘K / Ctrl+K** → 同上
- （Esc 关闭已由组件的 `phx-window-keydown` 处理）

### 2.5 LV handler

**建议**: CmdK 做成 `Phoenix.LiveComponent`
（`EzagentPluginLiveview.CommandPaletteComponent`），open-state +
query + results + handler 全在一处，每个 `ide_shell` LV 只在
`:command_palette` slot 渲染 `<.live_component module={CommandPalette}
id="cmdk"/>`。避免 13 个 LV 复制 handler。

handler:
- `open_command_palette` → `assign(:cmdk_open, true)`
- `command_query` → `assign(:cmdk_results, CommandSource.search(q))`
- `command_select_result` → 按 `result.kind` 分支:
  - `:nav` / `:entity` → `push_navigate(to: target)`
  - `:action` → `Ezagent.Invocation.dispatch(...)` 然后关闭

### 2.6 超出范围（V2）

- CmdK 内嵌带参数 action 的表单（V1: 导航到表单页）
- fuzzy-rank 调优 / recency 加权
- `uri_picker` 单选的 combobox autocomplete
- `uri_picker` 多选的 tag-input

## 3. PR 序列

| # | 标题 | 范围 |
|---|------|------|
| 0 | `@interface` 加 `description:` 键 + 回填所有 behavior + CLI 改读 | Part 0（前置）|
| 1 | `uri_picker` 组件 + `UriOptions` 源 + 接入 5 站点 | Part A |
| 2 | `CommandSource` query + `CommandPalette` live_component + JS hook + ⌘K | Part B |

PR-0 先落地（CmdK action 结果依赖它；也修 CLI 脆弱的 doc-scrape）。
PR-1 不依赖 PR-0/PR-2 —— 可并行。PR-2 依赖 PR-0（读 `description:`）
+ 复用 PR-1 的 `UriOptions`。

## 4. 验证

1. `routing_live` matcher arg 渲染活实体的 `<select>`，不是裸 text box
2. `routing_live` receivers 渲染 entity + session 的多选 checklist
3. `workspace_detail` add-member 用单选 picker
4. 点 header 搜索栏或按 ⌘K 打开 CmdK modal
5. 输入 "sessions" → `:nav` 结果 → Enter → 跳 /sessions
6. 输入 agent 名 → `:entity` 结果 → 跳它的页面
7. JSON-combinator 高级模式不变（仍是 textarea）
8. `uri_picker` 是纯 Tier-1 atom（无 LV/registry import）
9. CmdK 没加新 "registry" 模块 —— `CommandSource` 是对 Router +
   KindRegistry + BehaviorRegistry 的 query

## 5. Allen 待决问题

- **Q1**: `uri_picker` 多选 —— V1 发 plain checklist。tag-input +
  autocomplete 推迟到 V2 行吗？（推荐行 —— checklist 可访问 + 零 JS）
- **Q2**: CmdK 做共享 `LiveComponent` vs `on_mount` 注入 13 个
  ide_shell LV。推荐 LiveComponent（一处归宿）。
- **Q3**: CmdK 的 action 结果（源 3）V1 要不要做，还是 V1 只发
  nav + entity，action 留 V2？action 需要无参数过滤 + dispatch 路径。
  推荐: V1 发 nav + entity（你描述的高价值 "跳转" 场景），action
  推迟 V2 让 PR-2 紧凑。
