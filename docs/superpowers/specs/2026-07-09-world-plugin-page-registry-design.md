# world 插件页面注册表（去 kanban 硬编码）设计

- 日期：2026-07-09 · 状态：拍板可实施（jjkysy 2026-07-09"直接改"；范围经 world 隔离审查 + #1267 对齐确认正交）
- 任务：kanban 改版（socialware-rework-plan-0709 T2 前半）· 分支 `feat/sw-kanban-rework`

## 0. 消歧（先说清这不是什么）

**world 插件页面注册表 ≠ #1267 的"活页面连接层"。** 那边是 socialware 生成页（json-render 快照 → ExternalFeed → 外部匿名 SPA）的交互缺口调研；这边是 **world 运营者界面**（登录 operator 用的 LiveView + Vite React bundle）内部的接线卫生。两个页面系统服务人群、渲染栈、授权面都不同，零文件重叠（#1267 消化笔记核对过全文 diff）。

## 1. 问题

world 编译期不引 kanban 模块（dispatch-by-URI，编译图干净），**但把 kanban 页面接成了写死的一等特例**，6 处硬编码：

| # | 位置 | 内容 |
|---|---|---|
| 1 | `routes.ex:108-128` | `/plugins/kanban` + `/plugins/kanban/<id>` 具名分支 → `component: "kanban"` |
| 2 | `navigation.ex:17` + `:77` | 静态侧栏项 + patch 白名单正则 `~r{/plugins/kanban/[^/]+}` |
| 3 | `slot_registry.ex:71-72` | `kanban: {Ezagent.World.KanbanData, [{"kanban","看板"}]}` 专属 renderer family |
| 4 | `world_live.ex:625-635` + `:269-272` | `state_for_route(%{component: "kanban"})` 子句 + `@kanban_actions` 20 个动作串白名单（GitHub 4 动作已退役）→ `KanbanActions.handle_dispatch` |
| 5 | `main.tsx:11` + `:968` | `import {Kanban}` + `case "kanban":` 写死 switch |
| 6 | `slots.manifest.json:68` | 写死 `data_source: "Ezagent.World.KanbanData"` |

> 表中行号为审查时快照，以 `PluginPageRegistry` 现状为准。

后果：每加一个插件页面要改 6 个 world 文件；kanban 专属模块（KanbanData 315 行 / KanbanActions 406 行 / Kanban.tsx 608 行 / KanbanCanvas 198 行）与 world 基建纠缠，未来插件无路可走。

## 2. 目标 / 非目标

**目标**：world 内部引入**插件页面注册表**——一个页面 = 一条注册数据（route + nav + data-builder + action 前缀 + React 组件 key），6 处硬编码全部改为查注册表；kanban 从"写死特例"变成"注册表第一个条目"。**fail-closed**：未注册的 route/component/action 一律拒绝，无兜底放行（对齐 #1267 的白名单治理姿态 + P22 精神）。

**非目标**（明确不做，防 scope 爬）：
- 不把 KanbanData/KanbanActions/Kanban.tsx 物理搬进 kanban 插件（plugin→world 依赖禁令 + Vite 单 bundle 卡死；那是独立架构 follow-up）
- 不动 core、不动 kanban 插件本体（roles/behaviors/dispatch 面零变化）
- 不新建插件自声明协议（`UiSurfaceProvider.session_tabs` 的消费/改造留给 follow-up；本次注册表是 world 内部数据）
- 不改任何用户可见行为（/plugins/kanban 的 URL、界面、动作语义逐一保持）

## 3. 设计

新模块 `Ezagent.World.PluginPageRegistry`（ezagent_plugin_world 内部，编译期常量起步）：

```elixir
@pages [
  %{
    key: "kanban",                        # component key(React switch 用同名)
    route: {"/plugins/kanban", :index},   # 列表页
    detail_route: {"/plugins/kanban/:id", :detail},
    nav: %{label: "看板", path: "/plugins/kanban"},
    data_builder: Ezagent.World.KanbanData,
    renderer_families: [{"kanban", "看板"}],
    action_prefixes: ["kanban."],         # dispatch 准入(细白名单仍由 data_builder 声明)
    actions_module: Ezagent.World.KanbanActions
  }
]
def pages, do: @pages
def by_key(key), do: Enum.find(@pages, &(&1.key == key))   # nil = fail-closed
def by_route(path), do: ...                                 # 路径匹配 → {page, params} | nil
```

6 处硬编码的改法：

1. **routes.ex**：具名分支 → `PluginPageRegistry.by_route/1` 通配（放在现有具名路由之后，不影响 kb/feishu 等未迁移分支）
2. **navigation.ex**：静态项/正则 → 由 `pages()` 派生
3. **slot_registry.ex**：kanban 条目 → 由 `pages()` 派生注入
4. **world_live.ex**：`state_for_route(%{component: "kanban"})` → 通用 `state_for_route(%{component: key})` 查注册表拿 data_builder；`@kanban_actions` 串 → `action_prefixes` 前缀判定 + `actions_module.handle_dispatch`（**动作细白名单不放松**：前缀命中后仍逐动作校验，名单从 KanbanActions 声明导出，语义与现 20 串逐一等价）
5. **main.tsx**：`case "kanban"` → 组件注册表 map `{kanban: Kanban}` 查 key（import 仍显式，Vite 静态打包不变）
6. **slots.manifest.json**：data_source 由注册表生成或校验一致（取实现时更稳的一边）

KanbanData/KanbanActions/Kanban.tsx **代码原样不动**，只改接线。

## 4. 测试与验收

- 新增 `plugin_page_registry_test.exs`：注册表形状、by_key/by_route、fail-closed（未注册 key/route/action 拒绝）
- 现有 world 测试全绿**零断言改动**（行为不变的机器证明）；world 套件 + kanban integration 回归
- arch 全套（`ezagent.arch.scan` exit 0，socialware 两 gate 0/0 顺带）；`compile --warnings-as-errors`
- e2e（本任务后半）：agent-browser 真浏览器过 /plugins/kanban 全流程（列表→详情→动作→relay），每步截图——同时作为 kanban 收官清理后的新证据集

## 5. 顺序（本任务三段）

1. **注册表重构**（本 spec）→ 全绿提交
2. **kanban 收官清理**：docs/together 旧 handoffs 按日期收敛删旧 + 删过时证据图（feedback-pr-wrapup 纪律：换上最后一轮全功能证据，非少截图）
3. **e2e 重做**：一套最新全流程证据（注意 manifest boot scan 仅 prod 开，e2e 显式 scan 或 prod-shape）

段 1 绿后即可开 PR（段 2/3 追加进同一 PR）。
