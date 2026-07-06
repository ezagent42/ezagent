# World 场景 05：cc-agent(Claude Code)往返

| 字段 | 值 |
|---|---|
| 状态 | 🟥 FAIL |
| 执行时间 | 2026-07-02 17:29-17:35 SGT |
| 分支 / commit | `work/world-ui-user-surface-main-0702` / `01b1702f` |
| 服务 | `http://world.localhost:10042` |
| 被测 session | `session://system/default/world-e2e-session-0702` |
| 被测 agent | `entity://system/agent/claude-bot` |
| 浏览器会话 | `agent-browser --session world-login-e2e` |
| 完整录屏 | `evidence/world-scenario-05-cc-roundtrip/world-s05-cc-roundtrip-complete-flow-verified.webm` |

## 目标

验证 World UI 中 cc-agent(Claude Code)被邀请进 session 后，可以通过 `@claude-bot` mention 收到消息并回复。

本次实测结果：邀请、在线状态展示、mention 自动补全、消息发送均成功；消息写入后没有 cc-agent 回复。服务日志显示消息被写入并给 `claude-bot` 标记 delivered，但没有后续回复消息；更早的同次服务日志显示 `claude-bot` 的 Claude PTY 进程因 `unknown option '--dangerously-load-development-channels'` 退出，当前 UI 仍显示 `data-online=true`。

## 当前 UI 差异

旧 runbook 中邀请成员描述为输入完整 URI；当前页面实际是下拉选择卡片/选项：

- 点击 `Invite a member`
- 在 `Invite member` 下拉中选择 `claude-bot (agent)`
- 点击 `Invite`

## 证据

| 文件 | 内容 |
|---|---|
| `world-s05-cc-roundtrip-complete-flow-verified.webm` | scenario-05 从邀请 `claude-bot` 到发送消息、等待无回复的完整录屏 |
| `world-s05-cc-roundtrip-complete-flow.webm` | 本场景正式开始前的短预录屏，保留为 preflight 证据 |
| `world-s05-step01-session-baseline.png` | 进入 `world-e2e-session-0702` 的基线截图 |
| `world-s05-step02-invite-dropdown-options.png` | 当前 Invite member 下拉选项，包含 `claude-bot (agent)` |
| `world-s05-step03-claude-bot-member-added.png` | `claude-bot` 加入后成员数变为 4 |
| `world-s05-step04-claude-autocomplete.png` | 输入 `@claude` 后出现 `@claude-bot` 自动补全 |
| `world-s05-step05-claude-mentioned.png` | 通过自动补全写入 `@claude-bot` |
| `world-s05-step06-cc-message-sent.png` | 发送 `@claude-bot  cc-ping-world-0702` 后的聊天状态 |
| `world-s05-step07-cc-no-reply.png` | 等待后仍无 cc-agent 回复 |

## 执行步骤

| # | 操作 | 实际结果 | 判定 |
|---|---|---|---|
| 1 | 打开 `world-e2e-session-0702` | 页面可访问，服务健康检查 200 | ✅ |
| 2 | 点击 `Invite a member` | 出现 `Invite member` 下拉，候选包含 `claude-bot (agent)` | ✅ |
| 3 | 选择 `claude-bot (agent)` 并点击 `Invite` | 成员数从 3 变为 4，成员列表出现 `claude-bot` | ✅ |
| 4 | 读取成员 DOM 状态 | `claude-bot` 为 `kind=agent` 且 `online=true` | ✅ |
| 5 | 在消息框键入 `@claude` | 自动补全弹出 `@claude-bot` | ✅ |
| 6 | 点击 `@claude-bot` 候选并输入 ` cc-ping-world-0702` | 输入框出现 mention + 测试消息 | ✅ |
| 7 | 按 Enter 发送 | 聊天区新增 Admin 消息 `@claude-bot  cc-ping-world-0702` | ✅ |
| 8 | 等待约 30 秒 cc-agent 回复 | 未出现 `data-sender-kind=agent` 且包含 `cc-ping-world-0702` 的消息 | 🟥 |

页面文本最终状态：

```text
4 members · 3 turns
YOU Admin ... hello-noroute-world-0702
YOU Admin ... @py_default ping-world-0702
YOU Admin ... @claude-bot  cc-ping-world-0702
```

成员 DOM 状态最终仍显示：

```json
[
  {"text":"claude-bot\nAGENT","kind":"agent","online":"true"},
  {"text":"py_default\nAGENT","kind":"agent","online":"true"},
  {"text":"world-e2e-native-0702\nAGENT","kind":"agent","online":"true"},
  {"text":"Admin\nUSER","kind":"user","online":"true"}
]
```

## 日志摘要

关键发送路径正常：

```text
HANDLE EVENT "world:dispatch" ... "action" => "chat.send"
"text" => "@claude-bot  cc-ping-world-0702"
INSERT INTO "messages" ... mentions=[entity://system/agent/claude-bot]
INSERT INTO "read_markers" ... source="delivered" user_uri="entity://system/agent/claude-bot"
```

同次服务日志中 `claude-bot` 的 PTY 运行时失败：

```text
PtyServer spawned claude ... agent=entity://system/agent/claude-bot
PtyServer: child process exited for entity://system/agent/claude-bot: {:exit_status, 256}
pty_buffer: "error: unknown option '--dangerously-load-development-channels'"
phase: :dead
```

## 预期 vs 实际

| 断言 | 预期 | 实际 | 判定 |
|---|---|---|---|
| Invite `claude-bot` | agent 加入 session | 成员数 4，列表有 `claude-bot` | ✅ |
| Mention 自动补全 | 输入 `@claude` 后出现 `@claude-bot` | 成功出现并可点击 | ✅ |
| 消息路由 | Admin 消息 mention 指向 `claude-bot`，并标记 delivered | 日志确认 messages + delivered read_marker | ✅ |
| cc-agent 回复 | `claude-bot` 产生 agent 回复 | 无回复；UI online 与 PTY dead 状态不一致 | 🟥 |

## 后续自动化 Scenario

### 前置条件

- 已登录 Admin。
- 服务运行在 `http://world.localhost:10042`。
- 已存在 session：`session://system/default/world-e2e-session-0702`。
- 已存在 seeded cc-agent：`entity://system/agent/claude-bot`。
- 浏览器使用固定 session：`agent-browser --session world-login-e2e`。

### 自动化步骤

| # | 动作 | 建议定位 | 输入 | 自动化断言 | 截图 |
|---|---|---|---|---|---|
| 1 | 打开 session URL | `/sessions?session=<encoded session uri>` | - | URL 包含 `/sessions?session=`，页面标题为 `/Default/World-E2e-Session-0702` | `step01-session-baseline` |
| 2 | 打开邀请控件 | button text `Invite a member` | - | 页面出现 combobox `Invite member` | `step02-invite-dropdown-options` |
| 3 | 选择并邀请 `claude-bot` | combobox `Invite member` + button `Invite` | `claude-bot (agent)` | 成员列表包含 `claude-bot`，成员数为 `4` | `step03-claude-bot-member-added` |
| 4 | 验证成员 DOM 状态 | `[data-kind], [data-online]` | - | `claude-bot` 节点 `data-kind=agent`、`data-online=true` | - |
| 5 | 触发 mention 自动补全 | textbox `Message` | 键盘输入 `@claude` | listbox `Mention a member` 出现 button `@claude-bot` | `step04-claude-autocomplete` |
| 6 | 选择 mention 并发送 | button `@claude-bot` + textbox `Message` | ` cc-ping-world-0702` + Enter | 页面出现 Admin 发送的 `@claude-bot  cc-ping-world-0702` | `step05`、`step06` |
| 7 | 等待 cc-agent 回复 | `[data-sender-kind=agent]` | - | 30s 内应出现包含 `cc-ping-world-0702` 的 agent 消息；当前实测 FAIL | `step07-cc-no-reply` |

### 建议断言代码

```js
Array.from(document.querySelectorAll("[data-kind], [data-online]"))
  .map(el => ({
    text: el.innerText,
    kind: el.getAttribute("data-kind"),
    online: el.getAttribute("data-online")
  }))
```

```js
Array.from(document.querySelectorAll("[data-sender-kind=agent]"))
  .some(el => el.innerText.includes("cc-ping-world-0702"))
```

## 清理

本场景复用已有 session 和 seeded `claude-bot`，没有创建新实体。若需要回到 scenario-04 的成员状态，可从成员列表中移除 `claude-bot`。
