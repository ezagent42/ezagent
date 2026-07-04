# World 场景 02(执行记录):创建 agent

| 字段 | 值 |
|---|---|
| **状态** | ⚠️ PASS-with-gaps |
| **对应设计场景** | ⚠️ 设计场景缺位;参考 [e2e/scenario-02-create-agent](./scenario-02-create-agent.md) |
| **验证面** | world UI / agent provisioning / project_cwd selector |
| **执行人** | Codex + agent-browser |
| **执行时间** | 2026-07-02 16:46 +08 |
| **环境** | 分支 `work/world-ui-user-surface-main-0702` · commit `01b1702f` · server `http://world.localhost:10042` |
| **前置 scenario** | [world-scenario-01-login](./world-scenario-01-login.md) ✅ 已恢复 admin 登录态 |

## 前置条件(当次实际)

- 目标 worktree:`/home/lenovo/workspace/ezagent/.worktrees/world-ui-user-surface-main-0702`
- 已启动服务:`PORT=10042 WORLD_VITE_PORT=5173 mix phx.server`
- 健康检查:`http://localhost:10042/_health` → `200 {"status":"ok"}`
- 管理员已登录:`admin@ezagent.chat` / `worlddev`
- agent-browser session:`world-login-e2e`
- 录屏:从打开 New Agent 表单开始,持续到新 agent 在列表中可见

## 角色

- **调用方**:admin(`entity://system/user/admin`)
- **目标**:`workspace://system` 下创建 `entity://system/agent/world-e2e-native-0702`

## 当前表单实测字段

| 字段 | 当前 UI | 本次值 / 观察 |
|---|---|---|
| **Flavor** | 下拉:`cc`,`cc-headless`,`codex`,`codex-remote`,`py`,`curl`,`native`,`hello_builder` | `native` |
| **Name** | 必填文本框 | `world-e2e-native-0702` |
| **project_cwd** | 两张选择卡片,不是字符串输入 | 选中/默认:`使用系统默认目录（推荐）`;禁用:`使用自定义项目目录` |
| **role** | native 配置文本框 | 留空 |
| **Requested caps** | 文本框 | 留空 |
| **With PTY** | 复选框 | 未勾选 |
| **URI 预览** | 表单正文实时显示 | `entity://system/agent/world-e2e-native-0702` |

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | 打开 `http://world.localhost:10042/identities/agents/new` | New Agent 表单渲染;默认 flavor 为 `cc`;project_cwd 已展示为两张卡片 | [截图](./evidence/world-scenario-02-create-agent/world-s02-step01-agent-new-form.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ✅ |
| 2 | 将 flavor 改为 `native` | 表单切到 `NATIVE CONFIGURATION`;project_cwd 仍是两张卡片:默认目录可用,自定义目录禁用 | [截图](./evidence/world-scenario-02-create-agent/world-s02-step02-project-cwd-cards.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ✅ |
| 3 | 填写 Name=`world-e2e-native-0702` | Create 按钮启用;URI 预览为 `entity://system/agent/world-e2e-native-0702` | [截图](./evidence/world-scenario-02-create-agent/world-s02-step03-agent-form-ready.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ✅ |
| 4 | 点击 `Create` | 页面仍停留在 `/identities/agents/new`;没有跳转,也没有错误提示;随后用 `form.requestSubmit()` 继续提交 | [截图](./evidence/world-scenario-02-create-agent/world-s02-step04-create-click-noop.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ⚠️ |
| 5 | 执行 `form.requestSubmit(button[type=submit])` | 成功跳转 agent 详情页:`/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fworld-e2e-native-0702`;详情显示 Phase=`alive`,Flavor=`native` | [截图](./evidence/world-scenario-02-create-agent/world-s02-step05-agent-detail-success.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ✅ |
| 6 | 打开 `/identities/agents` 列表确认 | 列表中出现 `world-e2e-native-0702`,URI 为 `entity://system/agent/world-e2e-native-0702`,flavor 为 `native` | [截图](./evidence/world-scenario-02-create-agent/world-s02-step06-agent-list-confirmed.png) · [完整录屏](./evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| admin 能进入 New Agent 表单 | `/identities/agents/new` 正常渲染 | ✅ |
| project_cwd 按当前 UI 选择,不是手写字符串 | 当前是两张卡片:`使用系统默认目录（推荐）` 和禁用的 `使用自定义项目目录` | ✅ |
| 创建 agent 后进入详情页且 URI 正确 | `requestSubmit()` 后进入 `entity://system/agent/world-e2e-native-0702` 详情页 | ✅ |
| Agents 列表可见新 agent | `/identities/agents` 列表出现 `world-e2e-native-0702` | ✅ |
| 用户点击 Create 即可提交 | agent-browser 点击 `Create` 没有提交;需要 `form.requestSubmit()` 绕过 | ⚠️ |

## 遗留 / bug

- **需要修正文档/自动化**:`project_cwd` 已不是字符串输入框,而是卡片选择器。自动化不要再定位或填充 `project_cwd` 文本框。
- **点击提交 gap**:普通点击 `Create` 在本次 agent-browser 执行中没有触发提交;`form.requestSubmit()` 可以成功提交。建议前端确认 React island 表单 submit/click 事件是否被吞。
- 本次使用 `native` flavor 验证创建链路;它创建后 Phase=`alive`,但并不代表可聊天回显。下游聊天往返仍需使用有脚本/行为配置的 agent。

## 证据清单

- `evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm` — 创建 agent 完整 agent-browser 录屏
- `evidence/world-scenario-02-create-agent/world-s02-step01-agent-new-form.png` — New Agent 表单初始状态
- `evidence/world-scenario-02-create-agent/world-s02-step02-project-cwd-cards.png` — project_cwd 两张卡片当前 UI
- `evidence/world-scenario-02-create-agent/world-s02-step03-agent-form-ready.png` — 填写名称后 Create 可用
- `evidence/world-scenario-02-create-agent/world-s02-step04-create-click-noop.png` — 点击 Create 后未跳转
- `evidence/world-scenario-02-create-agent/world-s02-step05-agent-detail-success.png` — requestSubmit 后进入 agent 详情
- `evidence/world-scenario-02-create-agent/world-s02-step06-agent-list-confirmed.png` — Agents 列表确认新 agent

## 交叉引用

- 历史执行记录:`docs/e2e/scenario-02-create-agent.md`
- 当前前置登录记录:`docs/e2e/world-scenario-01-login.md`

---

## 自动化运行(agent-browser runbook)

**前置(自动化)**:world scenario 01 已完成登录;如果服务重启导致 cookie 失效,先用 `admin@ezagent.chat` / `worlddev` 恢复登录。
**入口 URL**:`http://world.localhost:10042/identities/agents/new`
**自建实体**:`entity://system/agent/world-e2e-native-0702`
**证据目录**:`docs/e2e/evidence/world-scenario-02-create-agent/`

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | record start | — | `world-s02-create-agent-complete-flow.webm` | 录屏开始 | `.webm` |
| 2 | navigate | — | `/identities/agents/new` | `document.body.innerText.includes("New agent")` | `world-s02-step01-agent-new-form.png` |
| 3 | select flavor | `select` / combobox `Flavor` | `native` | `document.body.innerText.includes("NATIVE CONFIGURATION")` | `world-s02-step02-project-cwd-cards.png` |
| 4 | assert project_cwd UI | body text | — | 包含 `使用系统默认目录（推荐）` 且包含 `使用自定义项目目录`;自定义卡片 disabled | 同 step3 |
| 5 | fill name | textbox `Name *` | `world-e2e-native-0702` | body text 包含 `entity://system/agent/world-e2e-native-0702` | `world-s02-step03-agent-form-ready.png` |
| 6 | click submit | button `Create` | — | 若未跳转,记录 no-op | `world-s02-step04-create-click-noop.png` |
| 7 | submit fallback | `document.querySelector("form").requestSubmit(button)` | — | `location.pathname.includes("/identities/agents/entity")` | `world-s02-step05-agent-detail-success.png` |
| 8 | navigate list | — | `/identities/agents` | body text 包含 `world-e2e-native-0702` | `world-s02-step06-agent-list-confirmed.png` |
| 9 | record stop | — | — | 录屏文件已保存 | `world-s02-create-agent-complete-flow.webm` |

**断言映射**:
- `project_cwd` 当前 UI → step4 卡片文案 + 自定义卡片 disabled
- agent 创建成功 → step7 详情页 URL + Phase=`alive`
- agent 列表可见 → step8 列表正文包含名称和 URI

**建议自动化脚本骨架**:

```bash
agent-browser --session world-login-e2e record start docs/e2e/evidence/world-scenario-02-create-agent/world-s02-create-agent-complete-flow.webm
agent-browser --session world-login-e2e open http://world.localhost:10042/identities/agents/new
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step01-agent-new-form.png
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e select '@e15' 'native'
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step02-project-cwd-cards.png
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e fill '@e16' 'world-e2e-native-0702'
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step03-agent-form-ready.png
agent-browser --session world-login-e2e click '@e14'
agent-browser --session world-login-e2e wait 2000
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step04-create-click-noop.png
agent-browser --session world-login-e2e eval "(() => { const form = document.querySelector('form'); const btn = form?.querySelector('button[type=submit]'); form.requestSubmit(btn); return location.href; })()"
agent-browser --session world-login-e2e wait --fn "location.pathname.includes('/identities/agents/entity')"
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step05-agent-detail-success.png
agent-browser --session world-login-e2e open http://world.localhost:10042/identities/agents
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-02-create-agent/world-s02-step06-agent-list-confirmed.png
agent-browser --session world-login-e2e record stop
```

**清理**:删除 `world-e2e-native-0702`,或重置 DB 后重新 seed。
