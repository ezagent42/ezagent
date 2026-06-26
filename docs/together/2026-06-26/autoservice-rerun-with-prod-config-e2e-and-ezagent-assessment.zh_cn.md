# AutoService 第二轮真实 E2E 与 ezagent 复现评估

日期：2026-06-26  
测试对象：`/mnt/d/Work/h2os.cloud/AutoService-dev-a`  
线上只读来源：`h2oslabs@100.64.0.27:/Users/h2oslabs/Workspace/autoService`  
证据目录：`docs/together/2026-06-26/evidence/autoservice-rerun/`

## 1. 本轮目标

上一轮报告中，部分功能被标为 `CONFIG-BLOCKED`，主要原因是本地 `auth.db` 与线上账号集不一致、General Bot 缺少 raw API key、Playwright 浏览器二进制未安装。

本轮按“本地照理说都能跑”的假设重新准备宿主机测试环境：

- 只读核对线上配置、账号、运行路径。
- 本地备份 `auth.db` 后，镜像线上 `auth.db` 到本地测试环境。
- 使用真实密码登录，而不是 `AUTH_DEV_MODE=1`。
- 安装 Playwright Chromium，跑 admin/operator/customer 三端浏览器 E2E。
- 本地生成 General Bot 测试 key，补跑 `/chat/cinnox`。

线上未做任何写入或重启。

## 2. 测试环境准备

### 2.1 线上只读核对

线上路径存在：

```text
/Users/h2oslabs/Workspace/autoService
git rev: 8f09bbdf
```

线上 `auth.db` 中确认存在生产账号：

- `_master`：`lin.yilun@h2oslabs.com`、`huang.jiajia@h2oslabs.com`、`chen.ruihua@h2oslabs.com`、`dai.ming@h2oslabs.com` 等。
- `cinnox`：`admin1@h2oslabs.com`、`admin2@h2oslabs.com`、`op1@h2oslabs.com`、`op2@h2oslabs.com`。
- 上述 `cinnox` admin/operator 均有 password hash。

线上 `.autoservice/config.local.yaml` 与本地配置差异较大：

- 线上 pool：`min_size=10`、`max_size=50`、`warmup_count=10`。
- 本地 pool：`min_size=1`、`max_size=5`、`warmup_count=4`。

本轮本地沿用较小 pool，避免宿主机资源和启动时间被线上规模拖垮。

### 2.2 本地准备动作

- 备份本地 auth DB：`.autoservice/e2e-backups/auth.local-before-prod-mirror.<timestamp>.db`
- 从线上只读复制：`.autoservice/database/auth.db`
- 本地安装 Playwright Chromium：`python -m playwright install chromium`
- 本地生成 General Bot key：`.autoservice/sandbox/cinnox/api_keys.json`

注意：General Bot raw key 只能生成时看到一次，线上只有 hash，不能反推。因此本地必须生成测试 key。

## 3. 服务启动

后端启动方式：

```bash
AUTH_DEV_MODE=0 PLACEHOLDER_ENABLED=0 .venv/bin/python -m uvicorn autoservice.web_gateway:create_app --factory --host 127.0.0.1 --port 8000 --log-level info
```

说明：

- 初次 `uv run uvicorn` 重建 `.venv` 很慢，后改用 `.venv/bin/python -m uvicorn`。
- 后端以 `AUTH_DEV_MODE=0` 启动，真实验证密码登录。
- cc_pool 启动成功，预热 4 个主池实例，另有 `triage`、`lead` 子池。

前端实际端口：

- operator-console：`http://127.0.0.1:5174`
- customer-chat：`http://127.0.0.1:5175`
- admin-portal：`http://127.0.0.1:5176`

`5173` 已被宿主机其他 Vite 进程占用，所以 customer 自动落到 `5175`，admin 自动落到 `5176`。

## 4. 真实 E2E 结果

### 4.1 Admin 端

场景：tenant admin 真实密码登录。

- 账号：`admin1@h2oslabs.com`
- tenant：`cinnox`
- 认证方式：`POST /api/auth/login`
- 结果：`PASS`

API 结果：

```json
{
  "ok": true,
  "redirect": "/",
  "tenant_id": "cinnox",
  "email": "admin1@h2oslabs.com",
  "role": "admin",
  "force_password_change": true
}
```

`/api/session/mode` 返回：

```json
{
  "mode": "master",
  "tenant_id": "cinnox",
  "authenticated": true,
  "authenticated_as": "admin1@h2oslabs.com",
  "tier": 1,
  "role": "admin"
}
```

浏览器 E2E：

- 登录页填写 tenant/email/password。
- 登录后进入 `http://127.0.0.1:5176/tenants/cinnox`。
- 页面显示 `TENANT: CINNOX`、`Signed in as admin1@h2oslabs.com`。
- 深链进入 `http://127.0.0.1:5176/tenants/cinnox/kb`。
- 页面显示 `Knowledge Base — cinnox`。

证据：

- `evidence/autoservice-rerun/admin-after-login.png`
- `evidence/autoservice-rerun/admin-kb.png`

结论：Admin tenant 管理端真实密码登录、session、KB 管理入口均通过。`force_password_change=true` 是线上账号状态，不阻塞登录，但产品上应引导用户改密。

### 4.2 Operator 端

场景：operator 真实密码登录并加载工作台。

- 账号：`op1@h2oslabs.com`
- tenant：`cinnox`
- 认证方式：`POST /api/auth/login`
- 结果：`PASS`

API 结果：

```json
{
  "ok": true,
  "redirect": "/operator",
  "tenant_id": "cinnox",
  "email": "op1@h2oslabs.com",
  "role": "responder",
  "force_password_change": true
}
```

`/api/auth/operator/me` 返回：

```json
{
  "tenant_id": "cinnox",
  "email": "op1@h2oslabs.com",
  "role": "responder",
  "force_password_change": true
}
```

`/api/conversations/active?tenant_id=cinnox`：

- 返回 145 个 active conversations。
- 样例 conversation：`web_anon_f47a56c52dc8`，状态 `auto`。

浏览器 E2E：

- 登录页填写 tenant/email/password。
- 登录后工作台显示 `op1@h2oslabs.com`、`Online · 145 chats`、`zchat connected`。
- 结果：`PASS`

证据：

- `evidence/autoservice-rerun/operator-after-login.png`

结论：Operator 登录、身份识别、会话列表加载、WS 连接状态均通过。接管/释放流程本轮未实际发送 `/hijack`、`/release`，但上一轮 DB 中已有真实历史事件；综合证据仍建议标为 `DATA-PASS`，不是本轮 `E2E-PASS`。

### 4.3 Customer 端

场景：customer-chat 浏览器打开、WebSocket 连接、发送消息、收到 AI 回复。

入口：

```text
http://127.0.0.1:5175/tenant/cinnox/chat
```

浏览器 E2E：

- 打开 cinnox customer chat。
- 移动视口下窗口自动打开，无需点击 FAB。
- 输入：`你好，我想了解 CINNOX Professional 套餐`
- 发送后页面出现用户消息。
- AI 返回：`方便问下您是已经在使用 CINNOX 产品，还是第一次了解咨询呢？`
- 结果：`PASS`

证据：

- `evidence/autoservice-rerun/customer-after-send.png`
- `evidence/autoservice-rerun/customer-browser-result.json`

结论：Customer UI + WS + 后端 + cc_pool + CINNOX soul/flow 路径真实跑通。这个结果比上一轮 “SHELL-PASS/DATA-PASS” 更强，应升级为 `E2E-PASS`。

### 4.4 General Bot API

上一轮 `/chat/cinnox` 因缺少 raw API key 被 `401` 阻塞。本轮本地生成 `api_keys.json` 后重测。

请求：

```text
POST /chat/cinnox
Authorization: Bearer <local-e2e-key>
body: {"query":"Hello, what is CINNOX?","inquiryID":"e2e-rerun-20260626"}
```

结果：`PASS`

返回结构：

```json
{
  "message": {
    "type": 1,
    "text": "CINNOX is M800's flagship all-in-one platform ..."
  }
}
```

结论：General Bot server-to-server 路径可本地复现；raw key 缺失不是功能缺失，而是凭据生成/保存流程要求。

### 4.5 Admin 数据 API

本轮验证：

- `/api/master/tenants`：返回租户清单，包括 `_master`、`cinnox`、`mystore`、多个测试租户。
- `/api/admin/kb/cinnox/sources`：返回 19 个 KB source，包括 `CINNOX Pricing`、`CINNOX Feature List 2026`、`M800 Global Rates`。
- `/api/tenants/cinnox/versions`：返回 v1-v16。
- `/api/dream/runs?tenant_id=cinnox&limit=3`：返回历史 completed Dream runs。
- `/api/sla/summary?tenant_id=cinnox`：本轮已有首响数据，`first_reply_ms.count=1`，p50/p95 约 8862ms。

结论：Admin 数据面可用，不只是代码存在。

## 5. 仍未通过或未完整 E2E 的功能

### 5.1 附件上传

请求：

```text
POST /api/upload
tenant_id=cinnox
conv_id=web_e2e_rerun
file=as-e2e.txt
```

结果：

```json
{"detail":"attachments disabled for this tenant"}
```

HTTP：`503`

结论：附件功能在代码中存在，但当前 tenant 配置禁用。本地和线上都不能把它算作已上线可用功能，除非明确启用 tenant attachment 配置并补 storage 设置。

### 5.2 Voice

`/api/voice/backend-info` 返回：

```json
{
  "backend": "doubao",
  "asr_ws_url": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
  "tts_url": "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
}
```

补充运行日志：

- SAUC ASR warmup 可连接。
- TTS warmup 失败，原因是当前宿主机环境启用了 SOCKS proxy，但 `.venv` 中缺少 `socksio`，`httpx.AsyncClient` 初始化 proxy transport 时抛出 ImportError。
- DeepSeek filler 也出现同类 `socksio` ImportError；主 customer 回复仍通过 cc_pool 正常返回。

结论：配置解析和部分 warmup 通过，但宿主机依赖缺 `socksio`，且未跑真实浏览器麦克风/ASR/TTS 媒体流。因此 Voice 仍是 `CONFIG-PARTIAL / NOT-RUN`，不能标为完整 E2E。

### 5.3 接管/释放

Operator UI 登录和会话列表通过；上一轮 DB 里有 `/hijack`、`/release` 历史事件。本轮没有对生产镜像数据追加真实接管命令。

结论：综合标为 `DATA-PASS`，如要升级到 `E2E-PASS`，需要在本地新建一条测试 conversation，再由 operator 浏览器执行接管、发送公开回复、释放。

### 5.4 改密流程

线上镜像账号均返回 `force_password_change=true`。本轮没有执行改密，因为会改变本地镜像 DB，并可能影响后续密码复用测试。

结论：登录成功，但改密引导/强制策略需要单独测。

## 6. Scenario 状态重分级

| Scenario | 上一轮状态 | 本轮状态 | 说明 |
| --- | --- | --- | --- |
| Customer SPA shell | SHELL-PASS | E2E-PASS | 浏览器真实发送消息并收到 AI 回复 |
| Customer WS message | DATA-PASS | E2E-PASS | `/tenant/cinnox/chat` 走通 |
| General Bot `/chat/cinnox` | CONFIG-BLOCKED | E2E-PASS | 本地生成 raw key 后通过 |
| Operator password login | CONFIG-BLOCKED | E2E-PASS | 线上 auth.db 镜像后真实密码通过 |
| Operator active list | E2E-PASS | E2E-PASS | 145 active conversations |
| Operator takeover/release | DATA-PASS | DATA-PASS | 本轮未执行命令级接管 |
| Admin password login | CONFIG-BLOCKED | E2E-PASS | 线上 auth.db 镜像后真实密码通过 |
| Admin KB manager | E2E-PASS | E2E-PASS | 浏览器深链 + API 均通过 |
| Admin versions | E2E-PASS | E2E-PASS | v1-v16 |
| Dream runs | DATA-PASS | DATA-PASS | 历史 run 可读，未触发新 run |
| SLA summary | PARTIAL | PARTIAL+ | 本轮产生 first reply 数据，其他指标仍为空 |
| Attachments | CONFIG-BLOCKED | CONFIG-BLOCKED | tenant 明确 disabled |
| Voice | NOT-RUN | CONFIG-PARTIAL / NOT-RUN | backend config OK；宿主缺 `socksio`，媒体流未测 |

## 7. 对 ezagent 复现评估的影响

本轮把之前很多“可能只是代码存在”的点提升为了真实可用证据，因此 ezagent 复现优先级可以更明确。

### 7.1 ezagent 可直接承接的能力

这些能力在 AutoService 已真实跑通，ezagent 已有相近基础，可作为优先复现目标：

- 多角色登录后的工作区分流：admin/operator/customer。
- 会话列表、消息历史、当前 conversation 状态。
- agent/AI 回复接入会话流。
- operator 侧工作台与实时状态。
- admin 侧 tenant 资源浏览。
- API key 型 server-to-server bot 入口。

ezagent 对应基础：

- session / workspace / agent / user / capability 模型。
- plugin protocol API。
- Feishu/外部镜像与会话桥接。
- operator-like workspace UI 的雏形。

建议复现级别：`L1 直接复现` 或 `L2 少量适配`。

### 7.2 ezagent 需要产品化适配的能力

这些 AutoService 已真实可用，但 ezagent 不是同构实现，需要做产品层适配：

- Customer public chat widget：ezagent 需要明确 public anonymous user/session 模型。
- Operator takeover/release：ezagent 有能力模型，但需要客服语义的接管状态、公开/内部消息可见性。
- General Bot API：ezagent 可用 Protocol API/HTTP plugin 承接，但需要 per-tenant key lifecycle。
- KB manager：AutoService 已有 source/chunk 管理；ezagent 需要统一 KB ingestion、source metadata、检索工具。
- SLA/CSAT：ezagent 可记录事件，但需要客服指标模型。

建议复现级别：`L2 适配实现`。

### 7.3 ezagent 当前缺失或需要新建的能力

这些不能仅靠现有 ezagent 配置复现：

- AutoService 式 CINNOX soul/skill/KB/publish 业务闭环。
- Tenant release v1-v16、sandbox preview、CR/publish/rollback 治理。
- 附件存储与 tenant 开关。
- Voice ASR/TTS 媒体链路。
- Billing/SLA 运营面板的完整指标口径。

建议复现级别：`L3 新开发`。

## 8. 结论

第二轮测试后，AutoService 的核心三端不是“代码里有但线上未验证”的状态：

- Admin：真实密码登录、tenant scope、KB 深链、versions、Dream runs 可用。
- Operator：真实密码登录、operator identity、active conversations、工作台 UI 可用。
- Customer：真实浏览器 WebSocket 发送消息并收到 CINNOX AI 回复。
- General Bot：本地生成 raw key 后 `/chat/cinnox` 可用。

仍不能宣称完整上线可用的部分：

- Attachments：当前 tenant disabled。
- Voice：配置可解析，但未跑真实媒体流。
- Operator takeover/release：有历史数据证据，本轮未命令级复现。
- Dream trigger/publish/rollback：本轮只读历史和版本，未执行修改性流程。

对 ezagent 来说，最合理的复现路径不是一次性复制全部 AutoService，而是按证据强度拆分：

1. 先复现已真实通过的 customer/operator/admin 核心会话闭环。
2. 再补 operator takeover、public widget、General Bot key、KB source manager。
3. 最后做 release governance、voice、attachments、billing/SLA 等垂直能力。
