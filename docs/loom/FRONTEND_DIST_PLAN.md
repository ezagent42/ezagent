# 开发计划:前端 → 引入 SDK → dist → 进 plugin → 链路跑通

> 状态:实施计划(未动工)· 日期:2026-05-28
> 配套:`SDK.md`(SDK 契约)、`TEMPLATE_DESIGN.md`(整体模型 §0.5 / §5 静态插槽)。
> 目标:把现有前端 `studio-mobile` 改成「引入 SDK 的打包产物 dist」,让 dist **脱离前端源码**、成为 `ezagent_plugin_hello` 的一部分,且 **bootstrap → 镜像 → 发言 → 卡片** 整条链路在 ESR 同源下正常运行。
> 约束:**ESR 改动越小越局限越好、非破坏性**(memory `feedback-minimize-esr-changes`);不碰 dispatch / 不引新 inbound 路径(P13:Phoenix 是 transport)。

---

## 0. 现状事实(计划的地基)

**前端 `C:\Users\Ning\Desktop\studio-mobile`:**
- Vite 8 + React 19 + Tailwind 4;入口 `index.html → /src/main.jsx`。
- `vite.config.js`:未设 `base`(= `/`),dev 端口 5175,无 proxy。
- `src/session.js`:传输层 = `bootstrap()`(POST `${VITE_ESR_BASE}/bootstrap`)+ `connectMirror({wsUrl,wsToken,sessionUri,onFrame,onStatus,onError}) → {close, send}`(phoenix.js Socket + channel `session:mirror:<uri>`、`message` 帧、`say` push)。**这就是 SDK 的抽取面。**
- `parseSpan` 目前内联在 `App.jsx`。

**ESR(`apps/ezagent_web`):**
- `endpoint.ex`:已有 `socket "/session_socket"`、`Plug.Static at:"/" from: :ezagent_web only: static_paths()`、CORS plug(覆盖 `/bootstrap`+`/api`)。
- `router.ex`:`/` = `HomeLive`,`/admin/* /sessions /identities/* …` = 一堆 LiveView,`post "/bootstrap"` 已在,末尾 `get "/*path"` → 404 兜底。
- 含义:**dist 不能挂 `/`**;需独立前缀;现有 Plug.Static 指向 `:ezagent_web` 不是 plugin。

**"脱离源码" 的定义(本计划的验收语义):** ESR 仓库**只含构建产物 dist**(在 plugin 的 `priv/static`),不含 React 源码;一次干净 ESR 启动(**不**起 5175 dev server)即可跑完整条链路。前端源码 + SDK 源码住在 ESR 仓库之外(前端 dev 的域)。

---

## 关键决策(动工前固化)

| # | 决策 | 取值(demo) | 备注 |
|---|---|---|---|
| D1 | 服务前缀 | **`/hello`** | 撞不到 LiveView;model B 下变 `/app/<id>`(`TEMPLATE_DESIGN.md §0.5`) |
| D2 | dist 落点 | **`apps/ezagent_plugin_hello/priv/static/`** | 满足「dist 是 plugin 的一部分」 |
| D3 | SDK 包位置 | **ESR 仓库之外**(前端 dev 域),demo 期可本地 `file:` 依赖 | 保持 ESR 干净;只有 dist 进 ESR |
| D4 | 同源策略 | **prod 同源**(`base=''`/`location.origin`);**dev 仍跨源** 5175↔ESR(留 CORS) | 同源免 CORS;dev 保留热更 |
| D5 | 指纹/缓存 | 用 Vite 自带 hash,**不跑 `phx.digest`**(避免双重指纹) | index.html no-cache,assets 长缓存 |

---

## Phase 1 — 抽 SDK(纯前端,无 ESR 改动)

**做:** 把 `session.js` + `App.jsx` 里的 `parseSpan` 抽成独立包 `@ezagent/session-sdk`,收敛成 `SDK.md §4` 的 `createSession` 门面:
- `createSession({base, persona, storageKey, autoReconnect})`、`connect()`、`onMessage`、`send`、`parseSpan`、`onStatus`/`onError`、`sessionUri`、(可选)`fab`。
- 把现有 `bootstrap`+`connectMirror` 包进去;补 **token 过期重 bootstrap**、**localStorage 复用 session_uri**(`SDK.md §2`)。
- 携带 **contract 版本号**(`connect()` 时与 ESR wire 不匹配显式报错)。
- 帧字段对齐:wire 是 `ref_id` → SDK 暴露 `refId`(`SDK.md §4.2`)。

**Owner:** 前端 dev。
**Gate 1:** SDK 能 `npm pack`/被 import;一个最小 demo 页 import SDK,API 形状符合 `SDK.md §4`。

---

## Phase 2 — 前端改为引入 SDK(纯前端,无 ESR 改动)

**做:**
- `studio-mobile` 依赖 SDK(demo 期 `file:../session-sdk` 或 npm-link)。
- `App.jsx`:`import { createSession } from '@ezagent/session-sdk'` 取代 `import {bootstrap, connectMirror} from './session.js'`;用 `session.onMessage` + `session.parseSpan` 取代内联解析;**删除 `src/session.js`**(逻辑已进 SDK)。
- `base` 仍走 env:dev = `VITE_ESR_BASE`(跨源),prod 留空(同源,Phase 4 用)。

**Owner:** 前端 dev(`App.jsx` 是前端的)。
**Gate 2(关键 checkpoint,源码仍在驱动):** `npm run dev`(5175)对着一个**在跑的 ESR**,跑通 **提问 → 2 子任务派发 → worker 回 → 组合卡片**。证明「换 SDK」没破坏链路 —— **在动 serving 之前先锁住这点。**

---

## Phase 3 — base 路径 + 出 dist(纯前端,无 ESR 改动)

**做:**
- `vite.config.js` 加 `base: '/hello/'`(D1)→ 资产 URL 变 `/hello/assets/...`。
- SDK `base`:prod 构建用同源(空 base / `location.origin`),即 bootstrap 打 `/bootstrap`、ws_url 用 bootstrap 返回的绝对值(D4)。
- `npm run build` → `dist/`。

**Owner:** 前端 dev。
**Gate 3:** 看 `dist/index.html` 引用 `/hello/assets/...`;`vite preview` 本地能打开(此时还没接 ESR serving)。

---

## Phase 4 — ESR 静态插槽:serve dist(**唯一的 ESR 改动集中在这里**)

**做(把 dist 放进 plugin + 让 ESR 在 `/hello` 提供它):**

1. **dist 入 plugin**(D2):`dist/*` → `apps/ezagent_plugin_hello/priv/static/`(`index.html` 在 `priv/static/index.html`,资产在 `priv/static/assets/`)。用一个 vendor 脚本做(Phase 6)。

2. **`endpoint.ex` +1 行 Plug.Static**(放在现有 `Plug.Static at:"/"` 旁,**在 `Router` 之前**):
   ```elixir
   plug Plug.Static,
     at: "/hello",
     from: {:ezagent_plugin_hello, "priv/static"},
     gzip: not code_reloading?,
     cache_control_for_etags: "public, max-age=31536000"
   ```
   → `/hello/assets/*`、`/hello/index.html` 等**真实文件**由它在到 Router 之前接走。

3. **`router.ex` + SPA 入口/兜底**(放在末尾 `get "/*path"` catch-all **之前**,否则被 404 兜底吃掉):
   ```elixir
   scope "/", EzagentWeb do
     pipe_through :browser
     get "/hello", HelloAppController, :index
     get "/hello/*path", HelloAppController, :index   # SPA 深链兜底 → index.html
   end
   ```

4. **新增 `HelloAppController`**(ezagent_web,极小;send_file plugin priv 的 index.html):
   ```elixir
   defmodule EzagentWeb.HelloAppController do
     use EzagentWeb, :controller
     @index Path.join(:code.priv_dir(:ezagent_plugin_hello), "static/index.html")
     def index(conn, _), do: conn |> put_resp_header("cache-control","no-cache") |> send_file(200, @index)
   end
   ```

**ESR 改动总清单(就这些,全部 additive / 非破坏):**
- `endpoint.ex`:+1 `Plug.Static`。
- `router.ex`:+2 route(1 个新 scope 或并入既有 browser scope)。
- `controllers/hello_app_controller.ex`:新文件,~6 行。
- `ezagent_plugin_hello/priv/static/`:新目录(放 dist)。

> 顺序要点:endpoint 的 Plug.Static 永远先于 Router 执行 → `/hello/assets/*` 走静态,`/hello`、`/hello/<非文件>` 才落到 `HelloAppController`。`/hello*` 路由必须声明在 `get "/*path"` 之前。
> 不变式:这条路径是纯 transport(P13),不碰 `Invocation.dispatch`,不新增 inbound topic(P14 不受影响)。

**Owner:** 我(ESR,最小改动)。
**Gate 4:** ESR 起来后浏览器开 `http://<esr-host>/hello` → 页面 + 资产全 200,**同源**由 ESR 提供(`/` 的 HomeLive、`/admin` 等不受影响)。

---

## Phase 5 — 同源链路打通 + 脱离源码(验收)

**做:**
- 确认 SDK 同源:bootstrap 打同源 `/bootstrap`,WS 用 bootstrap 返回的 `ws_url`。
- **核对 `HelloBootstrapController` 的 `ws_url` 由请求/endpoint host 派生**,不是硬编码 `localhost`(同源 prod + 跨源 dev 都要对)。若硬编码 → 改成 host 派生(小改动,记进 ESR 清单)。
- 确认 prod 同源下**不依赖 CORS**(CORS 仅 dev 5175 用)。

**Gate 5(主 e2e,脱离源码):** 干净 ESR 启动、**不起 5175**、仓库内只有 vendored dist → 开 `/hello` → 提问 → 看到编排卡片。`role` 左右气泡正确、`ref_id` 关联正确、超时/部分结果不崩。

---

## Phase 6 — 固化为流程 + 收尾

**做:**
- **vendor 脚本**:前端仓库 `npm run build` → 把 `dist/*` 拷进 `apps/ezagent_plugin_hello/priv/static/`(一条命令)。文档化为「交付 plugin 前一步」。
- **commit 策略**:demo 期把 vendored dist 提交进仓库(让 ESR 独立可跑);记一条 `.gitignore`/说明,区分「源码不进 ESR、产物进 ESR」。**提交本身等用户/Allen 确认**(`不要提交commit` 在先)。
- 在 `TEMPLATE_DESIGN.md §7` 勾掉「静态插槽」一项。

---

## 模板化增量(本计划之外,留给 model B 那期)

这些**现在不做**,但计划要指向它们,避免 demo 形态把路堵死:
- **前缀 `/hello` → `/app/<id>`**:Phase 4 的 Plug.Static / 路由参数化成 per-app(`TEMPLATE_DESIGN.md §0.5`)。
- **dist 落点 → 运行时可配外部路径**:demo 烘进 plugin priv(随 release 走);模板期改成可配路径,使更新 dist 免重新发布(`TEMPLATE_DESIGN.md §5`)。
- **SDK → 正式 npm 发布 + 版本矩阵**(`SDK.md §7`)。
- **每 app 一套 prompt/词汇/roster** 下沉为 per-plugin 配置(`TEMPLATE_DESIGN.md §7`)。

---

## 一页速查:谁改什么

| Phase | Owner | 改动 | Gate |
|---|---|---|---|
| 1 抽 SDK | 前端 dev | 新 SDK 包(ESR 外) | import 通、API 合 `SDK.md §4` |
| 2 前端引 SDK | 前端 dev | `App.jsx` 换 import、删 `session.js` | dev 5175 跑通编排 |
| 3 base+build | 前端 dev | `vite.config.js base`、出 dist | dist 引 `/hello/assets` |
| 4 静态插槽 | **我(ESR)** | endpoint +1 plug、router +2 route、新 controller、plugin priv 放 dist | `/hello` 同源 200 |
| 5 同源 e2e | 我 + 前端 | 核对 ws_url host 派生 | 不起 5175 跑通编排 |
| 6 固化 | 我 + 前端 | vendor 脚本、commit 策略 | 一条命令出可部署 plugin |
