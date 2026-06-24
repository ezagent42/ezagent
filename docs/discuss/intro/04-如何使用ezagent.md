# 04 · 如何使用 ezagent（手把手 e2e 走查）

> 上游最新 main（`b6818123`）。每步给"做法 + 验证"。
> 标 ✅ 的是本会话**真跑过**的结果（echo / curl-deepseek / cc-claude 三种 agent 都实测通过）。
> 工具链 = mise（Elixir 1.18.4 / OTP 27），命令都在 worktree 根、加 `mise exec --` 前缀。服务端口 **10042**（不是老 README 的 4000）。

## 第 0~2 步 · 起服务
```bash
mise exec -- elixir --version                 # 应是 1.18.4 / OTP 27
mise exec -- mix setup                        # 依赖 + 前端 assets
mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
mise exec -- iex -S mix phx.server            # 起服务(带 REPL)
```
**验证**（✅ 实测）：`curl -s -o /dev/null -w '%{http_code}' http://localhost:10042/login` 返回 `200`。

## 第 3 步 · 登录管理员（首次要先设密码）
⚠️ **dev 默认不给 admin 设密码**（登录页也提示）。先设一个（服务在跑也能设，✅ 实测）：
```bash
mise exec -- mix ezagent.user.set_password 'entity://system/user/admin' --password 'demo1234'
```
然后浏览器 `http://localhost:10042/login`，填 用户名 `admin` / workspace `system` / 密码 `demo1234` → 跳 `/admin`。

## 第 4~5 步 · echo agent：发消息收回复（核心验证 ✅）
echo 是不依赖外部工具的测试桩，**默认实例 `entity://system/agent/echo_default` 在启动时就自动起好**，开箱即用。在 iex 里：
```elixir
# 确认 echo 活着
Ezagent.KindRegistry.lookup(EzagentPluginEcho.Application.default_uri())
#=> {:ok, #PID<...>}

# 发消息(动作是 echo.say，参数键 msg，权限用 admin_genesis_cap)
target = Ezagent.URI.new!(
  "#{URI.to_string(EzagentPluginEcho.Application.default_uri())}?action=echo.say")
inv = %Ezagent.Invocation{
  target: target, mode: :call, args: %{msg: "hello"},
  ctx: %{caller: Ezagent.Entity.User.admin_uri(),
         caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
         reply: {:caller_inbox, self()}}}
Ezagent.Invocation.dispatch(inv)
#=> {:ok, %{echo: "hello"}}          ← ✅ 实测就是这个返回
```
这条链路 = 一条消息进 `Invocation.dispatch` → 找到 agent → `Kind.Runtime.handle_dispatch` 做权限检查 → echo 处理 → 回复送回，并写一行审计到 `invocations` 表。

## 真实 agent（都已实测 ✅）
- **curl / DeepSeek**：spawn 一个 `Entity.Agent` 的 `curl` flavor（`provider: "deepseek"`），把 key 写进它的 `:api_keys` slice（`put_api_key`），发消息触发真 HTTP 调用 → 回 "PONG"。
- **cc / Claude Code**：用 `mix ezagent.demo.seed_cc_sandbox --name <n>`（会把本地 `~/.claude/.credentials.json` 复制进 sandbox），在管理界面/iex 起一个 cc agent → 真 claude 启动、连上 agent bridge → 会话发消息 → claude 回复。
  - ⚠️ **claude 2.1.18x 兼容**：项目自动应答首启对话框的扫描器是给 2.1.170 写的，2.1.185 渲染变了（双空格/横幅碎片）会卡住。本会话已修两处（`apps/ezagent_domain_pty/.../server.ex`，commit `0cc522cb`，重置后不在当前树，需要时 cherry-pick 或回报上游）。

## 第 6 步 · 看审计
浏览器 `/admin/snapshots`，或查 `invocations` 表最新行：含 caller/target/behavior/action/result，密钥已脱敏。

## 第 7 步 · 命令行
```bash
mise exec -- mix ezagent --help     # 命令从 BehaviorRegistry 自动派生(需服务在跑,经 RPC 进 BEAM)
```

## ⚠️ 已知坑（这版前端）
- 现行管理面是 **world**（统一 React+shadcn 前端，挂在 `host: "world."`），它已**复刻并取代**了原来的 LiveView 管理面（`apps/ezagent_plugin_liveview` 已物理删除，LV→world parity 迁移已 100% 完成、零遗留）。下面凡是历史文档里讲"LiveView 管理面"的，主语现在都是 world。
- 前端仍有一批确定性测试失败（前端版本兼容/测试基础设施问题，**非产品功能坏**，以新 bootstrap 产物为准）。万一某个页面/按钮不灵，绕开办法不变：用 HTTP API（`POST /api/v1/:kind/:action`，带 `Authorization: Bearer <token>` + `X-Ezagent-Entity-URI` 两个头；token 用 `mix ezagent.user.token <uri> --mint` 铸），或在服务节点内用 iex/RPC 直接 dispatch。
- 注意：world 目前只接管**运营/作者面**；客户面（`/socialware/chat`、`/socialware/customer`）仍在旧栈 `ezagent_web`，"world 收编客户面"仍是 future（见 [08 socialware 深入](./08-socialware深入.md)）。

## 跑测试
```bash
mise exec -- mix test       # 4700+ 测试；当前不是全绿(world 前端那批确定性失败)，详见 bootstrap 产物
```

## 搭一个真正的客户产品？
echo/curl/cc 是验证"消息能通"的。要做**面向客户的产品**（公开会话给匿名用户），看 [08 socialware 深入](./08-socialware深入.md) + [09 如何搭建新 app](./09-如何在ezagent上搭建新app.md)。
