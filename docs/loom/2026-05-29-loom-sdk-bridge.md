# Loom SDK 桥 — 生成页 ↔ loom session 双向通道 设计 spec

- **日期**:2026-05-29
- **状态**:设计已定,待实现
- **父 spec**:`docs/loom/2026-05-29-frontend-plugin-integration.md`(前端托管 + WebPlug + `/loom/api/chat`)
- **历史参考(已废弃架构)**:`docs/loom/SDK.md`(`@ezagent/session-sdk` 的 bootstrap + Phoenix-Channel mirror 模型,已随大迁移拆除,勿照搬)

---

## 0. 一句话

把注入 Sandpack 沙箱的 `/platform.js`(当前是 `sendMessage` 桩)做成**真的 SDK**:让 AI 生成的页面能**以临时用户身份给所属 loom session 发消息(自动 @编排器)、实时同步 session 全部消息、拉取历史消息**。传输用 **postMessage 桥**(沙箱 ↔ 宿主页)+ **宿主页同源 fetch/SSE**(宿主页 ↔ ESR),免 CORS、免 token。并更新页面生成系统提示词,让 page-gen AI **知道**这些能力、**自主选择**在合适的页面里调用。

## 1. 背景 / 为什么这么设计

- 生成页跑在 **Sandpack 的 iframe** 里,与 ESR **跨源**;但**宿主页**(`/loom/:ws/:sid`,由 `EzagentPluginLoom.WebPlug` 提供)与 ESR **同源**。
- 因此最优雅的双向通道 = 沙箱 sdk.js 用 `postMessage` 跟宿主页通,宿主页(同源)再 `fetch`/`SSE` 跟 ESR 通。ESR 端点只对同源开放(不开 CORS,更安全),宿主页持有唯一一条 session 连接。
- 这是父 spec §10 "platform-sdk 维持桩 / 耦合 deferred" 那一步的兑现。

## 2. 已定决策

| # | 决策 |
|---|---|
| **C1** | 三个能力:`sendMessage({text})`、`onMessage(cb)`(全量实时)、`getHistory()`。**不做** parseSpan / getContext / onStatus(YAGNI)。 |
| **C2** | 传输 = **postMessage 桥 + 宿主页同源 fetch/SSE**。沙箱不直连 ESR、不碰 CORS/token。 |
| **C3** | 接收用 **SSE**(`text/event-stream` + Plug `chunk`),不用 WS。 |
| **C4** | 发消息身份 = **每 session 稳定临时用户** `entity://user/:ws/loomui_<sid>`(provision-or-reuse + 自动 join),`mentions:[编排器]`(否则 mention-gated 路由不触发编排器)。 |
| **C5** | `onMessage` 收**全量**(用户自己 + 编排器 + worker,含自己刚发的回显);生成页按 `id` 去重。 |
| **C6** | 系统提示词不仅**列** API,还给**何时用/不用**的判断指引 + 参考范式,让 AI 自主决定。 |

## 3. 架构 / 数据流

```
[沙箱:生成页]  sdk.js  (= 注入的 /platform.js)
   sendMessage / getHistory  ──postMessage RPC(correlation id)──┐
   onMessage(cb) 订阅         ◀──postMessage 推送───────────┐    │
                                                            │    ▼
[宿主页 /loom/:ws/:sid]  LoomBridge(从 location.pathname 取 ws/sid)
   send    → fetch POST /loom/api/:ws/:sid/messages ────────┼────┐
   history → fetch GET  /loom/api/:ws/:sid/history          │    │ (同源)
   (挂载即) EventSource /loom/api/:ws/:sid/stream ──收帧→推回沙箱┘   │
                                                                  ▼
[ESR EzagentPluginLoom.WebPlug]
   POST .../messages → 临时用户 + @编排器 → 投进 session
   GET  .../history  → 读消息历史 → JSON [frame]
   GET  .../stream   → 订阅 session PubSub → SSE 推全量
        │ dispatch
        ▼  [loom session → 编排器/worker]   （回复经 stream 流回 → 桥 → onMessage）
```

## 4. 组件与边界

| 单元 | 位置 | 职责 | 依赖 |
|---|---|---|---|
| **`sdk.js`** | 沙箱注入(替换 `lib/sandbox/platform-sdk.ts` 桩;在 Desktop 前端仓库改) | 暴露 3 函数;内部全 `window.parent.postMessage`。send/history 用 correlation id 做 Promise 请求/响应,onMessage 注册回调、收 parent 推送 | 无(纯浏览器) |
| **`LoomBridge`** | 宿主页(ai-ui-builder,新模块,在 Desktop 前端仓库) | 监听沙箱 `message` 事件 → 同源 fetch/SSE 打 ESR;挂载时开 `EventSource` 把帧 postMessage 回沙箱 iframe;从 URL 取 ws/sid | 无 |
| **WebPlug 新端点** | loom plugin `lib/ezagent/web_plug.ex` | 3 个 session-scoped 端点(见 §6);SSE 路由 + history 路由必须排在 SPA 兜底 `get "/*_path"` **之前** | DeepSeek 之外:Invocation/PubSub/消息历史(domain) |
| **临时用户 helper** | loom plugin(扩 `TempUser` 或新 helper) | provision-or-reuse `loomui_<sid>` + join session | TempUser/Invocation |
| **`page_gen_system_prompt`** | loom plugin `Prompts` | 改写 `./platform` 那段:3 函数契约 + 何时用指引 + 参考范式 | — |

## 5. 帧结构(send ack / onMessage / history 统一)

```ts
{ id: string, sender: string, role: "user"|"agent"|"unknown", body: string, refId: string|null }
```

- `body` 不透明字符串(编排器卡 JSON / 文本)。生成页自己决定怎么渲染。
- `role` 由 `sender` 的 URI 类型推导(`entity://user/...`→user,`entity://agent/...`→agent)。
- `refId` = wire 的 `ref_id`(worker 回复 ↔ 编排器派发对应)。

## 6. ESR 端点契约(WebPlug,`/loom` 前缀被 forward 剥掉)

> 同源调用,无 CORS;无鉴权(同 `/loom` 现状,见父 spec §10)。

**`POST /api/:ws/:sid/messages`**  body `{ "text": "..." }`
- 拼出 `session_uri = session://loom/<ws>/<sid>`;ensure 临时用户 `loomui_<sid>` + join;解析 session 成员里的编排器(`loomorch_*`);以临时用户身份 `dispatch` `chat.send`(或 session 的发送 action),`mentions:[orchestrator]`。
- → `200 {ok:true, id}` / `{ok:false, error}`(无编排器 / dispatch 失败 / session 不存在)。

**`GET /api/:ws/:sid/history`**
- 读该 session 的消息历史(同 AdminLive `load_session_messages/1` 的来源),映射成 `[frame]`。
- → `200 [frame, ...]`;无消息或 session 不存在 → `200 []`(生成页一律按"空历史"处理,不分支)。

**`GET /api/:ws/:sid/stream`** (SSE)
- `content-type: text/event-stream`、`cache-control: no-cache`、`send_chunked(200)`。
- 订阅该 session 的 PubSub(同 AdminLive 用的 `session_events_topic/1` → `{:chat_message, session_uri, %Ezagent.Message{}}`);每条 → `chunk(conn, "data: " <> json(frame) <> "\n\n")`。
- 周期性心跳注释(`": ping\n\n"`)保活 + 探测断开;`chunk` 返回 `{:error,_}` → 结束。

## 7. 系统提示词更新(C6 — 让 AI 自主用)

把 `page_gen_system_prompt` 里"平台能力:发送消息"那段从"只讲 sendMessage 桩"扩成三函数,并保留"判断该不该用"的风格:

- **契约**:`import { sendMessage, onMessage, getHistory } from './platform'`,各自签名 + 返回。
- **何时用**(指引,让 AI 自己判断):
  - 页面需要**把用户输入送进平台 / 跟编排器对话**时 → 用 `sendMessage` + `onMessage`(+ 进入时 `getHistory` 回填)。例:客服/咨询窗、服务申请表、对话式表单。
  - **纯展示页**(画个奥特曼、落地页)→ 不要引入。
- **参考范式**:一个"输入框 + 消息列表"的最小对话页(`getHistory` 回填 → `onMessage` 追加 → `sendMessage` 发送 + loading/错误反馈),强调"按用户需求调整 UI,别照抄"。

## 8. 错误处理

- `sendMessage`:后端 `{ok:false,error}` → sdk.js 的 Promise **正常 resolve** 出该对象(不 reject),生成页据 `ok` 反馈。
- postMessage RPC:correlation 超时(如 30s)→ resolve `{ok:false, error:"timeout"}`。
- SSE:宿主页 `EventSource` 自带重连;session 不存在 → 端点关闭,桥简单重试(v1 不做复杂退避)。
- 沙箱 onMessage 回调抛错 → 桥/ sdk 包裹 try/catch,不影响后续帧。

## 9. 测试

- **WebPlug**(`web_plug_test.exs` 扩展):
  - `POST .../messages`:验证 ensure 临时用户 + `mentions:[编排器]` + dispatch 调用(dispatch 可注入/mock);无编排器 → `{ok:false}`。
  - `GET .../history`:无消息 → `[]`;有消息 → 帧映射正确。
  - `GET .../stream`:建立后注入一条 PubSub 消息 → 收到一个 `data:` 帧(用测试 PubSub broadcast)。
- **sdk.js + LoomBridge**:纯前端,浏览器手动 e2e —— 让 AI 生成一个"对话页",`sendMessage` → `onMessage` 收到编排器回复,刷新页 `getHistory` 回填。

## 10. v1 不做(未来)

WS(用 SSE)、parseSpan、getContext、onStatus、presence、文件上传、调用特定 agent、鉴权、版本协商。多 session 聚合 / 历史浏览也不做。

## 11. 改动范围小结

- **Desktop 前端仓库**:`platform-sdk.ts` 桩 → 真 `sdk.js`(postMessage 客户端)+ 新 `LoomBridge`(宿主页接线)+ `PreviewPanel` 注入真 SDK + 重 build 覆盖 dist(同父 spec 的 dist-only 流程)。
- **loom plugin**:WebPlug 加 3 端点 + 临时用户 helper + `Prompts` 提示词改写。
- **ESR 核心**:**0 改动**(仍只有父 spec 那 1 行 forward;新端点都在 WebPlug 内)。
