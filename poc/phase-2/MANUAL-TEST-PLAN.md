# Phase 2 手动测试计划

> 服务已启动（端口 10142，profile poc-phase2）。逐个执行下面的测试，把结果记在每个 "📝 结果" 行。撞到问题就把现象贴回来，我据此改代码。

## 前置（已就绪，无需操作）

- 服务: `http://localhost:10142`，已起
- 租户: `acme`（已创建，soul fixture 在 `poc/fixtures/plugins/acme/souls/customer.md`）
- admin 登录: 用户名 `entity://user/system/admin`，密码 `ezagent-dev`
- 如果服务挂了，重启命令见本文件最后「附录：重启服务」

---

## Test 1 — 基本客户对话（无个性化验证，先看通不通）

```bash
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"alice","text":"你好","conv_id":"t1-'$(date +%s)'"}' \
  --max-time 90
```

**预期**: 看到 3 个 SSE 事件 —— `event: open`（含 session_uri + agent_uri）→ `event: message`（AI 的问候回复）→ `event: close {reason: terminal}`。首次 ~10s（cc 冷启 + bridge）。

📝 结果:

---

## Test 2 — Soul 个性化（核心：AI 回复要带 acme soul 的事实 + 语气）

```bash
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"bob","text":"How long is the warranty on my Acme laptop?","conv_id":"t2-'$(date +%s)'"}' \
  --max-time 90
```

**预期**: AI 回复里出现 soul 写的事实 —— "12-month warranty"（普通）和 "24 months" / "Pro line"（Pro 系列）。语气友好。这证明租户 soul 真的注入到了 AI。

对照 soul 内容（`poc/fixtures/plugins/acme/souls/customer.md`）:
- Laptops: 12-month warranty, 24-month for Pro line
- Phones: 6-month warranty, no extension
- 不在清单内的产品 → AI 应说 "I'll need to check with my team"

加分测试: 问一个 soul 没写的（如 "do you sell monitors?"），看 AI 是否按 soul 指示说"要问团队"而不是瞎编。

📝 结果:

---

## Test 3 — 并发隔离（两个客户不串消息）

```bash
# 同时发两个不同 conv_id 的请求
curl -sN -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"alice","text":"My name is ALICE-SECRET","conv_id":"t3-alice"}' \
  --max-time 90 > /tmp/t3-alice.txt &
curl -sN -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"bob","text":"My name is BOB-SECRET","conv_id":"t3-bob"}' \
  --max-time 90 > /tmp/t3-bob.txt &
wait
echo "=== alice stream ===" ; grep -c "BOB-SECRET" /tmp/t3-alice.txt
echo "=== bob stream ===" ; grep -c "ALICE-SECRET" /tmp/t3-bob.txt
```

**预期**: 两个 `grep -c` 都返回 `0`（alice 的流里没有 bob 的秘密，反之亦然）。证明 per-conv session 隔离有效。

📝 结果:

---

## Test 4 — Operator dashboard 看活跃对话

1. 浏览器打开 `http://localhost:10142/login`
2. 登录: `entity://user/system/admin` / `ezagent-dev`
3. 访问 `http://localhost:10142/admin/customer_sessions`

**预期**: 看到前面测试产生的活跃 customer session 列表（conv_id / workspace / 最近消息 / mode badge）。点进任意一个 → 看到该 session 的实时对话记录。

📝 结果:

---

## Test 5 — Operator 接手（takeover）

**先开一个"挂着"的客户对话**（在 takeover 模式下 AI 被 gate，SSE 流会挂住等 operator）:

终端 A（保持运行，模拟在线客户）:
```bash
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"carol","text":"I want a refund please","conv_id":"t5-takeover"}' \
  --max-time 180
```

浏览器（operator）:
1. `/admin/customer_sessions` → 找到 `t5-takeover` → 点进去
2. 看到 carol 说 "I want a refund please" + AI 的回复
3. 点 **"Take over"** 按钮

**预期 A（客户侧，终端 A）**: 看到一条 `event: message` 内容是 `(客服已接管对话)`。

4. 在 operator 输入框打字: "Hi Carol, this is a human agent. I can help with your refund." → 发送

**预期 B（客户侧，终端 A）**: 收到 operator 的这条消息（在 120s 窗口内）。

**预期 C（dashboard）**: mode badge 变成 "Takeover"；AI 不再自动回复。

📝 结果 A（接管通知）:
📝 结果 B（operator 消息到客户）:
📝 结果 C（mode badge + AI 静默）:

> ⚠️ 已知张力（见 ARCHITECTURE-zh.md）：C3 是请求/响应式 SSE。如果 operator 超过 120s 才回复，客户的 SSE 流会超时关闭。这是 Phase 3 要不要升级到持久 WS 连接的决策点 —— 本测试只要在 120s 窗口内操作即可验证核心。

---

## Test 6 — 同对话第二轮（验证 cc agent 复用，第二条应该快）

```bash
# 用 Test 2 已经建过的 conv_id（替换成你 Test 2 实际用的那个 t2-XXXX）
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"bob","text":"What about phones?","conv_id":"<填Test2的conv_id>"}' \
  --max-time 60
```

**预期**: 第二条消息明显比第一条快（cc agent 已经活着、bridge 已 bound，无冷启）。AI 回复手机保修信息（6-month, no extension）。

📝 结果:

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

## 测试完怎么办

把每个 📝 结果填好（通过 / 失败 + 现象）贴回来。我会:
- 全绿 → 着手 rebase 到 ezagent 最新 main（#439 create_agent / #438 URI canon / #434 workspace visibility）+ 重新验证 → 开 PR
- 有红 → 按现象改代码，重测
