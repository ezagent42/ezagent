# 平台前端 SDK 规格(`@ezagent/session-sdk`,包名待定)

> 状态:规格蓝本(未抽包)· 日期:2026-05-28
> 配套:`TEMPLATE_DESIGN.md` §2(SDK 是「省心的那道缝」)。本文档把那一节展开成可实现的 SDK 规格。
> 现状:雏形已存在 = 前端 `studio-mobile/src/session.js`(phoenix.js + bootstrap + 镜像)。抽成 npm 包 + 钉死契约 = 本文档的目标。

---

## 1. 定位:SDK 是什么

一句话:**SDK 是「会话镜像」的 JS 客户端**——开发者 `import` 它,就能把一个 ESR session 的实时消息流接进自己的前端,并往里发言;**传输 / 鉴权 / 重连 / 持久化全被它藏起来**。

它在三方所有权里的位置(见 `TEMPLATE_DESIGN.md` §0):

```
[平台 ESR 运行时]  ←wire 契约→  [SDK(平台发)]  ←API→  [开发者前端(UI/组件/渲染)]
```

- **SDK = wire 契约的载体**:契约一变,bump SDK 版本,而不是让开发者已 build 的 dist 静默全废。
- **SDK 把 Phoenix Channel / phoenix.js 变成内部细节**:开发者不 import phoenix.js、不知道有它。将来换 SSE / 裸 WS 也只动 SDK,开发者无感。

---

## 2. SDK 能做什么(能力)

| 能力 | 说明 |
|---|---|
| **建/复用会话(bootstrap)** | 调 `POST /bootstrap`,拿 `session_uri` + `ws_token` + `ws_url`。自动从本地存储复用上次的 `session_uri`(返客重入);失效则开新会话。 |
| **接入实时消息流** | 连镜像通道,订阅该 session 的**全部**消息;每条消息回调一帧给开发者。包含用户自己、编排器、worker 的消息(debug 期全推,可观测编排过程)。 |
| **发言** | `send(text)`:以 bootstrap 拿到的临时身份发一句;服务端推导发件人 + 自动 @编排器(mention-gated 路由),无须开发者关心路由。 |
| **自动重连 + 心跳** | 断线自动重连;token 过期时自动重新 bootstrap 续连。开发者只收到状态回调,不用自己写重连。 |
| **会话持久化 / 重入** | `session_uri` 存本地;刷新 / 重开页面接回同一会话(配合 ESR 端 session 仍存活)。 |
| **`parseSpan` 解析助手** | 把不透明的 `body` 字符串解析成 `{ type, props }`(提取首个 JSON 对象)。**只解析,不渲染**——认不认、怎么画是开发者的事。非卡片正文返回 `null`,开发者按纯文本处理。 |
| **状态 / 错误回调** | `onStatus` / `onError`,暴露 `connecting / open / reconnecting / closed` 与连接错误。 |
| **版本协商** | SDK 携带契约版本号;与平台 ESR 的 wire 版本不兼容时显式报错(而非静默错乱)。 |
| **平台浮窗按钮(FAB)** | 可选注入页面右下角一个**平台通用**固定按钮 → 打开平台提供的浮窗面板(默认 = 会话观测窗,见 §4.5)。样式可定制、可关闭;是 SDK 唯一会渲染的 UI。 |

---

## 3. SDK 不做什么(边界 / 非目标)

**刻意不做的(归开发者):**
- **不渲染你的业务 UI**:不带业务组件、不带样式。`onMessage` 给你数据,画成什么样、用什么框架,全是你的前端。**唯一例外**:可选的平台浮窗按钮 / 面板(§4.5)——那是 ESR 平台通用控件(非你的业务卡片),默认关、可定制、可关闭。
- **不定义 `type → 组件` 映射**:`parseSpan` 给你 `type`,映射到哪个组件由你决定。
- **不定义卡片词汇 / prompt**:有哪些 `type`、什么场景出什么卡,是**服务端 plugin 里的 prompt**(开发者配),不在 SDK。

**做不到的(架构边界):**
- **不运维 / 不部署 ESR**:SDK 是纯前端库;ESR 由平台跑(见 `TEMPLATE_DESIGN.md` §0.5)。
- **不改 agent 行为**:编排 / worker 逻辑在 plugin 的 Elixir 里,SDK 碰不到。
- **不保证 `body` 是卡片**:`body` 是**不透明字符串**(可能是 `<span>` 卡、markdown、纯文本)。`parseSpan` 解析不出就返回 `null`,开发者必须有纯文本 fallback。
- **不提供真实登录身份**:当前 bootstrap 只 mint **匿名临时用户**。真实账号体系是平台待决策项(`TEMPLATE_DESIGN.md` §6),SDK 现阶段不覆盖。
- **仅 JS**:面向 Web 前端(React / Vue / Svelte / 原生 JS 皆可)。非 JS 客户端(原生 App 等)需直接对接 §5 的裸 wire 契约,不经 SDK。
- **不做业务编排**:不缓存对话做摘要、不做多 session 聚合视图等——那是产品逻辑,开发者自理(可 new 多个实例)。

---

## 4. API

### 4.1 创建与生命周期

```js
import { createSession } from '@ezagent/session-sdk';

const session = createSession({
  base: 'https://app.example.com', // 平台分配给该 plugin 的源(bootstrap + ws 都在此源)
  persona: 'visitor',              // 可选:persona 提示,传给 bootstrap
  storageKey: 'xy:session',        // 可选:本地存储键(默认按 base 派生),用于复用 session_uri
  autoReconnect: true,             // 可选,默认 true
});

await session.connect();  // bootstrap + 开镜像通道;join 成功后 resolve
session.close();          // 主动断开
```

### 4.2 收消息

```js
const off = session.onMessage((frame) => {
  // frame = { sender, role, body, id, refId }
  const card = session.parseSpan(frame.body); // { type, props } | null
  if (card) renderCard(frame, card);          // 你的组件
  else renderText(frame, frame.body);         // 纯文本 fallback
});
// off() 取消订阅
```

**帧结构 `frame`:**

| 字段 | 类型 | 含义 |
|---|---|---|
| `sender` | string | 发件人 URI(如 `entity://user/...`、`entity://agent/...`) |
| `role` | `"user" \| "agent" \| "unknown"` | 由 sender 推导的角色,方便区分气泡左右 |
| `body` | string | **不透明正文**(span 卡 / markdown / 纯文本) |
| `id` | string | 消息 id |
| `refId` | string \| null | 关联的上游消息 id(worker 回复 ↔ 编排器派发的对应关系);wire 原始字段名 `ref_id` |

### 4.3 发言

```js
session.send('我想办理居住证');  // fire-and-forget;回复稍后作为 frame 流回
```

### 4.4 状态 / 错误 / 解析

```js
session.onStatus((s) => {/* 'connecting'|'open'|'reconnecting'|'closed' */});
session.onError((e) => {/* 连接 / bootstrap 错误 */});

session.parseSpan(body); // → { type: string, props: object } | null
session.sessionUri;      // 当前 session_uri(只读)
```

### 4.5 平台浮窗按钮(FAB · 可选)

SDK 可在页面右下角注入一个**平台通用**固定按钮,点开一个平台提供的浮窗面板。它跟开发者的业务 UI 无关——是 ESR 给每个 app 的「通用能力插槽」。默认**关闭**,一行开启:

```js
createSession({
  base,
  fab: {
    enabled: true,
    panel: 'inspector',        // 打开哪个平台面板(见下);默认 'inspector'
    position: 'bottom-right',  // 默认右下角
    theme: { /* 可选:配色 / 图标,跟你的站点融合 */ },
  },
});
// 或运行时:session.fab.show() / .hide() / .toggle()
```

**为什么这东西该由 SDK / 平台提供(而非开发者自造):** 它打开的内容是 **ESR 运行时层**的通用信息(路由 / 连接 / 会话),格式是平台的 wire 概念,不是开发者的业务。每个 ESR app 都想要、且都长一样 → 收进 SDK 最合适。

#### 推荐首发面板:会话观测窗(Session Inspector)🔍

点按钮 → 滑出一个面板,把**路由层在干什么**摊开给开发者看(debug / 演示):

- **原始消息流**:每帧 `sender / role / body / id / ref_id`,与业务卡片并行(业务前端只渲染漂亮卡片,这里看底层全量)。
- **本轮编排轨迹**:用户提问 → 编排器**派发**了哪几个子任务 → 哪些 worker **回了**(按 `ref_id` 对应)→ 聚合 / 超时 → **组合**成卡。一条龙可视化。
- **健康信号**:每段时延、span `type`、有没有 worker 超时未回(partial 卡)、有没有消息没人接(unroutable / DLQ)。
- **会话元信息**:`session_uri`、当前临时用户、连接状态。

**为什么它最贴 ESR:** ESR 是 *router* 不是 req/resp app(`CLAUDE.md`),身份就是 dispatch → fan-out → aggregate + telemetry + DLQ;「这条 message 没人接收,谁会知道」是 ESR 特有的认知负担。一个通用观测窗正好把这层暴露出来——每个 ESR app 开发者调试时都想要,且别人造不如平台造。

#### 其他候选(可换成其一,或并存为多面板)

| 面板 | 干什么 | ESR 通用性 |
|---|---|---|
| **新会话 / 重置** | 一键开新房间(新临时用户 + 新 session),返客常用 | 高,极简 |
| **连接状态胶囊** | online / reconnecting / offline + 手动重连 | 高(每个 WS app 都要) |
| **反馈 / 评价** | 对某条回复打标 → 落 telemetry,喂回平台质量监控 | 中(偏产品) |
| **会话历史** | 列出 / 重入本地存过的历史 session | 中 |

> **待定**:首发面板 = 观测窗(本文档示例),其余作为后续内置面板按需加。`panel` 取值是平台维护的枚举,加新面板 = SDK 升级。

---

## 5. 底层 wire 契约(SDK 封装的就是这层 · 版本化)

> 开发者**不直接用**这层;列出是为了:① 非 JS 客户端对接;② SDK 实现依据;③ 契约版本对照。**契约变 = bump SDK 版本。**

**① bootstrap**
```
POST {base}/bootstrap
body: { "persona": "visitor", "session_uri": "<上次的,可省略>" }
→ 200 { "ok": true, "session_uri": "...", "user_uri": "...",
        "ws_url": "...", "ws_token": "..." }
```

**② 镜像通道(当前实现 = Phoenix Channel,SDK 内部用 phoenix.js)**
- Socket 端点:`{ws_url}`(形如 `wss://app.example.com/session_socket`),连接参数 `{ token: ws_token }`
- Topic:`session:mirror:<session_uri>`(topic 内 session 必须 == token 绑定的 session,否则拒绝)

**③ 收(channel event `"message"`)**
```json
{ "sender": "...", "role": "user|agent|unknown",
  "body": "<不透明字符串>", "id": "...", "ref_id": "...|null" }
```

**④ 发(channel push `"say"`)**
```
push "say" { "text": "..." } → ack :ok（仅确认收到;真正回复走 message 帧异步流回）
```

> 注:`"say"` 立即 ack,是因为编排耗时(~15s)远超 phoenix.js 默认 10s push 超时;真正的卡片作为后续 `message` 帧到达。SDK 把这个细节藏掉,开发者只管 `send` + `onMessage`。

---

## 6. 怎么给别人用

### 6.1 安装

```bash
npm i @ezagent/session-sdk
```

(或随模板 plugin 一起分发一份 pinned 版本。)

### 6.2 最小集成(任意框架)

```js
import { createSession } from '@ezagent/session-sdk';

const session = createSession({ base: location.origin }); // dist 与 ESR 同源时
session.onMessage((frame) => {
  const card = session.parseSpan(frame.body);
  // ↓↓↓ 开发者自己的渲染层 ↓↓↓
  card ? mountComponent(card.type, card.props) : mountText(frame.body);
});
await session.connect();

inputEl.onsubmit = () => session.send(inputEl.value);
```

开发者要写的**只有**:`type → 组件` 的映射 + 各组件长什么样。

### 6.3 打包 + 进 plugin(交付链路)

1. 用任意 JS 栈写 UI,接 SDK(上面);
2. 在服务端 plugin 里配卡片词汇 prompt(决定 LLM 吐哪些 `type`,与你的组件配套);
3. `vite build` → `dist`;
4. `dist` 塞进 plugin 的静态插槽 → **把 plugin 交给平台审核 + 部署**(见 `TEMPLATE_DESIGN.md` §0.5 / §8)。

**同源即免 CORS**(dist 与 ESR 同源 serve);本地 dev 跑独立端口 + HMR 时是跨源,平台 dev 配置放行。

---

## 7. 版本与兼容

- **SDK 版本 ↔ wire 契约版本**绑定。平台 ESR 升级 wire(改帧结构 / bootstrap 形状)→ 发新 SDK 大版本 + 兼容矩阵;旧 dist 锁旧 SDK 仍可用,直到平台下线旧契约。
- SDK `connect()` 时做版本协商,**不匹配显式抛错**(不静默错乱)。
- 开发者**pin SDK 版本**;升级 = 重 build + 重新交 plugin(走部署周期)。

---

## 8. 现状 → 待办

| 项 | 现状 | 待办 |
|---|---|---|
| 传输 / bootstrap / 收发 | 已在 `studio-mobile/src/session.js` 跑通(phoenix.js) | 抽成独立 npm 包,API 收敛成 §4 |
| `parseSpan` | 前端 App.jsx 内联解析 | 移进 SDK,作为公开 helper |
| 重连 / 心跳 / token 续期 | 部分(phoenix.js 自带重连) | 补 token 过期重 bootstrap |
| 版本协商 | 无 | 加契约版本号 + `connect()` 校验 |
| 包名 / 发布 | 未定 | 定名 + 发布渠道(npm / 随模板) |

> 实施顺序见 `TEMPLATE_DESIGN.md` §7「模板化一期」①:抽共享 behaviors 库 + **SDK 发布**。本文档 = 该步的前端契约依据。
