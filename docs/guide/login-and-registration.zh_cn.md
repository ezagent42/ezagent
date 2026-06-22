# 登录、注册与邮件（task #87）

改为「邮箱+密码」后，ezagent 的认证如何工作。

## 登录

- 登录页（`/login`）为**邮箱+密码**，原来的 handle/URI 登录已移除。
- 底层把邮箱解析成规范 entity URI（`Profile.by_email/1`），再经
  `Ezagent.Entity.authenticate/3`（`allow_user_tokens: false`，表单里输 API token
  当密码登不进）认证。规范身份仍是 entity URI。
- 只有 `users.email_verified == true` 才能登录。
- **magic-link** 免密登录（已有账号）走 `POST /login/magic`，**仅在配置了 SMTP 时**
  才在登录页显示。
- CLI / API 的 `Authorization: Bearer` 程序化认证不变。

## 注册

自助注册**默认关闭**。两个运行时开关（`Ezagent.AppSettings`）：

| key | 默认 | 含义 |
|-----|------|------|
| `registration_open` | `false` | 为 `false` 时不能自助注册，仅 admin 开通 |
| `registration_require_invite` | `false` | 开放后是否要求邀请码 |

打开：

```elixir
Ezagent.AppSettings.put("registration_open", true)
Ezagent.AppSettings.put("registration_require_invite", true)  # 可选
```

流程：`GET/POST /register`（邮箱+密码+显示名，要求时再加邀请码）→ 建未验证用户
（`email_verified: false`）→ 发确认信 → `GET /auth/confirm/:token` 置
`email_verified` → 登录。失败信息统一（防枚举）；注册按 IP/邮箱限流。

workspace 归属：
- **邀请码模式** — 进邀请码上写的 workspace。
- **开放、无码** — 分配一个 `<handle>-<随机后缀>` 的新 workspace。

## 邀请码（`mix ezagent.invite`）

```bash
mix ezagent.invite mint --workspace team-alpha [--role member] [--max-uses 20] [--expires-in-days 14]
mix ezagent.invite list [--workspace team-alpha]
mix ezagent.invite revoke <code>
```

邀请码携带**权威**目标 workspace、名额（`max_uses`）和可选有效期。消费防超发
（原子条件更新），并与建用户同一事务。撤销只挡后续使用，不影响已建账号。

## 找回密码

`GET /auth/reset`（请求）→ 邮件发 `:reset` 一次性链接 → `GET/POST
/auth/reset/:token`（设新密码，至少 8 位）→ 登录。请求响应统一；只有已存在账号才收信。

## 邮件通道

邮件用 Swoosh，adapter 在编译期固定：

- **dev / test** — `Swoosh.Adapters.Local`（内存；链接进日志/信箱预览），无需 SMTP。
- **prod** — `Swoosh.Adapters.SMTP`，relay 运行时由 admin 的 SMTP 设置
  （`Ezagent.AppSettings` 的 `"smtp_config"`）提供。

### Cloudflare Email Sending（我们的托管部署）

CF Email Sending 提供 SMTP 提交口，所以它只是一份 `smtp_config`，无需新 adapter：

| 字段 | 值 |
|------|----|
| host | `smtp.mx.cloudflare.net` |
| port | `465`（隐式 TLS） |
| username | 字面量 `api_token` |
| password | 带 **Email Sending: Edit** 权限的 CF API token |
| from_address | `…@ezagent.chat` |

前置（运维）：`ezagent.chat` 域名需在 CF 账号里 onboard 给 Email Sending，token 需带
*Email Sending: Edit*。token 是运行时机密——放 `AppSettings`，别进库。self-host 自配
自己的 SMTP。

## admin 引导

`entity://system/user/admin` 在启动时幂等修复
（`EzagentDomainIdentity.Application.repair_admin_user/0`）：缺密码就设、补 admin
profile 邮箱、置 `email_verified`、保留原有 caps——因此无论邮件是否配好，admin 都能用
邮箱+密码登录。

| 环境变量 | 默认 | 用途 |
|----------|------|------|
| `EZAGENT_ADMIN_PASSWORD` | 生成并打一次日志 | admin 密码（生产请设置） |
| `EZAGENT_ADMIN_EMAIL` | `admin@ezagent.chat` | admin 登录邮箱 |
