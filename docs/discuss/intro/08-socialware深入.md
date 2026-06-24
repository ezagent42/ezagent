# 08 · socialware 深入（这个技术最关键的产品概念）

> 基于上游最新 main（`b6818123`，2026-06-22）+ 上游刚加的权威 skill `.claude/skills/ezagent-socialware/SKILL.md`。
> 这一篇专门把 socialware 讲透——它是"用 ezagent 做面向客户的产品"的核心。

## 一句话：socialware 就是"把一个会话公开出去，让外面的陌生人也能看、能进"

ezagent 平时的会话是给**注册的操作员**（运营/管理员/agent）用的，外人看不到。**socialware 做的事，就是给一个会话打开一道公开的门**：没注册的、匿名的外部访客（比如电商买家、客服的咨询用户）也能通过一个链接进来围观这个会话、甚至参与。

这就是把 ezagent 从"内部多 agent 编排系统"变成"能对外提供客户体验的产品"的那一层。

## 核心心智模型：一个 socialware app = 一个带 `public_view: true` 的会话模板

记住这一个就够了，代码都是它的展开：

- **socialware app（应用本身）** = 一个 **SessionTemplate（会话模板）**，它的内容里带了 **`public_view: true`** 这个标志。模板是这个 app 的**持久、可版本化、可 fork 的定义**。
- **session（会话）** = 这个模板的一个**活实例**，绑定在模板上。它才是用户真正连进来的东西——对话、成员、状态都在这里。
- 客户拿到的链接指向一个 **session**，但让这个 session "成为一个 socialware app" 的，是它**背后那个带 `public_view` 的模板**。

所以作者（你）要做的就三件事：**① 定义 app = 写一个 `public_view` 的会话模板；② 从模板起一个活会话；③ 把链接发出去。**

`public_view: true` 是**整套匿名访问生命周期的"结构性授权开关"**——它一打开，匿名用户铸造、只读加入、客户端页面、匿名→登录合并这一整套才被允许。这个标志由 `Ezagent.Socialware.PublicView.public_view?/1`（`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex`）在公开入口处、铸造任何匿名用户**之前**检查。

> ⚠️ **fail-closed 语义**：只有字面布尔 `true` 才打开；`"true"`（字符串）、`false`、或没写 = 私有。

## 一个 socialware app 对外暴露两个面

| 路由 | 控制器 | 给谁看 | 渲染什么 |
|---|---|---|---|
| `/socialware/chat?session_uri=…` | `ChatFeedController` | 匿名访客（`public_view` 会话）| 服务端壳 + 客户端 React SPA（`customer_app.js`）|
| `/socialware/customer?…` | `CustomerController` | token 绑定的客户 | 同一套 React + json-render 客户端 SPA |

（控制器在 `apps/ezagent_web/lib/ezagent_web/controllers/socialware/`。）

**关键**：客户看到的界面是 **agent 动态生成的**（由会话的编排器 agent 一轮一轮组合出来，React + json-render），**不是手写的 HEEx 页面**。运营/管理员那套界面（今天是 world）是另一回事。

## 匿名访问生命周期（自动的，你基本不用碰）

匿名访客第一次打开 `/socialware/chat`：
1. `public_view?` 门控通过 → 铸造一个 `Ezagent.Socialware.AnonUser`（只读、权限很窄）。
2. 记一条 `AnonBinding`（一个匿名用户 ⇄ 一个会话，终身绑定）。
3. 下发一个签名的 `socialware_anon` cookie。
4. 把这个匿名用户加入会话、返回带 `data-token` 的客户端 SPA。
- 废弃的匿名用户 48 小时后由 `AnonUser.GC` 回收。
- **匿名→登录接管**：匿名用户后来登录了，它的足迹会被"物理改名"成那个确认用户（`EzagentWeb.Socialware.AnonTakeover`，anon-user epic #68——这正是上游这几天在做的事）。

## 几个会浪费你时间的坑（skill 里血泪总结）

1. **`public_view?/1` 读的是"活会话"的 slice**：一个带 `public_view` 的会话如果当前没在服务节点里活着，门控就过不了，访客被踢去 `/login`（302）。正常产品流程里会话是在管理界面"当场"建的所以是活的；如果你在另一个进程里种了会话再启动服务，服务看不到它 → 302。
2. **`public_view` 是模板级开关，没有 per-session 开关**：world 已在「Session templates」面板提供「Public socialware app」勾选框（保存时 dispatch `Ezagent.World.WorkspacePluginActions.save_session_template/2` → `SessionTemplate.create/3` 写 `public_view: true`）；也可继续走模板内容/CLI JSON 设。注意它在**模板**上设，world 的「New session」表单不暴露这个标志——会话从所选模板继承。
3. **客户端 SPA 必须先 build**：`/socialware/chat` 加载 `customer_app.js` + `customer.css`，依赖在 `apps/ezagent_web/assets/package.json`（react/react-dom/sandpack），`node_modules` 没装的话页面是 HTTP 200 但**空白**。修：`cd apps/ezagent_web/assets && pnpm install` → `mix assets.build` → 刷新。

## 怎么验证一个 socialware app（本地 E2E）
权威 recipe 在 `.claude/skills/ezagent-socialware/references/local-e2e-recipe.md`（用隔离的本地栈：独立 `EZAGENT_HOME` + 独立端口，不碰共享 dev/prod 节点）。签收标准是"匿名访客能看到渲染出来的客户页面"的截图。简要见本系列 [09 篇](./09-如何在ezagent上搭建新app.md)。

## 关键模块速查（都已核实存在）
- `Ezagent.Entity.SessionTemplate`（`apps/ezagent_domain_session/.../entity/session_template.ex`）—— app 定义；`public_view` 内容键、`persist_version_as_system/2`。
- `Ezagent.Socialware.PublicView`（`public_view.ex`）—— `public_view?/1` 公开入口门控。
- `Ezagent.Entity.Session` —— `socialware_behaviors/0`；会话 Kind。
- `Ezagent.Behavior.Session.ConfigActions` —— `system_set_working_copy/2`（把会话绑到模板）。
- `ChatFeedController` / `CustomerController` —— 两个公开面。
- `Ezagent.Socialware.{AnonUser, AnonBinding, ChatFeed, CustomerFeed}` —— 匿名生命周期 + feed 投影。
- `EzagentWeb.Socialware.{AnonCookie, AnonTakeover}` —— 签名 cookie + 匿名→登录合并。
- `EzagentPluginWorld.WorldLive` + `Ezagent.World.WorkspacePluginActions` —— world 作者面（`save_session_template/2` 写 `public_view`）。

## 产品方向：world + agent-schema（已落地 main，#882）
之前列为"在建"的两条线现在**都已落到 main**，socialware skill 也同步标成"landed on main"：
- **world** —— **已落地**的统一 ezagent 前端（React/shadcn + Vite，跑在一层只做 SSR/通信壳的 LiveView `WorldLive` 上、用 `phx-hook="WorldRenderer"` 注水 TSX islands），挂在 `host: "world."`。它已**复刻并退役**了原管理端 LiveView 插件（`apps/ezagent_plugin_liveview` 已物理删除），运营/作者面现在就是 world——`public_view` 勾选框和"建 socialware app"作者 UX 都已在这里（见上文坑 #2）。**注意边界**：world 目前只接管运营/作者面；**对外/客户面**（`/socialware/chat`、`/socialware/customer`）**仍在旧栈** `ezagent_web` + `ezagent_domain_socialware` 上没动，本篇前面所有客户面描述（React + json-render SPA、两个公开面控制器）依旧成立。"world 最终也吃掉客户面"这件事**仍是 future**（skill §Future 还没做）。
- **agent-schema（= agent-contract）** —— **已落地**的 agent 声明契约：`Ezagent.AgentManifest`（schema + loader + slot render，`apps/ezagent_core/lib/ezagent/agent_manifest.ex`）+ 每 flavor 的 `flavor.compile`（纯渲染、泛化 SoulRenderer）+ `executor` 后端 fallback（spawn 期、fail-closed）+ dispatch 撑起的 `tools[]`（`:action`/`:participant`，CapBAC 用空 `ctx.caps`，`apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex`）+ 复用不可变 `@hash` pin 的 adopt-on-create + 账本追踪可恢复的 `migrate_session`（CLI 门面 `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex`）。它定义编排器 agent 怎么把后端服务组合出客户体验。

> ⚠️ **loom** 和 **autoservice** 仍是"仅供参考的设计词汇"，**没合进代码**，别当成已有实现引用。
> world（已是运营/作者面唯一前端，未来收编客户面）+ agent-contract（编排契约）合起来就是 socialware 产品化的底座。
