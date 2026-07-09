# World 场景 04(执行记录):agent mention 往返

| 字段 | 值 |
|---|---|
| **状态** | 🟥 FAIL |
| **对应设计场景** | [scenarios/08-4agent-comprehensive](../scenarios/08-4agent-comprehensive/scenario.zh_cn.md) |
| **验证面** | world UI / chat send / mention routing / agent runtime |
| **执行人** | Codex + agent-browser |
| **执行时间** | 2026-07-02 17:17 +08 |
| **环境** | 分支 `work/world-ui-user-surface-main-0702` · commit `01b1702f` · server `http://world.localhost:10042` |
| **前置 scenario** | [world-scenario-03-create-session](./world-scenario-03-create-session.md) ✅ |

## 前置条件(当次实际)

- admin 已登录:`admin@ezagent.chat` / `worlddev`
- 当前 session:`session://system/default/world-e2e-session-0702`
- scenario-03 已加入成员:`entity://system/agent/world-e2e-native-0702` + Admin
- 旧 scenario-04 指出当前可回显 agent 应使用 seeded `py_default`,不是 `native`
- 本次在当前 session 中额外加入 `entity://system/agent/py_default`
- `Advanced rules` 显示 `0`,即没有显式 routing 规则
- agent-browser session:`world-login-e2e`
- 录屏:从 session 基线开始,持续到 @mention 消息未收到 agent 回复

## 角色

- **调用方**:admin(`entity://system/user/admin`)
- **目标 session**:`session://system/default/world-e2e-session-0702`
- **目标 agent**:`entity://system/agent/py_default`

## 当前 UI / 运行态实测

| 项 | 当前观察 |
|---|---|
| 可回显 agent | seeded `py_default`;`world-e2e-native-0702` 只用于创建/成员链路验证 |
| 成员状态 | UI/DOM 显示 `py_default` 为 `data-kind="agent"` 且 `data-online="true"` |
| 路由规则 | `Advanced rules` 为 `0` |
| mention 输入 | 必须真实键盘输入 `@py`,点击 autocomplete 候选 `@py_default` |
| 失败点 | 服务日志显示 `PyAgent entity://system/agent/py_default receive failed input="@py_default ping-world-0702" reason=:not_alive` |

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | 打开第三条创建的 session | 页面显示 `/Default/World-E2e-Session-0702`;当前 `2 members · 0 turns`;成员为 `world-e2e-native-0702` + Admin;`Advanced rules=0` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step01-session-baseline.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 2 | 打开 Invite,选择 `py_default (agent)` | Invite 下拉中可见并选中 `py_default (agent)` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step02-py-default-selected.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 3 | 提交 Invite | 成员变为 `3 members`;页面显示 `py_default AGENT`;DOM 显示 `py_default` 为 `data-online="true"` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step03-py-default-member-added.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 4 | 发送普通消息 `hello-noroute-world-0702` | 消息上屏;2.5s 后 transcript 仅有 1 条 user 气泡,无 agent 气泡;符合 `ROUTING=0` 下无 @ 不送达 | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step04-no-mention-no-reply.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 5 | 真实键盘输入 `@py` | mention autocomplete 出现,候选为 `@py_default` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step05-mention-autocomplete.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 6 | 点击 `@py_default`,继续输入 `ping-world-0702` | 输入框中真实 mention 成为 `@py_default `,随后发送 `@py_default ping-world-0702` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step06-mention-selected.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ✅ |
| 7 | 等待 py_default 回显 | 30s 内没有 agent 气泡;transcript 只有两条 Admin user 消息。服务日志显示投递到 `py_default` 后 runtime `:not_alive` | [截图](./evidence/world-scenario-04-agent-roundtrip/world-s04-step07-mention-no-agent-reply.png) · [完整录屏](./evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm) | ❌ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| 无 @mention 且 `ROUTING=0` 时普通消息不送达 agent | `hello-noroute-world-0702` 仅显示 Admin user 气泡,无 agent 气泡 | ✅ |
| @mention 能解析到目标成员 | `@py` autocomplete 显示 `@py_default`,点击后输入框成为 `@py_default ` | ✅ |
| @py_default 消息被路由/投递到 agent | 服务日志显示 `agent.receive` 投递到 `entity://system/agent/py_default` | ✅ |
| py_default 回显 payload | 没有 agent 回复;日志显示 `reason=:not_alive` | ❌ |
| UI online 状态能反映 agent runtime 可接收 | UI/DOM 显示 `py_default data-online=true`,但 receive 失败 `:not_alive` | ❌ |

## 遗留 / bug

- **阻塞 roundtrip**:`py_default` 在成员列表中显示 online,但收到 mention 后 runtime 返回 `:not_alive`,导致无回显。
- **UI 状态偏差**:成员 `data-online="true"` 与 runtime `:not_alive` 不一致。后续需要确认 online 表示"成员在线/快照存在",还是应该代表实际 runtime alive。
- `ROUTING=0` 下无 @ 不回复的行为符合旧 scenario-04 的 divergence 记录;本轮再次复现。

## 证据清单

- `evidence/world-scenario-04-agent-roundtrip/world-s04-agent-roundtrip-complete-flow.webm` — 加入 py_default + 普通消息 + @mention 消息完整录屏
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step01-session-baseline.png` — session 基线,2 members / 0 turns / Advanced rules=0
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step02-py-default-selected.png` — Invite 下拉选择 `py_default`
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step03-py-default-member-added.png` — `py_default` 加入成员且 UI 显示 online
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step04-no-mention-no-reply.png` — 无 @mention 普通消息不触发 agent 回复
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step05-mention-autocomplete.png` — `@py` 触发 autocomplete 候选 `@py_default`
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step06-mention-selected.png` — `@py_default` 真实 mention 已插入
- `evidence/world-scenario-04-agent-roundtrip/world-s04-step07-mention-no-agent-reply.png` — @mention 后仍无 agent 回复

## 交叉引用

- 历史执行记录:`docs/e2e/scenario-04-echo-roundtrip.md`
- 前置 session 记录:`docs/e2e/world-scenario-03-create-session.md`

---

## 自动化运行(agent-browser runbook)

**前置(自动化)**:world scenario 03 已创建并打开 `session://system/default/world-e2e-session-0702`。
**入口 URL**:`http://world.localhost:10042/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fworld-e2e-session-0702`
**证据目录**:`docs/e2e/evidence/world-scenario-04-agent-roundtrip/`

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | record start | — | `world-s04-agent-roundtrip-complete-flow.webm` | 录屏开始 | `.webm` |
| 2 | assert baseline | body text | — | 包含 `World-E2e-Session-0702` 和 `Advanced rules 0` | `world-s04-step01-session-baseline.png` |
| 3 | invite member | combobox `Invite member` | `py_default (agent)` | 成员列表包含 `py_default` | `world-s04-step03-py-default-member-added.png` |
| 4 | send no-mention | textbox `Message` | `hello-noroute-world-0702` | 仅出现 user 气泡,无 agent 气泡 | `world-s04-step04-no-mention-no-reply.png` |
| 5 | trigger mention | keyboard `@py` | — | listbox 显示 `@py_default` | `world-s04-step05-mention-autocomplete.png` |
| 6 | select mention + send | click `@py_default`,type payload | `ping-world-0702` | user 气泡上屏 | `world-s04-step06-mention-selected.png` |
| 7 | wait for reply | `[data-sender-kind=agent]` | — | 期望 agent 气泡包含 `ping-world-0702`;本次实际 FAIL | `world-s04-step07-mention-no-agent-reply.png` |
| 8 | record stop | — | — | 录屏文件已保存 | `.webm` |

**当前自动化断言建议**:
- 若用于复现当前 bug:step7 断言"30s 内没有 agent 气泡" + 日志包含 `reason=:not_alive`。
- 若用于未来修复验收:step7 应改为等待 `Array.from(document.querySelectorAll('[data-sender-kind=agent]')).some(el => el.innerText.includes('ping-world-0702'))`。

**清理**:删除 `world-e2e-session-0702`,或重置 DB 后重新 seed。
