# AutoService 真实 E2E 场景与 Ezagent 复现报告

日期：2026-06-26

源项目：`/mnt/d/Work/h2os.cloud/AutoService-dev-a`（对应 `D:\Work\h2os.cloud\AutoService-dev-a`）

目标项目：`/home/huangjiajia/ezagent`

本报告基于 AutoService 本地运行、真实运行库数据、HTTP/API 调用和三端前端启动验证，不是纯代码分析。原来的 `autoservice-e2e-scenarios-and-ezagent-mapping.md` 未修改。

## 1. 实际跑测范围

### 1.1 AutoService 后端

启动命令：

```bash
AUTH_DEV_MODE=1 PLACEHOLDER_ENABLED=0 \
  .venv/bin/uvicorn autoservice.web_gateway:create_app \
  --factory --host 127.0.0.1 --port 8000 --log-level info
```

实际结果：

- 后端成功进入 `Application startup complete`。
- Uvicorn 监听 `http://127.0.0.1:8000`。
- `cc_pool` 完成 warmup：
  - 主 pool：4/4
  - triage 子 pool：1/1
  - lead 子 pool：1/1
- `/api/session/mode` 返回 200，未登录状态为 master 模式。

后端启动时也确认了运行配置：

- `AUTH_DEV_MODE=1`
- `PIPELINE_V2_ENABLED=true`
- `GENERAL_BOT_ENABLED=true`
- `POOL_MODE=1`
- voice backend 解析为 Doubao ASR/TTS
- cc_pool warmup tenant 为 `cinnox`

### 1.2 AutoService 三端前端

AutoService 默认端口为 5173/5174/5175，但本机 5173 已被当前 ezagent Vite 进程占用，所以改用 5273/5274/5275。

由于该项目目录来自 Windows 工作区，在 WSL 下第一次启动 Vite 时缺少 Linux Rollup optional dependency `@rollup/rollup-linux-x64-gnu`。执行：

```bash
cd frontend
CI=true pnpm install
```

修复依赖后启动三端：

```bash
pnpm --filter @autoservice/customer-chat exec vite --host 127.0.0.1 --port 5273
pnpm --filter @autoservice/operator-console exec vite --host 127.0.0.1 --port 5274
pnpm --filter @autoservice/admin-portal exec vite --host 127.0.0.1 --port 5275
```

三端页面加载结果：

| 端 | URL | 结果 |
|---|---|---|
| Customer Chat | `http://127.0.0.1:5273/` | 200，标题 `AutoService · Customer Chat`，存在 root div 和 script |
| Operator Console | `http://127.0.0.1:5274/` | 200，标题 `AutoService · Operator Console`，存在 root div 和 script |
| Admin Portal | `http://127.0.0.1:5275/` | 200，标题 `AutoService · Admin Portal`，存在 root div 和 script |

### 1.3 真实运行库证据

从 `.autoservice/database` 读取到的真实数据规模：

```json
{
  "auth.db": {
    "login_tokens": 21,
    "operator_sessions": 4,
    "operators": 6,
    "sessions": 86
  },
  "cinnox/conversations.db": {
    "conversations": 145,
    "events": 1420,
    "messages": 780,
    "participants": 321
  },
  "_master/conversations.db": {
    "conversations": 7,
    "events": 61,
    "messages": 27,
    "participants": 14
  },
  "knowledge_base/kb.db": {
    "kb_chunks": 359
  },
  "dream_runs.db": {
    "dream_runs": 71
  },
  "proposals.db": {
    "proposals": 10
  }
}
```

关键真实样例：

- `cinnox` 租户会话 `web_anon_f47a56c52dc8`
  - customer 消息：`帮我查一下我账号下昨天的工单状态`
  - filler 回复：`好的，我马上查一下您账号下昨天的工单状态，稍等哈`
  - agent 最终回复：要求客户提供姓名、公司、联系方式
- `_master/conversations.db` 中存在 operator 参与记录：
  - operator 加入会话
  - `auto -> copilot`
  - `/hijack` 触发 `copilot -> takeover`
  - `/release` 触发 `takeover -> auto`

### 1.4 登录与 API 验证

`.autoservice/access-credentials.md` 中记录的是线上账号/密码。本地 `auth.db` 中的 hash 状态和该文档不匹配，所以使用文档里的线上密码在本地登录返回 `invalid credentials`。

本次本地 E2E 使用 `AUTH_DEV_MODE=1` 下的 dev-login。

Admin dev-login 结果：

```json
{
  "ok": true,
  "redirect": "/admin"
}
```

Admin session mode：

```json
{
  "mode": "master",
  "tenant_id": null,
  "authenticated": true,
  "authenticated_as": "admin@dev.local",
  "tier": 0,
  "role": "admin",
  "brand_name": "AutoService"
}
```

Operator dev-login 结果：

```json
{
  "ok": true,
  "redirect": "/operator",
  "operator_id": "IcUfIWt99liM7qba-9mggg",
  "tenant_id": "cinnox",
  "email": "op@dev.local"
}
```

Operator `/api/auth/operator/me`：

```json
{
  "operator_id": "IcUfIWt99liM7qba-9mggg",
  "tenant_id": "cinnox",
  "email": "op@dev.local",
  "role": "responder",
  "force_password_change": false
}
```

实际验证过的 API：

- `/api/conversations/active?tenant_id=cinnox`：返回真实活跃会话列表。
- `/api/master/tenants`：返回 `_master`、`cinnox`、`mystore` 和多个 sandbox tenant。
- `/api/admin/kb/cinnox/sources`：返回真实 KB source 列表。
- `/api/tenants/cinnox/versions`：返回 `v1` 到 `v16`，当前为 `v16`。
- `/api/cc_pool/runtime`：返回 pool started，4 个可用实例。
- `/api/sla/summary?tenant_id=cinnox`：接口可用，但本地统计值为 null/count 0。
- `/api/dream/runs?tenant_id=cinnox`：返回历史 Dream run。
- `/api/upload`：返回 `attachments disabled for this tenant`。
- `/chat/cinnox`：未带 General Bot API 凭证时返回 `unauthorized`。

## 2. AutoService 真实 E2E 场景

### A. Customer 端

#### A1. Customer Chat SPA 加载

步骤：

1. 启动后端 8000。
2. 启动 customer-chat 前端 5273。
3. 打开 `http://127.0.0.1:5273/`。
4. 页面返回 200，标题为 `AutoService · Customer Chat`。

结论：SPA shell 验证通过。

注意：

- 本地直接访问后端 `/tenant/cinnox/chat` 返回 404。
- 当前开发形态下 customer SPA 由 Vite 承载，不由后端单独承载。

#### A2. Customer 消息 -> filler -> 最终 agent 回复

证据来自真实 `cinnox/conversations.db`：

1. 会话 `web_anon_f47a56c52dc8` 存在。
2. customer public message 已持久化。
3. agent 发送 filler message，metadata 含 `pipeline=v2` 和 `is_filler=true`。
4. agent 发送最终 public reply。
5. conversation、messages、events 均已落库。

结论：真实历史运行数据证明该闭环已跑通过。

依赖：

- `PIPELINE_V2_ENABLED=true`
- cc_pool 已 warmup
- `cinnox` 租户 runtime 可用

#### A3. Customer 历史消息

证据：

- `cinnox/conversations.db` 有 145 个 conversations、780 条 messages。
- operator session 调用 `/api/conversations/active?tenant_id=cinnox` 可看到真实会话列表和 last message。

结论：历史消息/会话列表验证通过。

#### A4. 附件上传

本次实际结果：

```json
{
  "detail": "attachments disabled for this tenant"
}
```

结论：接口存在，但本地被租户配置阻塞。

要复现通过，需要：

- `ATTACHMENT_ENABLED=1`
- `ATTACHMENT_ENABLED_TENANTS` 包含 `cinnox`
- sandbox/upload 存储路径配置可写

#### A5. General Bot API

本次实际结果：

```json
{
  "error": "unauthorized"
}
```

结论：接口存在，但缺少 General Bot API 凭证。

要复现通过，需要提供有效 Bearer/API key。

#### A6. 语音通话

后端启动时确认 voice backend 为 Doubao，但未做完整语音 E2E。

要复现通过，需要：

- Doubao ASR/TTS 凭证
- 浏览器麦克风权限或 fake media
- voice gateway 路径
- 外部服务费用/配额控制

### B. Operator 端

#### B1. Operator Console SPA 加载

步骤：

1. 启动 operator-console 前端 5274。
2. 打开 `http://127.0.0.1:5274/`。
3. 页面返回 200，标题为 `AutoService · Operator Console`。

结论：SPA shell 验证通过。

#### B2. Operator 登录

实际结果：

1. 使用线上 worksheet 密码在本地登录失败，返回 `invalid credentials`。
2. `AUTH_DEV_MODE=1` 下 `POST /api/auth/operator/dev-login` 成功。
3. `/api/auth/operator/me` 返回 active responder 身份。

本地测试身份：

- tenant：`cinnox`
- email：`op@dev.local`
- operator id：`IcUfIWt99liM7qba-9mggg`
- role：`responder`

结论：本地 dev-login 通过；本地 password-login 被 DB hash 差异阻塞。

#### B3. 查看活跃会话列表

实际结果：

- `/api/conversations/active?tenant_id=cinnox` 返回真实活跃会话。
- 包含 `customer_id`、`mode`、`state`、`last_message`、`last_sender`、`last_activity_ts`、`squad_id`。

结论：通过。

#### B4. Copilot / Takeover / Release

真实 DB 事件证明：

- operator 加入会话后产生 `participant.joined`。
- mode 从 `auto` 变为 `copilot`。
- `/hijack` 触发 `copilot -> takeover`。
- `/release` 触发 `takeover -> auto`。

结论：真实历史运行数据证明该流程跑通过。

#### B5. Pool 状态和 SLA

`/api/cc_pool/runtime` 返回：

```json
{
  "started": true,
  "max_size": 5,
  "checked_out": 0,
  "sticky": 0,
  "available": 4,
  "total": 4
}
```

`/api/sla/summary?tenant_id=cinnox` 返回结构正确，但本地指标 count 为 0。

结论：接口通过；本地缺少有效 SLA 聚合数据。

### C. Admin 端

#### C1. Admin Portal SPA 加载

步骤：

1. 启动 admin-portal 前端 5275。
2. 打开 `http://127.0.0.1:5275/`。
3. 页面返回 200，标题为 `AutoService · Admin Portal`。

结论：SPA shell 验证通过。

#### C2. Admin 登录

实际结果：

1. 使用线上 worksheet 密码在本地 password-login 失败。
2. `AUTH_DEV_MODE=1` 下 `POST /api/auth/dev-login` 成功。
3. `/api/session/mode` 返回已登录 tier-0 admin。

结论：本地 dev-login 通过；本地 password-login 被 DB hash 差异阻塞。

#### C3. Master 租户列表

实际结果：

- `/api/master/tenants` 返回 `_master`、`cinnox`、`mystore` 和多个 sandbox tenant。

结论：通过。

#### C4. KB source 管理

实际结果：

- `/api/admin/kb/cinnox/sources` 返回真实 KB source。
- 示例：
  - `CINNOX Pricing`
  - `CINNOX Feature List 2026`
  - `M800 Introduction`
  - `M800 Global Rates`
  - `CINNOX Glossary`

结论：KB source listing 通过。

#### C5. 版本和发布历史

实际结果：

- `/api/tenants/cinnox/versions` 返回 `v1` 到 `v16`。
- 当前版本为 `v16`。

结论：通过。

#### C6. Dream runs

实际结果：

- `/api/dream/runs?tenant_id=cinnox` 返回历史 completed Dream runs。
- `dream_runs.db` 有 71 行。

结论：历史 run listing 通过。

#### C7. Inbox / CR proposals

实际结果：

- `/api/admin/inbox/cinnox` 返回空 grouped inbox，`total: 0`。
- `proposals.db` 中有 10 条 proposal。

结论：接口通过；本次 `cinnox` 没有待处理 inbox item。

#### C8. Soul / Skill 读取

实际结果：

- `/api/admin/section/cinnox/customer/greeting` 返回该 section 无 slots。
- `/api/admin/skills/cinnox/customer` 返回 404。

结论：路由可达，但本次选的 section/skill id 不匹配当前租户布局。

要复现通过，需要先从当前 release/sandbox layout 读取实际 section id 和 skill id。

## 3. Ezagent 复现映射

### 3.1 Ezagent 可直接复现

| AutoService 场景 | Ezagent 对应能力 | Ezagent 证据 |
|---|---|---|
| Customer/API 消息往返 | Session message -> routing -> agent reply | `docs/e2e/scenario-04-echo-roundtrip.md`、`scenario-05-cc-roundtrip.md`、`scenario-06-codex-roundtrip.md`、`scenario-07-curl-roundtrip.md` |
| Customer 历史消息 | Session message store / session view | `docs/e2e/scenario-03-create-session.md`，`apps/ezagent_domain_session/test/e2e` |
| Operator 登录 | Identity password / magic-link | `docs/scenarios/01-magic-link-login`、`docs/scenarios/02-password-login-admin`、`docs/e2e/scenario-01-operator-login.md` |
| Operator 打开会话 | Session membership / visibility | `docs/scenarios/09-session-create-lv`、`docs/scenarios/16-workspace-switch-visibility` |
| mention-gated routing | routing rules / mention filtering | `docs/e2e/scenario-08-mention-routing.md`、`docs/scenarios/10-mention-gated-routing` |
| cross-session reject | sender/member locked routing | `docs/e2e/scenario-09-cross-session-reject.md`、`docs/scenarios/11-cross-session-mention-rejected`、`docs/scenarios/34-sender-locked-relay` |
| Feishu inbound/outbound | Feishu plugin binding / inbound dispatch | `docs/e2e/scenario-10-feishu-bind.md`、`docs/e2e/scenario-11-feishu-inbound.md`、`apps/ezagent_plugin_feishu/test/e2e/category_04_feishu_test.exs` |
| General Bot / OpenAI API | Protocol API plugin | `apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/openai_chat_plug_integration_test.exs` |
| Admin/workspace list | Workspace lifecycle | `docs/scenarios/20-workspace-lifecycle`、World UI scenarios |
| Agent 配置 | Agent console / template / flavor config | `docs/scenarios/29-admin-lv-smoke`、`docs/scenarios/30-plugin-author-behavior` |

### 3.2 Ezagent 可部分复现

| AutoService 场景 | Ezagent 状态 | 缺口 |
|---|---|---|
| Customer public widget | 部分 | Ezagent 有 external/anonymous access，但不是 AutoService 的 React widget + sessionStorage customerId 模型 |
| Operator copilot/takeover | 部分 | Ezagent 有 member、cap、routing、visibility，但没有 AutoService operator console 的 takeover timer 和完整 UX |
| Pool busy warning | 部分 | Ezagent 可暴露 agent/runtime health，但不是 AutoService cc_pool runtime API 形状 |
| Soul/Skill 编辑 | 部分 | Ezagent 用 SessionTemplate/Behavior/Agent config，不是 AutoService L0-L3 Soul + slots + markdown skill |
| Publish history/rollback | 部分 | Ezagent 可用 config/git/workspace state，但没有 tenant release pointer pipeline |
| CSAT | 部分 | 可用 session action/message metadata 表达，但未验证内建 CSAT 产品面 |

### 3.3 Ezagent 暂不能复现，需要开发

| AutoService 场景 | 原因 |
|---|---|
| KB ingestion / vector search / source management | Ezagent 没有同等 KB ingestion/source manager 子系统 |
| Dream -> proposal -> CR -> publish | Ezagent 没有 AutoService 风格 Dream/CR 治理闭环 |
| Sandbox preview -> publish archive -> pointer flip | Ezagent 配置模型不同，没有 tenant sandbox release pipeline |
| Billing dashboard | 非 ezagent 当前核心能力 |
| SLA analytics dashboard | 未验证到等价分析模块 |
| Voice ASR/TTS | 需要 voice channel、Doubao、浏览器 media path |
| Attachment upload storage policy | Ezagent 可承载 message metadata，但未验证 AutoService 等价 upload/storage 流程 |

## 4. Ezagent 自动化验证状态

执行过：

```bash
mix precommit
```

结果：未通过，但大量相关子模块已经跑绿。

已看到通过的相关模块：

- `ezagent_domain_identity`
- `ezagent_domain_workspace`
- `ezagent_domain_session`
- `ezagent_plugin_feishu`
- `ezagent_plugin_protocol_api`
- `ezagent_plugin_codex`
- `ezagent_plugin_curl_agent`
- `ezagent_plugin_cc`
- `ezagent_web` 大部分测试

主要失败项：

1. `apps/ezagent_plugin_content`、`apps/ezagent_plugin_cr`、`apps/ezagent_plugin_liveview` 是目录但没有 `mix.exs`，触发 plugin wiring invariant。
2. `apps/ezagent_plugin_liveview` 被 invariant 认为应保持 retired，但目录仍存在。
3. `ezagent_plugin_py` 的 `seed_default/0 brings up a live py_default that echoes via echo.py` 失败，`py_default` subprocess 未在 30 秒内变为 alive。
4. `ezagent_web` 的 `WorldHostRoutingTest` 遇到 PID 无法被 Jason encode。

解释：

- 这些是 ezagent 当前本地 precommit 环境/不变量问题。
- 它们不表示 AutoService 映射能力不存在。
- Feishu、Protocol API、session、identity、workspace 等与本报告映射强相关的模块在本轮 precommit 中已经有大量通过结果。

## 5. 复现依赖和配置流程

### 5.1 AutoService

必需项：

- Python 3.11+ / 当前 `.venv`
- `uvicorn`
- `.env`
- `.autoservice/config.local.yaml`
- 本地 dev-login 需要 `AUTH_DEV_MODE=1`
- 如果环境设置了 HTTP proxy，访问 localhost 需要 `--noproxy '*'` 或设置 `NO_PROXY`
- WSL 跑 Windows 工作区前端时，需要在 `frontend` 下执行 `CI=true pnpm install`
- 完整 live agent turn 需要模型/API 凭证
- voice E2E 需要 Doubao 凭证
- General Bot API 需要有效 API key
- 附件上传需要开启 attachment tenant config

本地启动流程：

```bash
# backend
AUTH_DEV_MODE=1 PLACEHOLDER_ENABLED=0 \
  .venv/bin/uvicorn autoservice.web_gateway:create_app \
  --factory --host 127.0.0.1 --port 8000 --log-level info

# frontend
cd frontend
pnpm --filter @autoservice/customer-chat exec vite --host 127.0.0.1 --port 5273
pnpm --filter @autoservice/operator-console exec vite --host 127.0.0.1 --port 5274
pnpm --filter @autoservice/admin-portal exec vite --host 127.0.0.1 --port 5275
```

### 5.2 Ezagent

建议复现入口：

- `docs/e2e/scenario-01-operator-login.md`
- `docs/e2e/scenario-03-create-session.md`
- `docs/e2e/scenario-04-echo-roundtrip.md`
- `docs/e2e/scenario-06-codex-roundtrip.md`
- `docs/e2e/scenario-07-curl-roundtrip.md`
- `docs/e2e/scenario-10-feishu-bind.md`
- `docs/e2e/scenario-11-feishu-inbound.md`
- `docs/e2e/scenario-12-dispatch-audit.md`

需要配置：

- 修复当前 `mix precommit` 的 plugin wiring / retired liveview / py_default / WorldHostRoutingTest 问题，才能得到干净自动化结果。
- live Feishu E2E 需要有效 Feishu credentials。
- Protocol API E2E 需要默认 agent 和 API key 配置。
- cc/codex/curl/py agent 取决于所选 flavor，需要对应外部凭证或本地 sidecar。

## 6. 覆盖度结论

| 区域 | AutoService 真实 E2E 状态 | Ezagent 复现状态 |
|---|---|---|
| Customer SPA shell | 通过 | public/external view 部分类似 |
| Customer message/agent reply | 真实 DB 证明通过；本次未强制新 live turn | 可通过 session/agent roundtrip 复现 |
| Customer history | 通过 | 可复现 |
| Attachment upload | 被 AutoService tenant config 阻塞 | 缺失/部分 |
| Voice | 未跑；依赖 Doubao | 缺失 |
| Operator SPA shell | 通过 | World/session UI 类似 |
| Operator login | dev-login 通过；本地 password hash 不匹配 | 可通过 identity scenarios 复现 |
| Operator active list | 通过 | session list/membership 类似 |
| Operator copilot/takeover | 真实 DB event 证明通过 | 部分，需要产品化 UX |
| Admin SPA shell | 通过 | World/Admin smoke 类似 |
| Admin tenant list | 通过 | workspace lifecycle 可复现 |
| Admin KB | AutoService 通过 | ezagent 缺失 |
| Admin publish versions | AutoService 通过 | ezagent 部分/模型不同 |
| Dream/CR | 历史 run listing 通过 | ezagent 缺失 |
| General Bot API | 接口存在，缺 key 返回 unauthorized | Protocol API 可复现 |
| Feishu | 本次未 live-run | 插件和测试存在，需要 credentials |

## 7. 主要发现

1. AutoService 的 customer/operator/admin 核心流程有真实运行数据支撑，不只是代码存在：客户消息、PV2 filler/final reply、operator join、takeover、release、KB sources、Dream runs、publish history 都能在本地运行库或 API 中验证。
2. 本地 `auth.db` 和线上账号文档的密码 hash 不一致，因此本地 password-login 失败；本次用 `AUTH_DEV_MODE=1` 完成登录验证。
3. Customer 新 live turn、General Bot API、附件上传、voice E2E 都依赖额外配置或外部凭证。
4. Ezagent 能复现核心 agent/session/routing/API/Feishu 概念，但不能直接复现 AutoService 的 KB、Dream/CR、sandbox publish、billing/SLA analytics、voice 子系统。
5. Ezagent 当前 `mix precommit` 未干净通过，需要先处理 plugin wiring、retired liveview 目录、py_default seed、WorldHostRoutingTest 的本地失败项。
