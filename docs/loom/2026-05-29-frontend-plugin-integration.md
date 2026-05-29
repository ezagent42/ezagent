# Loom 前端集成进 plugin — 设计 spec

- **日期**:2026-05-29
- **状态**:设计已定,待实现
- **母 spec**:`docs/superpowers/specs/2026-05-28-plugin-loom.zh_cn.md`(loom plugin 本体)
- **取代**:`docs/loom/FRONTEND_DIST_PLAN.md`(旧的 SDK+dist 模型,已废弃)
- **关联约定**:`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`(plugin → ezagent_web 唯一合法触碰 = 一条 `forward`)

---

## 0. 一句话

把前端项目 `ai-ui-builder`(Next.js 14,AI 对话 + Sandpack 浏览器内沙箱实时渲染 React 页面)集成进 loom plugin:plugin(全局)装上后,ESR 在 `/loom/:workspace/:session_id` 这条**路由**(非新端口)上提供这个前端页面。每个 session 在该路由下有自己的一份页面,互不影响。

## 1. 背景:被集成的前端是什么

`C:\Users\Ning\Desktop\loom\ai-ui-builder`:

- **栈**:Next.js 14 App Router + TypeScript + Tailwind 3 + Vercel AI SDK v4 + Zustand。
- **左栏**:`ChatPanel`,`useChat({ api: '/api/chat' })`。
- **服务端唯一依赖**:`app/api/chat/route.ts` —— `streamText` 打 **DeepSeek-V4-Flash**(OpenAI 兼容,非思考模式),用自定义 `fetch` 注入 `thinking:{type:'disabled'}`。用的 key 跟 loom 后端同一把。
- **右栏**:`PreviewPanel`,`@codesandbox/sandpack-react` —— **浏览器内**打包器,实时渲染 AI 生成的 React/JSX(Tailwind 走 Play CDN)。所谓"沙箱"是客户端 Sandpack,**不是**服务端进程。
- **代码提取**:`ChatPanel` 用正则从 AI 回复里抓首个 jsx 代码块 → 写 Zustand → Sandpack 重渲染。
- **已有 platform-sdk 桩**:`lib/sandbox/platform-sdk.ts` 往 Sandpack 注入 `/platform.js`,暴露 `sendMessage({text}) → POST {NEXT_PUBLIC_PLATFORM_URL}/messages`。当前是桩(URL 空时模拟成功)。这是"生成页 → 平台"的预留桥,本期**不接**。

**关键事实**:唯一需要服务端的是 `chat → DeepSeek` 这条代理;其余(Sandpack 预览)纯客户端。所以"用 plugin 托管"非常可行。

## 2. 已定决策(brainstorm 闭环)

| # | 决策 | 理由 |
|---|---|---|
| **D1** | **本期与 loom 编排后端解耦**。页面保持自己的直连-DeepSeek 生成,不走 loomorch/worker/飞书。 | 用户:"关系暂时不管"。最小耦合,先把托管链路跑通。 |
| **D2** | **作为现有 Phoenix server 上的一条路由提供,不开新端口;运行期无 Node**。 | 用户明确"以路由而非新端口"。排除 Node sidecar + 反向代理方案。 |
| **D3** | **per-session 路由 `GET /loom/:workspace/:session_id`**,独立标签页;workspace session 列表里给 loom session 加"打开 Loom ↗"链接。 | 用户选;workspace + session 两段才能全局唯一定位(`session://loom/<ws>/<name>`)。 |
| **D4** | **聊天代理非流式**,直接复用现有 `EzagentPluginLoom.DeepSeek.chat/2`。 | 页面本来就是等完整 JSX 代码块才渲染,流式只影响"逐字"观感;复用 = ESR 零新增 HTTP 代码。 |
| **D5** | **dist-only**:ESR 仓库只放构建产物;前端**源码留在 Desktop 仓库**;集成适配做成 Desktop 源码里的**环境开关**。 | 用户:以后在自己前端仓库改完 build 放进来即可。运行期/部署免 Node + clone 即跑。 |
| **D6** | plugin 是**全局/节点级**装一次(编进 umbrella 或 `mix ezagent.plugin.install`),**没有**按 workspace/session 的启用开关,也没有 uninstall(V2)。 | 核实自 `Ezagent.PluginRegistry` / `mix ezagent.plugin.install` / `Ezagent.Plugin.boot/1`。"session 装 plugin"在 ESR 里无对应机制,勿用该措辞。 |

**层级澄清(写给未来的自己,防架构漂移)**:plugin 全局 → `/loom` 路由全局存在 → 任何 workspace 里的任何 session 都能在 `/loom/<ws>/<它的id>` 打开**自己那一份**。workspace 只是 session 所在的命名空间,**不"含"也不"装"** plugin;页面也**不"属于" workspace**,而是按 session 分身。

## 3. 架构 & 数据流

```
浏览器 ── GET /loom/system/s_4575ef96 ───────────► ezagent_web Router
                                                     forward "/loom" → EzagentPluginLoom.WebPlug
                                                        ├─ Plug.Static  → priv/static/loom_ui/*  (资源:/_next 等)
                                                        ├─ POST /api/chat → 见下
                                                        └─ GET /:ws/:sid  → index.html (SPA 兜底)

浏览器 ── POST /loom/api/chat {messages} ─────────►  WebPlug
                                                        → 拼 page-gen 系统提示词
                                                        → EzagentPluginLoom.DeepSeek.chat/2
                                                                          → https://api.deepseek.com
                                                        ◄── 一次性完整文本 (text/plain) ──┘
Sandpack(浏览器内)── 渲染从回复里提取的 JSX ──(完全不经过服务端)
```

ESR 核心总侵入 = **1 行 `forward` + 1 个 workspace LV 链接**。唯一的服务端活就是聊天代理,且复用现成的 `DeepSeek.chat/2`。

## 4. 组件 & 边界

| 单元 | 位置 | 职责 | 依赖 |
|---|---|---|---|
| **前端构建** | `Desktop\loom\ai-ui-builder`(源码,**不进 ESR 仓库**) | 见 §5 的 4 处适配(环境开关)。`pnpm build` 产出 `out/` | Node/pnpm,**仅构建期** |
| **vendored dist** | `apps/ezagent_plugin_loom/priv/static/loom_ui/`(**提交**) | 被 `Plug.Static` 喂的静态产物 | 无(运行期免 Node) |
| **`EzagentPluginLoom.WebPlug`** | plugin(**新建** `lib/ezagent/web_plug.ex`) | `Plug.Static` 资源 + `GET /:ws/:sid`→index.html + `POST /api/chat` 代理 | `DeepSeek`、`Prompts`、`Plug.Router` |
| **`EzagentPluginLoom.Prompts`** | plugin(**已有**,新增一个常量) | 新增 `page_gen_system_prompt/0`(从前端 `lib/ai/system-prompt.ts` 搬来,ESR 持有) | — |
| **`ezagent_web` 路由** | 核心(**改 1 行**) | `forward "/loom", EzagentPluginLoom.WebPlug`,置于兜底 `/*path` 之前 | `:ezagent_plugin_loom` 已是 dep |
| **workspace session 列表 LV** | `EzagentPluginLiveview`(**小改**) | 给 loom session(`session://loom/...`)渲染"打开 Loom ↗"链接 → `/loom/<ws>/<短id>`(`target="_blank"`) | — |

## 5. 前端适配契约(做在 Desktop 源码里,环境开关)

下面 4 处改动必须落在 **Desktop 源码**(否则下次 rebuild 丢失),并做成**按环境开关**,使 `pnpm dev` 仍能独立跑、只有"面向 ESR 的 build"才切到 `/loom`:

1. **`next.config`**:`output: 'export'`,`basePath`/`assetPrefix` 在 ESR 构建模式下 = `'/loom'`(让 Next 产出**绝对**资源链接 `/loom/_next/...`,页面路径多深都不影响寻址);`images.unoptimized: true` 兜底。
2. **去掉 `app/api/chat/route.ts`**(静态导出不能带 Route Handler;聊天改由 ESR 提供)。standalone dev 仍要它 → 用环境开关:dev 保留、export 时排除(或把 handler 标 `export const dynamic`/条件编译)。系统提示词从这里搬到 ESR(§4 Prompts)。
3. **`useChat`**:`api` 在 ESR 模式 = **绝对路径** `'/loom/api/chat'`(不可写相对 `api/chat`,否则解析成 `/loom/<ws>/<sid>/api/chat`),并设 `streamProtocol: 'text'`。
4. **`app/page.tsx`**:从 `window.location.pathname` 解析 `:workspace` + `:session_id`,作为**状态隔离键**(见 §8)。

env 开关建议:用一个 build-time flag(如 `NEXT_PUBLIC_ESR_MODE=1` 或 `process.env.NODE_ENV==='production'` + 自定义变量)统一切 basePath / chat-url。

> **Node 只在前端仓库、只在构建/调试时出现**:`pnpm dev`(可选,独立预览)和 `pnpm build`(改前端时重出 dist)都在 `Desktop\ai-ui-builder` 跑。**ESR 永不跑 Node / 永不跑 dev** —— `mix phx.server` 直接喂已提交的 dist。

## 6. ESR 端:WebPlug

`EzagentPluginLoom.WebPlug`(`use Plug.Router`),经 `forward "/loom"` 挂载 —— **forward 会剥掉 `/loom` 前缀**,所以 plug 内部看到的是相对路径。

**匹配顺序(重要)**:
1. `plug Plug.Static, at: "/", from: {:ezagent_plugin_loom, "priv/static/loom_ui"}, only: [...]` —— 命中 `_next`、字体、`favicon` 等真实文件;非文件 fall through。
2. `post "/api/chat"` —— 显式、且是 POST;不会被下面的 GET 误吞。
3. `get "/:workspace/:session_id"`(以及 `get "/"`、`get "/:workspace"` 兜底)→ 读 `priv/static/loom_ui/index.html` 返回 `200 text/html`(SPA 兜底:客户端从路径读 ws/sid)。
4. `match _ → 404`。

**`POST /api/chat`**:
- 读 `conn.body_params["messages"]`(endpoint 的 `Plug.Parsers` 已在 router 前解析好)。
- 净化成 `[%{"role"=>_, "content"=>_}]`;在最前**前置一条** `%{"role"=>"system", "content"=>Prompts.page_gen_system_prompt()}`。
- 调 `EzagentPluginLoom.DeepSeek.chat(messages, thinking_disabled: true, temperature: 0.7)`。
- `{:ok, text}` → `200 text/plain` body = `text`(前端 `streamProtocol:'text'` 把整个 body 当一条助手消息)。
- `{:error, _}` → `502 text/plain` + 简短错误文案(`ChatPanel` 直接显示)。无 `DEEPSEEK_KEY` → 502 "DeepSeek 未配置"。

**鉴权**:本期无。`forward` 在顶层(同飞书 webhook),绕过 `:browser`/`:require_entity` 管线 → 没有 CSRF、没有登录校验。见 §10。

## 7. ESR 端:ezagent_web 一行 + workspace 链接

- **router**:在兜底 `get "/*path"` **之前**、顶层(无 `pipe_through`,同飞书 webhook 先例)加:
  ```elixir
  forward "/loom", EzagentPluginLoom.WebPlug
  ```
  这是 `plugin-authoring-contract` 认可的"plugin 唯一合法触碰 ezagent_web"模式。
- **workspace session 列表**:定位渲染 session 列表的 LV(`/workspaces/:name` 的 `WorkspaceDetailLive`,或 `/sessions` 的 `AdminLive`,实现期确认),对 `session://loom/...` 的 session 渲染:
  ```
  <a href={"/loom/#{ws}/#{short_id}"} target="_blank">打开 Loom ↗</a>
  ```
  仅对 loom session 显示(纯 UI 选择,与 plugin 层级无关)。

## 8. per-session 状态隔离

- **服务端天然隔离**:`/loom/api/chat` 无状态,每请求自带 messages,session 间不串。
- **浏览器端**:生成代码 / 聊天历史存在浏览器(Zustand/localStorage)。前端用 **`<workspace>/<session_id>`** 作存储键 → 同浏览器多标签互不影响。
- **唯一性**:键必须全局唯一。随机 `s_xxxx` 天然唯一;但 `LoomSession` 模板用用户填的名字,跨 workspace 同名会撞 —— 故键带上 workspace(本设计的 `/:workspace/:session_id` 已满足)。

## 9. 构建 & vendor 流程

```bash
# 在前端源码仓库(Desktop)
cd /path/to/loom/ai-ui-builder
NEXT_PUBLIC_ESR_MODE=1 pnpm build         # 静态导出 → out/

# 覆盖进 plugin(运行期由 Plug.Static 提供)
rm -rf  apps/ezagent_plugin_loom/priv/static/loom_ui
cp -r   out/  apps/ezagent_plugin_loom/priv/static/loom_ui
# 提交 priv/static/loom_ui/(可选:包一个 mix loom.ui task 替代手拷)
```

- 提交的是 **dist**;`node_modules`、Desktop 源码都不进 ESR 仓库。
- **CRLF**:给 `priv/static/loom_ui/` 配 `.gitattributes`(产物按二进制/`-text` 处理或统一 `eol=lf`),避免换行符抖动(用户被坑过)。
- **DEEPSEEK_KEY**:phx.server 进程的 env(已在启动脚本里),不进仓库。

## 10. v1 取舍 & 安全(均已被 D1 解耦决策接受,记录在案)

- **`/loom/*` 与聊天代理无鉴权**:任何能访问该端口的人都能打开任意 session 的页面、并消耗 DeepSeek token。本地 demo 可接受;加 token/cap 闸是后续。
- **`session_id` 不透明**:不校验是否真存在、不接编排器/飞书。但路由已带 `ws/sid`,未来可拼回 `session://loom/<ws>/<sid>` 绑定。
- **`platform-sdk.ts` 维持桩**:生成页里的 `sendMessage` 模拟成功;接进真实 loom session 是后续耦合步骤。

## 11. 测试

- **WebPlug Plug 测试**(`test/ezagent_plugin_loom/web_plug_test.exs`):
  - `GET /loom/system/s_x` → 200,body 含 index.html 标志。
  - `GET /loom/<不存在的资源>` → 走兜底返回 index.html(SPA)或 404(按 §6 设计)。
  - `POST /loom/api/chat`:验证 **消息净化 + 系统提示词前置** 的纯函数(把 `DeepSeek.chat/2` 抽成可注入/可 mock,真实网络调用不在单测里跑)。
- **手动 e2e**:build → vendor → 起 server(`EZAGENT_PROFILE=loom`,`DEEPSEEK_KEY`)→ 浏览器开 `/loom/system/s_x` → 输入"做一个登录页" → 右侧 Sandpack 渲染出登录界面。

## 12. 不在本期范围(未来)

- 聊天接 loom 编排团队(loomorch/worker)、`platform-sdk` 回调进 loom session(D1 的解耦反面)。
- 流式聊天(Plug chunk 转发 DeepSeek SSE)。
- `/loom/*` 鉴权(token/cap)。
- 按 workspace 启用 plugin(ESR 目前无此机制,属 Allen 决策)。
- 有 CI 后:dist 改为 `.gitignore` + CI 在 release 阶段 build(那时 Node 只在 CI)。
