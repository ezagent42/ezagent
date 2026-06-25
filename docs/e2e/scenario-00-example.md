<!-- 这是一条**填好的范例**,展示记录长什么样。真实测试时别改这条,复制 template 新建。 -->
# 场景 00(执行记录·范例):操作员登录 world UI

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS(示例) |
| **对应设计场景** | [docs/scenarios/02-password-login-admin](../scenarios/02-password-login-admin/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 14:30 |
| **环境** | 分支 `zyli-fullflow-validation-0624` · commit `5244e030` · server `http://world.localhost:10042` |
| **前置 scenario** | 无(全流程第一条) |

## 前置条件(当次实际)

- PG 已起 + world seed 已跑(`docs/guide/world-e2e-seed.md` 步 1–3),server `mix phx.server` 在 tmux `esrd`。
- `GET /_health` → 200 已确认。
- 凭据:world seed admin `admin@ezagent.chat` / `worlddev`。

## 角色

- **调用方**:匿名浏览器 session
- **目标**:`entity://system/user/admin`(Behavior `Ezagent.Behavior.Identity`,action `:password_login`)

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | agent-browser 打开 `http://world.localhost:10042`(未登录) | 重定向到 `/login`,渲染登录表单 | [s00-step1](./evidence/scenario-00/s00-step1-login-form.png) | ✅ |
| 2 | 邮箱填 `admin@ezagent.chat`,密码 `worlddev`,点 "Sign in" | 表单提交,LV 重定向到 world 主面板 | [s00-step2](./evidence/scenario-00/s00-step2-after-submit.png) | ✅ |
| 3 | 观察右上角用户态 + session 列表面板 | 显示 admin 已登录,workspace `system` 的 session 列表渲染 | [s00-step3](./evidence/scenario-00/s00-step3-dashboard.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| `users.last_login_at` 更新 | DB 查 `select last_login_at ...` 已刷新到本次时间 | ✅ |
| 写一行 `invocations`,`action=:password_login` | 审计表新增一行,behavior=Identity | ✅ |
| LV socket assigns 携带 `user_uri` | 后续导航 `/admin/sessions/...` 成功 mount | ✅ |

## 遗留 / bug

- 裸 handle `admin`(不填完整 URI)在共享 stack 表单上不解析 —— 小 UI 瑕疵,world seed 用邮箱登录不受影响。已在 scenarios/01 记录。

## 证据清单

- `evidence/scenario-00/s00-step1-login-form.png` — 未登录重定向到 /login
- `evidence/scenario-00/s00-step2-after-submit.png` — 提交后重定向
- `evidence/scenario-00/s00-step3-dashboard.png` — 登录态 + session 列表

## 交叉引用

- 设计场景:`docs/scenarios/02-password-login-admin`、`docs/scenarios/01-magic-link-login`
- 相关:登录/注册操作指引 `docs/guide/login-and-registration.zh_cn.md`
