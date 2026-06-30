# 终端用户怎么用 kanban 插件

本文写给**想用 kanban 看板的终端用户**——你登录 ezagent 之后，想用「看板」这个插件把一条
产品/团队开发流（9 个 stage：定位 → 北极星 → 痛点 → 认领 → 线框 → 功能卡 → issue → 测试 → PR）
跑起来。读完你会知道：怎么登录、怎么建/绑一块看板、在会话里能发哪些命令、每个 kanban 动作
（action）干什么/怎么触发/要什么参数/板会怎么变、怎么跟 pm-coordinator agent 协作派活、
World UI 上能看到什么，以及一个从绑板到走完一轮的完整示例。

> 看板在 ezagent 里**不是**一个独立的网页应用，而是一个 **agent**（role `kanban-manager` ×
> flavor `native`）。一块「看板」= 一个 kanban-manager agent，URI 形如
> `entity://<workspace>/agent/<board-name>`。板上的节点树（node tree）就是这个 agent 的
> `:kanban` 状态。所有「改板」的动作都是向这个 agent dispatch 一个 `kanban.<action>`。
> 你不直接和这个 agent 聊天（它是 **passive** 的，不能被 @、不进群、不收 chat）——你通过
> **World UI 点按**、**CLI dispatch**，或者 **@pm 让 pm-coordinator 替你 dispatch** 来操作它。

---

## ① 登录

kanban 是登录后才能用的功能。登录细节见
[`login-and-registration.md`](./login-and-registration.md)，这里只给最短路径：

- 打开 `/login`，用**邮箱 + 密码**登录（旧的 handle/URI 登录已废弃）。
- 自助注册默认关闭（`registration_open=false`），一般由管理员开账户或发**邀请码**
  （`mix ezagent.invite mint --workspace <ws>`）。注册后要先点确认邮件里的链接把邮箱验证了
  才能登录。
- 命令行/接口调用（CLI / API）用 `Authorization: Bearer <token>`；CLI 还要带上
  token 对应的 entity URI（`EZAGENT_USER_TOKEN` + `EZAGENT_ENTITY_URI`，见 §3 CLI 部分）。

登录后你处在某个 **workspace**（租户）里，看板、会话、agent 都按 workspace 隔离——你只能看到/
操作自己 workspace 里的板。

---

## ② 进入/创建 session，并 bind 一块看板

看板有两个入口，它们解决不同的事：

| 入口 | 路径 | 作用 |
|---|---|---|
| **Plugins 配置入口** | 左栏 Plugins → 「看板」(`/plugins/kanban`) | 列出/新建看板，进单块看板的操作面 |
| **会话内 kanban tab** | 某个 session 视图里多出来的「看板」tab | 一块板**绑定**到这个 session 后才出现，在会话语境里看这块板 |

### 2.1 新建一块看板

1. 左栏 Plugins 里点「看板」进 `/plugins/kanban`，看到本 workspace 已有的看板列表
   （列表来源 = 按 role `kanban-manager` 枚举本 workspace 的 agent，**包括休眠的板**，
   重启后也不会消失）。
2. 点「新建」，填一个名字（如 `kbflow`）。后台会用 `Ezagent.Workspace.create_agent`
   创建一个 role `kanban-manager` × flavor `native` 的 agent，得到
   `entity://<workspace>/agent/kbflow`——这就是这块板的地址。
3. 新建后这块空板的入口就出现在左栏看板列表里，点进去看它的节点树（一开始是空的）。

### 2.2 把看板「绑定」到一个 session（接力的前置）

如果你想让看板和团队会话联动（人在会话里 @pm 派活、动作播报回会话、触发下一个 agent 接力），
需要把这块板 **bind** 到一个 session：

- **怎么操作**：在看板操作面里执行 `bind_session` 动作（World UI 配置区填会话 URI；
  或 CLI dispatch，见 §3 的 `bind_session` 行），参数是 `session_uri`，形如
  `session://<workspace>/<owner>/<name>`。
- **绑定后会发生什么**：
  1. 那个 session 的会话视图里**多出一个「看板」tab**，显示这块绑定的板
     （`session_tabs` 的 condition = 「该 session 绑了板」才出现）。
  2. 之后这块板上的**接力动作**（`claim_node` / `set_status` / `register_pr`）成功后，
     会自动往这个 session `session.send` 一条公告，形如 `[kanban:claimed] by <user>`，
     消息重入路由就能触发下一个 agent 接力（见 §4）。

> 一块板同一时间只跟一个 session 绑定（板级配置）。换会话就再 `bind_session` 一次。

---

## ③ 在 session/看板里能做哪些动作（全 action 清单）

看板的全部能力 = `Ezagent.Behavior.Kanban` 声明的 **25 个 action**。每个 action 有三种触发方式：

- **World UI 点按** —— 看板操作面里的按钮/表单（背后是 `kanban.<action>` 的 socket dispatch，
  带你**本人**的登录身份和 caps，per-node 授权在 Behavior 里如实判，UI 层不放水）。
- **@pm 自然语言** —— 在绑定的 session 里 @pm（pm-coordinator agent）用人话说要干嘛，
  pm 用**它自己的 caps** 替你 dispatch 对应 action（见 §4）。注意：board agent 本身是
  passive 的，**不能直接 @ 它**；自然语言要发给 pm。
- **CLI dispatch** —— 通用动词：

  ```bash
  mix ezagent dispatch <board-uri> --action kanban.<action> --args '<json>'
  ```

  `<board-uri>` = 板的 entity URI（如 `entity://system/agent/kbflow`）；`--args` 是该 action
  参数的 JSON 对象（无参用 `'{}'` 或省略）。授权走 CapBAC，用的是**你 token 对应的身份和 caps**，
  没有后门。CLI 身份用环境变量 `EZAGENT_USER_TOKEN` + `EZAGENT_ENTITY_URI`（或 `--token` /
  `--uri` 旗标）提供。

下面是**全部 25 个 action**（直接对 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`
的 `action/3` 宏核对）。所有动作都是 `:call` 模式（同步返回结果/错误）。

### 拓扑动作（建/改/移/删节点、stage）

| action | 参数 | 作用 / 板怎么变 | 授权 |
|---|---|---|---|
| `add_node` | `parent_id`, `title`（返回 `{id}`） | 新增节点。`parent_id=""` 建**根**节点（链首 stage = `positioning`）；非空则加子节点（默认继承父 stage） | 建根 = admin；加子 = 父节点 owner 或 admin |
| `rename_node` | `id`, `title` | 改节点标题 | 节点 owner 或 admin |
| `move_node` | `id`, `new_parent_id` | 把节点（连同子树）移到新父下。禁止成环；且移动后 stage 必须 ≥ 新父 stage（单调链） | 节点 owner 或 admin |
| `remove_node` | `id` | 删节点 + **级联删整棵子树** | 节点 owner 或 admin |
| `set_stage` | `id`, `stage` | 把节点推进到链上某个 stage。强制相邻棒推进：根只能是链首；非根只能是「父棒」或「父棒+1」，不能跳棒/回退 | 节点 owner 或 admin |
| `drop_subtree` | `id`, `reason` | 砍掉一棵子树（指标不达标时 drop），并在**图级别**的 drop 历史（`tree.drops`）记一笔（标题/stage/原因/砍掉节点数） | 节点 owner 或 admin |

> stage 链（9 棒：`positioning, metric, pain, anchor, ux, feature, issue, test, pr`）不是写死在
> Behavior 里的，而是 `kanban-manager` recipe 的 `config` 数据。所以 `set_stage` 的合法值 = 这 9 个。

### 认领 / 状态动作

| action | 参数 | 作用 / 板怎么变 | 授权 |
|---|---|---|---|
| `claim_node` | `id` | **认领**一个未分配节点：`owner=你`，`status → claimed`。已被认领的报 `already_claimed` | 任意成员可认领未分配节点 |
| `unclaim_node` | `id` | **退领**：`owner=nil`，`status → unassigned` | 节点 owner 或 admin |
| `set_status` | `id`, `status` | 状态流转，`status ∈ {claimed, doing, done}`。**必须先认领**（未认领报 `must_claim_first`） | 节点 owner 或 admin |

> 不变式：`owner==nil ⟺ status==:unassigned`。所以四态里 `unassigned` 只能经 claim/unclaim 切换，
> 三态 `claimed/doing/done` 经 `set_status` 在已认领节点上流转。

### 挂载动作（产物 / 指标）

| action | 参数 | 作用 / 板怎么变 | 授权 |
|---|---|---|---|
| `attach_artifact` | `id`, `artifact`（map：`{tool, kind, ref, url}`） | 给节点挂一个**工具产物**（GitHub PR / 飞书文档 / xmind / 上传文件…） | 节点 owner 或 admin |
| `detach_artifact` | `id`, `ref` | 按 `ref` 从节点移除一个产物 | 节点 owner 或 admin |
| `set_metric` | `id`, `metric`（map：`{name, target, current, unit}`） | 按 `name` **upsert** 一个指标（同名覆盖），给价值/运营节点挂量化指标 | 节点 owner 或 admin |

### 读 / 导入导出

| action | 参数 | 作用 | 授权 |
|---|---|---|---|
| `get_tree` | 无（返回 `{tree, drops, config, miro, github, stages, ci}`） | 读**整棵树**（节点 + 根 id + drop 历史 + 连接器配置 + Miro/GitHub 连接状态 + stage 链 + PR 节点的 CI 评价摘要）。World UI 每次动作后都靠它刷新 | 持 cap 成员 |
| `export_markmap` | 无（返回 `{markdown}`） | 把节点树导出成 markmap markdown | 持 cap 成员 |
| `import_markmap` | `markdown`（返回 `{count}`） | 用 markmap markdown **覆盖导入**拓扑（保留图级 drop 历史；导入节点默认 stage = `feature`） | admin |

### 出站连接器动作（GitHub / Miro / 配置 / 绑定）

| action | 参数 | 作用 / 板怎么变 | 授权 |
|---|---|---|---|
| `sync_github` | `id`（返回 `{number, url}`） | 把节点出站成一个 **GitHub issue**，并把 issue 产物回挂到节点 | 节点 owner 或 admin |
| `register_pr` | `id`, `pr` | **登记 PR 号**：把 PR 链接挂到节点（不发评论）。这是一个**接力动作**（成功后向绑定会话播报 `[kanban:pr_registered]`） | 节点 owner 或 admin |
| `push_pr` | `id`（返回 `{url}`） | 把节点的需求摘要（requirement_digest）作为软留言 post 到已登记的 PR | 节点 owner 或 admin |
| `attach_code_file` | `id`, `sha`, `path`（返回 `{url}`） | 钉一个 commit SHA + 文件路径，拼成 GitHub blob 链接挂到节点 | 节点 owner 或 admin |
| `sync_prs` | 无（返回 `{advanced}`） | 轮询所有已登记 PR 的节点；PR 已 merged/closed 的自动 `set_status → done` | 持 cap 成员 |
| `sync_miro` | 无（返回 `{board_id}`） | 一键推 Miro：首次建板 + 绑定，之后复用同一块 Miro 板同步 | 持 cap 成员 |
| `set_board_config` | `github_repo`, `miro_board`（返回同名字段） | 写**本图**的连接器配置（GitHub 仓库名 + Miro 板名；token 不在这里，在全局凭证） | 持 cap 成员 |
| `bind_session` | `session_uri`（返回 `{session_uri}`） | **绑定**本看板到一个 session（见 §2.2）：之后接力动作会向该会话播报、触发下一个 agent | 持 cap 成员 |
| `save_github_creds` | `access_token`, `repo` | 保存**全局** GitHub 凭证 | admin-gated |
| `save_miro_creds` | `access_token`, `board_id` | 保存**全局** Miro 凭证 | admin-gated |

> World UI 还有几个**纯 UI 便捷动作**（不是 Behavior action，是前端 socket 事件）：
> `kanban.create`（新建一块板 = create_agent）、`kanban.select_board`（侧栏切换看哪块板）、
> `kanban.attach_upload`（上传文件 → 校验 grant → 底层走 `attach_artifact`）。功能上它们包在
> 上面 25 个 action 之外/之上，使用时你看到的是按钮，不用记动作名。

---

## ④ 跟 pm-coordinator agent 协作（派活 → dev 产物接力回 pm）

看板的「默认 agent」是 **pm**（role `pm-coordinator`，一个 cc-headless 大脑）。和 board agent
（passive）不同，pm 是**会聊天的 principal**：可以被 @、可以进会话群。pm 的职责是当**流程管家**——
判每个 gate、帮编辑、提醒缺啥、按 role 把活分给 dev。

从**终端用户视角**，一轮协作你会看到这些：

1. **你在会话里 @pm 派任务**（自然语言）。例如：
   `@pm 帮我把"用户登录"这个功能卡推进到 issue，分给开发。`
   pm 收到后会先**判 gate**（这张卡够不够进下一棒？缺啥它会直接告诉你），然后替你操作板。

2. **pm 替你 dispatch 改板 + 派活给 dev**。pm 用它**自己的 least-priv caps** 跑：
   - `kanban.claim_node` + `kanban.set_status doing`——把节点标成在做（pm 当 owner，担责）；
   - 然后 `mix ezagent session send --session <s> --message "@dev-together-kbflow ..."`
     把活以 @mention 派给开发 agent（带 scope / DoD / 分支要求）。
   你在会话里能看到 pm 发出的这条派活消息。

3. **dev 产出产物，自动接力回 pm**。开发 agent（跑 `dev-together` skill）只**产出 artifact**
   （分支/代码/一个 return 文档），**不碰板、不持有看板 caps**。它做完后用 `session send`
   把 return 发回会话给 pm。你在会话里看到 dev 的回复。

4. **pm 收 return 后接力到板上**。pm 判 DoD 达标后，用自己的 caps 把结果记到板：
   `github.create_issue` → `kanban.register_pr` → `kanban.set_stage pr` → `kanban.set_status done`。
   `register_pr` / `set_status` 是接力动作，会向绑定会话播报 `[kanban:pr_registered]` /
   `[kanban:status]`，于是看板 tab 自动刷新、下一棒被触发。

整条接力：**人 @pm 派任务 → pm 判 gate + 认领 + `session send` 派活 → dev dive/build/return（只给产物）
→ pm 收 return → pm 接力（register_pr / set_stage / GitHub）**。看板始终是唯一真相源，每个特权动作都
在「拥有它的身份」下执行。你作为终端用户，主要就是**@pm 提需求、在会话里看播报、在看板 tab 看板的变化**。

> 分工红线：dev **不**直接操作板（它没有看板 caps，硬 dispatch 会被 CapBAC 正确拒绝）；
> 只有 pm（和有权限的人类）能改板。所以「派活」靠 chat handoff，不是靠把板节点的 owner 改成 dev。

---

## ⑤ World UI 上你能看到什么

进一块看板（`/plugins/kanban/<board>` 或会话内 kanban tab）后，前端（`Kanban.tsx` /
`KanbanCanvas.tsx`）会渲染 `get_tree` 的投影：

- **节点树 / 看板**：每个节点显示 `title`、所属 `stage`（9 棒之一）、`owner`（认领人，未认领为空）、
  `status`（unassigned / claimed / doing / done）。
- **节点产物（artifacts）**：挂在节点上的工具产物（GitHub PR/issue、飞书文档、上传文件…）。
  file 类产物会签发可下载链接。
- **指标（metrics）**：价值/运营节点上的 `{name, target, current, unit}`。
- **drop 历史**：图级别被砍子树的记录（标题/stage/原因/数量）。
- **连接器状态**：本图的 GitHub 仓库、Miro 板绑定状态、凭证是否 configured。
- **CI 评价**：`pr` 棒节点会附一个 CI gate 评价摘要（徽章），来自 `get_tree` 里算好的 `ci` map。
- **stage 链**：9 棒的列/泳道（链来自 recipe config，不是前端写死）。
- **会话内播报**：板绑定 session 后，接力动作会在会话聊天流里出现 `[kanban:claimed]` /
  `[kanban:status]` / `[kanban:pr_registered]` 这类机器可读的播报。
- **操作反馈**：每次动作后 UI 会刷新（`last_dispatch_status` = `ok` 或 `error:<reason>`），
  动作失败不会静默——会显示错误原因（如 `error:forbidden`、`error:must_claim_first`）。

---

## ⑥ 完整示例：从绑板到一个节点走完一轮

下面用 CLI dispatch 演示一轮（World UI 点按是同样的动作，只是换成点按钮；@pm 协作见 §4）。
假设板 URI = `entity://system/agent/kbflow`，会话 = `session://system/default/kbflow`。

```bash
# 0) CLI 身份（你本人的 token + entity URI）
export EZAGENT_USER_TOKEN=<your-token>
export EZAGENT_ENTITY_URI=entity://system/user/<you>
B=entity://system/agent/kbflow

# 1) 把板绑定到团队会话（之后接力动作会播报回会话、触发下一棒）
mix ezagent dispatch $B --action kanban.bind_session \
  --args '{"session_uri":"session://system/default/kbflow"}'

# 2) 建根节点（链首 positioning，建根需 admin）
mix ezagent dispatch $B --action kanban.add_node --args '{"parent_id":"","title":"我的产品"}'
#   → {"id":"n1"}

# 3) 在根下加一个子节点（继承父 stage），然后逐棒推进
mix ezagent dispatch $B --action kanban.add_node --args '{"parent_id":"n1","title":"用户登录"}'
#   → {"id":"n2"}
mix ezagent dispatch $B --action kanban.set_stage --args '{"id":"n2","stage":"metric"}'   # 相邻棒推进

# 4) 认领并开始做（认领后才能 set_status）
mix ezagent dispatch $B --action kanban.claim_node --args '{"id":"n2"}'   # owner=你, status→claimed
mix ezagent dispatch $B --action kanban.set_status --args '{"id":"n2","status":"doing"}'

# 5) 挂一个产物（比如一份线框文档）
mix ezagent dispatch $B --action kanban.attach_artifact \
  --args '{"id":"n2","artifact":{"tool":"feishu","kind":"doc","ref":"login-wireframe","url":"https://..."}}'

# 6) 推进到开发棒，开 issue，登记 PR（接力动作，会向会话播报）
mix ezagent dispatch $B --action kanban.set_stage  --args '{"id":"n2","stage":"issue"}'
mix ezagent dispatch $B --action kanban.sync_github --args '{"id":"n2"}'           # → {number, url}
mix ezagent dispatch $B --action kanban.set_stage  --args '{"id":"n2","stage":"pr"}'
mix ezagent dispatch $B --action kanban.register_pr --args '{"id":"n2","pr":"123"}' # 播报 [kanban:pr_registered]

# 7) PR merge 后收尾：轮询 PR 状态，merged 的自动置 done
mix ezagent dispatch $B --action kanban.sync_prs --args '{}'                        # → {advanced}
# 或手动：mix ezagent dispatch $B --action kanban.set_status --args '{"id":"n2","status":"done"}'

# 8) 随时读全树看现状
mix ezagent dispatch $B --action kanban.get_tree --args '{}'
```

每一步若失败都会同步返回错误（如未认领就 `set_status` 会得 `must_claim_first`，跳棒会得
`stage_order_violation`，改别人节点会得 `forbidden`），不会静默——按提示修正即可。

---

## 速查：触发方式对照

| 想做的事 | World UI | @pm（自然语言） | CLI |
|---|---|---|---|
| 改板（建/认领/推进/挂产物/登记 PR…） | 看板面板按钮/表单 | `@pm <人话>` | `mix ezagent dispatch <board> --action kanban.<action> --args '<json>'` |
| 给队友派活/说话 | 会话聊天框 | `@pm` 让它派 | `mix ezagent session send --session <s> --message "@<member> ..."` |
| 看板的现状 | 看板面板 / 会话 kanban tab | `@pm 读一下板` | `mix ezagent dispatch <board> --action kanban.get_tree --args '{}'` |

记住三点：board agent 是 passive 的（不能直接 @，只能 dispatch/点按/让 pm 代操作）；所有动作都按
**你本人的身份和 caps** 授权（per-node owner 闸在 Behavior 里如实判）；动作不会静默失败，错误会带原因返回。
