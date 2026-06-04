# ezagent Web Admin —— 静态 HTML 原型设计简报

本文档是一次性的设计简报，面向将为 **ezagent** web admin 制作静态 HTML/CSS 原型的 UI 设计师。原型交付之后，工程师会把它翻译回 Phoenix LiveView（HEEx）。本简报告诉你设计所需的一切信息，**无需阅读任何源代码** —— 下文出现的所有 `.ex`、`.css`、`.js` 文件路径都是给工程师后续参考用的，与你无关。本文档中的词汇表、页面界面、组件清单和约束对设计目的而言是完整的；如果某个组件名称或原语在正文中描述过，那就是完整列表 —— 你不需要去别处查。

请把本文档当作合约。视觉效果和微文案可以随意迭代，但请遵守 §2 的页面清单、§3 的组件拆分以及 §4 的 LiveView 约束 —— 这些决定了工程师能否干净地把你的 HTML 重新搬过去。如有不清楚的地方，请直接问 Allen，而不是钻进代码仓库里翻。

---

## 1. 使用逻辑 —— ezagent 是什么

ezagent 是一个 **多智能体编排平台**。四件事最重要：

1. **实体类型无关。**无论参与者是人类还是智能体，他们都可以使用同一套界面（人类通过浏览器，Agent通过agent-browser等自动化工具），同一套API，同一套CLI，没有只能人类使用或者只能智能体使用的操作接口。
2. **人类与智能体对话。** 一个人打开 admin，在聊天框里输入，由 LLM 驱动（或脚本驱动）的智能体回复。
3. **智能体之间互相对话。** 一个智能体可以在聊天房间里 `@mention` 另一个智能体；平台据此路由消息。
4. **一切都通过 Session 介导。** 一个 `Session` 就是一个聊天房间。任何身为该 Session 成员的人或智能体都能看到其中的消息。

到今天（v1，今晚刚到达此状态），系统是一个支持 PTY-in-browser 与远程 API（用于非 PTY 智能体）的多用户、多智能体 IM 平台。ezagent是所有功能的总集成：一个 Entity（用 `user://` URI 或者`agent://` 登录的人或者agent）配置 Workspaces、打开聊天、观察路由、并在需要时直接戳一下其他Entity。

### 每个 Entity 到处都会看到的词汇表

| 术语 | 它是什么 | URI 示例 |
|---|---|---|
| **Entity**（实体） | 任何一等公民参与者 —— 人类或智能体 —— 能持有 cap、加入 Session、并进行 dispatch | `user://allen`、`agent://cc/cc-architect` |
| **User**（用户） | Entity 的一种子类型，principal 是人类（用密码登录） | `user://allen` |
| **Agent**（智能体） | Entity 的另一种子类型，非人类（LLM、脚本、桥接）。URI 是带类型的：`agent://<类型>/<名称>`，见 PR #131 | `agent://cc/cc-architect`、`agent://curl/deepseek-coder` |
| **Session**（会话） | 一个聊天房间 —— 有成员、有消息、有路由。成员是 URI，与 Entity 子类型无关 | `session://review-room` |
| **DM**（私聊） | 两个 Entity 之间的隐式 1:1 Session | `session://allen-cc-architect-dm` |
| **Workspace**（工作区） | 持久化的集群配置：成员 + session_templates + routing_rules | `workspace://research` |
| **Kind**（类型） | 任何 Live 事物的类型标识符（User、Session、Agent、Workspace） | — |
| **Behavior**（行为） | 实例实现的能力表面（例如 `chat.send`） | — |
| **Capability (cap)**（能力） | 一份签名后的授权，允许某 Entity 在某实例上调用 `kind.behavior` | `chat.send@session://oncall` |
| **RoutingRegistry**（路由注册表） | 规则的全局表：matcher → receivers | — |
| **Template Class**（模板类） | 由插件注册、可被孵化（spawn）的 Kind 蓝图（例如 `cc.agent`） | — |

### 当前的 Agent 种类

每个 Entity 都应能一眼识别 —— 请给每种 Kind / agent 类型一个独特的图标/颜色：

| Template Class | 行为 | 给设计师的注释 |
|---|---|---|
| `cc.agent`（`mode: local-pty`） | 在服务器上的 PTY 中孵化一个真实的 **Claude Code TUI** | local-pty 模式是 **唯一拥有 xterm.js 视图的模式** —— 任何子类型的 Entity 都爱看 TUI |
| `cc.agent`（`mode: remote-channel`） | 为外部 Claude Code 进程铸造一份 token 桥接，让它通过 `/cc_socket` 加入 | 替代旧的 `cc.channel_instance` 拆分；把它当作同一个 `cc.agent` Template 的另一个 mode 呈现（PR-D2，2026-05-19）。很少作为焦点行；通常作为同名 agent 的 local-pty 行的子项呈现 |
| `curl.agent` | 把消息发到远端 HTTP completion API（DeepSeek、OpenAI 等） | 需要从调用方 Entity 的 KeyVault 取 API key。URI 形状：`agent://curl/<名称>` |
| `feishu.chat_binding` | 把一个飞书（Lark）群/私聊绑定到本地 Session | 双向桥接；两边都能看到所有消息 |
| `echo` | 测试桩，原样回显 | 用来在不烧 token 的情况下让新 Entity 熟悉系统 |

### 主交互窗口必须支持的两种模式

这是与通用 Slack-clone 最关键的视觉差异点：

- **Chat 模式（聊天）** —— Slack/Discord/飞书 的体验：滚动消息流、撰写框、右侧成员名单。对所有 agent 种类都适用。
- **PTY 模式** —— 当 agent 是 `cc.agent` 且 `mode` 为 `local-pty` 时，观察者可以直接切到 **实时 Claude Code TUI 的 xterm.js 视图**。他们看到的就是 CC 进程绘制到自己终端的同一份 TUI —— 完整的颜色、闪烁的光标、滚动回看。按键回流到 PTY。

设计必须允许任意观察者在同一个 agent 上 **切换（toggle）** Chat 与 PTY，或者把它们 **并排（side-by-side）** 摆放。主面板内的标签条（tab strip）、页头里的分屏切换按钮（split-pane toggle）、或一个滑出抽屉（slide-over drawer）都可以 —— 挑读起来干净利落的方式。分屏方案尤其漂亮，因为人类可以同时用键盘直接驱动 TUI，又能看着面向房间的聊天会话。

### Session 实际怎么展开（一天的工作）

下面的观察者是 `user://allen`，但当行动者是通过 agent-browser + `/api/v1` 驱动同一组界面的 agent 时，流程完全一致。

1. 落在 `/login`，以 `user://allen` 登录（或者，对 agent 而言：用 `agent://curl/myself` + secret 向 `/login` 发 POST）。
2. 抵达 `/admin`。左侧栏显示该 Entity 参与的 Sessions（他作为成员的房间），以及若干 "Floating agents"（已被孵化但尚未指派到任何房间的 agent）。
3. 点选 `session://review-room`。主面板显示聊天流；右面板显示成员（人类与 agent 任意混合 —— 它们都活在同一个 `members` map 里）。
4. 输入 `@agent://cc/cc-architect please look at PR #42`。发送。@mention 通过 RoutingRegistry 路由到该 agent，`cc.agent` 读到消息，将回复发回 Session。当房间里某个 agent `@mentions` 另一个 agent 时，触发的路径完全一致 —— Routing 对人类/智能体没有特例。
5. Allen 注意到回复有点慢，直接打开该 agent 的 DM，切到 PTY 模式，看到正在回复中的实时 TUI。看它工作，并直接往 TUI 里发送一个澄清按键。
6. 转去 `/admin/workspaces/research`，用自动派生（auto-derived）表单添加一个新的 `curl.agent` Template，然后跳回 chat，新 agent 已经加入。
7. 顺道去 `/admin/routing`，加一条 `from` 规则，把 `user://billing` 说的所有话都复制到 `session://oncall`。同一条规则的 `from` 参数同样可以写成 `agent://feishu/customer-bot` —— Routing matcher 是 URI 对 URI 的比较，不关心哪一边是哪个 scheme。

原型应让上述流程的每一步对人类与 agent 行动者都感觉理所当然。

---

## 2. 页面路由 —— 端点 + 跳转

Phoenix 路由器位于 `apps/ezagent_web/lib/ezagent_web/router.ex`。下面是原型必须镜像的完整路由清单，每条都用一行说明每个页面上发生了什么。

### Auth（由 controller 渲染，非 LiveView）

| 路由 | 方法 | 发生什么 |
|---|---|---|
| `/` | GET | `HomeLive` —— 小型落地页；已登录用户重定向到 `/admin` |
| `/login` | GET | 登录表单（URI + 密码） |
| `/login` | POST | 鉴权 + 重定向到 `/admin` |
| `/logout` | DELETE / POST | 清除 session，回到 `/login` |

### Admin core（全部位于 `:require_user` 之后）

| 路由 | LiveView | 用途 |
|---|---|---|
| `/admin` | `AdminLive` | **主中枢**：按 session 的聊天 —— sessions 侧栏、聊天窗口、成员面板、调试面板 |
| `/admin/workspaces` | `WorkspacesLive` | 列出 + 创建 Workspaces |
| `/admin/workspaces/:name` | `WorkspaceDetailLive` | 编辑一个 Workspace：成员、session templates（带 Template Class 选择器 + 自动派生表单）、路由规则（此处只读） |
| `/admin/routing` | `RoutingLive` | 全局 RoutingRegistry 编辑器 —— MentionRouting / SessionRouting 表的标签页，Form 模式与 JSON 模式的规则编辑器 |
| `/admin/users` | `UsersLive` | 列出 + 创建用户，设置密码 |
| `/admin/users/:uri/caps` | `UserCapsLive` | 每用户的能力（capability）授权 |
| `/admin/users/:uri/api-keys` | `UserApiKeysLive` | 每用户的 API key 保险库（供 curl-agent 等使用） |
| `/admin/snapshots` | `SnapshotsLive` | 观察持久化的 `kind_snapshots` 行 —— 列表、dump-to-JSON 弹窗、按行清除 |
| `/admin/agents` | `AgentsLive` | 列出由 PTY 管理的活跃 agent（目前仅 `cc.agent` 的 local-pty 模式） |
| `/admin/agents/:uri` | `AgentDetailLive` | 单个 agent 的状态：os_pid、cwd、最近 PTY 输出、重启按钮 |
| `/admin/agents/:uri/terminal` | `PtyTerminalLive` | 该 PTY agent 的 xterm.js 终端 |
| `/admin/auto/:kind` | `AutoDeriveLive` | **自动生成的列表**，针对任意已注册 Kind |
| `/admin/auto/:kind/:uri` | `AutoDeriveLive` | **自动生成的详情**，针对任意已注册 Kind 实例 |
| `/admin/feishu/bindings` | `FeishuBindingsLive` | 管理飞书 open_id ↔ 本地 user 绑定 |

### API / Dev（不面向设计师）

| 路由 | 用途 |
|---|---|
| `/_health` | JSON 存活探针 |
| `/api/cc-events` | 接收 CC hook 错误报告的 POST 端点 |
| `/api/feishu/webhook` | 飞书 webhook 接收器 |
| `/api/v1`、`/api/v1/:kind/:action` | 自动派生的 REST API —— 这是实体类型无关的 dispatch 表面；任何调用方（LV 驱动的人类、agent-browser 驱动的 agent、CLI）凭一份 bearer token 就能调用任意 `kind.behavior.action` |
| `/dev/dashboard` | LiveDashboard（仅 dev） |

你不需要为 API 或 dev 路由做设计。原型只需要为 **Auth** 与 **Admin core** 两个表里的行提供 HTML。

### 需要设计的跳转

- **Login → `/admin`** 鉴权成功后。
- **`/admin` ⇄ 其他所有 admin 页面** 通过左侧栏。
- **Sessions 侧栏 → 切换活跃 Session** 在 `/admin` 内部（无导航；LV 在原地替换消息流 + 成员）。
- **Agent 行 → `/admin/agents/:uri`**（状态）→ **`/admin/agents/:uri/terminal`**（xterm）。
- **Workspaces 列表 → Workspace 详情 → 添加 session template → 回到 `/admin` 看到新孵化的 Session 出现在侧栏。**

### 导航模型 —— 请替换掉当前的顶部导航

当前 LV 在 AdminLive 布局之上提供了一个由 5 个水平锚链接组成的细条状顶部导航。它在 v1 能用，但扩展不开。请设计一个像样的 **左侧栏外壳（left sidebar shell）**：

- 顶部 **Logo + 产品文字标志**。
- 顶部右侧或侧栏底部的 **已登录 Entity 胶囊**（avatar、当前 URI —— `user://allen` 或 `agent://curl/myself`、退出登录）。胶囊必须接受任一 Entity 子类型 —— 通过 agent-browser 驱动 admin 的 agent 看到的也是同一个入口。
- **主导航分组**（可折叠分组）：
  - **Chat（聊天）** —— 用户的 Sessions + DMs 列表（这是"在线"的工作面）。
  - **Workspaces（工作区）** —— 链接到列表，展开显示最近的 workspaces。
  - **Agents（智能体）** —— 链接到列表，展开显示运行中的 agent（带状态点）。
  - **Users（用户）** —— 仅 admin。
  - **Routing（路由）** —— 仅 admin。
  - **Observability（可观测性）** —— Snapshots、Audit log、CC Bridges。
  - **Integrations（集成）** —— Feishu Bindings，以及未来的 channel。
- 主面板根据当前激活的路由切换；侧栏保持挂载。

这意味着大多数 LV 页面会渲染进 *同一个* 外壳。外壳本身应是一个静态 HTML 片段，工程师可以把它放进 Phoenix layout 里。

---

## 3. 组件清单

当前的 LiveView 模块位于 `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/`。下面是每个视觉表面、它当前是什么、以及在原型里叫什么。

### 顶层 LiveView 页面

| 当前 LV 文件 | 当前用途 | 原型组件名 | 可复用？ |
|---|---|---|---|
| `admin_live.ex` | 三列布局：sessions 侧栏 + 聊天窗口 + 成员面板 + 下方调试面板 | `<ChatHubPage>` —— 由 `<SessionList>`、`<ChatStream>`、`<MemberRoster>`、`<DebugDrawer>` 组合 | 页面专用 |
| `workspaces_live.ex` | 列出 Workspaces + 创建表单 | `<WorkspacesPage>` | 页面专用 |
| `workspace_detail_live.ex` | 成员表 + session-templates 表 + Template Class 选择器 + 自动表单 + 只读路由规则 | `<WorkspaceDetailPage>` —— 由 `<MemberTable>`、`<TemplateTable>`、`<TemplateClassPicker>`、`<AutoForm>`、`<RuleViewer>` 组合 | 页面专用 |
| `routing_live.ex` | 标签条（MentionRouting / SessionRouting）+ 规则表 + 带 Form/JSON 模式切换的添加规则表单 | `<RoutingPage>` —— 由 `<TableTabs>`、`<RuleTable>`、`<RuleEditor>`（带 Form/JSON 切换）组合 | 页面专用 |
| `users_live.ex` | 用户表，含内联密码设置 + 创建用户表单 | `<UsersPage>` | 页面专用 |
| `user_caps_live.ex` | 列出 + 授予 + 撤销某用户的 capabilities | `<UserCapsPage>` | 页面专用 |
| `user_api_keys_live.ex` | 用户的 API key 保险库（provider + 掩码后的 key + put/delete） | `<UserApiKeysPage>` —— 使用 `<KeyVault>` | 页面专用 |
| `snapshots_live.ex` | 列出 `kind_snapshots` 行 + dump 弹窗 + clear | `<SnapshotsPage>` | 页面专用 |
| `agents_live.ex` | 活跃 PTY agent 的表 | `<AgentsPage>` | 页面专用 |
| `agent_detail_live.ex` | 单 agent 状态表 + 最近 PTY 输出 + 重启 | `<AgentDetailPage>` —— 使用 `<StatusGrid>`、`<TerminalOutputBlock>` | 页面专用 |
| `pty_terminal_live.ex` | 整页的 xterm.js 宿主 | `<PtyTerminalPage>` —— 包装 `<PtyViewer>` | 页面专用 |
| `auto_derive_live.ex` | 对任意 Kind 的通用列表/详情 | `<AutoDerivePage>` —— 使用 `<KindInstanceTable>`、`<KindDetailCard>` | 页面专用 |
| `feishu_bindings_live.ex` | 列出 bindings + 绑定表单 + 解绑 | `<FeishuBindingsPage>` | 页面专用 |

### `admin/` 内的子组件

| 当前 LV 文件 | 用途 | 原型组件名 |
|---|---|---|
| `admin/sessions_sidebar.ex` | Sessions 列表 + "New session" 表单 + Floating agents | `<SessionList>`（这是 app 外壳的一部分 —— 见下文） |
| `admin/chat_window.ex` | Session 页头 + 消息流 + 撰写表单 | `<ChatStream>` + `<MessageComposer>` |
| `admin/member_panel.ex` | 右面板成员表（uri / 在线 / 最近见到） | `<MemberRoster>` |
| `admin/debug_panel.ex` | CC Events 表 + CC Bridges 表 + 可折叠的 Debug 区（Echo、Manual Dispatch、Audit Log） | `<DebugDrawer>`（一个可折叠面板） —— 内部使用 `<EventTable>`、`<BridgeTable>`、`<ManualDispatchForm>`、`<AuditLogStream>` |

### 共享原语（Allen 已在 `ezagent_domain_ui/` 里建了一些）

代码仓库里已有一个受 shadcn 启发的小库，位于 `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex` —— 当前暴露 `<.button>`、`<.card>`、`<.badge>`、`<.page_header>`、`<.stat>`。请在原型中 **扩展这套词汇**；不要另起炉灶。使用下列名称并按需补充：

| 原语 | 原型必须展示的变体 |
|---|---|
| `<Button>` | `default`、`primary`、`success`、`danger`、`ghost`、`outline`；尺寸 `sm`/`md`/`lg`；加载态（`phx-disable-with` 的等价物 —— spinner + 变暗） |
| `<Card>` | 纯卡片；带 header slot；带 footer slot |
| `<Badge>` | `default`、`primary`、`success`、`warning`、`danger`、`info` |
| `<PageHeader>` | 标题 + 副标题 + actions slot（右对齐按钮） |
| `<Stat>` | 标签 + 数值；数字采用 tabular 对齐；success/warning/danger 变体 |
| `<StatusDot>` | 小圆点：绿=在线、灰=离线、琥珀=连接中、红=错误 —— 用于侧栏导航与成员名单 |
| `<Avatar>` | 用户：用 URI 取首字母组合（monogram）；agent：按 Kind 给小图标 |
| `<Tabs>` | 水平标签条 —— 用于 RoutingPage 与主面板的 Chat/PTY 切换 |
| `<Modal>` | 居中遮罩，含 header/body/footer —— Snapshot dump 使用它 |
| `<Toast>` | 闪现消息（成功 / 错误） —— 右下角，点击消失 |
| `<Table>` | 表头行 + 表体行 + 列头可选排序提示；斑马纹可选 |
| `<EmptyState>` | 图标 + 标题 + 一句话 + CTA 按钮 —— 用于空 Sessions 列表、空成员、无 Snapshots 等 |
| `<FormField>` | Label + input + 帮助文本 + 错误 slot。输入类型：`text`、`password`（掩码，可切换显示）、`uri`（等宽 + 协议校验提示）、`json`（textarea，等宽）、`select`、`textarea` |
| `<UriChip>` | 一个等宽胶囊，渲染 URI，悬停时显示复制按钮 |

### 领域专用可复用组件

这些是设计系统的核心；请把它们做得有质感且一致。

| 组件 | 出现位置 | 必须做什么 |
|---|---|---|
| `<SessionList>` | App 外壳左侧栏 | 分组显示："Direct messages（私聊）" 与 "Channels（多人 Sessions）"。DM 渲染为 `<Avatar> @对方`；Channels 渲染为 `# session 短名`。选中项高亮。每个分组底部有内联的 "+ New" 入口。 |
| `<FloatingAgentList>` | App 外壳左侧栏（底部） | 显示已注册但尚未加入任何 Session 的 agent。点击一行可通过小下拉框把 agent 加进一个 Session。 |
| `<ChatStream>` | ChatHubPage 主面板 | 倒序消息气泡，含发送者徽章、时间戳、顶部 "Load older（加载更早）" 按钮。新消息自动滚动。按发送者 Kind 区分气泡背景（user vs agent vs system）。 |
| `<MessageComposer>` | `<ChatStream>` 下方 | Mention 下拉 —— 应列出 **当前 Session 的每一个成员 URI**，不论 Entity 子类型（`user://`、`agent://`）。当前 LV 把下拉限制为仅 `agent://` URI；原型应把这视为 v1 bug，并把下拉设计成同样允许 Entity `@mention` 一个人类。文本输入框、发送按钮。当前 Session 没有其他可被 mention 的成员时禁用并提示。 |
| `<MemberRoster>` | ChatHubPage 右面板 | 成员表，含 `<StatusDot>`、URI、最近见到时间。通过 avatar/icon 在视觉上区分 Entity 子类型（human / agent / system），但行的处理、排序、操作是统一的 —— roster 不关心子类型。 |
| `<TemplateClassPicker>` | WorkspaceDetailPage | 横向按钮行，列出已注册的 Template Class（`cc.agent`、`curl.agent`、`feishu.chat_binding`、`echo` 等），外加一个 "JSON (custom)" 的逃生出口。点击某类 → 下方表单自适应。对 `cc.agent` 而言，表单包含一个 `mode` 字段（`local-pty` vs `remote-channel`）—— PR-D2 把之前的 `cc.pty` / `cc.channel_instance` 拆分合并为单个 Template 加一个 mode 切换。 |
| `<AutoForm>` | WorkspaceDetailPage、UserCapsPage 等 | 从一份 schema 描述符渲染出表单 —— 字段类型：`text`、`path`、`uri`、`select`。这是关键：见下文 §3a 它消费的 JSON 形状。 |
| `<RuleTable>` | RoutingPage | 行：ID + 来源徽章 + Matcher（等宽）+ Receivers（等宽，拼接）+ Delete/Disable/Enable 按钮。禁用规则的行变灰。 |
| `<RuleEditor>` | RoutingPage | Form 模式（matcher_type 下拉 + 参数输入 + receivers 字段）对比 JSON 模式（完整 matcher JSON 文本域 + receivers）。两种模式间用 tab 切换。同时设计一种 **wizard 模式**（见下文 UX polish），引导操作者走 {matcher} → {receivers} → {preview}。 |
| `<KeyVault>` | UserApiKeysPage | provider 名称 + 掩码后的 key（`sk-...XXXX`）+ "Reveal（显示）" 切换 + put/delete。添加 key 的表单含 provider 下拉与掩码输入。 |
| `<PtyViewer>` | PtyTerminalPage，以及 ChatHubPage 内当前 agent 为 `cc.agent`（local-pty）时的一个 tab | 一个黑盒子，工程师将通过 JS hook 把 xterm.js 挂进去。尺寸撑满容器。WebSocket 建立中显示 "Connecting…" 状态。 |
| `<BridgeTable>` | DebugDrawer | 列出连接到 `/cc_socket` 的 CC bridges：agent_uri、状态（绿点）、connected_at、客户端信息。 |
| `<EventTable>` | DebugDrawer | hook 报告的 CC 错误：等级胶囊、bridge_id、类型、文本、时间戳。 |
| `<AuditLogStream>` | DebugDrawer | 仅追加的派发记录表：target、action、鉴权结果、result、duration_us、at。流式更新；新行从顶部淡入。 |
| `<KindInstanceTable>` | AutoDerivePage 列表视图 | URI + 切片键徽章 + "detail →"。 |
| `<KindDetailCard>` | AutoDerivePage 详情视图 | 头部 URI；分节为 "Kind module"、"Behaviors"（含 action 列表）、"Slices"（每个 slice 一个可折叠块，JSON 美化）。 |
| `<SnapshotTable>` | SnapshotsPage | URI + kind_type + bytes + version + updated_at + "Dump" + "Clear" 按钮。 |

### 3a. `<AutoForm>` schema —— 工程师的杀手级抽象

这是系统中最重要的可复用组件。插件作者声明一个 Template Class，并通过 `Ezagent.UI.Form` behaviour 自描述其表单字段。UI 消费一组字段描述符并通用地渲染它们。描述符形状：

```json
[
  {
    "name": "agent_uri",
    "type": "uri",
    "label": "Agent URI",
    "required": true,
    "placeholder": "agent://cc/cc-architect"
  },
  {
    "name": "model",
    "type": "select",
    "label": "Model",
    "required": true,
    "options": ["claude-sonnet-4-7", "claude-opus-4-7", "claude-haiku-4-7"]
  },
  {
    "name": "cwd",
    "type": "path",
    "label": "Working directory",
    "required": false,
    "placeholder": "/var/lib/ezagent/projects/research"
  },
  {
    "name": "system_prompt",
    "type": "text",
    "label": "System prompt",
    "required": false
  }
]
```

字段类型在 v1 锁定为 **四种**：`text`、`path`、`uri`、`select`。建议的视觉处理：

- `text` —— 普通输入框。
- `path` —— 等宽输入框，边框颜色略有差异，或带一个前导文件夹图标。
- `uri` —— 等宽输入框 + 用户输入时的小 `<UriChip>` 预览，外加内联协议校验（`agent://…`、`user://…` 等）。
- `select` —— 使用 `options` 数组的下拉框。

每个字段渲染为 `<FormField label="..." required={true}>`，内含相应输入控件。必填字段加一个星号，校验失败时获得红色焦点环。

同一个 `<AutoForm>` 被复用于：Workspace 添加模板、用户能力授权（cap-grant）、Feishu 绑定，以及未来任何通过 `ezagent_domain_ui` 自动派生体系注册的 Kind。

---

## 4. 设计师必须知道的 LiveView 技术约束

你可能来自 React/Next.js 背景。Phoenix LiveView 在结构上不一样。原型用你喜欢的任何技术栈构建都可以，但为了确保工程师能干净地把它搬过去，请尊重下列约束。

### 4.1 LiveView 是什么

- LiveView 在 **服务器端渲染 HTML**，然后通过有状态的 **WebSocket diff** 流到浏览器。浏览器持 DOM；服务器持状态。
- 没有客户端路由。页面跳转要么是完整的 HTTP 请求，要么是在一个 `live_session` 内的 `live_redirect`（保留 WS 不断）。§2 中所有 admin 路由都位于同一个 `live_session :require_user` 内 —— 它们之间跳转很快，但各自是独立的 LiveView 模块。
- HEEx 模板语言是 LV 的 JSX 等价物：服务器端渲染的 HTML，带 `{@assigns}` 插值，外加 `:if`、`:for`、`:let`，以及通过 `<.component_name>` 进行的组件组合。

你不需要写任何 HEEx —— 但请 **避免那些 LV 无法在没有英雄主义的情况下复现的固化模式**：

| 在原型中可接受 | 在 LV 中麻烦 |
|---|---|
| 带命名输入（`name="user[uri]"`）的普通 HTML 表单 | 跨越重渲染自我管理 React state 的表单 |
| 触发 `onClick` 回调的按钮 | 修改客户端 store 并据此重渲染的按钮 |
| 通过 `?tab=routing` URL 或由服务器驱动的 `aria-selected` 实现的 Tabs | 状态仅存于客户端 JS、并能神奇地跨导航存活的 Tabs |
| 流式追加的列表行（向 `<ul>` 追加一个元素） | 虚拟化的 10 万行表格 —— 可能但昂贵 |
| 由服务器驱动的 `show?` 布尔决定显示的 Modal | 从全局 client context 堆叠的 Modal |
| 由 CSS class 切换驱动的入/出场动画（class 由服务器渲染的属性变化触发） | 复杂入/出场动画，需要 JS 同时知道前后状态 |

### 4.2 LV 中的组件

LV 组件有三种风味；这映射到工程师将如何复用你的原型组件：

- **Function components**（`def my_component(assigns)`） —— 无状态，仅是接受 attrs 的模板。你的 `<Card>`、`<Badge>`、`<Button>` 等大多数都会是这种。便宜，可任意深嵌。
- **Stateful child LVs**（用 `live_render` 挂载） —— 像一个承载服务器状态的 iframe。较重；少用。`<PtyViewer>` 可能会是这种，因为它的生命周期独立于页面。
- **JS hooks**（`phx-hook="MyHook"`） —— 一个 DOM 节点 + 一个 JS 模块，在 connect 时挂载，处理客户端行为，并把事件回推到 LV 进程。**xterm.js、代码编辑器、图表库、拖放、任何带丰富客户端状态的东西** 都用它。

### 4.3 React / Vue / Svelte 能放在哪里（不能放在哪里）

React/Vue/Svelte 组件 **可以嵌入** —— 但只能通过把它们包在 `phx-hook` 里，在 connect 时挂载框架。这是重型机械且增加构建依赖。

**建议**：原型中所有东西都首选纯 HTML/CSS + 轻量原生 JS。仅对真正无法约简的富控件保留框架：

- **xterm.js** —— 已在 `<PtyViewer>` 中使用。Hook 位于 `apps/ezagent_web/assets/js/app.js`，叫 `PtyTerminal`。DOM 合约是一个 `<div phx-hook="PtyTerminal" phx-update="ignore">`；hook 挂载终端，把 `term.onData(...) → pushEvent("pty_input", ...)` 接好，并监听 `handleEvent("pty_chunk", ...)`。在你的原型里镜像这一模式：渲染一个带正确尺寸的黑色 `<div>` 占位符，并标注为"集成时由 JS hook 接线"。
- **Monaco / CodeMirror** —— 如果你想为 RoutingPage 的 JSON 模式文本域做一个富 JSON 编辑器，可以；标注一下即可。
- **其他一切** —— 请使用纯 HTML。

**不要** 把原型做成带客户端路由的 SPA（Next.js App Router、React Router 等）。URL 跳转必须与 §2 的路由 1:1 对应 —— 每个路由一个 HTML 文件。工程师会把每个文件重新搬成一个 LiveView 模块。

### 4.4 CSS

使用 **Tailwind CSS v4**。应用的 `apps/ezagent_web/assets/css/app.css` 已包含 `@source` 指令，从插件 LiveView 路径 *以及* `ezagent_domain_ui` 拉取，因此你在原型 HTML 中使用的任何 Tailwind class，在工程师把 HTML 翻译回这些位置的 HEEx 时都会被自动采集。

- 尽量用 Tailwind 工具类（`px-4 py-2 text-sm`），别写自定义 CSS。
- daisyUI 也已配置（`@plugin "../vendor/daisyui"`） —— 如果适配可放心使用 daisyUI 组件，但 `ezagent_domain_ui` 中现有的原语是纯 Tailwind，新组件请优先采用此方式。
- 现有原语的调色板是 **zinc 中性色**（slate-grey 背景、柔和边框、rounded-md、shadow-sm），带语义色（`emerald` 表示 success、`red` 表示 danger、`sky` 表示 info、`amber` 表示 warning）。可以偏离，但工程师需要在整个原型范围内换调色板，而不是把你那套硬贴在现有方案之上 —— 所以请通过设计系统协调，不要散乱样式。
- 暗色模式通过 `data-theme="dark"` 启用。请为原语同时设计明色与暗色两套变体。

### 4.5 表单

LV 表单合约：

- 包在 `<.form for={@form} phx-submit="event_name">` 里。
- 输入命名为 `name="formname[field_name]"` —— 服务器端参数据此到达（`%{"formname" => %{"field_name" => "value"}}`）。
- `phx-change="event_name"` 在每次按键时触发，若你要实时校验。
- 提交通过 WebSocket 完成，而非浏览器导航。设计中不需要 `action=` 属性（由 controller 渲染的 `/login` 是例外 —— 那个是真正的 HTML 表单）。

**对设计师而言**：清晰地标注表单元素（`<form data-lv-submit="add_rule">` 或通过 `<!-- LV: phx-submit="add_rule" -->` 注释），让工程师知道要接哪些事件。给输入挑稳定、有描述性的 `name` 属性 —— 这些将原封不动地变成服务器端参数 key。

### 4.6 实时数据流

设计师应在 HTML 中标注两种模式：

- **Streams（`phx-update="stream"`）** —— 仅追加或仅修订的列表，行随时间到达。用于：聊天消息流、audit log、CC events 表。请在这些位置加注释，让工程师把它们接成 LV streams（否则默认会在每次更新时整列表重渲染）。
- **Live child islands（`<.live_component>` / `live_render`）** —— 自管理服务器状态的有状态子区域。`<PtyViewer>` 会是一个。`<DebugDrawer>` 也可能是。

### 4.7 没有客户端表单状态

这一点令人解放：你 **不需要** 为表单输入设计 Redux/Zustand/Pinia 的状态机。用户键入的内容存在于 LV 进程；每次按键（`phx-change`）LV 都会看到新值并可以重新渲染任何东西。原型的表单看起来就该像普通 HTML 表单。

### 4.8 原型交付什么

你可以用任意技术栈 *构建* 原型，但 **交付物** 必须是一个含 HTML 文件 + CSS（首选 Tailwind）+ 最少原生 JS 的文件夹。最简单的合约是：§2 中每个路由一个 HTML 文件。如果你想用工具构建（Astro、Eleventy、纯 HTML，甚至 Storybook），都很好 —— 把渲染后的静态输出交给工程师即可。

---

## 5. 架构分层 + 组件拆分

后端是分层的。请在原型目录结构中镜像该分层，使工程师的翻译变成机械操作。

### 后端分层（只读上下文 —— 不要提议变更）

| 层 | Apps | 此处的内容 |
|---|---|---|
| `ezagent_core` | `apps/ezagent_core/` | 与领域无关的基础设施：`Kind`、`Behavior`、`Capability`、`Routing`、`KindRegistry`、`BehaviorRegistry`、`RoutingRegistry`、`SpawnRegistry`、`Ezagent.UI.Form`（自动表单 behaviour） |
| `ezagent_domain_*` | `apps/ezagent_domain_instance_message`、`_identity`、`_workspace`、`_ui`、`_python` | 有界上下文。`_ui` 是 shadcn 风格 HEEx 原语（`<.button>`、`<.card>`…）所在地 |
| `ezagent_plugin_*` | `apps/ezagent_plugin_cc`、`_curl_agent`、`_feishu`、`_echo`、`_liveview` | 即插即用的 agent 集成。每个插件自注册其 Kind、Template Class，以及（通过 `Ezagent.UI.Form`）其表单字段。`ezagent_plugin_liveview` 本身也是一个插件 —— 它拥有所有 Live* 页面 |
| `ezagent_web` | `apps/ezagent_web/` | Phoenix endpoint、router、auth controllers、JS hooks、CSS pipeline |

北极星目标（Allen 的设计血脉所定）是 **plugin isolation（插件隔离）**：未来开发者通过编写一个插件 app 就能加入一种新 agent 种类，而不触碰 `ezagent_web` 或 `ezagent_plugin_liveview`。自动派生的表单 + 自动派生的列表/详情（`/admin/auto/:kind`）就是让这成立的机制。

### 建议的原型目录布局

```
prototype/
├── components/
│   ├── shell/
│   │   ├── sidebar.html               (左侧导航，带分组)
│   │   ├── top-bar.html               (页面标题、已登录用户、退出)
│   │   ├── page-frame.html            (承载页面的外壳包装)
│   │   └── floating-agents.html       (侧栏底部溢出列表)
│   ├── chat/
│   │   ├── chat-stream.html
│   │   ├── message-bubble.html
│   │   ├── message-composer.html
│   │   ├── mention-picker.html
│   │   ├── member-roster.html
│   │   └── session-list.html
│   ├── forms/
│   │   ├── auto-form.html             (消费 §3a 中的字段描述符 JSON)
│   │   ├── form-field-text.html
│   │   ├── form-field-uri.html
│   │   ├── form-field-path.html
│   │   ├── form-field-select.html
│   │   ├── form-field-password.html
│   │   └── form-field-json.html
│   ├── agent/
│   │   ├── agent-card.html
│   │   ├── status-badge.html
│   │   ├── status-dot.html
│   │   └── pty-viewer.html            (xterm.js 宿主占位)
│   ├── workspace/
│   │   ├── template-class-picker.html
│   │   ├── template-card.html
│   │   └── member-table.html
│   ├── routing/
│   │   ├── rule-table.html
│   │   ├── matcher-builder.html       (form 模式)
│   │   ├── matcher-json.html          (JSON 模式)
│   │   └── rule-wizard.html           (拟新增的引导式；见 UX polish)
│   ├── primitives/
│   │   ├── button.html
│   │   ├── card.html
│   │   ├── badge.html
│   │   ├── modal.html
│   │   ├── toast.html
│   │   ├── tabs.html
│   │   ├── table.html
│   │   ├── empty-state.html
│   │   └── uri-chip.html
│   └── observability/
│       ├── audit-log-stream.html
│       ├── bridge-table.html
│       └── event-table.html
└── pages/
    ├── login.html
    ├── admin-chat.html                (主中枢，已选中某 Session)
    ├── admin-chat-pty-toggle.html     (同一中枢，当前 agent 处于 PTY 模式)
    ├── workspaces.html
    ├── workspace-detail.html
    ├── routing.html
    ├── users.html
    ├── user-caps.html
    ├── user-api-keys.html
    ├── snapshots.html
    ├── agents.html
    ├── agent-detail.html
    ├── agent-terminal.html            (整页 xterm)
    ├── auto-derive-list.html
    ├── auto-derive-detail.html
    └── feishu-bindings.html
```

当工程师把每个 `pages/*.html` 翻回 LiveView 时，组件 import 是 1:1 映射：`components/chat/chat-stream.html` 变成 `EzagentPluginLiveview.Admin.ChatWindow.chat_stream/1`，依此类推。

---

## UX 打磨清单 —— 请把这些作为具体示例融合进来

Allen 明确点名了下列各项：

### 登录（Login）

当前 `/login` 表单要求填写完整的 `user://username` URI。**修掉它**：

- 接受纯标识符（`allen`）—— 服务器默认构建 `user://allen`。完整 URI 字段是高级回退，供其他 Entity 子类型使用（例如某个自动化 agent 通过同一端点登录自己时填 `agent://curl/myself`）。
- 提供一个切换 / 高级区，暴露完整 URI 字段，供非默认 URI 协议使用。
- 考虑一个 "Continue as guest（以访客继续）" 或一键 **dev 模式 admin 登入** 按钮 —— 由一条横幅守门："Dev mode only; disable in production"。
- 登录成功后跳转到 `/admin`，并打开 Entity 最近使用的 Session（若无则给一个友好的空状态）。

### 主聊天 —— Chat 与 PTY 切换

当任意 Entity（人类或 agent —— 两者都通过同一个 `/admin` LV 抵达此视图）打开某个 agent 的 DM（`session://allen-cc-architect-dm`），主面板应让他们选择：

- **Chat with this agent（与该 agent 聊天）** —— 隐式 Session 聊天流（默认）。
- **Open the PTY TUI directly（直接打开 PTY TUI）** —— 底层 `cc.agent`（运行在 `local-pty` 模式）的完整 xterm 视图。

主面板顶部的 **标签条**（"Chat" / "Terminal"）是最简设计。**分屏切换**（"Show side-by-side（并排显示）"）更强大 —— 左半边 chat，右半边 terminal。设计师定夺；两者皆可。

让这一项 **只在 DM 中的 agent 是 `cc.agent` 且 `mode` 为 `local-pty` 时才出现** —— 对 `cc.agent[remote-channel]`、`curl.agent` 或 `echo` agent，隐藏终端选项。

### Sessions 与 DMs 的视觉区分

在 `<SessionList>` 中清楚地分组：

- **Direct messages（私聊）** —— 标题标签，行显示 *对方* 的 avatar + 名称（而不是 DM 的 URI）。
- **Channels（多人 Sessions，频道）** —— 标题标签，行显示 `# session 短名`，附带成员数。

当前 LV 用等宽字体显示完整 session URI；用更友好的渲染替换它。悬停 tooltip 显示 URI。

### 路由规则引导（Routing rule wizard）

当前 `/admin/routing` 是一个扁平表 + 一次性添加规则的表单。新 Entity 容易困惑。在现有表单之外，请设计一个 **rule wizard（规则向导）**：

1. **Step 1 —— When?（何时？）** 选 matcher：`mention`（任何 Entity URI 被 @ —— 对 `user://` 和 `agent://` 目标都生效）、`from`（特定发送者，同样可为任意 Entity URI）、`text_contains`（文本包含）、`text_matches`（文本匹配）、`always`（始终）。每个选项给一段简短说明。
2. **Step 2 —— What's it about?（关于什么？）** 填入 matcher 的参数（`mention` / `from` 的 URI、`text_contains` 的子串、`text_matches` 的正则）。内联预览将匹配到的 sessions/messages。
3. **Step 3 —— Who receives it?（谁接收？）** 从注册表多选 URI（user/agent URI 可自由混合），外加魔法 token `$session_members`（UI 中渲染为 "(dynamic) all members of the current session"）。
4. **Step 4 —— Preview & save.（预览与保存）** 显示规则最终形态（下方给出 JSON 供高级用户），保存按钮。

保留现有的扁平表单模式作为高级用户的 "quick add（快速添加）" 切换。

### 能力授权 UI（Capability grant UI）

当前 `/admin/users/:uri/caps` 是一个列表 + 一个自由文本授权输入。请设计为：选 Kind → 选 Behavior → （可选）选实例 URI → 确认。已授予的 cap 渲染为 `<Badge>` 胶囊，点击胶囊的 × 可撤销。

### API key 保险库

默认全部掩码。使用眼睛图标的 "reveal（显示）" 模式。在 "Put（提交）" 时显示一次性确认（key 已保存），之后再也不重新显示。

### 空状态（Empty states）

每个列表都有空状态；请为它们做设计：

- 无 Sessions → "Create your first Session（创建第一个 Session）" CTA 打开新建 session 的内联表单。
- 无 Workspaces → "Create a Workspace（创建一个工作区）" → workspaces 页面。
- 无 Agents → 说明当某 Workspace 加入 `cc.agent` Template（或任何其他 agent Template Class）时 agent 才会出现；链接到 Workspaces。
- 无 CC Bridges → 说明 bridge 在 `cc.agent` 运行于 `remote-channel` 模式（或 `local-pty` agent 的 Python sidecar）加入 `/cc_socket` 时建立。

### Toasts / flash 消息

目前 LV 在每页内联渲染 `<p style="color: red">`。用 toast 模式替换（右下角，滑入，4 秒后自动消失，点击关闭）。工程师会把 `Phoenix.LiveView.put_flash/3` 接到你的 toast 组件来渲染。

### 退出登录（Sign-out）

始终可在外壳中触达 —— 侧栏底部，与用户胶囊在一起。

---

## 你 **不应** 做的事

- 不要 列举详尽的 HEEx 示例。HEEx 由工程师写，不是你。
- 不要 提议后端架构的变更。§5 的分层是固定的；原型必须适配它。
- 不要 一上来就敲定配色方案 —— 给出选项。现有的 zinc/emerald/sky/amber/red 调色板是基线，但设计师的决定为准。
- 不要 在交付物里写 Elixir 或 HEEx。
- 不要 设计带客户端路由的 SPA —— 页面跳转必须映射到 §2 的路由表。
- 不要 试图通过这份 markdown 与 Allen 头脑风暴 —— 与他另行迭代。本文件是一次性上下文。

---

## 设计师可忽略的参考文件（工程师注释）

下列内容是 LV 工程师反向工程时的指针；设计师不需要打开它们：

- 路由器：`apps/ezagent_web/lib/ezagent_web/router.ex`
- LiveView 模块：`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*.ex`
- Admin 子组件：`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/*.ex`
- 自动表单 behaviour：`apps/ezagent_core/lib/ezagent/ui/form.ex`
- shadcn 风格原语：`apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex`
- Tailwind 配置：`apps/ezagent_web/assets/css/app.css`
- xterm.js hook：`apps/ezagent_web/assets/js/app.js`（搜索 `PtyTerminal`）
- 登录 controller（唯一的非 LV 页面）：`apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`

---

## Definition of done —— 设计师交付什么

一个匹配 §5 布局的 `prototype/` 目录，含：

1. **§2 中每个路由（Auth + Admin core）一个 HTML 文件**。
2. **一个组件库**，位于 `prototype/components/`，含 §3 中的原语与领域组件，每个都是独立的 HTML 片段，工程师可复制粘贴进 HEEx 函数组件。
3. **一份 Tailwind 配置**，在 Tailwind v4 下能干净编译（或者工程师可移植的原生 CSS）。
4. **明色与暗色两套变体**，至少在外壳 + 主聊天页面上展示。
5. **一份简短的 index.html**，列出每个页面 + 每个组件以供视觉评审。

就这些。把这些发出来，工程师从那里接手。
