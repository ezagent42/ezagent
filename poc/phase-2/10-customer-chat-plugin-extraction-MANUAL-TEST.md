# 插件抽取版 — 手动测试计划

> 抽取后的 `ezagent_plugin_customer_chat` 已部署,服务在跑(端口 10142,profile
> poc-phase2),资源已构建,cc 已预热。逐个点,把结果记在每个 "📝 结果" 行。
> 撞到问题贴回来。
>
> **和之前最大的不同**(抽取带来的):
> 1. 客服现在是 `/plugins` 里的一张独立插件卡片("Customer Service")。
> 2. operator 入口从 `/admin/customer_sessions` 变成了 **`/operator/:tenant`**,
>    **不用再手动切工作区**(之前那个坑)。
> 3. operator 控制台是个**聚焦的专属界面**,没有 admin 的导航/路由/终端那些噪音。

## 前置(已就绪)
- 服务: `http://localhost:10142`
- 登录: `entity://user/system/admin` / `ezagent-dev`
- 租户 acme,soul 在 `poc/fixtures/plugins/acme/souls/customer.md`(12个月 / Pro 24个月)
- 建议两个窗口:A=客户(不登录),B=operator/admin(登录)

---

## Test 1 — 客户聊天页(和之前一样,确认抽取没弄坏)
**窗口 A** 打开 👉 **http://localhost:10142/chat/acme**

**预期**: 主题页(标题 "Acme Support"、玫红主色、底部居中输入框 + 玫红 Send)。
输入框先禁用显示 "connecting…",~10s 后可用。问
*"How long is the warranty on my Acme laptop?"* → AI 回复带 **12-month / Pro 24-month**。

> 注:如果布局错乱(输入框跑到顶部、没颜色),说明 CSS 没加载——硬刷新(Cmd+Shift+R)。
> 抽取时踩过一个 Tailwind 的坑已修,正常应该是对的。

📝 结果 1:

---

## Test 2 — 刷新续接
**窗口 A** Test 1 聊完后刷新(F5 / Cmd+R)。
**预期**: 同一段对话还在(不是空白新会话)。

📝 结果 2:

---

## Test 3 — 插件出现在 /plugins(抽取的核心成果)
**窗口 B**: 登录后打开 👉 **http://localhost:10142/plugins**
**预期**: 看到一张 **"Customer Service"** 插件卡片。点它 → 跳到 **`/operator`**。

📝 结果 3(卡片在不在 + 点击是否进 /operator):

---

## Test 4 — operator 直达入口,免切工作区(关键改进)
**窗口 B**(已登录)直接打开 👉 **http://localhost:10142/operator/acme**

**预期**: **直接**落到 acme 的客服会话列表——**不需要**先进 admin、也**不需要**手动切到
acme 工作区(对比之前:要 `/admin/customer_sessions` + 左上角切工作区)。列表里能看到
前面测试产生的会话(conv_id / Auto badge / 最近消息预览)。界面是聚焦的专属控制台
(顶部 "Customer Service / acme"),没有 ezagent 的 admin 导航噪音。

> `/operator`(不带租户)会列出你有权限的工作区;只有一个时直接跳进去。

📝 结果 4(是否免切工作区直达 + 列表是否有会话):

---

## Test 5 — operator 接管
1. 先在**窗口 A** 开/刷一个客户对话(`/chat/acme`),发一句如 "I want a refund"。
2. **窗口 B**: 在 `/operator/acme` 列表点进那个会话(URL 变成 `/operator/acme/<conv_id>`)。
3. 看到该会话的实时记录 + 右上 "Take over" 按钮(mode badge = Auto)。
4. 点 **Take over** → badge 变 **Takeover**,出现 operator 输入框。
5. 输入框打字发一句:"Hi, human agent here."

**预期(窗口 A 客户侧,实时、无需刷新)**:
- 出现 **"客服已接管"** 角标 + 居中 **"(客服已接管对话)"** 通知气泡
- 收到你发的 operator 消息(绿色"客服"气泡)

📝 结果 5A(接管通知):
📝 结果 5B(operator 消息实时到客户):

---

## Test 6 — 旧链接重定向(不破坏老书签)
**窗口 B**(已登录)打开 👉 **http://localhost:10142/admin/customer_sessions**
**预期**: 自动跳到 `/operator`(不是 404)。

📝 结果 6:

---

## Test 7(加分)— 可嵌入 widget
widget 控制器没动(还在 ezagent_web),iframe 指向 `/chat/acme?embed=1`(现在样式也修好了)。
如果想验:终端起一个 `cd /tmp && python3 -m http.server 8088`,然后浏览器开
`http://localhost:8088/widget-test.html`(之前建过)。右下角💬气泡 → 点开 iframe 聊天。

📝 结果 7:

---

## 测试完
把 📝 结果填好(通过/失败 + 现象,失败最好截图)贴回来。我们再决定下一步:
- 全绿 → 把 PR #446 转 ready 交团队 review,或直接进 admin-edit(改 AI 知识库/话术/流程)的 brainstorm。
- 有红 → 按现象改。

## 附录:服务挂了怎么重启
```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 \
  MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY \
      -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  mix phx.server
# 起来后若页面没样式: mix esbuild ezagent_web && mix tailwind ezagent_web (带同样的 MIX_DEPS_PATH)
```
