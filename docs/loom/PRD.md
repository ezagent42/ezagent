# Hello PRD — 每访客一 session 的多 agent 编排 + 浏览器实时镜像

> 状态：Draft · 日期：2026-05-27
> 性质：**产品/集成 PRD**,不改 `ARCHITECTURE.md`。运行时原语沿用现状;新增的 browser-user 模板与 session 镜像 WS 若触及架构,走 Allen review。

---

## 1. Executive Summary

我们在 ESR(Ezagent,多 agent 消息路由运行时)上做「Hello」:每个网页访客开页面即得一个专属 session,房间里 1 个**编排器 agent** + 2 个 **worker agent**;访客只跟编排器对话,编排器**每轮把意图拆解、并发派给 worker、收齐交付物后组合**成一张卡片回复;前端通过 **WebSocket 实时镜像**该 session 的全部聊天,该 session 同时**单向镜像到飞书群**。

**这是一个平台能力 demo**——目标是证明「ESR 能在一个真实 session 里原生编排多个 agent(拆解→并发派发→聚合→回复)」。访客的孵化器咨询旅程只是承载这次编排的载体,不是给孵化器看的业务产品。

---

## 2. Problem Statement

### 谁有这个问题
ESR 团队自己——需要一个**可演示、可观察**的证据,证明平台的多 agent 编排原语(dispatch / Kind / Behavior / Generator / 路由 / ExternalMirror)在「一个 session 多 agent + 编排器」这一原生场景下真的串得起来。

### 问题是什么
当前前端接入方式(`POST /api/v1/hello/say`,请求/响应,单 agent 直接出 `<span>` 卡片)把前端**硬接到单个 agent**,**绕过了 session**。后果:
- ezagent 会话视图里看不到这轮对话;
- 飞书同步只能靠 `:say` 内部旁路回写;
- **完全无法展示「编排器调度多个 worker」**——而这正是平台的核心卖点。

### 为什么痛
平台的差异化价值(原生多 agent 编排)**目前没有任何活的、看得见的证据**。当前的单 agent 请求/响应接入反而把前端做成了一个「绕过平台模型」的反例。

### 证据
- 现状代码 `hello.ex` 的 `:say` 是单 agent、单次 DeepSeek 调用、前端塞 history——典型 req/resp,不经 session(`apps/ezagent_plugin_hello/lib/ezagent/behavior/hello.ex`)。
- 飞书同步靠 `maybe_mirror_to_session/4` 内部旁路(同文件)。
- 编排原语已存在但无端到端演示:cc-orchestrator 的 7 个工具是**装配期**的,不含运行时聚合(`apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex`)。

---

## 3. Target Users & Personas

| 角色 | 在这次 demo 里的位置 | 备注 |
|---|---|---|
| **平台评审者 / 团队**(主要受众) | demo 的真正观众:盯着调试期全展示的消息流,看「拆解→并发派发→聚合」真实发生 | 承重点在这里 |
| **网页访客**(载体角色) | 开页面→进专属 session→跟编排器对话→看卡片走一遍孵化器咨询旅程 | 4 persona:visitor/invited/resident/internal |
| **编排器 agent(Hello)** | session member;每轮拆解→派 worker→组合→回用户 | DeepSeek 脑 |
| **worker agent ×2** | session member;接子任务→产内容片段→回编排器 | 政策侧 / 企业侧(主题分工,业务细节后续再定) |
| **飞书群成员** | **只看不回**:镜像观察该 session 全部聊天 | 单向 |

> JTBD(主要受众):"当我要判断 ESR 的多 agent 编排是否落地,我想看到一个真实 session 里编排器并发调度 worker 并聚合出结果的活演示,这样我才能确信平台模型成立,而不是只看架构文档。"

---

## 4. Strategic Context

### 为什么现在
平台编排原语已基本就位(路由/Generator/ExternalMirror/PubSub 底座),但**从未端到端跑通过「运行时编排」**。在投入真实业务产品前,先用最小代价证明编排链路闭环——避免在业务 PRD 里才发现运行时聚合根本没人写过(G-D 风险)。

### 范围定位
平台能力 demo,不是业务产品 demo。因此:
- worker 只需**最薄主题分工**即可证明编排,业务角色(政策/企业/表单/审批四件套)留待后续业务 PRD;
- 「调试期全展示 worker 过程」**就是产品本身**(证据来源),不是临时调试便利;
- 内容由 LLM 合理虚构,**不接真实业务数据**。

### 约束
- 不改 `ARCHITECTURE.md`(架构决策走 Allen review)。
- 本环境**无 `claude` 二进制** → 编排器/worker 用 **DeepSeek 脑**,不用依赖 claude 的 cc-orchestrator。
- 沿用现有鉴权(PAT + `X-Ezagent-Entity-URI`);前端访客用短期 `ws_token`。

---

## 5. Solution Overview

前端退化为「一个 session 的实时镜像视图」,所有智能在 ESR 侧。四条数据流,运行时原语全部复用现状(守 P14:Kind 间只走 dispatch)。

### 5.1 开页面 → 建/复用 session(G-C)
浏览器 `POST /bootstrap`(带 origin 校验/一次性 nonce)→ ESR:① 实例化临时 browser user(`entity://user/<ws>/tmp_<id>`);② 用 Generator 从 SessionTemplate 幂等装配团队 `members = {tmp_user, 编排器, worker-policy, worker-company}` + **定向路由规则** + caps;③ tmp_user join。返回 `{session_uri, ws_url, ws_token}`,前端**保存** `session_uri`。重入带 `session_uri` 回来 = 复用同一(还活着的)session。

### 5.2 前端 ↔ session 实时镜像 WS(G-B)
前端用 `ws_token + session_uri` 连镜像 Socket → 服务端校验 token、**绑定 tmp_user 身份(sender 服务端推导,不可伪造)** → 订阅 `session_events_topic` → 每条新消息推一帧。前端发言 = 服务端以 tmp_user 身份 `chat.send`(经 dispatch,**镜像 WS 只读、不作 inbound 通路**)。**调试期推全部消息(含编排器↔worker 过程)。**

### 5.3 session 内编排(G-D,核心)
```
tmp_user ─chat.send(只到编排器)─▶ 编排器 :receive
  ① 派发段(DeepSeek):吐 {"dispatch":[{to,task},...]},N=数组长度;解析失败→编排器直接答(降级)
  ② :cast 并发 @worker-policy / @worker-company(各带子任务,记 ref_id)
  ③ worker 各产内容片段 ─chat.send(只回编排器, ref_id 指回子任务)─▶
  ④ 收齐 N 或超时 → 组合段(DeepSeek)揉两段 → normalize/1 出唯一 <span> → chat.send 回用户
```
- **组件化由 `normalize/1` 做**(确定性 inferType + 兜底降级),不另设 worker。
- **聚合(方案 B)**:编排器 slice 存「待聚合状态(按 turn)」+ 定时器(`handle_kind_message` 接);超时把已到交付组合成「部分结果」降级卡,**经 `Invocation.dispatch` 自发**回用户——绝不静默卡死。

### 5.4 session → 飞书(单向,自动)
session 绑定飞书群后,任何落进 session 的消息(用户/编排器/worker)被 `ExternalMirrorWorker` **自动镜像**到飞书——零编排器侧代码。**只看不回**,不做飞书→inbound。

### 5.5 前端渲染契约
编排器给用户的回复永远是单个 `<span type="X">{json}</span>`(type ∈ text/notice/services/detail/companies/steps/form/choices/application/intent);前端按 type 渲染,`actions` 点击 = 以 tmp_user 身份发新消息驱动多轮;未知 type 降级 text,不可崩。**不做 token 流式,整条消息推。**

---

## 6. Success Metrics(demo 验收 = 主指标)

平台 demo 的「指标」是验收门,不是业务转化。

### 主验收门(必须全绿)
1. 一个访客开页面 → 自动得到含 {tmp_user, 编排器, 2 worker} 的 session,WS 连通。
2. 用户发一句 → 调试流里**可见**编排器并发派发两条子任务 + 两条 worker 交付 + 一张组合卡(证明编排真实发生)。
3. 卡片 100% 是合法单 span(含降级路径)。
4. 全部消息单向镜像进飞书群。

### 次要观测
- 每轮 LLM 调用次数 = 派发 1 + worker N + 组合 1(N=2 时共 4 次);端到端延迟可接受(无流式,见 §9 成本账)。
- 重开 = 复用同一 session + 前端本地全文渲染,不新建房间。

### 护栏指标(不可回退)
- 无 silent drop:任何投递点失败都有 telemetry/DLQ/降级卡。
- worker 之间零 cross-talk(无消息风暴)。

---

## 7. User Stories & Requirements

### Epic Hypothesis
我们相信:把前端从「单 agent req/resp」改为「一个 session 的实时镜像 + 运行时编排器调度 2 个 worker」,能在不改架构的前提下**端到端证明 ESR 的多 agent 编排闭环**,因为现有原语(路由/Generator/ExternalMirror/PubSub)已就位、缺的只是运行时编排行为(G-D)与对外通道(G-B/G-C)。验收 = §6 主验收门全绿。

### 缺口即 Story(带验收标准)

**G-A — browser temp user 模板 + 生命周期**
作为系统,我要为每个访客实例化一个临时用户并在会话级隔离它。
- [ ] 从模板实例化 `entity://user/<ws>/tmp_<id>`,自动 join 目标 session。
- [ ] 隔离单元 = session:该用户只能经其 `ws_token` 访问绑定的 `session_uri`。
- [ ] 兜底清理:无活动 N 小时的 tmp_user/session 被 terminate(放弃永不回收)。

**G-B — 浏览器 session 镜像 WS**
作为前端,我要实时订阅一个 session 的全部消息。
- [ ] 连接校验 `ws_token` → 绑定 `session_uri` + tmp_user 身份(server-derived,不可伪造)。
- [ ] 订阅 `session_events_topic`,每条新消息推一帧 `{sender, role, body}`。
- [ ] 只读:不作为 inbound 通路(发言走 `chat.send` dispatch)。
- [ ] 调试期推全部消息;隐藏 worker 过程列入 Out of Scope。

**G-C — bootstrap 端点**
作为前端,开页面时我要建/复用一个 session。
- [ ] `POST /bootstrap` 带 origin 校验/一次性 nonce。
- [ ] 首次:实例化 tmp_user + Generator 幂等装配团队,返回 `{session_uri, ws_url, ws_token, user_uri}`。
- [ ] 重入:带已存 `session_uri` → 复用同一 session,签发新 `ws_token`。

**G-D — DeepSeek 脑编排器运行时(几乎全新,非复用 `:say`)**
作为编排器,我要每轮拆解→并发派发→收齐→组合。
- [ ] 派发段吐结构化 JSON dispatch;解析失败降级为编排器直接答。
- [ ] worker 花名册从 SessionTemplate 注入进 prompt。
- [ ] `:cast` 并发派发,N = dispatch 数组长度;子任务带 `ref_id`。
- [ ] 待聚合状态在 slice + 定时器;收齐 N 或超时→组合段→`normalize/1`→回用户。
- [ ] 超时出「部分结果」降级卡,经 dispatch 自发,守 P14。
- [ ] 复用边界诚实:仅复用 `deepseek()` HTTP 壳与 `normalize/1`;拆解/派发/聚合/组合逻辑全新。

**G-E — 2 个 worker 的 prompt**:政策侧/企业侧最薄主题分工;接子任务→产内容片段→`chat.send` 只回编排器(`ref_id` 指回);**worker `:receive` 只处理编排器 @ 它的子任务,其余一概忽略(loop-guard)**。

**G-F — SessionTemplate**:声明 members + caps + **定向路由规则**(用户→编排器;worker→编排器;编排器→@mention 定向),**显式覆盖默认 `$session_members` 全员 fan-out**。

**G-G — 测试**:编排器派发/聚合/超时降级、镜像 WS token-auth、bootstrap 建/复用、定向路由不串台、worker loop-guard。

**G-H — 前端 H5**(独立交付物):按 §5.5 协议实现卡片组件 + WS 客户端 + actions 回填 + 本地全文存储/渲染。

### 约束与边界
- 每轮编排器**必须派发**,无直接答旁路(派发段解析失败才降级直接答)。
- 关联 id 复用 `Message.ref_id`(Message envelope 无自定义 metadata 字段)。

---

## 8. Out of Scope

- **生产期隐藏 worker 过程**:本期调试期全展示;生产期改为只展示「用户↔编排器」,过程折叠/隐藏——后续。
- **token 级流式**:WS 推整条消息,不做逐字。
- **重入快照 / 「重起一幕」**:已砍(过早优化)。重开 = 前端渲染本地全文 + WS 重连到还活着的 session;换设备/清缓存 = 当新访客。
- **worker 业务角色四件套**(政策/企业/表单/审批):demo 用 2 个主题 worker;业务细节走后续业务 PRD。
- **动态拉起 worker**:固定模板;运行时改 session 拓扑(`add_agent_slot`)留待后续(触架构,需 Allen)。
- **真实业务数据接入**:LLM 合理虚构。
- **cc-orchestrator / claude 二进制**:本环境无 claude,改 DeepSeek 脑。
- **飞书 → inbound**:单向只看不回。
- **多租户/鉴权体系改造**:沿用现有 PAT;访客用 `ws_token`。
- **持久化上云**:本期本地 SQLite + 简化服务器。

---

## 9. Dependencies & Risks(每条守护对应一个机制)

### 依赖
- **外部**:DeepSeek API(`DEEPSEEK_KEY` + 额度);飞书应用凭据(建议环境变量,勿硬编码)。
- **内部运行时耦合(显式)**:① 编排器 prompt 必须**注入 SessionTemplate 的 worker 花名册**(否则不知道能 @ 谁);② 聚合「收齐或超时」依赖编排器 **slice 待聚合状态 + 定时器**(`handle_kind_message`);定时器不持久化——进程重启即丢(见失败路径)。
- **复用件**:路由/Resolver/RuleStore、Generator、`session_events_topic` PubSub、`normalize/1`、ExternalMirror、WS token-auth 范式。

### 风险与机制化守护
| 风险 | 结构性机制 |
|---|---|
| **越权看他人会话** | 隔离单元 = **session**(不是 workspace);`ws_token` 绑定单一 `session_uri`,服务端只允许订阅对应 topic、sender 服务端推导不可伪造 |
| **聚合丢/挂(worker 不回)** | 方案 B 超时兜底:出「部分结果」降级卡,经 dispatch 自发,绝不静默卡死 |
| **worker 消息风暴 / cross-talk** | G-F 定向路由**覆盖默认全员 fan-out**;worker `:receive` loop-guard 只认编排器 @ 的子任务 |
| **silent drop** | 编排器任何失败回可渲染 error span;每个投递点 telemetry/DLQ |
| **派发段吐脏 JSON** | 解析失败降级为编排器直接答(可渲染),不崩 |
| **bootstrap 裸奔 → 无界增长** | origin 校验/nonce 一道门 + tmp_user/session 兜底清理 |
| **改架构** | browser-user 模板 / 镜像 WS 若需新原语或 Decision → 暂停标 issue 等 Allen |

### 闭环失败路径(走一遍)
- **某 worker 超时**:编排器收齐门到时只到 1 段 → 组合「部分结果」降级卡(标注),用户仍得到可渲染回复。✅
- **半路刷新**:编排器进程没倒 → 待聚合状态还在,旧 turn 正常收口;前端重连后照常收到该 turn 的组合卡(因为不做「重起一幕」,不产生第二个 turn,无孤儿)。✅
- **进程重启**:编排器倒了 → slice 由 `{:snapshot,:on_change}` 恢复,但**内存定时器丢失** → 该 in-flight turn 不会自动超时收口。**缓解**:重启后下一条用户消息触发新 turn 正常;**残留风险**:重启瞬间正在 fan-out 的那一个 turn 可能不出卡——记为**已知限制**(本期可接受,因 demo 单机、重启罕见),不假装已解决。

---

## 10. Open Questions

**真·开放(本期不阻塞)**
- Q-飞书绑定的运维入口:demo 期直接写 `external_mirror_bindings` 行即可,正式入口后续。
- worker 主题分工的最终业务形态(四件套?):待后续业务 PRD。

**已从开放升级为「现在拍板」(原 PRD 的阻塞项)**
- ~~worker 固定还是动态~~ → **固定模板**(动态拉起触架构,后续)。
- ~~聚合机制~~ → **方案 B**(并发收齐+超时降级)。
- ~~重入语义~~ → **不做快照,复用活 session + 前端本地全文**。
- ~~隔离单元~~ → **session 级,token-scoped 订阅**。
- ~~编排器派发 vs 直接答~~ → **必须派发**,仅派发段解析失败才降级直接答。

---

## 附录 A — 14 条系统护栏自查(书面回答)

1. **观众与目的写最前** ✅ §1/§4:平台能力 demo,访客旅程是载体。
2. **每份状态唯一真相来源** ✅ 对话历史 = 服务端 session(ESR 持久化);前端本地全文仅用于显示恢复;编排器记忆读服务端历史。无第二份权威。
3. **不变式↔机制** ✅ §9 表每条守护都连到一个机制(token-scope/方案B/定向路由/降级 span/清理门)。
4. **边界真名** ✅ 写「session 级隔离」,未借 workspace 级。
5. **复用诚实** ✅ G-D 标「几乎全新,仅复用 `deepseek()` 壳 + `normalize/1`」;其余 ✅复用各指明模块。
6. **编排拓扑自洽** ✅ 并发 fan-out + 收齐 N(方案B),非顺序流水线;worker 拆解=并行主题,与聚合同拓扑。
7. **失败可见性** ✅ §6 护栏 + §9:每个投递点 telemetry/DLQ/降级卡;防 cross-talk/风暴。
8. **默认行为对立点出** ✅ §5.3/§7 G-F:默认 `$session_members` 全员 fan-out 与定向投递对立,G-F 显式覆盖。
9. **不用 LLM 做确定性代码的事** ✅ 组件化归 `normalize/1`,不另设格式化 worker。
10. **不做 demo 不需要的状态机** ✅ 快照/重起一幕已砍入 Out of Scope。
11. **内部耦合写出** ✅ §9 依赖:花名册注入 + 定时器。
12. **开放 vs 阻塞** ✅ §10 分两类,阻塞项已拍板。
13. **成本账** ✅ 每轮 N+2 次 LLM(N=2 → 4 次)、无流式、用户等整条消息——UX 决策:demo 可接受,生产期再议折叠/流式。
14. **闭环失败路径** ✅ §9 走了 worker 超时/半路刷新/进程重启三条,其中进程重启列为已知限制(不假装解决)。

---

## 附录 B — 完整 Demo 故事(可执行验收脚本)

> 单一访客 visitor 旅程,贯穿四链路 + 一条失败路径。每步标注验证项。

**第 0 步 · 开页面(验证 5.1/G-C/隔离)**
访客打开 H5。前端 `POST /bootstrap`(origin 校验通过)。ESR 实例化 `entity://user/ws_demo/tmp_7f3a`,Generator 幂等装配 `{tmp_7f3a, 编排器, worker-policy, worker-company}` + 定向路由 + caps,tmp_user join。返回 `{session://ws_demo/s_91, wss://…, ws_token=eyJ…, user_uri}`。前端存 `session://ws_demo/s_91`。
✔ 验证:每访客一 session、会话级隔离(token 绑定 s_91)。

**第 1 步 · 连镜像 WS(验证 5.2/G-B,P14)**
前端用 `ws_token + session://ws_demo/s_91` 连 Socket。服务端校验 token → 绑定 tmp_7f3a 身份 → 订阅 `esr:session:session://ws_demo/s_91:events`。调试期全推。
✔ 验证:server-derived identity 不可伪造;WS 只读。

**第 2 步 · 用户发问 → 一轮编排(验证 5.3/G-D,核心)**
用户输入:「我想了解你们有哪些政策,顺便看看有没有对口我们新材料方向的企业。」
- 前端经服务端以 tmp_7f3a 身份 `chat.send` → 定向路由**只**送编排器。
- 编排器派发段 DeepSeek 输出:`{"dispatch":[{"to":"worker-policy","task":"梳理新材料方向可申报政策(名称/额度/截止)"},{"to":"worker-company","task":"匹配新材料对口企业(名称/fit/对接路径)"}]}`,N=2。
- 编排器 `:cast` 并发 @worker-policy、@worker-company,各带 `ref_id=msg_a1`/`msg_a2`。**调试流可见这两条派发** ← 证明编排发生。
- worker-policy 回:「张江专项产业扶持(最高 500 万,6/30 截止)、研发费用加计扣除……」(`ref_id=msg_a1`,只回编排器)。worker-company 回:「未名智引(fit 91,石墨烯导热膜)、芯岭半导体(fit 78)……」(`ref_id=msg_a2`)。**调试流可见两条交付。**
- 编排器收齐 2 段 → 组合段 DeepSeek 揉成 → `normalize/1` 出 `<span type="services">{"type":"services","text":"给你挑了几条最相关的,先看政策面…","items":[…],"actions":["这些企业里哪家最匹配","我想申请政策对接"]}</span>` → `chat.send` 回用户。
- 前端经 WS 渲染服务卡 + actions 按钮。
✔ 验证:派发→并发→聚合→组合→normalize→定向回用户;ref_id 关联;P14 全程 dispatch。

**第 3 步 · 多轮推进(验证 5.5 actions)**
用户点「我想申请政策对接」→ 前端以 tmp_7f3a 身份 `chat.send` 该短句 → 重复第 2 步(编排器又必派发)→ 出 `<span type="form">`(采集机构/方向)→ 用户提交 → 出 `<span type="application" stage="draft" progress=90>`。编排器多轮上下文**读服务端 session 历史**。
✔ 验证:actions 驱动多轮;对话历史唯一真相来源 = 服务端 session。

**第 4 步 · 飞书单向镜像(验证 5.4)**
第 2、3 步每条落进 s_91 的消息(用户、两 worker、编排器卡片)被 `ExternalMirrorWorker` 自动镜像进绑定飞书群。群成员只看不回。
✔ 验证:ExternalMirror 零编排器侧代码;单向。

**第 5 步(失败路径) · worker-company 超时(验证 §9 聚合兜底)**
用户再问「换个方向,看看智能制造的企业」。编排器并发派发后,worker-company 卡在 DeepSeek 超过收齐门(如 8s)。编排器只收到 worker-policy 一段 → 定时器触发 → 组合「部分结果」降级卡:`<span type="notice" tone="warn">{"text":"政策这边给你了;企业匹配还在跑,稍等我再补一张","title":"部分结果",…}</span>`,经 dispatch 自发回用户。
✔ 验证:超时不静默卡死,用户拿到可渲染兜底卡(失败被看见)。

**第 6 步 · 关页面重开(验证收敛后的重入)**
访客关页面、稍后同浏览器重开。前端读本地 `session://ws_demo/s_91` + 本地全文 → **直接渲染本地历史**(显示恢复)→ 用新 `ws_token` 重连那个**还活着**的 s_91 → 后续消息继续推。无快照、无「重起一幕」、无 mid-turn 孤儿。
✔ 验证:复用活 session;前端本地全文显示;编排器记忆走服务端历史。

**故事结论**:六步走通四链路 + 一条失败路径,每步都能回答「失败了谁会知道」→ 链路闭环。
