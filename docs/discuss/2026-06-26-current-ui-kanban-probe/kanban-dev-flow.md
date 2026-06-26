# Kanban 插件开发流程（基于现状的可执行手册）

> 基线：worktree `kanban-agent-e2e`，已合入 #1004/#1007 kanban-as-role + RF-1..RF-9 role-foundation。
> 本文所有论断都带 `file:line` 实证，已用 skill-1（project-discussion-esr-ng）+ 真实代码核实。
> 读者定位：第一次接手 kanban 的新人，照着做就能改对、不踩 gate。

---

## 0. 一句话现状

看板（kanban board）现在**就是一个 agent**，不是独立的 `resource://kanban` 资源类型。一张看板 = 一个 agent，它的身份是「角色 `kanban-manager`（一份沙箱内容配方）× 引擎 `native`（一个不带具体大模型的通用宿主）」。看板的数据存在这个 agent 的快照里一个叫 `:kanban` 的分片（slice）。所有节点操作都通过给这个 agent 的 URI 发分发请求来完成。

证据链：
- 角色配方在 kanban 插件里声明：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:64`（`def roles, do: [kanban_manager_recipe()]`），配方名 `"kanban-manager"` 在 `:76`。
- 新建看板 = 创建一个 `native × kanban-manager` 的 agent：`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:310`（`Ezagent.Workspace.create_agent(... flavor: @native_flavor, role: @kanban_role ...)`，两个常量定义在 `:32-33`）。
- 旧的 `resource://kanban` 路线已经被删，而且被架构扫描 gate 锁死（见第 5 节）。

---

## 1. 三层架构：改东西先搞清楚动哪一层

ezagent 是三层 umbrella（core 框架 / domain 领域 / plugin 插件）。kanban 相关代码散在三个 app 里，**改之前先认准你要动的是哪一层**，因为每层的稳定性和改法完全不同。

| 你想改什么 | 动哪个 app | 哪一层 | 关键文件 |
|---|---|---|---|
| 看板的某个动作行为/授权（加节点、认领、改状态…） | `ezagent_plugin_kanban` | plugin | `lib/ezagent/behavior/kanban.ex` |
| 连接器逻辑（GitHub / Miro / PR 出站同步） | `ezagent_plugin_kanban` | plugin | `lib/ezagent/behavior/kanban/connectors.ex`、`miro_sync.ex`、`github.ex` |
| 看板 UI 怎么渲染（列表页、详情页、画布） | `ezagent_plugin_world`（前端） | plugin(world) | `assets/src/components/Kanban.tsx` |
| UI 的路由 / 分发编排 / 读模型 | `ezagent_plugin_world`（后端） | plugin(world) | `routes.ex`、`world_live.ex`、`kanban_data.ex`、`kanban_actions.ex` |
| 角色机制、分发主干、URI、CapBAC、role-create | `ezagent_core` / `ezagent_domain_*` | core/domain | **基座，原则上别动**（见第 5 节） |

**核心边界规矩**：world（统一前端）只当「纯分发器」（dispatcher），**不允许直接引用任何 kanban 插件模块**。world 收到前端事件后，只负责把它翻译成一个发给 agent URI 的分发请求，真正的业务逻辑（连接器、授权）全在 kanban 插件的 Behavior 里。这条边界目前是守住的（`kanban_actions.ex` 里全是 `Ezagent.URI.with_action` + `Invocation.dispatch`，没有 `EzagentPluginKanban.*` 直引），**改的时候别破坏它**。

---

## 2. 数据怎么流：从前端点一下到 Behavior 执行

理解这条链路是改 kanban 的前提。以「加一个节点」为例，完整走一遍：

1. **前端**：用户在画布上操作，`Kanban.tsx` 调 `onAction("kanban.add_node", args)`。前端不认识业务，只是把动作名 + 参数透传出去。
2. **world 后端白名单拦截**：`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:242` 有一张写死的白名单 `@kanban_actions`（24 条 `kanban.*` 字符串），`:244` 的 `handle_event` 子句要求 `action in @kanban_actions` 才放行。不在白名单的动作根本进不来。
3. **转交 KanbanActions**：放行后交给 `Ezagent.World.KanbanActions.handle_dispatch/3`。
4. **拼出带 action 的 URI 并分发**：`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:172`（`target = Ezagent.URI.with_action(uri, :kanban, action)`），得到 `entity://<ws>/agent/<id>?action=kanban.add_node`，然后 `Invocation.dispatch` 打过去。这是 ezagent 里**唯一合法的跨 Kind 通信方式**（设计原则 P14）。
5. **Behavior 执行**：分发落到 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` 里对应的 `handle_add_node/2`，里面做授权检查（`owner_or_admin?`，如 `:311`）+ 写入（唯一写入口 `commit/1`，如 `:325`）。

**关键认知**：前端动作名、world 白名单、Behavior 里的 action 声明，这三处是「三段对齐」的。任何一个新动作要能从 UI 触发，三处都得加（见第 4 节的改动 checklist）。

---

## 3. 25 个动作 vs 24 个白名单：差在哪，别搞错

- **Behavior 里声明了 25 个动作**：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` 里 `action(:xxx, ...)` 宏一共 25 个（实测 `grep -cE '^\s*action\(:' = 25`）。完整清单：
  `add_node / rename_node / move_node / remove_node / set_stage / claim_node / unclaim_node / set_status / attach_artifact / detach_artifact / set_metric / drop_subtree / get_tree / export_markmap / import_markmap / sync_github / push_pr / register_pr / attach_code_file / sync_prs / sync_miro / set_board_config / bind_session / save_github_creds / save_miro_creds`。
- **world 前端白名单只有 24 个**：`world_live.ex:242` 的 `@kanban_actions`（实测去重 = 24）。
- **差的那一个 + 没进白名单的几个**：
  - `get_tree` 是**只读取树**，不走前端 `kanban.*` 分发白名单，而是后端读模型直接调（`kanban_data.ex:120` 的 `with_action(uri, :kanban, :get_tree)`），所以它不在 24 条里很正常。
  - `export_markmap` / `import_markmap` 这两个在 Behavior 里声明了，但**还没经 UI 白名单暴露**——它们是「后端能力已就绪、前端入口还没接」的状态。
  - 白名单里有几个是 Behavior 之外的 world 编排动作（如 `kanban.create` 新建看板、`kanban.select_board` 选板），这些不是发给 Behavior 的节点操作，而是 world 自己处理的，所以 25 和 24 两个集合不是简单包含关系。

**新人提醒**：不要假设「Behavior 有 25 个动作 = UI 能点 25 个」。要确认某动作能不能从 UI 触发，去数 `world_live.ex:242` 的白名单，不是数 Behavior。

---

## 4. 持续开发 kanban：四类常见改动，分别动哪层

### 改动类型 A：改某个动作的「行为或授权」（只动 plugin）
比如想让 `claim_node`（认领节点）改授权规则，或给 `set_status` 加个副作用。
- **只动** `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`。
- 改对应的 `handle_<action>/2` 函数。授权统一用 `owner_or_admin?(ctx, node)`（per-node 所有者或管理员，`:311/:343/:372` 等多处），写入统一走 `commit/1`（`:325` 等），**不要自己拼快照、不要绕过 commit**。
- 能力声明（cap）在 `required_caps/0`（`:255`）。这里有个要点：cap 的「类型轴」声明成 `:any`（`:284`），运行时按宿主 agent 的真实类型（`Entity.Agent` → `:agent`）替换后再授权（`:251-254` 注释）。所以你新增动作时照抄这个 `:any` 写法即可，别写死成具体类型。
- world / core **一行都不用动**。

### 改动类型 B：新增一个看板动作（动 plugin + world，三处对齐）
要让一个全新动作能从 UI 点：
1. **plugin**：在 `kanban.ex` 加 `action(:my_action, ...)` 宏 + `handle_my_action/2`。
2. **world 后端**：把 `kanban.my_action` 加进 `world_live.ex:242` 的 `@kanban_actions` 白名单，并在 `kanban_actions.ex` 加一个 handler（薄转发，照抄现有的 `act/3` 模式，`:168` 一带）。
3. **world 前端**：在 `Kanban.tsx` 加一个触发 `onAction("kanban.my_action", args)` 的按钮/控件。
- 三处任缺一处，动作就「半通」：缺白名单 → 被 `world_live.ex:244` 挡掉；缺前端 → 没入口点。

### 改动类型 C：改看板 UI 渲染（只动 world 前端）
比如改画布样式、改列表展示。
- 只动 `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx`。
- 这个组件按有没有选中某张板二分：`:62-65`，有 `kanban_uri` 渲染 `KanbanDetail`（`:127`），没有则渲染 `KanbanList`（`:70`）。看板列表数据 `state.instances` 在 `:132` 取、`:210` 渲染。
- 读模型已经把数据备好了（`kanban_data.ex` 算出 instances + 每张板的树），前端纯按数据渲染。

### 改动类型 D：改连接器（GitHub / Miro 出站，只动 plugin）
- Miro 出站是 kanban 插件**自养的独立进程** `EzagentPluginKanban.MiroSync`（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex`），跑在 kanban 自己的监督树下（`application.ex:101-102`），**故意不复用 external_mirror 域**（那个是「会话 → 外部聊天目标」的出站，模型套不到「看板 = agent」上）。
- GitHub 出站同理是 kanban 自己的 REST 客户端 `github.ex`。
- 凭证（token）走 core 统一的凭证文件机制（`system://credentials/miro.yaml`、`github.yaml`），这是唯一跟外部共享的部分。
- **排障提醒**：kanban 出站不在 external_mirror 域，所以不享有 external_mirror 那套统一的 binding 监督/重启/能力检查可观测性。排 kanban 出站问题，看 kanban 操作面 + 那两个凭证文件，**别去 Admin 的 external mirror 绑定面板找**，那里只配飞书会话镜像。

---

## 5. Gate 拦什么：哪些事会被自动挡下来

ezagent 没有 CI（仓库里没有 `.github/workflows`），但有几道架构扫描 gate（`mix` 任务）和不变式测试，红了靠人工跑测试发现。改 kanban 时这几道会拦你：

### Gate 1 — K5 资源类型锁（最容易撞）
- 位置：`apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex:330` 起的 `resource-only-files gate`。
- 拦什么：kanban-as-role 把看板从 `resource://` 搬到了 `Entity.Agent`（`:334-335` 注释），这道 gate **锁死了任何 kanban 重新声明 `resource://` live Kind 的企图**。
- 对你意味着：**不要试图把看板改回 `resource://kanban` 资源类型**。kanban 插件的 `kinds/0` 必须保持默认 `[]`（`application.ex` 里），看板就是 agent，认这个设定。

### Gate 2 — world 不直引 plugin
- world 层（`kanban_actions.ex` / `kanban_data.ex`）只能 `Invocation.dispatch`，不能 `import`/直接调用 `EzagentPluginKanban.*` 模块。目前是干净的，连接器逻辑全下沉到 Behavior。改 world 时**别为了图方便直接调 kanban 插件函数**。

### Gate 3 — P14 唯一分发路径
- 所有跨 Kind 通信必须走 `Invocation.dispatch` / `Router.dispatch`，**禁止 `PubSub.broadcast` 到入站 topic**。kanban 全链路已经遵守（`kanban_actions.ex:172` 一路 dispatch）。

### Gate 4 — 写入唯一收口
- Behavior 里改看板数据只能经 `commit/1`，不能自己写快照存储。`kanban.ex` 里所有写动作都返回 `[commit(...)]` effect。

### Gate 5 — 测试基线
- kanban 单 app 测试基线：**59 tests, 0 failures, 7 excluded**（excluded 是 `:live_miro` 标签，要真 Miro 凭证才跑）。
- **跑法（务必照这个，否则假失败）**：
  ```bash
  # 先起 PostgreSQL 测试库容器
  docker compose -f docker-compose.pg.yml up -d
  MIX_ENV=test mise exec -- mix ecto.create
  MIX_ENV=test mise exec -- mix ecto.migrate
  # 在 umbrella 根跑（别 cd 进 app）
  bash scripts/test-app.sh ezagent_plugin_kanban
  ```
- **两个致命坑**：① 必须经 `mise`（Elixir 1.18/OTP27），系统默认的 1.19/OTP28 会放大跨进程数据库沙箱不稳定；② **绝不要 `cd apps/ezagent_plugin_kanban && mix test`**，隔离 app 缺兄弟插件，注册/热装/架构扫描测试会假失败暴增。

---

## 6. 两个已知缺口（B1 / B2）：合规改法

现状 kanban-as-role 的**后端 + 路由 + 分发全链路是对的、合规的**。但前端入口有两个真实缺口，照下面改，**零改 core**。

### B1 — kanban 在 `/plugins` 列表页没有可点入口
- 现象：`/plugins` 列表里 feishu 有 `/plugins/feishu/bindings` 链接，**kanban 那行没有任何能点进 `/plugins/kanban` 的链接**，只能手输 URL。
- 根因：kanban 插件没真声明 `config_surface/0`。`application.ex:106-114` 只有 TODO 注释（`:108` 写明「DELIBERATELY NOT」、`:114` 写「Re-add config_surface/0 in K4」），默认返回 `nil`（core 默认 `apps/ezagent_core/lib/ezagent/plugin.ex:295` `def config_surface, do: nil`）。world 的 `workspace_plugin_data.ex:273` 拿 `config_surface()` 的结果，nil 时 `config_target` 返回 `{nil, "Configure"}`（`:297`）；前端 `WorkspacePlugin.tsx:253` 只在 `config_path` 非空时才渲染链接 —— 所以 kanban 行是死的。
- **合规改法（只动 plugin 层）**：在 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` 删掉 106-114 的 TODO，真声明：
  ```elixir
  def config_surface, do: %{kind: :route, path: "/plugins/kanban", label: "看板"}
  ```
  `:route` 形态是 core 允许的（`plugin.ex:289` 的 `config_target(%{kind: :route, ...})` 子句 + `:974` 起的 `assert_config_surface!` 校验通过）。这样 `/plugins` 列表自动出「看板」可点链接，world / core 一行不用动。

### B2 — `/plugins/kanban` 列表页是空壳，零看板时死锁
- 现象：一个 workspace 还没有任何看板时，进 `/plugins/kanban` 只看到 Miro/GitHub 凭证配置表单，**无路可建第一张板**（看板列表和「建板」输入框只藏在某张板详情页的侧边栏里 → 鸡生蛋死锁）。
- 根因：`Kanban.tsx:70` 的 `KanbanList` 只渲染凭证表单 + Status，**完全不读 `state.instances`、没有建板按钮**。而 instances 列表（`:210` 的 `instances.map`）和建板输入框（`:224` 的 `kanban.create`）只在 `KanbanDetail`（`:127`）侧边栏里。读模型其实早就把 `instances` 算好传过来了（`kanban_data.ex` 已备好），列表页却丢弃不用。
- **合规改法（只动 world 前端）**：改 `Kanban.tsx` 的 `KanbanList`（`:70`），加上 `state.instances.map` 的看板列表 + 一个调 `kanban.create` 的建板输入框（逻辑可从 `KanbanDetail` 侧边栏 `:210-224` 抽出来复用）。纯前端改动，instances 数据已经传过来了。

---

## 7. 改 kanban 的安全边界总表（背下来）

| 可以放心改 | 谨慎改（要对齐多处） | 别碰（基座，要改先问 Allen） |
|---|---|---|
| `behavior/kanban.ex` 动作行为/授权 | 新增动作（plugin+world 三处对齐） | `Ezagent.URI.with_action` / `Invocation.dispatch`（core） |
| `behavior/kanban/connectors.ex`、`miro_sync.ex`、`github.ex` | world 的 `routes.ex`/`world_live.ex`/`kanban_actions.ex`/`kanban_data.ex` | role 基座 `role.ex`/`role_registry`/`CapMint`（core/domain） |
| `Kanban.tsx` 纯渲染 | `application.ex` 的 `config_surface/0`、`roles/0` | `AgentRoleResolver`（domain_agent） |
| 凭证文件保存逻辑 | | `plugin.ex` 的 config_surface 契约（core） |

遵循项目的「grill 文化」：实施期发现某个不变式跟需求冲突，**暂停、写 issue、等 Allen**，不要自作主张改 core 或绕过 gate。kanban 这套 kanban-as-role 设计是经过 grill 闭环定下来的，看板 = agent 是有意为之，不是临时方案。

---

## 8. 上手第一步（新人 day-1 动作）

```bash
# 1. 起测试库 + 建库（只需一次）
docker compose -f docker-compose.pg.yml up -d
MIX_ENV=test mise exec -- mix ecto.create && MIX_ENV=test mise exec -- mix ecto.migrate

# 2. 跑 kanban 基线，确认绿（59t/0fail/7excl）
bash scripts/test-app.sh ezagent_plugin_kanban

# 3. 真浏览器走一遍（按团队规矩，每个有意义步骤都截图）：
#    起 dev server → /plugins/kanban 建看板 → 加节点 → 认领 → 推 Miro → 截图存档
mix phx.server
```

读码顺序建议：先读 `kanban_actions.ex` 顶部 moduledoc（`:1-25`，把整条链路讲清了），再读 `behavior/kanban.ex` 的 25 个 `action` 声明，最后读 `Kanban.tsx`。三个文件读完，kanban 的「前端→world→Behavior」全貌就有了。
