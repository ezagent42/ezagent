# 场景 01(执行记录):操作员登录 world UI

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/02-password-login-admin](../scenarios/02-password-login-admin/scenario.zh_cn.md) · [scenarios/01-magic-link-login](../scenarios/01-magic-link-login/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~15:15(开测) |
| **环境** | 分支 `feat/product-gaps-f9-f12` · commit `913e2ba0` · server `http://world.localhost:10042`(PORT=10042 / vite 5173) |
| **前置 scenario** | 无(全流程第一条) |

## 前置条件(当次实际)

- PG:Windows 宿主 `127.0.0.1:5432`,DB `ezagent_pg_compat_dev`(`POSTGRES_*` 经 `bin/dev-pg` 注入)
- 已跑:`mix ecto.migrate`(already up)+ core seed + `mix run scripts/world_e2e_seed.exs`
- server:`mix phx.server` 后台运行,`/_health` → **200**;vite 5173 ready;`WorldLive` 已确认在浏览器 mount
- 凭据:`admin@ezagent.chat` / `worlddev`(world seed)
- ⚠️ 环境噪音:DB 携带前几轮遗留脏 agent 快照(`test-codex-3`、`r2-*`、`r3-*`),boot 时 crash-loop(codex 需 pypi 网络、PTY agent 缺目录)——纯噪音,未拖垮节点;但 agent picker / 列表里可能出现这些 stale 项,记录时注意区分本轮新建的。

## 角色

- **调用方**:匿名浏览器 session
- **目标**:`entity://system/user/admin`(Behavior `Ezagent.Behavior.Identity`,action `:password_login`)

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | agent-browser(observer)open `world.localhost:10042/login`,React 受控 input native-setter 填 `admin@ezagent.chat`/`worlddev`,`f.submit()` | 跳转 `/sessions`,**无 bounce 回 /login**;导航栏 Overview/Sessions/Identities/Admin/... 可见,确认 admin 身份;页面 "Rendered by React from LiveView state" | [s01-step0-observer-ready](./evidence/scenario-01/s01-step0-observer-ready.png) · [s01-step0-identities](./evidence/scenario-01/s01-step0-identities.png) | ✅ |
| 2 | zyli 自己浏览器 open `world.localhost:10042`,填 `admin@ezagent.chat`/`worlddev` 登录 | 成功进 **Sessions 列表页**,无卡 /login;右上 Admin / `workspace://system` 选择器 / Command palette;Session activity 表渲染 3 条(feishu-bing `Open`、两个 conv_* `Available`,均 External mirror);"New session" 按钮可见;无报错/白屏 | [s01-step2-zyli-login-success](./evidence/scenario-01/s01-step2-zyli-login-success.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| LV 重定向到主面板,session 认证为 admin | observer 登录后落 `/sessions`,admin 导航可见 | ✅ |
| 写一行 `invocations`,`action=:password_login` | 待 scenario-12 审计收口核对 | ⏳ |

## 环境基线(2026-06-25 开测时,observer 抓取 —— 用于区分本轮新建项)

- **Session(3,均 external-mirror)**:`session://system/default/feishu-bing`、`session://system/generic/conv_workspace_system_1b51c08c`、`...c4e49e36`
- **干净基线 agent**:`claude-bot`(cc)、`echo_default`(echo)
- **遗留 STALE agent**:`r2-echo`、`r2-echo-1`、`r2-echo-pty`、`r3-echo-pty-1`;疑似 stale:`e2e-test`(cc)、`test-echo-1`(echo)
- `test-codex-3` 未出现在 Identities→Agents(仅快照层,boot 时 crash-loop 噪音)
- → **zyli 本轮新建的 agent/session 将是上述清单之外的新条目**

## 遗留 / bug

- 无阻塞。`:password_login` 的 `invocations` 审计行留待 scenario-12 收口统一核对。
- 备注:裸 handle `admin` 不解析的旧 UI 瑕疵本轮未触发(world seed 用邮箱登录)。

## 证据清单

- `evidence/scenario-01/s01-step0-observer-ready.png` — observer 登录后 Sessions 主面板
- `evidence/scenario-01/s01-step0-identities.png` — observer 抓的 Identities 目录(环境基线)
- `evidence/scenario-01/s01-step2-zyli-login-success.png` — zyli 自己浏览器登录成功(Sessions 列表)

## 交叉引用

- 设计场景:`docs/scenarios/02-password-login-admin`、`01-magic-link-login`
- 操作指引:`docs/guide/login-and-registration.zh_cn.md`
