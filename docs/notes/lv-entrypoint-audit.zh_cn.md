# LiveView 入口审计

审计需求 2026-05-30（Allen）：ezagent 的每个功能是否都能从 LiveView UI 进入？进不去的，
原因是什么、是否合理？已有的 LV 功能放置/样式是否合理？在 LV 中新增功能组件的原则是什么？

> 范围说明：本文是**代码/架构层**的一遍梳理。放置/样式的结论（Q2）在动手重构前应先用
> agent-browser 对着实时截图（`http://100.64.0.27:10042`）确认 —— 遵守「先打开 UI」铁律。
> 本文先把结构定下来；视觉那一遍是后续。

## Q1 —— 功能 → LV 可达性

系统已经强制 **LV → CLI** parity：`LvCliParityTest` 遍历每个有副作用的 `handle_event/3`，
要求都有对应的 `mix ezagent …`（分类 `:cli` / `:ui_only` / `:pty_stream` / `:deferred`）。
所以每个 LV 动作都能用 CLI 驱动。审计问的是**反方向**：哪些运维功能（mix task / dispatch
action）**没有** LV 入口。

| 运维功能（mix task） | LV 入口 | 结论 |
|---|---|---|
| `agent.create` | `/identities/agents/new` | ✓ 可达 |
| `user.create`、改凭证 | `/identities/users`、`/profile`（自助） | ✓ 可达 |
| agent api-keys | `/identities/agents/:uri/api-keys` | ✓ 可达 |
| caps 授予/撤销/审计 | `/identities/*/caps`、`/admin/caps`、`/admin/audit/authz` | ✓ 可达 |
| `workspace.*`（建/成员/模板） | `/workspaces`、`/workspaces/:name` | ✓ 可达 |
| `routing.add_rule` | `/admin/routing` | ✓ 可达 |
| `external_mirror.*` | `/admin/sessions/:id/external_mirror` | ✓ 可达 |
| `feishu.bind/list/unbind` | `/plugins/feishu/bindings` | ✓ 可达 |
| snapshots | `/admin/snapshots` | ✓ 可达 |
| sessions / chat | `/sessions`、terminal | ✓ 可达 |
| 可观测 / registry | `/admin/logs`、`/admin/registry` | ✓ 可达 |
| `plugin.install` | `/plugins` **只读** | ⚠ 缺口 —— **合理**（装插件是代码部署动作，不是运行时操作） |
| `home.backup/restore/init/adopt_db` | 无 | ⚠ 缺口 —— **合理**（宿主级迁移/灾备运维；从被迁移的 UI 里跑它不安全） |
| `bootstrap`、`db.reset`、`stress`、`demo.seed_*`、`check_invariants` | 无 | ⚠ 缺口 —— **合理**（dev/CI/bootstrap 工具，非运维功能） |

**结论**：每个**运行时运维功能**都能从 LV 进入。仅有的缺口是 (a) 装插件、(b) 宿主迁移/
bootstrap/dev 工具 —— 全部是部署期或灾备操作，刻意只留 CLI，不放进 in-session 的 UI。
**没有发现不合理的缺口**。这里最强的保证是结构性的：`LvCliParityTest` 防止两个面板漂移。

## Q2 —— 已有 LV 功能的放置/样式

放置由文档化的契约（`ui-contract.md`）管，不是临时拍脑袋：

- **嵌套 shell**（2026-05-22）：一个 `AppShell.app_shell` 拥有全局 chrome；
  `perspective={:workspace}`（工作流面：/sessions、/routing、/identities、/plugins）
  vs `perspective={:admin}`（系统配置：/admin/*、/workspaces）。每个 LV 只渲染其一 ——
  信息架构一致。
- **header vs 状态栏 litmus**（Allen 2026-05-22）：header = workspace 域、跨视图不变
  （workspace 下拉、⌘K、通知、头像）；状态栏 = 位置域、随视图变（当前 entity/session URI、
  信号灯、成员面板开关、debug 计数）。判据：*「这个控件在每一页都讲得通吗？」* 是 → header，
  否 → 状态栏。

这给任何控件一个清晰、可测的归位。**待 agent-browser 视觉确认的开放项：**
- admin 面（/admin/*）是否正确继承了外层 chrome（头像/通知/搜索）—— 这正是当初嵌套 shell
  重构的动因 bug，值得截图确认它没回退。
- 两个 perspective 的 activity-bar / settings-nav 分组是否和上表的路由分类一致（无孤儿路由、
  无死链 —— `ui-contract` DON'T #93）。

## Q3 —— 决策流程：一个 UI 组件该放哪？

组件归位由两个正交的轴决定 —— **作用域 SCOPE**（它作用在什么上）和 **provider 层级
TIER**（谁拥有代码）—— 再用页内规则细化。两轴独立：作用域决定 *路由 + perspective*，
层级决定 *归属模块* 以及是否需要专门的 plugin 界面。

### 轴 1 —— 作用域 → 路由 + perspective（主导轴）

问：*「这个功能作用在什么上？」*（下列路由均对照 `apps/ezagent_web/lib/ezagent_web/router.ex` 核实）：

| 作用域（作用在…） | 路由 | perspective |
|---|---|---|
| 整个部署 / 系统 | `/admin/<feature>` | `:admin` |
| 一个 workspace | `/workspaces/:name` | `:admin` |
| 一个 session —— **实时使用** | `/sessions` 上的会话内 tab | `:workspace` |
| 一个 session —— **配置/管理** | `/admin/sessions/:id/<feature>` | `:admin` |
| 一个实体（agent / user） | `/identities/{agents,users}/:uri/<feature>` | `:workspace` |
| 当前用户（自助） | `/profile` | `:workspace` |

经验法则：**系统级配置 → `:admin` perspective；任何在 workspace / session / 实体*内部*操作
的 → `:workspace` perspective。**（perspective 是 `AppShell.app_shell perspective={…}` 的
类型化契约：`:admin` 显示 `ezagent / system` 上下文标签，`:workspace` 显示 workspace 切换器。）

### 轴 2 —— provider 层级 → 归属 + 专门的 plugin 界面

- **core / domain 功能**（如 routing=`ezagent_core`、caps=core CapBAC、
  api-keys=`ezagent_domain_identity`、templates/snapshots=core）：直接落在轴 1 的界面上 ——
  `/admin/routing`、`/identities/*/caps`、`/admin/snapshots` 等，无额外中转。
- **plugin 功能**：插件自己拥有一个 **全局配置页** `/plugins/<plugin>/<feature>`
  （如 `/plugins/feishu/bindings`）。按 North Star（插件隔离）插件 UI **禁止**硬塞进 core
  admin 页 —— 它自注册 `/plugins/<plugin>` 界面。
- **作用域在 session / 实体 / workspace 的 plugin 功能**：**两处都出现** —— 插件的全局页
  （`/plugins/<plugin>`，跨实例管理）+ 作用域的轴 1 界面（`/admin/sessions/:id/<feature>` 等）
  做 per-instance 配置。

### 标杆实例 —— ExternalMirror（线上核实过）

ExternalMirror 是 **domain 原语**（ExternalMirror Domain 拥有所有出站镜像 —— 架构不变量 #15）；
**Feishu** 是 **plugin adapter**；一个 binding 是 **session 作用域**。套两轴 → 它在四个协调的
位置出现，正是你说的 *「plugin 提供配置界面 + sessions/xx 提供 per-session 配置页面」* 模式：

- `/plugins/feishu/bindings` —— **插件**的全局 binding 管理。
- `/admin/sessions/:id/external_mirror` —— **per-session** binding 配置（`:admin`）。
- `/sessions` 上的会话内 **「Bindings」** tab —— in-context、实时、per-session 视图（`:workspace`）。
- `/admin/routing?tab=bindings` —— 跨会话全局只读视图。

### 轴 3 —— 选定页内，控件放哪？

1. **三层构建**：原子（`ezagent_domain_ui`）→ 组合（`ezagent_plugin_liveview`）→ LV 容器。
   绝不把原子逻辑 fork 进单个 LV。
2. **经 `AppShell.app_shell perspective={…}` 渲染**（只接一次 CmdK）；绝不直接渲染 shell 组件。
3. **header vs 状态栏 litmus**：这控件在*每一页*都讲得通（workspace 不变）？→ header。
   绑当前位置（这个 session / 实体 / 视图）？→ 状态栏。
4. **用原子**（`.page_header` / `.card` / `.button` / `.badge` / `.empty_state` /
   `.uri_picker`）；不用裸 input / 内联 `style=` / 写死 hex；`bg-*`/`text-*` 永远配 `dark:`。
5. **挣到 CLI 行**：新增有副作用的 `handle_event` 必须在 `LvCliParityTest` 加 `mix ezagent …`
   对应行（或归类 `:ui_only` / `:pty_stream`）。
6. **不留死链** —— 删功能就删链接，别留孤儿按钮。

### 一行决策流

```
作用域?  ──► 路由 + perspective（轴 1）
  └─ 层级?  ──► core/domain：直接用轴 1 界面
               plugin：     另开 /plugins/<plugin>，若有作用域，
                            per-instance 配置放到作用域界面（轴 2）
        └─ 页内：三层 + app_shell + header/状态栏 litmus（轴 3）
              └─ 加 LvCliParity 行
```

审计衍生的一条新增原则：**新的*运行时*运维功能应在同一次改动里同时落地 `mix ezagent` task
和 LV 面。** `LvCliParityTest` 强制 LV→CLI，但没东西强制新 CLI 功能长出 UI —— 所以「这需要
LV 入口吗？按轴 1 该放哪？」应进每个新 `mix ezagent.<x>` task 的 checklist。
