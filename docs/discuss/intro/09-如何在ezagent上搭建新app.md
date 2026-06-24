# 09 · 如何用 ezagent 搭建一个新 app / 产品

> 基于上游最新 main（`b6818123`）。给"想用这套技术做产品"的人。
> 先读 [00 总览](./00-总览.md) 和 [08 socialware 深入](./08-socialware深入.md)。

## 先分清楚：你要"扩展平台能力"还是"做一个面向客户的产品"

ezagent 上"搭新东西"有两条**完全不同**的路，别混：

| | 路 A：写一个 **plugin** | 路 B：做一个 **socialware app** |
|---|---|---|
| 你在加什么 | 一种新的**平台能力**：新的 agent 类型 / 新渠道 / 新行为 | 一个**面向客户的产品实例**：公开会话 + 客户体验 |
| 形态 | 一个 OTP app（`apps/ezagent_plugin_xxx/`），编译进来 | 一个带 `public_view` 的**会话模板**（数据，不是新代码 app） |
| 例子 | cc（Claude Code）/ codex / curl（DeepSeek）/ feishu（飞书渠道） | 一个客服咨询页、一个电商买家围观页 |
| 改不改 core/domain | 不改，**声明式注册** | 不改任何代码，纯配置 + 编排 |
| 谁来做 | 平台/框架开发者 | 产品设计者 / 运营 |

**大多数"产品工作"是路 B**（不写代码，组合现有能力）。**只有当你需要一种平台还没有的底层能力时**才走路 A。

---

## 路 A · 写一个 plugin（加平台能力）

核心是**声明式**：你写一个 OTP app，`use Ezagent.Plugin`，在 `start/2` 里 `Ezagent.Plugin.boot(__MODULE__)`，然后只填一组**声明回调**，框架替你做所有注册——你**绝不碰** registry，编译期 `:ezagent_plugin_check` 强制这条规矩（参见 [03 插件与传输层](./03-插件与传输层.md)）。

要填的声明回调（按需）：
- `plugin_info/0` — 元信息
- `behaviors/0` — 这个插件提供哪些 Behavior（动作处理者）
- `template_classes/0` — 提供哪些模板类（怎么从模板造实例）
- `agent_flavors/0` — 提供哪些 agent "口味"（如 cc/codex/curl）
- `adapters/0` — 出站/桥接适配器（如飞书出站、agent_bridge）
- `config_surface/0` / `children/0` / `after_boot/0`

**最省事的起步**：照抄一个现有最像的插件改。
- 加一个"调某个 HTTP LLM API 的 agent"→ 抄 `apps/ezagent_plugin_curl_agent/`（它就是 OpenAI 兼容 HTTP，已是 `Entity.Agent` 的一个 flavor）。
- 加一个新的**入站渠道**（像飞书那样把外部消息接进来）→ 抄 `apps/ezagent_plugin_feishu/`：入站走 `InboundDispatcher` → `Invocation.dispatch`（`mode: :call`），出站写一个 `ExternalMirror.Adapter`。
- 加一个跑命令行 agent（像 cc/codex）→ 抄 `apps/ezagent_plugin_cc/`（PTY + agent_bridge）。

**铁律**（[01 核心框架层](./01-核心框架层.md) 的 P14）：跨 Kind 的唯一通路是 `Ezagent.Invocation.dispatch/1`，不许 `PubSub.broadcast` 到入站 topic；消息没人接收要有显式去处（死信队列/遥测），不能静默丢。

---

## 路 B · 做一个 socialware app（面向客户的产品）—— 重点

这是把 ezagent 变成"客户能用的产品"的路。**不写代码**，三步（详细见 [08 篇](./08-socialware深入.md) 和上游 skill）：

### ① 定义 app = 写一个 `public_view` 的会话模板
```elixir
{:ok, template_uri} =
  Ezagent.Entity.SessionTemplate.persist_version_as_system(
    %{name: "my-app", public_view: true},
    "team-alpha"          # workspace 名
  )
```
（CLI 等价：`mix ezagent.workspace.add_template <ws> <name> --json '{…}'`，但那条路还要 `class` 字段指定编排器 agent 类，比如 `cc`。最低摩擦用上面的 `persist_version_as_system/2`。）

### ② 从模板起一个活会话
```elixir
session_uri = Ezagent.URI.new!("session://team-alpha/default/my-app-1")
{:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Session,
  %{uri: session_uri, behaviors: Ezagent.Entity.Session.socialware_behaviors()})
:ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))
{:ok, _} = Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(
  session_uri, %{session_template_uri: template_uri})
```
产品流程里运营是在管理界面用 `Ezagent.Workspace.create_session/3` 建的——如果模板配了编排器，这步**还会一并起编排器 agent**（就是它生成客户界面）。编排器重、要 cc 凭证、可能超时，**但会话本身一定会持久化**——断言要断在会话上，别断编排器。

### ③ 把链接发出去
匿名访客打开 `/socialware/chat?session_uri=<session_uri>`，平台自动铸匿名用户、下 cookie、加入会话、返回客户端 SPA。

### 客户看到的界面是 agent 生成的
不是你写页面，是会话的**编排器 agent** 一轮轮组合出 React + json-render 的界面。"产品设计"在这条路上很大程度是**设计编排器怎么编排**（用什么 agent、什么规则、什么模板）——这正是**已落地**的 **agent-schema / agent-contract** 在规范的东西：一份声明式 `Ezagent.AgentManifest`（`apps/ezagent_core/lib/ezagent/agent_manifest.ex`）就能 spawn 出成员 agent，编排器用 `:participant` 工具把它招进会话。

---

## 验证（本地隔离 E2E，签收 = 匿名访客看到客户页截图）

简版（完整在 `.claude/skills/ezagent-socialware/references/local-e2e-recipe.md`）：
```bash
# 0 一次性：装客户端 SPA 依赖
cd apps/ezagent_web/assets && pnpm install

# 1 隔离 home + 库
export EZAGENT_HOME=/tmp/ezagent_sw_e2e MIX_ENV=dev
rm -rf "$EZAGENT_HOME"
mix ezagent.home.init && mix ezagent.home.adopt_db
mix ecto.create --quiet && mix ecto.migrate --quiet

# 2 在"服务节点内"种 app+活会话(关键：public_view? 读活 slice，必须同一个 BEAM)
#   把上面 ①② 的代码写成 seed.exs，然后：
export PORT=4030 PHX_HOST=0.0.0.0
nohup sh -c 'tail -f /dev/null | iex --dot-iex seed.exs -S mix phx.server' > /tmp/sw.log 2>&1 &
mix assets.build

# 3 验证匿名能看
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:4030/socialware/chat?session_uri=session://system/default/swlive"   # 期望 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4030/assets/js/customer_app.js                                       # 期望 200
# 浏览器打开 /socialware/chat?session_uri=… 应看到 "Your conversation" 客户面
```
⚠️ 工具链用 mise（OTP27/1.18），命令前加 `mise exec --`（见 [00 总览](./00-总览.md)）。

---

## 产品方向（决定你这条产品线往哪走）
- **world** = **已落地**的**统一前端**（`apps/ezagent_plugin_world`，React/shadcn + Vite 跑在一层 LiveView 通信壳上），已**复刻并退役**了原 LiveView 管理面（`apps/ezagent_plugin_liveview` 已物理删除）。它现在就是运营/作者面，`public_view` 勾选框、"建 socialware app" 的作者 UX 已经在 world 里。**注意边界**：world 目前只接管运营/作者面，**客户面**（`/socialware/chat`、`/socialware/customer`）**仍在旧栈** `ezagent_web` 上没动 —— "world 收编客户面"仍是 future。
- **agent-schema / agent-contract** = **已落地**的编排契约（`apps/ezagent_core/lib/ezagent/agent_manifest.ex`）：声明式 manifest（soul/skills/tools/caps/executor）+ 每 flavor 的 `flavor.compile`（纯渲染）+ `executor` 后端 fallback（cc→codex→curl，spawn 期 fail-closed）+ dispatch 撑起的 `tools[]`（`:action`/`:participant`，CapBAC 用空 ctx.caps）+ 复用不可变 `@hash` 的版本钉（`Ezagent.TemplateTags`）+ 账本追踪可恢复的 `migrate_session`。它定义客户体验里的 **agent 零件怎么被声明、换后端、版本化、迁移**。
- **loom / autoservice** = 只是设计词汇，**没进代码**，别当已有实现。

> 所以你这条产品设计线，落点很可能是：**在 socialware 这套底座 + 已落地的 world/agent-schema 底座上，设计一个新的统一客户出口和它的编排工作流**，而不是去改底层或搬旧的 autoservice/loom。
