# AutoService 真实 E2E 与 Ezagent 适配最终评估

日期：2026-06-26

源项目：

- 本地：`/mnt/d/Work/h2os.cloud/AutoService-dev-a`
- 线上只读：`h2oslabs@100.64.0.27:/Users/h2oslabs/Workspace/autoService`

目标项目：`/home/huangjiajia/ezagent`

参考输入：

- 代码分析文档：`docs/together/2026-06-26/autoservice-e2e-scenarios-and-ezagent-mapping.md`
- 第一轮真实跑测报告：`docs/together/2026-06-26/autoservice-real-e2e-scenarios-and-ezagent-reproduction.zh_cn.md`
- 第二轮本地真实密码/浏览器 E2E：`docs/together/2026-06-26/autoservice-rerun-with-prod-config-e2e-and-ezagent-assessment.zh_cn.md`
- 线上 Linux 只读验证：`docs/together/2026-06-26/autoservice-online-linux-e2e-verification.zh_cn.md`
- 证据截图与结果：`docs/together/2026-06-26/evidence/autoservice-rerun/`

本报告的判断原则：

- **代码存在 != 线上功能真实可用**。
- 只有真实启动、真实 API 调用、真实前端交互、真实 WebSocket、真实数据库记录或线上运行证据支撑的能力，才标为通过。
- 线上验证遵守只读边界：没有修改 admin 设置，没有 publish/rollback，没有改 tenant 配置。
- 登录、customer 会话、voice 探针会产生正常 runtime session/conversation 数据，属于本次允许的验证范围。
- Ezagent 复现评估按“可直接复现 / 可适配复现 / 需要开发 / 不建议按配置复现”分层。

## 1. 最终结论

AutoService 的 customer/operator/admin 三端核心客服链路已经不只是“代码里有”。经过本地真实密码浏览器 E2E 和线上 Linux 验证后，可以确认：

- **Customer**：本地浏览器完整跑通 customer chat、WebSocket、发送消息、收到 CINNOX AI 回复；线上 WebSocket 跑通握手、欢迎消息、客户消息发送和 `message_confirm`。
- **Operator**：本地和线上均跑通真实密码登录、operator 身份接口、active conversations；线上 active conversations 返回 408 条，本地镜像返回 145 条。
- **Admin**：本地和线上均跑通真实密码登录、session、KB sources、versions 等只读管理面；线上 KB sources 为 170 个，release versions 到 `v20`。
- **General Bot API**：本地生成 raw API key 后 `/chat/cinnox` 跑通。
- **Voice**：线上 split greeting TTS 链路跑通，收到 3 个二进制音频帧，共 25472 bytes；ASR 麦克风转写未测。

仍不能宣称完整通过的功能：

- **Attachments**：本地 `/api/upload` 返回 `attachments disabled for this tenant`，当前 tenant 配置禁用。
- **Operator takeover/release**：有历史 DB 事件证据，本轮未在线上或本地重新执行 `/hijack`、`/release`。
- **Dream trigger / CR apply / publish / rollback / admin settings**：本轮只做只读验证，未执行修改性流程。
- **Voice ASR**：只验证到线上 TTS greeting，未发送真实麦克风音频并验证转写。
- **Billing / CSAT / SLA 完整指标面板**：接口或部分数据存在，但未形成完整业务闭环验证。

对 ezagent 的最终判断：

Ezagent 可以作为 AutoService 的 **agent/session/routing/channel 底座复现平台**，适合优先复现 customer/operator/admin 的核心会话闭环；但当前不能作为 AutoService 的 **完整客服业务平台替代品**。KB ingestion、Dream/CR/publish、voice、attachments、billing/SLA 等都应按新能力或插件开发评估，不能写成“已有配置即可复现”。

## 2. 证据等级

| 等级 | 含义 | 是否可证明真实能力 |
| --- | --- | --- |
| E2E-PASS | 本次真实 API、浏览器、WebSocket 或线上运行验证通过 | 可以 |
| VOICE-TTS-E2E-PASS | voice WS 与 TTS 音频返回链路通过 | 可证明 TTS，不证明 ASR |
| DATA-PASS | 数据库有历史成功记录 | 可证明历史跑通过，不证明本轮新请求通过 |
| SHELL-PASS | SPA shell 可加载 | 只能证明入口可用 |
| CONFIG-BLOCKED | 功能存在但被配置、凭证、租户开关阻塞 | 不能算通过 |
| PARTIAL | 接口或部分链路通过，业务闭环不足 | 不能算完整通过 |
| NOT-RUN | 代码存在但本次未跑 | 不能算通过 |
| MISSING | 当前系统没有对应能力 | 不能算通过 |

## 3. AutoService 三端最终 Scenario

### 3.1 Customer 端

| Scenario | 代码分析结论 | 真实 E2E/线上结果 | 最终状态 |
| --- | --- | --- | --- |
| Customer Chat SPA | 有 React customer-chat | 本地浏览器打开 `http://127.0.0.1:5175/tenant/cinnox/chat` | E2E-PASS |
| Customer WS handshake | 有 `/ws/customer` | 线上 `server_hello` 返回 `viewer_role=customer`、`brand_name=CINNOX` | E2E-PASS |
| Welcome message | 有 agent welcome | 线上收到中英双语 CINNOX 欢迎消息 | E2E-PASS |
| 发送 customer message | 有 WS message pipeline | 本地发送中文咨询并收到 AI 回复；线上发送 `Hello, what is CINNOX?` 并收到 `ack`、`message_confirm` | E2E-PASS |
| AI final reply | 有 Pipeline V2 / cc_pool | 本地浏览器收到 `方便问下您是已经在使用 CINNOX 产品，还是第一次了解咨询呢？` | E2E-PASS |
| 历史持久化 | 有 conversations/messages DB | 第一轮 DB 中有 customer message、filler、final reply 记录 | DATA-PASS |
| General Bot `/chat/cinnox` | 有 server-to-server bot API | 本地生成 raw key 后返回 CINNOX 文本答复 | E2E-PASS |
| Attachments | 有 `/api/upload` | 本地返回 `attachments disabled for this tenant` | CONFIG-BLOCKED |
| Voice greeting TTS | 有 voice WS / Doubao backend | 线上 split greeting 返回 3 个音频帧 | VOICE-TTS-E2E-PASS |
| Voice ASR | 有 ASR backend 配置 | 未发送真实麦克风音频验证转写 | NOT-RUN |
| CSAT | 代码分析有场景 | 未验证真实 UI/API/DB 闭环 | NOT-RUN |
| 多语言切换 | 代码和数据有中英痕迹 | 未做切换 E2E | PARTIAL |

Customer 结论：

- 核心 public chat 已经真实跑通，本地是完整浏览器消息闭环，线上是 WS 握手、发送、确认链路。
- 附件和 ASR 不应计入已上线通过能力。

### 3.2 Operator 端

| Scenario | 代码分析结论 | 真实 E2E/线上结果 | 最终状态 |
| --- | --- | --- | --- |
| Operator Console SPA | 有 React operator-console | 本地浏览器登录后显示工作台 | E2E-PASS |
| 真实密码登录 | 有统一 auth | 本地和线上 `op1@h2oslabs.com` 登录成功 | E2E-PASS |
| Operator identity | 有 `/api/auth/operator/me` | 线上返回 operator_id `1uInaAg1To3Ug34z--eloA` | E2E-PASS |
| Active conversations | 有 active list API | 本地 145 条，线上 408 条 | E2E-PASS |
| zchat/实时状态 | 前端有状态显示 | 本地 UI 显示 `zchat connected` | E2E-PASS |
| Join/copilot | 有 operator participation | 第一轮 DB 有 `participant.joined`、`auto -> copilot` | DATA-PASS |
| Takeover `/hijack` | 有 command | DB 有 `copilot -> takeover` 和 `/hijack` 历史事件 | DATA-PASS |
| Release `/release` | 有 command | DB 有 `takeover -> auto` 和 `/release` 历史事件 | DATA-PASS |
| Pool runtime | 有 `/api/cc_pool/runtime` | 线上 `started=true`、`available=9`、`total=10`、`max_size=50` | E2E-PASS |
| SLA summary | 有 API | 本地第二轮产生 1 条 first reply；线上当前窗口 count 为 0 | PARTIAL |

Operator 结论：

- 登录、身份、会话列表、工作台加载已真实通过。
- 接管/释放有历史运行证据，但本轮没有新建测试会话重新执行命令，因此仍标为 DATA-PASS，不升级为 E2E-PASS。

### 3.3 Admin 端

| Scenario | 代码分析结论 | 真实 E2E/线上结果 | 最终状态 |
| --- | --- | --- | --- |
| Admin Portal SPA | 有 React admin-portal | 本地浏览器真实登录并进入 tenant 页 | E2E-PASS |
| 真实密码登录 | 有统一 auth | 本地和线上 `admin1@h2oslabs.com` 登录成功 | E2E-PASS |
| Session mode | 有 `/api/session/mode` | 返回 authenticated admin、tenant `cinnox`、tier 1 | E2E-PASS |
| Tenant list | 有 `/api/master/tenants` | 本地返回 `_master`、`cinnox`、`mystore` 等 | E2E-PASS |
| KB sources | 有 KB source API | 本地 19 个 source；线上 170 个 source | E2E-PASS |
| KB 页面深链 | 有 KB manager UI | 本地浏览器进入 `/tenants/cinnox/kb`，显示 `Knowledge Base — cinnox` | E2E-PASS |
| Versions | 有 version API | 本地 v1-v16；线上 v1-v20 | E2E-PASS |
| Dream runs list | 有 Dream API | 本地有历史 completed runs；线上 `cinnox` 当前返回空数组 | PARTIAL |
| Inbox/CR | 有 inbox/CR API | 只读接口可查，未执行 apply/publish | PARTIAL |
| Soul/Skill 编辑 | 代码存在 | 第一轮盲猜 section/path 返回 404 或 no slots | NOT-RUN |
| Publish/rollback | 代码存在 | 按线上约束未执行 | NOT-RUN |
| Billing dashboard | 代码分析有场景 | 本次未验证 | NOT-RUN |

Admin 结论：

- 只读管理面真实可用，线上数据规模明显大于本地镜像。
- 发布、回滚、配置修改、Soul/Skill 编辑必须单独开受控测试，不能由只读 API 推断为已通过。

## 4. 关键修正

### 4.1 Customer 入口修正

后端直接访问 `/tenant/cinnox/chat` 返回 404，本地 dev 必须启动 customer-chat Vite app，由前端承载该 route。最终有效入口是前端端口上的：

```text
http://127.0.0.1:5175/tenant/cinnox/chat
```

### 4.2 登录阻塞已被解除

第一轮本地 password login 失败，原因是本地 `auth.db` 与线上账号 hash 不一致。第二轮备份本地 DB 后镜像线上 `auth.db`，`admin1@h2oslabs.com` 和 `op1@h2oslabs.com` 均真实密码登录通过。

最终判断：

- 账号/密码链路本身可用。
- 本地复现如果要用生产测试账号，必须同步或准备匹配的 auth DB。
- 这些账号当前返回 `force_password_change=true`，改密流程仍需单独测试。

### 4.3 General Bot 是凭据依赖，不是功能缺失

第一轮 `/chat/cinnox` 未带 key 返回 `unauthorized`。第二轮本地生成 raw API key 后通过，说明该能力可复现，但依赖：

- tenant 下存在 `api_keys.json` 或等效 key store。
- 调用方保存 raw key，因为线上 hash 不能反推 raw key。

### 4.4 Attachments 是 tenant 配置阻塞

`/api/upload` 返回：

```json
{"detail":"attachments disabled for this tenant"}
```

这不是测试代码错误，而是当前 tenant 配置禁用。除非明确开启 attachment 配置并补齐 storage 设置，否则不能算已上线能力。

### 4.5 Voice 结论上调，但只上调 TTS

本地 voice 只验证到 backend-info，且宿主机因 SOCKS proxy 缺 `socksio` 出现 TTS warmup 失败。线上验证更强：voice split greeting 返回音频 bytes。

最终判断：

- TTS greeting：线上 E2E-PASS。
- ASR 麦克风转写：NOT-RUN。
- Ezagent 若复现 voice，需要媒体 WebSocket、ASR/TTS adapter、音频帧协议和前端权限处理，不能只映射到文本 session。

### 4.6 SLA / Dream / CR 不等于完整业务闭环

SLA endpoint 可用，但线上当前窗口 count 为 0；本地第二轮只有 first reply 单点数据。Dream runs 本地有历史数据，线上 `cinnox` 当前为空。CR/publish 未执行。

最终判断：

- 可以证明接口和部分数据读取存在。
- 不能证明完整运营指标、Dream 生成、CR 应用、发布治理闭环已通过。

## 5. Ezagent 复现分层

### 5.1 L1：可直接复现，优先做

这些能力对应通用 agent/session/channel 底座，AutoService 已真实跑通，ezagent 已有相近基础。

| AutoService 能力 | Ezagent 复现方式 | 推荐证据 |
| --- | --- | --- |
| 用户发消息到会话 | session/chat flow | `docs/e2e/scenario-03-create-session.md` |
| Agent 回复 | py/cc/codex/curl agent roundtrip | `scenario-04/05/06/07` |
| 消息历史 | MessageStore/session view | session E2E |
| Operator/Admin 登录 | identity password / magic-link | `scenario-01`、identity tests |
| 会话列表和工作区 | workspace/session lifecycle | `docs/scenarios/20-workspace-lifecycle` |
| Routing / mention | routing rules / mention-gated dispatch | `scenario-08/09` |
| Server-to-server bot API | protocol API / HTTP plugin | protocol_api tests |
| Feishu inbound/outbound | `ezagent_plugin_feishu` | `scenario-10/11`、Feishu tests |

建议 L1 闭环：

1. 创建 workspace。
2. 创建 user/operator/admin。
3. 创建 session。
4. 加入 agent。
5. user 发消息。
6. agent 回复。
7. operator 打开 session 看 history。
8. 通过 routing/mention 验证目标 agent 投递。
9. 通过 protocol API 验证 HTTP chat。
10. 通过 Feishu 插件验证 inbound/outbound。

### 5.2 L2：可适配复现，但不能宣称等价

这些能力可以用 ezagent 现有抽象模拟业务语义，但产品协议和 AutoService 不同。

| AutoService 能力 | Ezagent 可用抽象 | 缺口 |
| --- | --- | --- |
| Customer public widget | public/anonymous session + external channel | 缺 AutoService widget/sessionStorage/customerId 模型 |
| Operator copilot | session member + visibility + routing | 缺客服 console 级 copilot UX |
| Takeover/release | caps + routing + session state | 缺 `/hijack`、倒计时、idle release、banner |
| Squad/filter/unread | workspace/session metadata | 缺产品化列表、计数和 SLA 口径 |
| General Bot API | protocol API / custom plug | 缺 per-tenant key lifecycle 和 AutoService response shape |
| Admin tenant resources | workspace/admin UI | 缺 AutoService tenant admin 信息架构 |
| Soul/Skill | SessionTemplate + Behavior + Agent config | 模型不同，不是 L0-L3 Soul |
| Publish/version | config snapshot / git / workspace state | 缺 release archive/pointer flip |
| CSAT | message/action metadata | 缺内建客服产品面 |

建议表达：

- 可以说“ezagent 可用现有抽象复现业务语义”。
- 不要说“ezagent 已完整复现 AutoService 该功能”。

### 5.3 L3：需要开发，不能当配置任务

| AutoService 能力 | Ezagent 当前状态 | 建议 |
| --- | --- | --- |
| KB ingestion / source manager / vector search | 缺失 | 新建 KB domain/plugin |
| Dream -> proposal -> CR -> publish | 缺失 | 新建 governance/CR 插件或 domain |
| Sandbox preview / release archive / pointer flip | 缺失 | 新建 release pipeline |
| Voice ASR/TTS | 缺失 | 新建 voice channel/plugin |
| Attachment upload storage | 部分缺失 | 新建 upload/storage/message attachment 规范 |
| Billing dashboard | 缺失 | 新建 billing/analytics |
| SLA analytics | 缺失 | 新建 metrics/event aggregation |

这些能力不应写成“配置即可复现”。

## 6. 推荐最终 Scenario 集

### 6.1 AutoService 已真实验证 Scenario

| ID | Scenario | 状态 | 证据 |
| --- | --- | --- | --- |
| AS-CUST-01 | Customer chat 浏览器打开、发送消息、收到 AI 回复 | E2E-PASS | 本地 Playwright 截图与结果 JSON |
| AS-CUST-02 | Customer WS 线上握手、欢迎消息、发送、确认 | E2E-PASS | 线上 WS frame |
| AS-CUST-03 | General Bot `/chat/cinnox` 带 key 调用 | E2E-PASS | 本地 API 返回 CINNOX 文本 |
| AS-CUST-04 | Voice split greeting TTS | VOICE-TTS-E2E-PASS | 线上 voice WS 音频 bytes |
| AS-OP-01 | Operator 真实密码登录 | E2E-PASS | 本地/线上 login API |
| AS-OP-02 | Operator 工作台加载 | E2E-PASS | 本地 Playwright 截图 |
| AS-OP-03 | Operator active conversations | E2E-PASS | 本地 145、线上 408 |
| AS-OP-04 | Operator takeover/release 历史事件 | DATA-PASS | conversation DB events |
| AS-ADMIN-01 | Admin 真实密码登录和 session | E2E-PASS | 本地/线上 login + session API |
| AS-ADMIN-02 | Admin KB sources | E2E-PASS | 本地 19、线上 170 |
| AS-ADMIN-03 | Admin versions | E2E-PASS | 本地 v1-v16、线上 v1-v20 |
| AS-ADMIN-04 | Admin KB 页面深链 | E2E-PASS | 本地 Playwright 截图 |

### 6.2 AutoService 未完整通过 Scenario

| Scenario | 当前状态 | 原因 |
| --- | --- | --- |
| Attachment upload | CONFIG-BLOCKED | tenant 明确 disabled |
| Voice ASR | NOT-RUN | 未发送真实音频验证转写 |
| Operator 新会话 takeover/release | DATA-PASS | 本轮未执行命令级接管 |
| Force password change | NOT-RUN | 登录返回 flag，但未执行改密 |
| Dream trigger | PARTIAL | 只读历史/空列表，未触发新 run |
| CR apply / publish / rollback | NOT-RUN | 修改性操作按约束未执行 |
| Soul/Skill 编辑 | NOT-RUN | 未枚举真实 section/skill 后执行编辑 |
| Billing dashboard | NOT-RUN | 未验证 |
| SLA 完整指标 | PARTIAL | 接口可用，数据口径未完整覆盖 |

### 6.3 Ezagent 推荐复现场景

| ID | Ezagent Scenario | 对应 AutoService | 复现级别 |
| --- | --- | --- | --- |
| EZ-L1-01 | Session + Agent Roundtrip | customer message + agent reply + history | L1 |
| EZ-L1-02 | Operator/Admin Identity | operator/admin login + role/cap | L1 |
| EZ-L1-03 | Routing / Mention / Cross-session Guard | agent routing、session isolation | L1 |
| EZ-L1-04 | Protocol API Chat | General Bot API | L1/L2 |
| EZ-L1-05 | Feishu inbound/outbound | 外部 channel bridge | L1 |
| EZ-L2-01 | Public Anonymous Session | customer widget | L2 |
| EZ-L2-02 | Operator Takeover State | takeover/release | L2 |
| EZ-L2-03 | Admin Resource Browser | tenant admin read-only | L2 |
| EZ-L3-01 | KB Manager | KB sources/chunks/search | L3 |
| EZ-L3-02 | Release Governance | Dream/CR/publish/rollback | L3 |
| EZ-L3-03 | Voice Channel | ASR/TTS media WS | L3 |

## 7. 复现依赖与配置

### 7.1 AutoService 本地复现依赖

必须准备：

- Python `.venv` 可运行 `autoservice.web_gateway:create_app`。
- 前端 Vite apps：customer-chat、operator-console、admin-portal。
- Playwright Chromium。
- 与测试账号匹配的 `.autoservice/database/auth.db`。
- tenant `cinnox` 的 conversation/KB/version 数据。
- General Bot raw API key，如果要测 `/chat/cinnox`。

建议后端启动：

```bash
AUTH_DEV_MODE=0 PLACEHOLDER_ENABLED=0 .venv/bin/python -m uvicorn autoservice.web_gateway:create_app --factory --host 127.0.0.1 --port 8000 --log-level info
```

第二轮实际端口：

- operator-console：`http://127.0.0.1:5174`
- customer-chat：`http://127.0.0.1:5175`
- admin-portal：`http://127.0.0.1:5176`

注意：

- `5173` 可能被其他 Vite 进程占用，端口需以实际启动输出为准。
- 本地使用生产测试账号时，必须保证 auth DB/hash 与密码一致。
- 不要把线上 raw API key 当作可读取资产，线上通常只保存 hash。

### 7.2 线上验证依赖

线上已验证：

- `uvicorn` 在 `127.0.0.1:8000` 运行。
- `caddy`、`cloudflared` 运行。
- `/api/ping` 返回 `{"ok": true}`。
- cc_pool 线上配置为 warmup 10、max 50。
- voice backend 为 Doubao。

线上只读边界：

- 可验证 login/session/read-only APIs/customer WS/voice greeting。
- 不应修改 admin settings、tenant config、KB、Soul/Skill、publish/rollback。

### 7.3 Ezagent 复现依赖

L1 复现需要：

- identity/user/admin/operator-like role。
- workspace/session/message history。
- 至少一个可响应 agent，例如 cc/codex/curl/py agent。
- routing/mention 规则。
- protocol API 或等效 HTTP 入口。
- 可选 Feishu 插件。

L2/L3 额外需要：

- public anonymous session 模型。
- operator takeover 状态机和可见性规则。
- per-tenant API key lifecycle。
- KB source/chunk/search domain。
- voice media WS 与 ASR/TTS adapter。
- release governance/publish archive。
- SLA/CSAT/billing 事件模型。

## 8. Ezagent 当前验证状态

本次执行过：

```bash
mix precommit
```

结果：未通过。

已观察到的主要失败：

1. `apps/ezagent_plugin_content`、`apps/ezagent_plugin_cr`、`apps/ezagent_plugin_liveview` 是目录但缺 `mix.exs`，触发 plugin invariant。
2. `apps/ezagent_plugin_liveview` 被测试认为应保持 retired，但目录仍存在。
3. `AllPluginAppsWiredToWebTest` 认为若上述 plugin app 存在于 `apps/` 下，就必须 wire 到 `apps/ezagent_web/mix.exs`。
4. `KindProvenanceTest` 发现 `entity://system/agent/py_default` alive，但不在 declared Kind supervisor 下。
5. `EzagentDomainInstanceMessage.Integration.PresenceReadReceiptsE2ETest` 本次完整 precommit 中出现 `wait_until timed out`。
6. `ezagent_plugin_feishu` 的 sidecar orphan reap 测试要求 `main.js` 注册 stdin EOF handler。
7. `ezagent_plugin_py` 的 `seed_default/0` 30 秒内未让 `py_default` subprocess alive。

这些是 ezagent 当前 repo 自动化环境问题，不是本报告文件引入的功能代码变更；但它们意味着“在 ezagent 下复现 AutoService”前，需要先清理本地 precommit 基线。

## 9. 最终建议

### 9.1 短期：只承诺 L1 核心会话闭环

优先把下列能力作为 ezagent 复现目标：

- user/operator/admin 身份。
- workspace/session 创建。
- customer-like message。
- agent reply。
- message history。
- operator-like session list。
- routing/mention。
- protocol API。
- Feishu 或其他外部 channel。

这部分和 AutoService 已通过的核心 customer/operator/admin 会话能力最贴近，风险最低。

### 9.2 中期：把 L2 做成明确的客服语义适配

可以设计：

- public anonymous customer session。
- operator takeover/release state。
- public/internal message visibility。
- active list/filter/unread。
- per-tenant bot key。
- admin read-only resource browser。

但文档和产品说明中要写清楚：这是 ezagent 抽象下的客服语义适配，不是 AutoService UI、协议、数据模型逐字复刻。

### 9.3 长期：L3 单独立项

以下能力应单独立项，不应混入“复现配置”：

- KB ingestion / source manager / vector search。
- Dream / proposal / CR / publish / rollback。
- sandbox preview / release archive / pointer flip。
- Voice ASR/TTS。
- Attachment storage。
- SLA / CSAT / billing analytics。

## 10. 最终一句话判断

AutoService 的 customer/operator/admin 核心客服闭环已经通过真实本地 E2E 和线上 Linux 验证；ezagent 可以复现其中的 agent/session/routing/channel 底座，但要成为等价的客服业务平台，还需要新增 KB、发布治理、voice、附件、SLA/CSAT/billing 等产品级能力。
