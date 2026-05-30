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

## Q3 —— 新增 LV 功能组件的原则

写在 `ui-contract.md`，承重规则：

1. **三层、不跳层**。Layer 1 无状态原子（`ezagent_domain_ui`）→ Layer 2 插件组合 →
   Layer 3 LV 容器。别为「就这一页」把原子逻辑 fork 进 LV —— 会破坏换肤边界。
2. **经 `AppShell.app_shell` 渲染**，带正确 `perspective`；绝不直接渲染 shell 组件
   （它只在这里接一次 CmdK）。
3. **按 header/状态栏 litmus 放控件**，不是按顺手。
4. **用原子**（`.page_header`、`.breadcrumb`、`.card`、`.button`、`.badge`、
   `.empty_state`、`.uri_picker`）—— 不用裸 input / 内联 `style=` / 写死 hex；
   `bg-*`/`text-*` 永远配 `dark:`。
5. **挣到 CLI 对应**。新增有副作用的 `handle_event` 必须在 `LvCliParityTest` 映射表加行
   （或归类 `:ui_only`/`:pty_stream`）—— 防止 LV 变成某个 headless 运维唯一入口。
6. **不留死链**。功能删了就删链接，别留个孤儿按钮（`feedback_ui_no_misleading_buttons`）。

本次审计值得新增的一条原则：**新运维功能应在同一次改动里同时落地 mix task 和 LV 面**——
parity 测试强制 LV→CLI，但没有东西强制新 CLI 功能长出 UI。上面那些「合理缺口」没问题；
风险是某个**运行时**功能因疏忽只发了 CLI。新增 `mix ezagent.<x>` task 时，把「这需要 LV
入口吗？」列进 checklist。
