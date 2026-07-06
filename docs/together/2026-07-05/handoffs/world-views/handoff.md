# Handoff — world 通用消费 SessionView registry

> Branch `feat/sw-world-views` · worktree `.claude/worktrees/sw-world-views` · 基线 `bf5e03e9`
> 三件套：本 `handoff.md` + `spec.md`（分节 dev spec）+ `plan.md`（TDD 逐 task）

## 一句话任务

world（那个 React 做的会话界面）现在会话面板顶上只有写死的 "Chat / PTY" 两颗按钮，页面（hello 的 Page）
是靠一个写死的布尔值 `is_hello` 硬塞进去的。这次要把它改成**通用**的：world 去问 `SessionViewRegistry`
（一个"谁注册了会话视图"的登记处）"这个会话、这个用户，能看到哪些视图？"，问到几个就出几颗 tab，并按视图声明的
渲染方式把内容画出来。做完之后，**别人注册一个新视图，world 不用改一行代码就能冒出对应 tab**。

这补的是一个真实缺口：视图契约（`SessionView`）和登记处（`SessionViewRegistry`）早就写好了，pty/routing/
external_mirror/hello-page 也都注册进去了，**但 world 从来没去读这个登记处**——它自己另搞了一套写死的 tab。
（对应 ezagent-scout Q8 T15(b) + 更广的 registry 消费。）

## 为什么不是"直接把注册的视图渲染出来就行"

有个绕不过的坎：`SessionView` 的 `render/1` 返回的是 **HEEx**（Phoenix 的服务端模板），是给早就退役的
LiveView 老界面用的；而 world 是 **React 单页应用**，它根本渲不了 HEEx。所以"通用消费"在 world 落地要拆成两层：

- **出 tab 这层是真·通用**：tab 列表 100% 由登记处 `applicable_views(会话, 用户)` 决定（这个函数本身就带了
  "视图适不适用" + "用户有没有权限看" 两道过滤）。
- **画内容这层按声明分派**：每个视图归到一个 world React 认得的 render mode——
  - `chat` → world 自己的 React 聊天流
  - `pty` → world 自己的 React 终端组件
  - `external` → 外部页面（hello/socialware 的页），复用现在已经在用的 iframe（`/socialware/external`，权限在路由再核）
  - `unsupported` → 只有 HEEx、world 没有 React 渲染器的视图（routing / external_mirror）→ 出一个诚实的
    "此视图暂无网页渲染器" 占位，**不静默藏起来**

聊天（chat）现在压根没注册到登记处（它是 world 原生默认面）。为了让它"也走登记处"，我们在 world 里注册一个
极小的 `Ezagent.World.ConversationView`（只为贡献那颗 tab，内容还是 React 画）。

## 动了哪些东西 / 边界（只碰 world）

- **允许改**：`apps/ezagent_plugin_world/`（owner，本来就是目标）。会加一条对 `ezagent_domain_ui` 的
  umbrella 依赖（登记处的属主），这是引用不是改它代码。
- **登记处属主 `ezagent_domain_ui`**：允许改，但**这次不用改**——`applicable_views/2` + `external_render?/1`
  已经够用了。计划里对它 0 改动。
- **禁止碰**：core / `ezagent_domain_session` / `ezagent_plugin_hello`（它的 PageView 早就按"world 通用消费"
  写好了，注释里明说"world 通用渲染任何注册的视图，所以不用改 world"——我们正是要兑现这句）/
  `ezagent_domain_socialware` / 其它任何 plugin。

## 迁移会带来的可见变化（要在 PR 里标出来，别当 bug）

- **PTY tab 变有条件**：以前每个会话都硬显示 PTY tab；改成登记处驱动后，只有"会话里有活着的 PTY 成员"才出
  PTY tab（这其实是修对了，但界面会变）。
- **Page 从右侧常驻分栏变成一等 tab**：hello 的页面以前挂在右边一直显示，现在是可切的 Page tab，且没
  `hello_render` 权限的人看不到它。
- **routing / external_mirror 会新冒两颗 tab**（占位）：它们注册了但只有 HEEx，world 画不了 → 出占位。
  是否给它们建 React 渲染器 **留给 Allen 定**（spec §7 open item），先按占位诚实落地。
- role-slot #1180/#1185 已落地，**不影响**本改动（不碰 Definition/recipe/role）。registry P1/P2（#1173/#1176）
  是 socialware 分发/安装侧，**与本 UI view registry 无关**。

## 分阶段 todolist

### Stage 1 — world server 读登记处出动态 tab 数据
- [ ] world `mix.exs` 加 `{:ezagent_domain_ui, in_umbrella: true}` 依赖（Task 1）
- [ ] 新建 `Ezagent.World.ConversationView`（chat 进登记处，人人可见、不 cap-gate）（Task 1）
- [ ] world `Application.start/2` 里 `SessionViewRegistry.init()` + 注册 ConversationView（Task 1）
- [ ] `ConversationData.session_views/2` + `session_view_ids/2` + `render_mode/2`（读 `applicable_views/2`，classify mode）（Task 2）
- [ ] `state_for/2` 出 `"views"` 数组、删 `"is_hello"` 布尔 + `page_session?` 死代码（Task 3）
- [ ] gate：`mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs` 绿 + conversation_view_test 绿

### Stage 2 — 内容渲染接线（React 侧）
- [ ] `Conversation.tsx`：加 `views` 类型、按 `state.views` 渲染动态 tab 条（图标 lucide 查表 + 缺省回退）（Task 4）
- [ ] 内容区按 active view 的 `mode` 分派：chat/pty/external/unsupported（Task 4）
- [ ] `HelloPagePreview` 通用化改名 `ExternalSurfaceView`（保留 open-in-tab + publish 控件），删 `isHelloSession` 右侧分栏（Task 4）
- [ ] `npm run build` 过、无 TS 错误（Task 4）

### Stage 3 — 授权 cap 门
- [ ] `switch_view/3` 白名单从写死 `["chat","pty","page"]` 改成 `session_view_ids(会话, 用户)` 动态集（Task 5）
- [ ] gate：`conversation_actions_test.exs` 绿——枚举内的 id 切得过、不在的 → `error:bad_view`

### Stage 4 — 现有 view 迁移不破坏 + cap 门回归锁
- [ ] 集成测试：cap-gated 视图对无 cap / 匿名 caller **不出 tab**（证 world 不绕过 `authorize_view/3`）（Task 6）
- [ ] gate：`mise exec -- mix test apps/ezagent_plugin_world/test` 全绿（含现有 visibility 测试无回归）

### Stage 5 — 真浏览器 e2e（禁 stub，每 stage 截图存 `e2e/2026-07-05/world-views/`）
- [ ] 新建 dev/test-only `Ezagent.World.TestView`（env guard 注册）（Task 7）
- [ ] 起真栈（Postgres + migrate + `npm run build` + `mix phx.server` @ 10042）（Task 7）
- [ ] Playwright：真登录 `admin@ezagent.chat`/`worlddev`；证 ① TestView 无脑冒 tab（通用枚举）② hello session
      冒 Chat/PTY/Page 且 Page 渲出真内容 ③ 匿名/非成员无 `hello_render` cap → Page tab 不出现（cap 门真控）
      ④ 切 tab 内容随之切换——每步截图（Task 7）
- [ ] gate：e2e 全绿 + 截图齐

## 完成的定义（DoD）

- world 会话 tab **完全**由 `applicable_views/2` 驱动，无任何写死的视图 id 列表；`switch_view` 白名单同源。
- 新注册一个 SessionView（如 TestView）**不改 world 渲染逻辑**就冒 tab（e2e 实证）。
- cap-gated 视图对无权限 caller 既不冒 tab 也切不过去（单测 + e2e 双证）。
- chat/pty/page 迁移后行为符合"迁移可见变化"那节的预期，无静默丢失。
- 改动只落在 `apps/ezagent_plugin_world/`（+ 一条 domain_ui umbrella dep）。
- 每 stage 有对应测试；Stage 5 有真浏览器 e2e + 截图。**别 commit，Allen 来 commit。**
