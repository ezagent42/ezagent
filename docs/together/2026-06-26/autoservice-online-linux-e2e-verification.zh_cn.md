# AutoService 线上 Linux 验证记录

日期：2026-06-26  
线上主机：`h2oslabs@100.64.0.27`  
线上路径：`/Users/h2oslabs/Workspace/autoService`  
约束：只读线上配置；不修改 admin 设置；不发布、不回滚、不改 tenant 配置。

## 1. 验证边界

本轮只验证线上真实运行状态和会话能力：

- 运行进程、健康接口。
- admin/operator 真实登录和只读 API。
- customer WebSocket 文本会话。
- voice WebSocket split 模式连接和音频帧返回。

没有执行：

- admin 设置修改。
- KB 上传/删除/编辑。
- Soul/Skill 编辑。
- CR apply/publish/rollback。
- tenant 配置修改。

登录和 customer/voice 会话会产生正常运行时 session/conversation 数据，这是本轮允许的验证范围。

## 2. 线上运行状态

线上项目：

```text
/Users/h2oslabs/Workspace/autoService
git rev: 8f09bbdf
```

运行进程：

- `uvicorn autoservice.web_gateway:create_app --factory --host 127.0.0.1 --port 8000 --proxy-headers`
- `caddy`
- `cloudflared`

健康接口：

```json
GET /api/ping
{"ok": true}
```

cc_pool：

```json
{
  "started": true,
  "max_size": 50,
  "checked_out": 1,
  "sticky": 0,
  "available": 9,
  "total": 10
}
```

结论：线上 gateway 与 pool 正常运行，pool 规模为线上配置的 10/50。

## 3. Admin 线上验证

账号：

- tenant：`cinnox`
- email：`admin1@h2oslabs.com`
- role：`admin`

真实密码登录：

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

session：

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

只读数据 API：

- `/api/admin/kb/cinnox/sources`：返回 170 个 KB source。
- 样例 source 包括：
  - `https://www.m800.com/us-virtual-number`
  - `https://www.m800.com/international-toll-free-number`
  - `https://www.m800.com/ai-agent`
  - `https://www.cinnox.com/ivr-solution`
  - `https://docs.cinnox.com/docs/cx-api-reference`
- `/api/tenants/cinnox/versions`：返回 20 个 release version，尾部为 `v16` 到 `v20`。
- `/api/sla/summary?tenant_id=cinnox`：接口可用，但当前窗口各指标 count 为 0。
- `/api/dream/runs?tenant_id=cinnox&limit=3`：返回空数组。

结论：线上 admin 登录与只读资源面真实可用。和本地镜像相比，线上数据更新更多：KB source 170 个、release 到 v20。

## 4. Operator 线上验证

账号：

- tenant：`cinnox`
- email：`op1@h2oslabs.com`
- role：`responder`

真实密码登录：

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

operator me：

```json
{
  "operator_id": "1uInaAg1To3Ug34z--eloA",
  "tenant_id": "cinnox",
  "email": "op1@h2oslabs.com",
  "role": "responder",
  "force_password_change": true
}
```

active conversations：

- `/api/conversations/active?tenant_id=cinnox`
- 返回 408 个 active conversation。
- 样例：
  - `web_cust_96e0b0a6`
  - `cinnox_cinnox:2450eae6-ca06-40fd-874a-fa95c4f7aac2`

结论：线上 operator 登录、session、身份 API、活跃会话列表均可用。

## 5. Customer WebSocket 线上验证

入口：

```text
ws://127.0.0.1:8000/ws/customer?tenant=cinnox&source=<source>
```

第一次探针被线上协议校验拒绝，原因：

- frame `id` 必须是 UUIDv4。
- `ts` 必须是毫秒精度 UTC ISO8601，例如 `2026-04-15T10:30:00.123Z`。

按协议修正后重试通过。

收到帧：

```json
{
  "type": "server_hello",
  "payload": {
    "viewer_role": "customer",
    "brand_name": "CINNOX",
    "server_capabilities": ["v1"]
  }
}
```

随后收到 agent 欢迎消息：

```text
您好，我是 CINNOX 的 AI 助手。请问需要帮您了解哪方面？

Hi! I'm CINNOX AI, your virtual assistant for CINNOX and M800 products. How can I help you today?
```

发送 customer message：

```text
Hello, what is CINNOX?
```

收到：

- `ack`
- `message_confirm`

`message_confirm` 包含：

```json
{
  "conversation_id": "web_e2e_online_text_45d1382d",
  "sequence_number": 2
}
```

结论：线上 customer WS 协议、握手、欢迎消息、客户消息持久化确认均通过。由于本轮只等待到 `message_confirm` 和已有 agent 欢迎帧，没有等待完整后续 AI 答复，因此文本会话状态标为 `E2E-PASS(handshake+send+confirm)`。

## 6. Voice 线上验证

voice backend-info：

```json
{
  "backend": "doubao",
  "tts_url": "https://openspeech.bytedance.com/api/v3/tts/unidirectional",
  "asr_ws_url": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
  "asr_resource_id": "volc.bigasr.sauc.duration",
  "asr_language": "en-GB",
  "tts_voice": "auto(en=en_female_sarah_mars_bigtts,zh=zh_female_cancan_mars_bigtts)"
}
```

WebSocket：

```text
ws://127.0.0.1:8000/ws/voice?tenant=cinnox&conversation_id=<conv>&source=e2e_voice_probe
```

发送 start frame：

```json
{"type": "start", "mode": "split", "greeting": "Hello, this is a voice connection probe."}
```

收到：

```json
[
  {"type": "state", "state": "connecting"},
  {"type": "state", "state": "greeting"}
]
```

并收到：

```json
{
  "bytes_frames": 3,
  "bytes_total": 25472
}
```

结论：线上 voice split 模式 WebSocket、TTS greeting 音频返回链路通过。该验证没有发送真实麦克风音频，因此 ASR 真实转写仍未覆盖；但比本地 `backend-info` 更强，可标为 `VOICE-TTS-E2E-PASS / ASR-NOT-RUN`。

## 7. 和本地第二轮的差异

| 项 | 本地第二轮 | 线上本轮 |
| --- | --- | --- |
| git rev | 本地工作区 | `8f09bbdf` |
| pool | 4 warmup / max 5 | 10 warmup / max 50 |
| KB sources | 19 | 170 |
| release versions | v1-v16 | v1-v20 |
| active conversations | 145 | 408 |
| SLA summary | 本地本轮产生 1 条 first reply | 线上当前窗口 count 0 |
| Dream runs | 本地有历史 runs | 线上 `cinnox` 当前返回空 |
| Voice | 本地缺 `socksio`，TTS warmup 部分失败 | 线上 split greeting 返回音频 bytes |

## 8. 综合结论更新

线上验证后，核心状态应更新为：

| Scenario | 状态 |
| --- | --- |
| Admin 真实登录 | E2E-PASS |
| Admin KB source 只读 | E2E-PASS |
| Admin versions 只读 | E2E-PASS |
| Operator 真实登录 | E2E-PASS |
| Operator active conversations | E2E-PASS |
| Customer WS handshake/send/confirm | E2E-PASS |
| Voice split greeting TTS | E2E-PASS |
| Voice ASR 麦克风转写 | NOT-RUN |
| Attachments | 未在本轮线上测试，仍沿用本地 tenant disabled 结论 |
| Publish/Rollback/Admin settings | 按约束未测试 |

对 ezagent 评估的影响：

- AutoService 的 customer/operator/admin 三端核心会话能力已经有线上真实证据，不应再按“仅代码存在”处理。
- Voice 至少线上 TTS greeting 链路可用；ezagent 若要复现 voice，需要补媒体 WS、ASR/TTS adapter、音频帧处理，而不是只做文本 session。
- 线上 KB/release 数据规模大于本地镜像，ezagent 的 KB manager 和 release governance 评估应按线上规模估算复杂度。

