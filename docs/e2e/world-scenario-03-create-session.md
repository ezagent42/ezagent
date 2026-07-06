# World 场景 03(执行记录):创建 session + 加成员

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/09-session-create-lv](../scenarios/09-session-create-lv/scenario.zh_cn.md) |
| **验证面** | world UI / session create / member invite |
| **执行人** | Codex + agent-browser |
| **执行时间** | 2026-07-02 17:04 +08 |
| **环境** | 分支 `work/world-ui-user-surface-main-0702` · commit `01b1702f` · server `http://world.localhost:10042` |
| **前置 scenario** | [world-scenario-01-login](./world-scenario-01-login.md) ✅ + [world-scenario-02-create-agent](./world-scenario-02-create-agent.md) ✅ |

## 前置条件(当次实际)

- admin 已登录:`admin@ezagent.chat` / `worlddev`
- workspace:`workspace://system`
- scenario-02 已创建 agent:`entity://system/agent/world-e2e-native-0702`
- 已启动服务:`PORT=10042 WORLD_VITE_PORT=5173 mix phx.server`
- 健康检查:`http://localhost:10042/_health` → `200 {"status":"ok"}`
- agent-browser session:`world-login-e2e`
- 录屏:从 `/sessions` 开始,持续到新 session 创建成功并加入 agent 成员

## 角色

- **调用方**:admin(`entity://system/user/admin`)
- **目标 session**:`session://system/default/world-e2e-session-0702`
- **目标成员**:`entity://system/agent/world-e2e-native-0702`

## 当前 UI 实测字段

| 区域 | 当前 UI | 本次值 / 观察 |
|---|---|---|
| New session | `Create a new session` 按钮展开内联表单 | 点击后显示 Name + Template |
| Name | 文本框 | `world-e2e-session-0702` |
| Template | 下拉:`default`,`generic`,`hello` | `default` |
| Invite member | 下拉选择器,不是手写完整 URI | 选择 `world-e2e-native-0702 (agent)` |
| 成员状态 | 成员列表 DOM 暴露 `data-kind` / `data-online` | agent 与 Admin 均 `data-online="true"` |

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | 打开 `http://world.localhost:10042/sessions` | Sessions 列表渲染;可见 `Create a new session` 按钮 | [截图](./evidence/world-scenario-03-create-session/world-s03-step01-sessions-page.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 2 | 点击 `Create a new session` | 内联创建表单出现;字段为 Name 与 Template;Template 默认 `default` | [截图](./evidence/world-scenario-03-create-session/world-s03-step02-new-session-form.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 3 | 填写 Name=`world-e2e-session-0702` | Create 按钮启用;Template 保持 `default` | [截图](./evidence/world-scenario-03-create-session/world-s03-step03-session-form-ready.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 4 | 点击 `Create` | 普通点击提交成功;跳转到 `/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fworld-e2e-session-0702`;页面显示 `/Default/World-E2e-Session-0702`,初始 `1 member · 0 turns` | [截图](./evidence/world-scenario-03-create-session/world-s03-step04-session-created.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 5 | 点击 `Invite` | 邀请表单打开;当前 UI 是 `Invite member` 下拉框,不是旧文档里的手写 URI 输入 | [截图](./evidence/world-scenario-03-create-session/world-s03-step05-invite-form.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 6 | 在下拉框选择 `world-e2e-native-0702 (agent)` | 下拉框选中目标 agent | [截图](./evidence/world-scenario-03-create-session/world-s03-step06-member-selected.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |
| 7 | 点击 `Invite` 提交 | 成员列表变为 `2 members · 0 turns`;显示 `world-e2e-native-0702 AGENT` 与 `Admin USER`;DOM 确认 agent/user 均 `data-online="true"` | [截图](./evidence/world-scenario-03-create-session/world-s03-step07-member-added.png) · [完整录屏](./evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| session spawn 成功并进入 session 页 | 成功进入 `session://system/default/world-e2e-session-0702`;页面显示 `/Default/World-E2e-Session-0702` | ✅ |
| 默认模板可创建 session | Template=`default` 创建成功 | ✅ |
| 加入 scenario-02 创建的 agent 成员 | `world-e2e-native-0702` 加入成员列表 | ✅ |
| 成员加入即 ready/online,无 `no_such_actor` 快照竞态 | DOM 显示 `LI[data-kind=agent][data-online=true]`;Admin 也 `data-online=true` | ✅ |

## 当前 UI 差异 / 备注

- 创建 session 的普通 `Create` 点击本次正常提交,没有复现第二条 agent 创建里的 click no-op。
- Invite 成员当前是下拉选择器,不是旧 runbook 里的完整 URI 文本输入。自动化应选择可见项 `world-e2e-native-0702 (agent)`。
- session 显示名会 title-case 为 `/Default/World-E2e-Session-0702`,但 URL/URI 中仍是 `session://system/default/world-e2e-session-0702`。

## 证据清单

- `evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm` — 创建 session + 加成员完整 agent-browser 录屏
- `evidence/world-scenario-03-create-session/world-s03-step01-sessions-page.png` — Sessions 初始页面
- `evidence/world-scenario-03-create-session/world-s03-step02-new-session-form.png` — New session 表单
- `evidence/world-scenario-03-create-session/world-s03-step03-session-form-ready.png` — 填写 session 名称后 Create 可用
- `evidence/world-scenario-03-create-session/world-s03-step04-session-created.png` — session 创建成功并进入详情
- `evidence/world-scenario-03-create-session/world-s03-step05-invite-form.png` — Invite member 下拉框
- `evidence/world-scenario-03-create-session/world-s03-step06-member-selected.png` — 选中 `world-e2e-native-0702 (agent)`
- `evidence/world-scenario-03-create-session/world-s03-step07-member-added.png` — 成员加入成功,成员数为 2

## 交叉引用

- 历史执行记录:`docs/e2e/scenario-03-create-session.md`
- 依赖 agent 创建记录:`docs/e2e/world-scenario-02-create-agent.md`

---

## 自动化运行(agent-browser runbook)

**前置(自动化)**:world scenario 01 已登录;world scenario 02 已创建 `entity://system/agent/world-e2e-native-0702`。
**入口 URL**:`http://world.localhost:10042/sessions`
**自建实体**:`session://system/default/world-e2e-session-0702`
**证据目录**:`docs/e2e/evidence/world-scenario-03-create-session/`

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | record start | — | `world-s03-create-session-complete-flow.webm` | 录屏开始 | `.webm` |
| 2 | navigate | — | `/sessions` | body text 包含 `Sessions` | `world-s03-step01-sessions-page.png` |
| 3 | click | button `Create a new session` | — | 表单出现,包含 `Name` 与 `Template` | `world-s03-step02-new-session-form.png` |
| 4 | fill | textbox `Name` | `world-e2e-session-0702` | button `Create` enabled | `world-s03-step03-session-form-ready.png` |
| 5 | click submit | button `Create` | — | `location.href` 包含 `world-e2e-session-0702` | `world-s03-step04-session-created.png` |
| 6 | click | button `Invite a member` | — | `Invite member` combobox visible | `world-s03-step05-invite-form.png` |
| 7 | select | combobox `Invite member` | `world-e2e-native-0702 (agent)` | combobox value 已选中 | `world-s03-step06-member-selected.png` |
| 8 | click submit | button `Invite` | — | body text 包含 `2 members` 和 `world-e2e-native-0702` | `world-s03-step07-member-added.png` |
| 9 | assert DOM | `[data-kind=agent]` | — | `data-online === "true"` | 同 step8 |
| 10 | record stop | — | — | 录屏文件已保存 | `.webm` |

**断言映射**:
- session 创建成功 → step5 URL 包含 `world-e2e-session-0702`
- agent 成员加入 → step8 正文包含 `2 members` 和 `world-e2e-native-0702`
- 无 `no_such_actor` / 成员 ready → step9 `LI[data-kind=agent][data-online=true]`

**建议自动化脚本骨架**:

```bash
agent-browser --session world-login-e2e record start docs/e2e/evidence/world-scenario-03-create-session/world-s03-create-session-complete-flow.webm
agent-browser --session world-login-e2e open http://world.localhost:10042/sessions
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step01-sessions-page.png
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e click '@e10'
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step02-new-session-form.png
agent-browser --session world-login-e2e fill '@e23' 'world-e2e-session-0702'
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step03-session-form-ready.png
agent-browser --session world-login-e2e click '@e17'
agent-browser --session world-login-e2e wait --fn "location.href.includes('world-e2e-session-0702')"
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step04-session-created.png
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e click '@e13'
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step05-invite-form.png
agent-browser --session world-login-e2e select '@e18' 'world-e2e-native-0702 (agent)'
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step06-member-selected.png
agent-browser --session world-login-e2e click '@e19'
agent-browser --session world-login-e2e wait --fn "document.body.innerText.includes('2 members') && document.body.innerText.includes('world-e2e-native-0702')"
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-03-create-session/world-s03-step07-member-added.png
agent-browser --session world-login-e2e eval "Array.from(document.querySelectorAll('[data-kind=agent]')).some(el => el.innerText.includes('world-e2e-native-0702') && el.getAttribute('data-online') === 'true')"
agent-browser --session world-login-e2e record stop
```

**清理**:删除 `world-e2e-session-0702`,或重置 DB 后重新 seed。
