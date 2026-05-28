# Phase 3 手动测试计划（网页版 UI）

> Phase 3 客户聊天页 + operator 控制台已做好，服务在跑（端口 10142，profile
> poc-phase2）。这份计划全程**用浏览器点**，不再用 curl。逐个执行，把结果记在
> 每个 "📝 结果" 行。撞到问题就把现象（最好带截图）贴回来，我据此改代码。
>
> 建议用两个浏览器窗口（或一个普通窗 + 一个无痕窗）：
> - **窗口 A = 客户**（不登录）
> - **窗口 B = operator**（登录 admin）
> 这样接管测试时能同时看到两边。

## 前置（已就绪，无需操作）

- 服务: `http://localhost:10142`，已起
- 租户: `acme`（soul fixture 在 `poc/fixtures/plugins/acme/souls/customer.md`）
- acme 主题: `apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json`
  （标题 "Acme Support"、玫红主色 `#e11d48`）
- admin 登录: 用户名 `entity://user/system/admin`，密码 `ezagent-dev`
- 后端已验通：cc 客服 agent 能拉起并带 acme soul 回复（12 个月 / Pro 24 个月）
- 服务挂了的话，重启命令见文末「附录」

---

## Test 1 — 打开客户聊天页（看渲染 + 主题）

**窗口 A（客户）**：浏览器打开 👉 **http://localhost:10142/chat/acme**

**预期**：
- 一个聊天页，顶部标题 **"Acme Support"**，发送按钮是**玫红色**（acme 主题）。
- 中间有一条欢迎气泡（"Hi! I'm the Acme assistant…"）。
- 刚打开时底部输入框是**禁用**的、上方显示 **"connecting…"**——这是后台在拉起
  cc 客服 agent（首次冷启 ~10 秒）。等它就绪后输入框变可用、"connecting…" 消失。

📝 结果 1（页面/主题/connecting→ready）:

---

## Test 2 — 客户和 AI 对话 + soul 个性化（核心）

**窗口 A**，等输入框可用后，输入：

```
How long is the warranty on my Acme laptop?
```

按回车 / 点发送。

**预期**：
- 你的消息立刻以**玫红气泡**靠右出现。
- 几秒后 AI 的回复以**灰色气泡**靠左出现，内容带 soul 事实：
  **"12-month warranty"**（普通）+ **"24 months" / "Pro"**（Pro 系列），语气友好。

**加分**：再问一个 soul 没写的（如 "Do you sell monitors?"），看 AI 是否按 soul
指示说"要问团队"而不是瞎编。

📝 结果 2（AI 回复 + soul 事实）:

---

## Test 3 — 刷新续接（验证对话不丢）

**窗口 A**，在 Test 2 聊完之后，**刷新页面（F5）**。

**预期**：刷新后看到的还是**同一段对话**（你的问题 + AI 的回复都在），不是一个空白
新会话。（实现：conv_id / customer_id 存在 localStorage，刷新时自动续接。）

> 原理：第一次打开是 `/chat/acme`，hook 把 conv 存进 localStorage；刷新时若 URL
> 没有 `?conv=` 就从 localStorage 恢复并跳到 `/chat/acme?conv=…&cid=…`。

📝 结果 3（刷新后对话还在）:

---

## Test 4 — 可嵌入 widget（模拟商家网站）

**窗口 A**，浏览器打开本地文件 👉 **file:///tmp/widget-test.html**
（我已建好；它模拟"Acme 自己的网站"，只贴了一行
`<script src=".../widget.js" data-tenant="acme">`）

**预期**：
- 页面右下角出现一个**聊天气泡按钮**（💬）。
- 点一下 → 弹出一个聊天面板（其实是个 iframe，指向 `/chat/acme?embed=1`，没有
  顶部 header、背景透明贴合气泡）。
- 在里面发一句消息 → AI 正常回复（和 Test 2 一样）。
- 再点气泡按钮 → 面板收起。

> 如果面板空白：可能是 iframe 被某些浏览器的第三方内容拦截；把现象贴回来。

📝 结果 4（气泡 + iframe 聊天）:

---

## Test 5 — Operator 控制台：监听活跃会话

**窗口 B（operator）**：
1. 打开 **http://localhost:10142/login**
2. 用 `entity://user/system/admin` / `ezagent-dev` 登录
3. 访问 **http://localhost:10142/admin/customer_sessions**

**预期**：看到前面测试产生的活跃 customer session 列表（conv_id / workspace /
最近消息 / mode badge，mode 应是 **Auto**）。点进任意一个 → 看到该会话的
**实时对话记录**（窗口 A 里发生的 customer ↔ AI 对话）。

**联动验证**：保持窗口 B 停在某个会话详情页，回到**窗口 A** 在该会话里再发一句；
窗口 B 的对话记录应**实时**多出这句（operator 是订阅者，无需刷新）。

📝 结果 5（会话列表 + 实时记录 + 联动）:

---

## Test 6 — Operator 接手（takeover，最核心）

准备：**窗口 A** 开一个新的客户对话（可直接刷新 /chat/acme 或开新会话），发一句
比如 "I want a refund please"。然后 **窗口 B** 进入这个会话的详情页。

在**窗口 B**：
1. 点 **"Take over"** 按钮。
2. mode badge 变成 **"Takeover"**，出现 operator 输入框。
3. 在输入框打字："Hi, this is a human agent. I can help with your refund." → 发送。

**预期 A（窗口 A 客户侧，实时、无需刷新）**：
- 出现一条居中的系统提示气泡 **"(客服已接管对话)"**，顶部出现 **"客服已接管"** 角标。
- 紧接着收到 operator 发的那句消息（绿色气泡，标着"客服"）。
- **关键**：这一切在客户的持久连接上实时到达，**没有 120 秒 SSE 超时问题**——这正是
  换成 LiveView 顺手解决的那个架构债。

**预期 B（窗口 A 客户再发消息时）**：takeover 模式下 AI 不再自动回复；客户发的消息
窗口 B 能看到，由 operator 人工回复。

📝 结果 6A（接管通知 + 角标）:
📝 结果 6B（operator 消息实时到客户）:
📝 结果 6C（AI 静默、operator 人工回）:

---

## 测试完怎么办

把每个 📝 结果填好（通过 / 失败 + 现象，失败最好带截图）贴回来。我会：
- 全绿 → 把活体结果补进 `ACCEPTANCE.md`，然后按 HANDOFF 推进：rebase 到 ezagent
  最新 main（#439 / #438 / #434）→ 重新验证 → 开 PR。
- 有红 → 按现象改代码（代码在 `ezagent_plugin_liveview` 的 `CustomerChat` 命名
  空间 + `ezagent_web` 路由），重新编译、重测。

---

## 附录：重启服务（如果挂了）

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 \
  MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY \
      -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  mix phx.server
```

> 注：客户聊天页是 LiveView，需要浏览器加载 `/assets/js/app.js`（LiveSocket
> 客户端）。如果页面**永远卡在 "connecting…"、输入框禁用**，多半是 app.js 没构建
> （返回 404）→ LiveView 连不上 socket → 异步 bootstrap 不触发。
>
> **共享 MIX_DEPS_PATH 下的资源构建坑**：esbuild 的 `NODE_PATH` 指向仓库本地
> `deps/`，但我们用共享 deps，本地 `deps/` 不存在 → esbuild 找不到 phoenix /
> phoenix_live_view 的 JS。一次性修复：
>
> ```bash
> cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
> # 1) 让本地 deps/ 指向共享缓存（gitignored，安全）
> [ -e deps ] || ln -s /Users/daiming/workspace/ezagent42/.poc-shared-deps deps
> # 2) 构建前端 bundle
> MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix esbuild ezagent_web
> MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix tailwind ezagent_web
> # 3) 验证（都应 200）
> curl -s -o /dev/null -w "%{http_code}\n" http://localhost:10142/assets/js/app.js
> ```
> 做完后**硬刷新**浏览器（Cmd+Shift+R）清掉缓存的 404。建好 deps 符号链接后，
> dev 的 esbuild/tailwind watcher 后续也能正常增量构建。
