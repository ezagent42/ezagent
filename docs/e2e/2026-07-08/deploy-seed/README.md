# E2E：部署级 seed 车道 — autoservice + hello 经该车道发布/可用

- 日期：2026-07-08
- 分支：`feat/sw-hello-deploy-seed`（seed 机制 + autoservice 迁移 + hello 迁移 组合态）
- 工具链：`mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix ...`
- 隔离环境：scratch `EZAGENT_HOME=/home/yaosh/.claude/jobs/850e99f0/tmp/ezhome-e2e`，`EZAGENT_PROFILE=default`
- DB：docker PG `ezagent-pg-compat-audit-postgres`（127.0.0.1:55432），**全新 scratch 库 `POSTGRES_DB=ezagent_deploy_seed_e2e`**（原因见 blocker 1）

## 结论

**通过。** 部署级 seed 车道端到端验证成功：

1. `mix ezagent.home.init` 幂等把两个 socialware（autoservice + hello）从各 app `priv/socialware_seed/*` copy 进 `$EZAGENT_HOME/default/socialware/`。
2. boot 时晚扫描车道 `ManifestSeed.scan_all!` 从部署目录（`deploy` source）经治理链把两者 **published**。
3. 二者在 world「新建会话」的「应用」选择器里 **可发现**（screenshot 02）。
4. hello 的 public 页 **匿名可看**（清 cookie 后 HTTP 200、`登录后参与` 只读态，未跳 /login）（screenshot 01）。

DB 侧交叉印证：`socialware_config_pointers` 里 `socialware:autoservice-tier1` 与 `socialware:hello` 两条 pointer 均已落库。

## 步骤与证据

### 1. home.init 幂等 seed 到部署目录

`mix ezagent.home.init` 输出（关键行）：

```
[info] socialware deploy-seed: autoservice → /home/yaosh/.claude/jobs/850e99f0/tmp/ezhome-e2e/default/socialware/autoservice
[info] socialware deploy-seed: hello → /home/yaosh/.claude/jobs/850e99f0/tmp/ezhome-e2e/default/socialware/hello
```

`ls $EZAGENT_HOME/default/socialware/`：

```
autoservice/   manifest.yaml package.yaml kb/ persona/
hello/         manifest.yaml
```

两个包目录 + 各自 `manifest.yaml` 都在。（boot 时再跑一遍是幂等：目录已存在则 `File.exists?` 跳过，不覆盖 operator 编辑，所以 boot 日志里不再出现 deploy-seed 行，符合设计。）

### 2. DB

`mix ecto.create && mix ecto.migrate`（scratch 库）→ `Migrations already up`。

### 3. 起 server + 经部署车道发布（核心文字证据）

`mix phx.server` 启动日志关键行：

```
[info] Running EzagentWeb.Endpoint with Bandit 1.11.1 at 0.0.0.0:10042 (http)
[info] socialware manifest seed: autoservice-tier1 (deploy) → published
[info] socialware manifest seed: hello (deploy) → published
```

`(deploy)` 即 source label = 部署级 seed 目录（`system://socialware`），证明两者走的是**部署级车道**而非 app-priv 旧车道。

DB 交叉印证：

```
$ psql ... -c "SELECT subject_uri FROM socialware_config_pointers WHERE subject_uri IN ('socialware:hello','socialware:autoservice-tier1');"
 socialware:autoservice-tier1
 socialware:hello
```

### 4. 浏览器证据

工具：`agent-browser`（Chromium）。world 需登录（admin `admin@ezagent.chat`，密码经 `mix ezagent.user.set_password` 设为本地 dev 值——见 CLAUDE.md 的 dev 凭证，见 blocker 2）。

- **02-world-discover.png** — 登录 admin 进入 world `/sessions`，点「新建会话」，「应用」下拉里同时出现两个经部署车道发布的 socialware：`AutoService Tier-1` 与 `Pure-config hello`（截图为选中 hello 的状态，含其描述 "Hello socialware authored as a manifest." 及 builder/responser 角色 np·py）。证明**可发现**。下拉完整选项（快照文字）：
  `不关联 / AutoService Tier-1 / chat / Pure-config hello / Orchestrator / socialware`
- **01-hello-public-page.png** — 由 world「新建会话」真实创建 hello 会话实例 `session://system/socialware-install-hello/hello-deploy-seed-e2e` 后，**清空 cookie** 以匿名身份访问其 public 页
  `http://localhost:10042/socialware/chat?session_uri=session://system/socialware-install-hello/hello-deploy-seed-e2e`
  → HTTP 200、`<title>Socialware Chat</title>`、渲染 hello 视图（"还没有页面…"）、底部 `登录后参与` 输入框 **disabled** + `登录` 按钮 = 只读匿名 public_view，**未**跳转 /login。证明 hello public 页**匿名可看**。

## Blockers / 如实记录（均与被测特性无关，为环境坑）

1. **共享 PG 库污染 → cc plugin `role_seed_collision "orchestrator"` 导致首次 boot 崩溃。**
   默认库 `ezagent_pg_compat_dev` 有历史数据，`EzagentPluginCc.Application` 的 RoleSeedHook 检测到 `orchestrator` recipe 已存在而拒绝，节点起不来。**与 deploy-seed 无关**。用全新 scratch 库 `ezagent_deploy_seed_e2e` 后 boot 正常。

2. **前端资产未构建 → LiveSocket 不连 → world SPA 交互（建会话）不生效。**
   `apps/ezagent_web/priv/static/assets/js/app.js` 初始是 20 字节 `// test placeholder`，esbuild/vite watcher 因 `node_modules` 缺失报 `:watcher_command_error`。修复（属环境搭建、未改 lib）：
   - `cd apps/ezagent_plugin_world/assets && npm install`（vite dev server 起在 :5173）
   - `cd apps/ezagent_web/assets && npm install && mix esbuild ezagent_web`（产出真实 746KB app.js）
   之后 LiveSocket 正常连接，world SPA 原生挂载，可发现 + 建会话都通。tailwind CSS 未单独构建（world SPA 样式由 vite 注入，截图 02 已正常上色）。

3. **hello 会话建成但建会话调用 5s 超时（py sidecar）。**
   建 hello 会话时 builder/responser 是 py flavor agent，spawn 走 py sidecar；UI 报
   `创建会话失败：{:create_session_exit, {:timeout, {GenServer, :call, [...action=workspace.create_session..., 5000]}}}`。
   但**会话实例本身已落库**（routing rules + `session://.../hello-deploy-seed-e2e` snapshot 均已写），public 页照常渲染。py agent 不应答是 sidecar 环境坑，不影响 deploy-seed 发布/可发现/匿名可看的验证。

## 复现要点

```bash
export EZAGENT_HOME=/home/yaosh/.claude/jobs/850e99f0/tmp/ezhome-e2e EZAGENT_PROFILE=default
export POSTGRES_DB=ezagent_deploy_seed_e2e
M="mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix"
$M ezagent.home.init
$M ecto.create && $M ecto.migrate
# 前端一次性搭建（环境，不改 lib）
(cd apps/ezagent_plugin_world/assets && npm install)
(cd apps/ezagent_web/assets && npm install) && $M esbuild ezagent_web
$M phx.server           # 观察 socialware manifest seed: ... (deploy) → published
$M ezagent.user.set_password "entity://system/user/admin" --password "$ADMIN_PW"   # 本地 dev 值,见 CLAUDE.md
# 浏览器：world.localhost:10042 登录 admin → 新建会话（应用选 hello）→ 清 cookie 匿名开 /socialware/chat?session_uri=<uri>
```
