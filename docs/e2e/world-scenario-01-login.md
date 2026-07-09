# World 场景 01(执行记录):登录成功与失败流程

| 字段 | 值 |
|---|---|
| **状态** | ⚠️ PASS-with-gaps |
| **对应设计场景** | [scenarios/02-password-login-admin](../scenarios/02-password-login-admin/scenario.zh_cn.md) |
| **验证面** | world UI / password login / failure prompt |
| **执行人** | Codex + agent-browser |
| **执行时间** | 2026-07-02 16:12 +08 |
| **环境** | 分支 `work/world-ui-user-surface-main-0702` · commit `01b1702f` · server `http://world.localhost:10042` |
| **前置 scenario** | 无(World E2E 第一条登录流程) |

## 前置条件(当次实际)

- 目标 worktree:`/home/lenovo/workspace/ezagent/.worktrees/world-ui-user-surface-main-0702`
- 已启动服务:`PORT=10042 WORLD_VITE_PORT=5173 mix phx.server`
- 健康检查:`http://localhost:10042/_health` → `200 {"status":"ok"}`
- Vite:`http://localhost:5173/src/main.tsx` → `200`
- 已跑 seed:`mix run scripts/world_e2e_seed.exs`
- 管理员凭据:`admin@ezagent.chat` / `worlddev`
- agent-browser session:`world-login-e2e`
- 录屏:从失败登录开始,持续到成功进入 `/sessions`

## 角色

- **调用方**:匿名浏览器 session
- **目标**:`entity://system/user/admin` password login

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | 打开 `http://world.localhost:10042/login` | 登录页渲染;可见标题"登录"、邮箱输入框、密码输入框和"登录"按钮 | [截图](./evidence/world-scenario-01-login/world-s01-step01-login-page.png) · [完整录屏](./evidence/world-scenario-01-login/world-s01-login-complete-flow.webm) | ✅ |
| 2 | 在 `/login` 输入账号 `123456`,密码 `123456`,点击"登录" | 未发起登录跳转;浏览器原生邮箱格式校验提示:`请在电子邮件地址中包括“@”。“123456”中缺少“@”。` | [截图](./evidence/world-scenario-01-login/world-s01-step02-invalid-account-error.png) · [完整录屏](./evidence/world-scenario-01-login/world-s01-login-complete-flow.webm) | ⚠️ |
| 3 | 在 `/login` 输入账号 `admin@ezagent.chat`,密码 `123456`,点击"登录" | 仍停留在 `/login`;页面提示:`Invalid email or password.` | [截图](./evidence/world-scenario-01-login/world-s01-step03-wrong-password-error.png) · [完整录屏](./evidence/world-scenario-01-login/world-s01-login-complete-flow.webm) | ⚠️ |
| 4 | 在 `/login` 输入账号 `admin@ezagent.chat`,密码 `worlddev`,点击"登录" | 成功进入 `http://world.localhost:10042/sessions`;Sessions 列表页渲染,可见导航和会话列表 | [截图](./evidence/world-scenario-01-login/world-s01-step04-sessions-success.png) · [完整录屏](./evidence/world-scenario-01-login/world-s01-login-complete-flow.webm) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| `/login` 使用 `admin@ezagent.chat` / `worlddev` 登录后进入 `/sessions` | 成功进入 `/sessions`,Sessions 页面渲染 | ✅ |
| `/login` 使用账号 `123456` / 密码 `123456` 时出现账号错误提示 | 实际触发 HTML email 输入框原生格式校验:`请在电子邮件地址中包括“@”。“123456”中缺少“@”。` | ⚠️ |
| `/login` 使用账号 `admin@ezagent.chat` / 密码 `123456` 时出现密码错误提示 | 实际提示为通用英文:`Invalid email or password.` | ⚠️ |

## 遗留 / bug

- 账号 `123456` 当前被浏览器原生 `type=email` 格式校验拦截,不是业务层"账号不存在"提示。如要覆盖账号不存在,建议后续用格式合法但不存在的邮箱,例如 `missing-user@example.com`。
- 错误密码提示当前为通用英文 `Invalid email or password.`,不是中文或密码专属提示。若产品要求"密码错误"提示,需要补 UI 文案或后端错误映射。
- agent-browser 的 `wait --url '**/sessions'` 在本次执行中超时,但随后 `get url` 已确认当前 URL 为 `/sessions`;自动化建议改用 `wait --fn "location.pathname === '/sessions'"` 或等待 Sessions 页面稳定元素。

## 证据清单

- `evidence/world-scenario-01-login/world-s01-login-complete-flow.webm` — 从失败登录到成功登录的完整 agent-browser 录屏
- `evidence/world-scenario-01-login/world-s01-step01-login-page.png` — `/login` 初始页面
- `evidence/world-scenario-01-login/world-s01-step02-invalid-account-error.png` — `123456` 账号触发邮箱格式校验
- `evidence/world-scenario-01-login/world-s01-step03-wrong-password-error.png` — 正确账号 + 错误密码提示
- `evidence/world-scenario-01-login/world-s01-step04-sessions-success.png` — 正确账号 + 正确密码进入 `/sessions`

## 交叉引用

- 设计场景:`docs/scenarios/02-password-login-admin`
- 操作指引:`docs/guide/login-and-registration.zh_cn.md`

---

## 自动化运行(agent-browser runbook)

**前置(自动化)**:目标分支服务已启动,world seed 已导入,管理员账号 `admin@ezagent.chat` / `worlddev` 可用。
**入口 URL**:`http://world.localhost:10042/login`
**证据目录**:`docs/e2e/evidence/world-scenario-01-login/`

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | record start | — | `world-s01-login-complete-flow.webm` | 录屏开始 | `.webm` |
| 2 | navigate | — | `/login` | `location.pathname === "/login"` | `world-s01-step01-login-page.png` |
| 3 | fill | `input[type=email]` | `123456` | — | — |
| 4 | fill | `input[type=password]` | `123456` | — | — |
| 5 | click submit | `button[type=submit]` | — | `input[type=email].validationMessage` 包含 `@` | `world-s01-step02-invalid-account-error.png` |
| 6 | fill | `input[type=email]` | `admin@ezagent.chat` | — | — |
| 7 | fill | `input[type=password]` | `123456` | — | — |
| 8 | click submit | `button[type=submit]` | — | `document.body.innerText.includes("Invalid email or password.")` | `world-s01-step03-wrong-password-error.png` |
| 9 | fill | `input[type=email]` | `admin@ezagent.chat` | — | — |
| 10 | fill | `input[type=password]` | `worlddev` | — | — |
| 11 | click submit | `button[type=submit]` | — | `location.pathname === "/sessions"` | `world-s01-step04-sessions-success.png` |
| 12 | record stop | — | — | 录屏文件已保存 | `world-s01-login-complete-flow.webm` |

**断言映射**:
- 登录页可访问 → step2 `location.pathname === "/login"`
- 错误账号提示 → step5 `validationMessage` 包含 `@`
- 错误密码提示 → step8 页面正文包含 `Invalid email or password.`
- 登录成功 → step11 `location.pathname === "/sessions"`

**建议自动化脚本骨架**:

```bash
agent-browser --session world-login-e2e close || true
agent-browser --session world-login-e2e set viewport 1440 900
agent-browser --session world-login-e2e record start docs/e2e/evidence/world-scenario-01-login/world-s01-login-complete-flow.webm
agent-browser --session world-login-e2e open http://world.localhost:10042/login
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-01-login/world-s01-step01-login-page.png
agent-browser --session world-login-e2e snapshot -i
agent-browser --session world-login-e2e fill '@e2' '123456'
agent-browser --session world-login-e2e fill '@e3' '123456'
agent-browser --session world-login-e2e click '@e4'
agent-browser --session world-login-e2e eval "document.querySelector('input[type=email]').reportValidity()"
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-01-login/world-s01-step02-invalid-account-error.png
agent-browser --session world-login-e2e fill '@e2' 'admin@ezagent.chat'
agent-browser --session world-login-e2e fill '@e3' '123456'
agent-browser --session world-login-e2e click '@e4'
agent-browser --session world-login-e2e wait 1000
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-01-login/world-s01-step03-wrong-password-error.png
agent-browser --session world-login-e2e fill '@e2' 'admin@ezagent.chat'
agent-browser --session world-login-e2e fill '@e3' 'worlddev'
agent-browser --session world-login-e2e click '@e4'
agent-browser --session world-login-e2e wait --fn "location.pathname === '/sessions'"
agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-01-login/world-s01-step04-sessions-success.png
agent-browser --session world-login-e2e record stop
```

**清理**:无(本流程只读登录,未创建业务实体)。
