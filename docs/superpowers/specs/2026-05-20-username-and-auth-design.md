# Username & Auth — 设计 Spec

- **日期**:2026-05-20
- **状态**:LOCKED v1(brainstorm 闭环完成,待实现)
- **作者**:dev team(Allen 已于 v1 release / Phase 7 closeout 交接)
- **产出**:新 Decision Log 条目 #145–#148(实现期 append 到 `ARCHITECTURE.md` Appendix B)
- **范围**:一份合并 spec,内部分 M1/M2/M3 三个里程碑

> **执行拆分(2026-05-20 更新)**:本 spec 描述完整 feature(含 UI)。实施时发现
> `feat/phase-8-ide-shell-liveview` 正在重写整个 admin LiveView 层(已含
> `settings_live.ex` / `profile_live.ex` / `identities_live.ex`),与本 spec 的
> LiveView UI 部分几乎完全冲突。经 Allen 决定:**本轮只实施后端**(数据层 + 设置/邮件
> 后端 + magic-link 认证 controller —— 见 `docs/superpowers/plans/2026-05-20-username-and-auth.md`
> 的 M1–M3),**admin LiveView UI(显示名渲染 + SMTP 设置页)交给 Phase 8** ——
> 交接 prompt 见 `docs/superpowers/plans/2026-05-20-username-and-auth-UI-handoff.md`。
> 本 spec 下文的 §3.2 接入点、§4.3 `/admin/settings` LV 等 UI 描述是设计意图,由 Phase 8 落地。

---

## 0. 背景与目标

### 0.1 起因

当前 Ezagent 的身份/认证体系有三个痛点:

1. **显示难看**:LiveView 到处直接渲染裸 URI(`entity://user/admin`、`entity://agent/echo`),没有友好显示名。
2. **输入困难**:登录、建用户、routing rule 表单都要求手敲完整 `entity://...` URI。
3. **没有注册/登录流程**:用户只能由 admin 用 `mix ezagent.user.create` 或 `/admin/users` LV 预置;没有自助注册,没有邮件能力。

### 0.2 当前状态(勘察结论)

| 关注点 | 现状 |
|---|---|
| 显示名 / 昵称 / 全名 | 完全不存在。`users` 表只有 `uri / password_hash / caps_json / timestamps`。`Ezagent.Behavior.Identity` slice 只装 `caps`。ARCHITECTURE.md §6.3 概念上提过 `display_name`,从未实现。 |
| username 字段 | 无独立字段。`entity://user/<name>` 的 `<name>` 路径段是事实上的唯一 handle。 |
| 登录 | `EzagentWeb.SessionController`(纯 POST 表单,故意不用 LV)→ `Ezagent.Entity.authenticate/2`,按 URI host 分派:`user`→bcrypt 密码,`agent`→bearer token。 |
| 注册 | 无。 |
| 邮件 | 无 mailer。`ezagent_web` 无 `:swoosh` / `:gen_smtp` 依赖。 |
| 配置存储 | 无通用 settings 表。`config/runtime.exs` 只读启动期 env。 |
| at-rest 加密 | **无**。`ApiKeys` Behavior 把用户 API key **明文**存进 snapshot blob。静态密钥仅靠 SQLite 文件权限保护。 |
| 外部标识映射先例 | Feishu `UserBinding`(`open_id ↔ user_uri` 表)是"外部标识 ↔ 内部 URI"的成熟范式。 |

### 0.3 目标

- 引入 entity-agnostic 的 `display_name`,LV 显示友好化。
- 引入邮箱 magic-link 自助注册/登录,域名白名单准入。
- admin 用密码登录(break-glass),登录后在 UI 配置 SMTP。
- 不动 agent 认证(`entity_tokens` 路径保持原样)。

### 0.4 非目标(YAGNI — 见 §11)

at-rest 加密、事后 slug rename、agent device-code、email 即 URI、MFA/SSO/OAuth、运行中 session 三方合并。

---

## 1. 设计铁律

本设计必须遵守的不变式(违反 = 设计错误):

1. **URI 不可变 = 系统主键**。`entity://user/<slug>` 嵌进 caps(`granted_by`/`instance`)、routing rules、message `sender`、audit log、snapshot、Feishu binding。principal 创建后 URI 冻结。`email` / `display_name` 是挂在 URI 上的可变属性。**绝不让 email 变成 URI。**
2. **`display_name` 渲染必须便宜**。它在每条聊天消息渲染时被读 → LV mount/刷新时**批量**载入成员 profile,**绝不**每条消息一次 Kind `:call` 分派。
3. **认证边界走 controller 不走 LV**。`SessionController` moduledoc 的理由仍成立:凭据录入不应依赖 websocket。所有 magic-link 路由是纯 controller。
4. **不破坏 agent 认证**。`Ezagent.Entity.authenticate/2` 的 `agent` 分支与 `entity_tokens` 表完全不改。现有 `entity_tokens` 测试必须保持绿。
5. **认证不是 actor 消息**,不走 `Ezagent.Invocation.dispatch/1`。但**注册创建 principal** 时,User Kind 的 spawn 仍走 `Ezagent.SpawnRegistry`,默认 caps 仍由 `Ezagent.Entity.User.default_caps/0` 提供(invariant #6,Decision #133)。
6. **session 固定防御**:magic-link 消费成功后必须 `configure_session(renew: true)`,再塞 `current_entity_uri`,funnel 进与现有 `EzagentWeb.LiveAuth` / `RequireEntity` 完全相同的 session 槽。

---

## 2. 数据模型

### 2.1 三字段模型

"username" 概念拆成三个字段、三种角色:

| 字段 | 角色 | 唯一? | 可变? |
|---|---|---|---|
| URI slug(`entity://user/<slug>`) | 永久 handle | 是 | **仅注册完成步可改,principal 创建后冻结** |
| `display_name` | 友好显示名 | 否 | 随时可改 |
| `email` | 登录凭据 | 是 | v1 仅 admin 可改;用户自助改 = v1.x(需重新验证) |

### 2.2 新表 `entity_profiles`(entity-agnostic)

```
entity_profiles
  entity_uri    :string   PK         — entity://user/x 或 entity://agent/y
  display_name  :string   not null   — 自由文本,可变,可重复
  email         :string   nullable   — 仅 user;partial unique index where email is not null
  inserted_at / updated_at
```

- **为什么 entity-agnostic**:Q1 的例子含 agent(`entity://agent/echo`)。`display_name` 对 user 和 agent 都要;`email` 仅 user(agent 行 email 为 NULL)。一张表服务"友好显示"和"email→URI 解析"两个用途。
- **为什么不动 `users` 表**:`users` 已 seed 了 admin 行;少碰它少出迁移意外。`display_name`/`email` 单独成表,`users` 保持"provisioning config"语义不变。
- `email` 的 partial unique index 是 magic-link 的 email→URI 解析基石。

### 2.3 新表 `app_settings`(key-value)

```
app_settings
  key     :string  PK     — "smtp_config" | "registration_domains"
  value   :text            — JSON
  inserted_at / updated_at
```

- `smtp_config` value:`{"host","port","username","password","from_address","tls"}` JSON。
- `registration_domains` value:`["company.com", ...]` JSON list。
- **SMTP 密码明文存** —— 与 Ezagent 现状一致(`ApiKeys` 明文存 API key)。at-rest 加密是单独的全项目决策(§11)。
- 一张表同时装 SMTP 配置 + 域名白名单,避免为单一 blob 建表。

### 2.4 新表 `magic_link_tokens`

```
magic_link_tokens
  id            :id       PK
  email         :string   not null   — 申请链接的邮箱
  token_hash    :binary   not null   — SHA-256(raw token);raw 进 URL,不落盘
  expires_at    :utc_datetime_usec   — inserted_at + 15min
  consumed_at   :utc_datetime_usec nullable
  inserted_at
  index on token_hash, index on email
```

- **不复用 `entity_tokens`**:那是 bcrypt 长期 bearer token,语义不对。magic-link 需要单次性 + 短 TTL + 明文进 URL。
- **哈希用 SHA-256 不用 bcrypt**:token 是高熵随机串(`:crypto.strong_rand_bytes`),不需要 bcrypt 的慢哈希抗暴破;SHA-256 足够且查表快。
- **单次性**:消费时置 `consumed_at`(保留行用于审计/重放检测),已 `consumed_at` 的 token 拒绝。

### 2.5 `users` 表

**不变**。password-less 用户已被支持(`password_hash` 可空,seed 的 admin 行就是 NULL)。magic-link 注册的用户:`password_hash` 永远 NULL,`caps_json` 由 `Ezagent.Users.create/3` 自动 prepend `default_caps`。

---

## 3. M1 — 命名与显示

最小、独立、可先上的里程碑。

### 3.1 `Ezagent.EntityPresenter`

新 helper 模块,放 `ezagent_domain_identity`(与 `entity_profiles` schema 同 app,这样 `ezagent_web` 和 `ezagent_plugin_liveview` 都能用):

- `display(uri)` → 查 `entity_profiles.display_name`,缺失则回退到 URI 路径段(如 `admin`)。
- `display_many(uris)` → 一次查询批量解析,返回 `%{uri => name}` map。**用于聊天/成员列表渲染,满足铁律 #2。**

`entity_profiles` 的 Ecto schema 模块:`Ezagent.Entity.Profile`(`ezagent_domain_identity`,与 `Ezagent.Entity.Token` 并列)。

### 3.2 接入点

| 文件 | 改动 |
|---|---|
| `admin/member_panel.ex` | 成员表显示 `display_name`,URI 作为次要小字 / title 属性 |
| `entities_live.ex` | 表格加 "name" 列 |
| `users_live.ex` | 列表显示 display_name;建用户表单接受裸 handle |
| `admin/chat_window.ex` | @mention `<option>` 的 label 用 `display(uri)`,value 仍是 URI |
| `admin_live.ex` | @mention 下拉按 `display_name` 子串过滤 |

### 3.3 表单 handle 补全

`users_live.ex` 建用户表单 + 登录凭据表单接受裸 handle(`allen`),提交时自动补 `entity://user/` 前缀;已是完整 URI 则原样。

### 3.4 display_name 的写入路径

- 注册流程 `/register/complete` 写入(见 §5)。
- `/admin/users` 加一个"改显示名"输入(admin 可改任意 entity 的 display_name)。
- agent 的 display_name:M1 阶段由 `mix` task 或 `/admin/users` 风格界面设置;无 profile 行时回退 URI 路径段,不阻塞。

---

## 4. M2 — 配置存储与邮件

### 4.1 `app_settings` 访问层

新模块 `Ezagent.AppSettings`(放 `ezagent_domain_identity` 或新建小模块):

- `get(key)` → decoded JSON term 或 `nil`。
- `put(key, term)` → upsert。
- `smtp_configured?/0` → `get("smtp_config")` 非空且字段完整。

### 4.2 Mailer

- `ezagent_web/mix.exs` 加 `{:swoosh, "~> 1.16"}` + `{:gen_smtp, "~> 1.2"}`。
- 新模块 `EzagentWeb.Mailer`(`use Swoosh.Mailer`)。
- SMTP adapter 配置**运行时**从 `app_settings` 读 —— 不在 `config/*.exs` 写死。`deliver` 时把 `smtp_config` 转成 Swoosh SMTP adapter 的 per-deliver 配置,或在 settings 变更时 `Application.put_env`。

### 4.3 `/admin/settings` LV

- 新 LV,admin-cap 门禁(读 `current_entity_uri`,要求 admin 的 wildcard cap 或显式 settings cap)。
- SMTP 表单(host/port/username/password/from/tls)。
- "发送测试邮件" 按钮 → 用当前表单值试发到 admin 邮箱,回报成功/失败。
- 域名白名单编辑器(增删 `registration_domains`)。
- 密码字段显示用 mask(参考 `ApiKeys.mask/1`),不回显明文。

### 4.4 at-rest 加密

**已知遗留风险,本 spec 不解决**。SMTP 密码明文存,与 `ApiKeys` 现状一致。spec §11 记录为单独的未来 Decision(引入 Cloak,统一加密 `ApiKeys` + SMTP 密码)。

---

## 5. M3 — 认证流程

### 5.1 路由表

```
GET    /login              邮箱输入页(人类主路径)
POST   /login              查白名单 → 发 magic link → "查收邮件"页
GET    /login/credentials  现有的 entity-URI + 密码/token 表单(admin break-glass + agent/CLI)
POST   /login/credentials  现有 SessionController.create 逻辑
GET    /auth/magic/:token  消费 token → resolve-or-create → session → /admin
GET    /register/complete  首次注册:handle + display_name 表单
POST   /register/complete  校验 handle 唯一 → 创建 principal → renew session → /admin
DELETE /logout             不变
```

现有 `SessionController` 拆分:`/login` 主路径改邮箱;`/login/credentials` 承接旧的 URI+密码/token 表单。

### 5.2 注册 2 步流程

```
新用户:
  GET  /login             → 输入邮箱
  POST /login             → 查域名白名单 → 发 magic link → "查收邮件"页
  GET  /auth/magic/:token → token 有效 + 该邮箱还不是 principal
                          → 消费 token → session 存 pending_registration_email
                          → 跳转 /register/complete
  GET  /register/complete → 表单:handle(预填派生 slug,可改)+ display_name(预填邮箱本地段 humanize)
  POST /register/complete → 校验 handle 唯一 → 创建 principal → renew session
                          → 塞 current_entity_uri → /admin

老用户:
  GET  /auth/magic/:token → 该邮箱已是 principal → 消费 token → renew session
                          → 塞 current_entity_uri → /admin(不出现 /register/complete)
```

### 5.3 slug 派生 / 编辑 / 冻结

- **派生**:email local-part → slug。`allen.woods@x.com` → `allen-woods`(非法 URI 字符替换为 `-`,转小写)。
- **编辑**:`/register/complete` 表单里用户可改。此刻 URI 尚未提交,没有任何东西引用它 → 改 + 查重零风险。
- **冻结**:`POST /register/complete` 创建 principal 后,URI = `entity://user/<slug>` 永久冻结。之后可变的是 `display_name`。
- **冲突**:`POST /register/complete` 提交时校验 `users.uri` 唯一。撞了 → 重渲染表单 + 错误提示 + 自动建议一个空闲替代(如 `allen-woods-2`)。

### 5.4 resolve-or-create

`GET /auth/magic/:token` 消费成功后:

1. 查 `entity_profiles` by `email`。
2. 命中 → 老用户:`ensure_spawned` User Kind(参考 `Ezagent.Entity.authenticate` 的 `ensure_spawned/1`)→ session。
3. 未命中 → 新用户:置 `pending_registration_email` → `/register/complete`。
4. `POST /register/complete` 创建:
   - `Ezagent.Users.create(uri, nil, [])` —— password 传 `nil`,`default_caps` 自动 prepend。
   - 插入 `entity_profiles` 行(`entity_uri`, `display_name`, `email`)。
   - spawn User Kind(`Ezagent.SpawnRegistry.spawn(uri)`)。
   - `configure_session(renew: true)` + `put_session(:current_entity_uri, uri_str)`。

### 5.5 域名白名单

- 仅对**新注册**生效。已存在的 principal 即使其域名后来被移出白名单,仍能登录(移除域名不应锁死老用户)。
- `POST /login` 逻辑:先查 `entity_profiles` by email。命中(老用户)→ 无条件发链接。未命中(新注册)→ 查 `registration_domains`,域名不在 → 不发。
- **防枚举**:`POST /login` 对所有情况返回同一句通用文案("如果该邮箱可注册或已注册,我们已发送登录链接")。是否真的发信由内部决定。攻击者无法从响应区分"邮箱已注册" vs "域名不允许"。

### 5.6 限流

- `POST /login` 按 **email** + **IP** 限流(防邮件轰炸 / SMTP 配额烧毁)。
- Ezagent 无限流设施 → 新增轻量 ETS 窗口计数器(不引入新依赖)。
- 阈值(实现期可调):每 email ≤ 3 次/15min;每 IP ≤ 10 次/小时。
- 超限 → 仍返回 §5.5 的通用文案(不泄露限流状态),内部不发信。

### 5.7 admin break-glass

- admin 永久保留 `/login/credentials` 的 `entity://user/admin` + 密码登录。SMTP 挂了也能进。
- 系统**至少保留一个非邮箱登录账号**是硬约束。

### 5.8 SMTP 未配置时

- `smtp_configured?/0` 为 false 时,`/login` 邮箱路径显示 "邮箱登录暂未启用,请联系管理员",`POST /login` 直接拒绝。
- `/login/credentials` 不受影响 —— admin 始终能进去配 SMTP。

---

## 6. Q3 — Agent 认证(不动)

- `Ezagent.Entity.authenticate/2` 的 `agent` 分支、`entity_tokens` 表、`Ezagent.Entity.Token` 模块**完全不改**。
- agent 仍走 `/login/credentials` 的 token 路径(或 CLI / 程序化)。
- 未来外部 agent 的 device-code:在 `Entity.authenticate` 加第三条路径,agent 仍以 `entity_tokens` 为最终凭据。`Entity.authenticate` 保持单一认证漏斗。本 spec 不实现。

---

## 7. 错误处理与边界情况

| 情况 | 处理 |
|---|---|
| token 过期 | 拒绝,"链接已过期,请重新申请" |
| token 已消费 | 拒绝,"链接已使用",记 telemetry(可能的重放) |
| token 伪造 / 查不到 | 拒绝,"无效链接" |
| 域名不在白名单(新注册) | `POST /login` 返回通用文案,内部不发信(§5.5) |
| `/register/complete` slug 冲突 | 重渲染表单 + 错误 + 自动建议替代 slug |
| `/register/complete` 时 email 已被另一并发注册占用 | 检测到 email 已是 principal → 转为登录路径,不报错 |
| SMTP 未配置 | `/login` 邮箱路径禁用(§5.8) |
| SMTP 发信失败 | `POST /login` 仍回通用文案(不泄露),记 telemetry + 错误日志;"发送测试邮件" 按钮如实回报 |
| 限流触发 | 返回通用文案,内部不发信(§5.6) |
| `pending_registration_email` session 丢失(用户中途清 cookie) | `/register/complete` 无 pending email → 重定向 `/login` |
| 老用户域名已被移出白名单 | 仍能登录(§5.5) |

---

## 8. 测试策略

遵循 esr-developer skill 的不变式测试范式(production setup + production code path + 可观测 side-effect 断言)。

### 8.1 不变式测试(新增)

- `magic_link_token_single_use_test.exs` —— 同一 token 消费两次,第二次失败。
- `magic_link_token_expiry_test.exs` —— 过期 token 被拒。
- `registration_domain_allowlist_test.exs` —— 白名单外域名的新邮箱不发信;白名单内发信;老用户无视白名单。
- `session_renew_on_magic_login_test.exs` —— magic-link 消费后 session id 变更(防固定)。
- `agent_auth_untouched_test.exs` —— 现有 `entity_tokens` / `Entity.authenticate` agent 路径测试全绿(回归门)。

### 8.2 单元 / 集成测试

- `EntityPresenter.display/1` + `display_many/1`:命中 / 回退。
- `Ezagent.AppSettings`:get/put/smtp_configured?。
- slug 派生 + 冲突建议。
- resolve-or-create 两条分支。
- 限流计数器窗口。

### 8.3 e2e flow

1. admin 用密码登录 `/login/credentials` → 配 SMTP → 配域名白名单。
2. 白名单内新邮箱 → `/login` → 收链接 → `/register/complete` 选 handle → 进 `/admin`。
3. 同一邮箱再次 `/login` → 收链接 → 直接进 `/admin`(老用户路径,无 `/register/complete`)。
4. 白名单外邮箱 → `/login` → 通用文案,实际不发信。
5. 聊天界面成员/消息显示 display_name 而非裸 URI。

### 8.4 性能门

- 聊天渲染路径:断言一个 N 成员的 session 渲染 M 条消息时,profile 查询次数为 O(1)(批量),不是 O(M)。可通过 `Ecto` 查询计数 / telemetry 断言。

---

## 9. 里程碑分解

| 里程碑 | 内容 | 依赖 | 可独立上线 |
|---|---|---|---|
| **M1** | `entity_profiles` 表 + `EntityPresenter` + LV 显示接入 + 表单 handle 补全 | 无 | ✅ |
| **M2** | `app_settings` 表 + `Ezagent.AppSettings` + Swoosh/gen_smtp + `Mailer` + `/admin/settings` LV | M1(profile 表可独立,但 settings LV 复用显示约定) | ✅ |
| **M3** | `magic_link_tokens` 表 + `/login` 邮箱流 + `/login/credentials` 拆分 + resolve-or-create + 域名白名单 + 限流 + 2 步注册 | M1(写 `entity_profiles`)+ M2(发信) | ❌(依赖 M1+M2) |

合并为一份 spec,但实现按 M1→M2→M3 推进,PR 仍可分批评审,M1/M2 各自可先上。

---

## 10. 新 Decision Log 条目(拟稿,实现期 append 到 ARCHITECTURE.md Appendix B)

- **#145 — `entity_profiles` 表 + URI 即不可变身份**:URI 是全系统主键,`display_name`/`email` 是挂在其上的可变属性。entity-agnostic 表覆盖 user + agent。WHY:URL 嵌进 caps/rules/audit,改 URI = 全表迁移。DRIFT DEFENSE:principal 创建后无任何代码路径 mutate `users.uri` / `entity_profiles.entity_uri`。
- **#146 — magic-link 认证模型**:`magic_link_tokens` 表,SHA-256 哈希、单次性、15min TTL。与 `entity_tokens`(bcrypt 长期 bearer)分离。WHY:语义不同。
- **#147 — `app_settings` key-value 配置存储**:运行时 UI 驱动的配置(SMTP + 域名白名单)。WHY:`.env` 文件与"admin 在 LV 配置"冲突。NOTE:SMTP 密码明文存,at-rest 加密留作单独决策。
- **#148 — 域名白名单注册策略 + 防枚举**:新注册查白名单,老用户登录无视白名单;`POST /login` 通用文案防账号枚举。

---

## 11. 范围外(YAGNI)

- **at-rest 加密**:`ApiKeys` 明文存 API key 是现状;SMTP 密码同等对待。引入 Cloak 统一加密是单独的全项目决策。
- **事后 slug rename**:做成 admin-only 迁移型 `mix` task(正确重写所有引用)。v1 里换名 = 改 `display_name`。
- **用户自助改 email**:v1 仅 admin 可改 `entity_profiles.email`。自助改(需重新验证新邮箱、确认旧邮箱)= v1.x。
- **agent device-code**:Q3 明确延后。
- **email 即 URI**:违反铁律 #1,永不。
- **MFA / SSO / OAuth**:v1 不做。
- **运行中 session 三方合并**:与 Decision #141 一致,范围外。

---

## 12. 实现期待定的小决策

以下留给实现期(`writing-plans` / IMPL 决策),不阻塞本 spec:

- Swoosh / gen_smtp 的精确版本号。
- 限流阈值的最终数值。
- `Ezagent.AppSettings` 模块的归属 app(`ezagent_domain_identity` vs 新建)。
- `/admin/settings` 的 admin-cap 判定:复用 admin wildcard cap,还是新增显式 `settings` cap。
- `/register/complete` 是否值得做成 LV 以支持实时查重(当前 spec:纯 controller + 提交时校验)。
- 新 Decision 与 `CLAUDE.md` "不要修改 ARCHITECTURE.md" 的张力 —— Allen 已交接,esr-developer skill 明确 Decision Log 由 dev team append;实现期确认。
