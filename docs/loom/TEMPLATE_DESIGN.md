# Hello → 可复用「能力模板 plugin」设计 note

> 状态:设计蓝本(未实施)· 日期:2026-05-28
> 来源:把当前 hello v0.2 demo(编排 + bootstrap + 镜像 WS + span 协议,见 `PRD.md`)抽象成**任意开发者可省心复用**的模板。
> 性质:设计文档,不改 `ARCHITECTURE.md`;实施时触及架构的走 Allen review。

---

## 0. 立场:谁拥有什么

一句话:**ESR 运行时是平台方的;前端 + 业务话术是开发者的;中间靠一份版本化契约 + 一个 SDK 缝合。**

但「ESR vs 前端」这条线切得不够准——**业务 prompt / 卡片词汇也是开发者的,只是它运行在 ESR 侧**。所以是三类,不是两类:

| 类别 | 内容 | 归属 | 形态 |
|---|---|---|---|
| **运行时机制** | dispatch / session / 路由 / 编排机制(派发→fan-out→聚合→组合)/ 传输端点 / `normalize` 兜底 | **平台方(ESR)** | Elixir,稳定 |
| **业务配置** | 编排器/worker 的 prompt、**卡片词汇表**、worker 角色花名册、persona、(可选)飞书 chat_id | **开发者**,但**跑在 ESR 侧** | 配置 / SessionTemplate / 文件,**不是改代码** |
| **前端** | UI 组件、`type → 组件` 映射、交互 | **开发者** | 任意 JS 栈,产物 = dist |

**两档开发者(都交 plugin):**
- **薄 plugin(省心档)**:import 平台共享的 orchestrator/worker Behavior,只配 prompt + 卡片词汇 + 角色花名册 + 塞 dist。Elixir 极少(基本是 `application.ex` 注册配置 + 静态路由)。← 模板主场景。
- **厚 plugin(高级)**:要质变 agent 行为(新 worker 逻辑、调真实工具) → 在自己的 plugin 里写新 agent 品种(Elixir,flavor/Kind/Behavior,见 `application.ex` `agent_flavors/0`)。

> 模板目标:把平台的 orchestrator + 通用 worker 品种做成**可复用共享库 + 配置驱动**,让**多数开发者只需薄 plugin**,不必写品种。

---

## 0.5 部署模型(已定:平台托管单一 ESR,开发者交 plugin)

**决定(2026-05-28):平台运维唯一一个 ESR;开发者交付的就是 plugin(OTP app,hello 那种形态:bootstrap + team + behaviors + prompts + 内嵌 dist);所有开发者的 plugin 都部署进这同一个 ESR。** 开发者**写 plugin 但不运维 ESR**——这是「省心」与「ESR 原生扩展模型(plugin = OTP app)」的结合,不是「上传 config+dist、不写 Elixir」。它把下面这些从「可选」变成「硬约束」:

- **ESR 就一个、是平台的;交付单位 = plugin**(dist + prompt **内嵌在 plugin 里**,不是单独上传)。多个开发者的 plugin **共存于同一 BEAM**。
- **信任与隔离(已定:先审后上)**:多个第三方 plugin 跑在**同一个 BEAM**。决定走 **(a) 策展/审核**——plugin **先审后上**,审核通过即视为**第一方可信代码**,正好对齐 ESR 现行假设(CLAUDE.md P22「plugin 作者绕不过」),**无须进程级隔离**,「一个 ESR」成立。**残留**:审核挡住恶意代码,但通过审核的 plugin 仍可能有 bug crash 共享 BEAM(可用性爆炸半径)→ 运维层关注(监控 / 重启策略),非阻塞、非架构变更。
- **多租户在「一个 ESR、多 plugin」层面**:每个 plugin 是一个租户;session / workspace / 路由 / 静态全部按 **plugin 命名空间**隔离(ESR 的 plugin 模型 + workspace URI 正好承载);app A 不可见 app B 的 session(workspace 结构隔离 + `ws_token` 绑单一 session 的既有机制)。
- **部署机制**:把 plugin 装进运行中的 ESR = 热加载(code hot-swap,风险高)或**重建 release + 滚动发布**(更现实)。所以「上一个 plugin」≈ 一次**发布周期**,不是即时。**内容**(dist/prompt)若走运行时可配路径(§5)可不重发布更新;**Elixir 改动必须走发布**。
- **plugin ↔ ESR API 版本**:plugin 依赖 core/domain API,ESR 升级可能 break plugin → **Elixir 侧也要契约 + 版本**(与 §1 的前端 wire 契约并列)。
- **配额 + 回收(硬要求)**:per-plugin 的 DeepSeek 预算 / session 上限 / **真·清理**——demo 期「不回收」在多租户下必须变成真回收(`TempUser.cleanup` + session TTL sweeper)。
- **LLM key(待决策)**:平台共享 key + per-plugin 计费,还是每 plugin 自带 key(config)?见 §6。

**对现有代码的含义**:当前 hello plugin 就是「一个开发者 plugin」的范本。模板化 = 把它的通用部分(orchestrator/worker Behavior、bootstrap、镜像、span)抽成**平台共享库 / domain**,让新 plugin 薄薄一层(import 共享库 + 配 prompt/roster + 塞 dist)即可;只有要质变 agent 行为才在自己 plugin 里写 Elixir flavor。

---

## 1. Wire 契约(平台方钉死 + 版本化)

开发者(或 SDK)只依赖这层,不碰 ESR 内部:

- **`POST /bootstrap`** `{persona, session_uri?}` → `{session_uri, ws_url, ws_token, user_uri}`
- **镜像通道**:订阅一个 session 的全部消息,每条一帧 `{sender, role, body, id, ref_id}`
- **发言**:以 ws_token 身份发一句(服务端推导 sender、@编排器)
- **`body` 是不透明字符串**:前端/SDK 怎么解释(span / markdown / 纯文本)是前端的自由

契约必须 **版本化**:wire 一变,bump SDK 版本、开发者升级——而非「已 build 的 dist 静默全废」。

---

## 2. SDK:省心的那道缝(核心)

封装一个 JS SDK(现在的 `studio-mobile/src/session.js` 就是雏形,抽出来发包即可):

**SDK 封装(开发者不用管):**
- `bootstrap`(建/复用 session、persona、ws_token)
- 镜像连接 + **重连/心跳**(传输实现是 SDK 内部细节)
- `send(text)`
- 会话持久化 / 重入(localStorage)
- `parseSpan(body) → {type, props}` 解析 helper

**SDK 不封(还是开发者的):** UI 组件 + `type→组件` 映射 + 服务端卡片词汇 prompt。

**关键好处:传输协议变成 SDK 内部细节。**
- 开发者**不 import phoenix.js、不知道有它**——SDK 内部 bundle。所以「phoenix.js 绑死仅 JS」的顾虑,以及「Channel vs SSE」之争,都化解了:**保留 Phoenix Channel(house 一致),SDK 内部用 phoenix.js,开发者照样省心**。想换 SSE/裸 WS 也只动 SDK。
- **SDK = 版本化契约的载体**(解了上面的契约漂移问题)。
- 边界:SDK 是 JS 的。React/Vue/Svelte/原生 JS 都能用(H5 足够);非 JS 客户端才需裸契约。

建议 API 形状:
```js
const s = createSession({ persona, base });   // 内部 bootstrap + 连接
s.onMessage((frame) => render(parseSpan(frame.body)));  // 开发者渲染自己的组件
s.send(text);
```

---

## 3. 卡片词汇的「三处收口」(易漏)

卡片词汇活在**三个地方**,不是两个:

1. **prompt**(LLM 吐什么 `type`)—— 开发者的
2. **前端 renderer**(认得什么 `type`)—— 开发者的
3. **ESR 的 `normalize/1` + `infer_type`**—— 里面有 `@known_types`(固定 10 种)!

现状:`normalize` 只认 `@known_types` 里的 type,否则瞎猜/降级 `text`。→ **开发者定义新 type,LLM 吐出来会被 ESR 卡掉。**

**改造:`normalize` 改成「词汇无关」**——只要模型吐了 `type` 字段就**原样透传**(认不认是前端的事,前端已有 fallback);`infer_type` 字段猜测只在 `type` 缺失时兜底。不改,「自定义卡片」是假的。

---

## 4. Prompt 分层(机制 vs 词汇业务)

编排器 system prompt 拆两层,各归各家:

| 层 | 内容 | 归谁 |
|---|---|---|
| **机制层**(权威) | 派发段 dispatch JSON 格式、组合段「揉成一条回复」的指令 | **ESR/模板** |
| **词汇 + 业务层** | 有哪些卡 type、props、什么场景出什么卡、业务背景/persona | **开发者**(跟组件配套) |

ESR 运行时拼 `[机制层] + [开发者词汇业务层]`。`parse_dispatch` 解析失败已降级直接答,所以即便开发者 prompt 把 LLM 带偏,机制层不崩——**分层是稳的**。开发者的这层 prompt 走**可配置路径**(改完即生效,不重编译)。

---

## 5. 静态插槽(dist 落地)

- 开发者 `vite build` → dist 丢进 plugin 的**可配置静态目录**;ESR `Plug.Static` 同源 serve。
- **同源 → 生产免 CORS**;dev 仍可跑独立 :5175 + HMR(那时跨源、留 CORS)。
- **机制要求**:ESR 运行时读一个**可配置的外部静态路径**(改完即生效),而不是 bake 进 release——否则「丢 dist」要重新发布,不省心。
- 模板**ship 一份参考前端**(studio-mobile 的 dist 作示例);共享仓库别提交某个具体开发者的 dist(gitignore 插槽 / 文档说明替换)。

---

## 6. 待决策(实施前必须定)

> 「单应用 vs 多租户」**已定 = 平台单一 ESR + 多 plugin**;「信任 / 隔离」**已定 = 先审后上**(见 §0.5)。余下:

1. **身份模型**:bootstrap 现在 mint「匿名临时用户」。开发者若做有真实登录的产品,这套不合身——平台统一身份层,还是每 plugin 自带身份对接?
2. **LLM key**:平台共享 key + per-plugin 计费,还是每 plugin 自带 key(config)?
3. **传输**:有 SDK 后低风险——默认 Phoenix Channel(SDK 内封),需要时换 SSE/裸 WS,开发者无感。

---

## 7. demo → template 的差距(当前 vs 需要)

当前 hello v0.2 是 **demo 形态**(能跑通编排,见 `PRD.md` / 已活验证),但下列都**硬编码**,要模板化得外置:

- 编排器/worker prompt + 卡片词汇:`EzagentPluginHello.Prompts`、`HelloWorker` 的主题 prompt —— module attr → **走配置/文件**
- orchestrator/worker Behavior —— → 抽成**平台共享库 / domain**,plugin import(薄 plugin 的根基)
- worker 花名册:名字派生 —— → **plugin 内配置声明**(回到 S3 的 A 方案方向)
- `normalize` 的 `@known_types` —— → **透传**(见 §3)
- 飞书 chat_id / workspace —— → **plugin 内配置**(飞书本身另有「临时 session 绑定」的架构摩擦,见 PRD 备注,本期 gate 关)

**实施建议**:等当前 demo 体验/编排定型,再一次性做**模板化一期**:① 抽共享 behaviors 库 + SDK 发布 ② prompt 分层外置 ③ `normalize` 透传 ④ 静态插槽(可配路径)⑤ 前端 wire + plugin↔ESR 双契约文档化 + 版本号 ⑥ 落地 §0.5(信任/隔离 + 部署机制 + per-plugin 命名空间/隔离/回收)+ 定 §6 余下(身份 / LLM key)。**不要边改 demo 边动模板结构**,两头乱。

---

## 8. 开发者最终流程(交 plugin,平台部署)

1. 拿模板 plugin(import 平台共享 behaviors)+ 前端 `npm i` SDK;
2. 用任意 JS 栈写 UI,`session.onMessage` 里把 `{type, props}` 渲染成自己的组件;
3. 配业务:卡片词汇 prompt + worker 角色花名册(+ 可选自带 LLM key);要质变 agent 行为才写自己的 Elixir flavor;
4. `vite build` → dist 塞进 plugin 静态插槽 → **把 plugin 交给平台**,平台审核 + 部署进那唯一的 ESR(发布周期)→ **完**。

不运维 ESR、前端不引 phoenix.js、用喜欢的栈——前提是 §0.5 的信任/隔离 + 部署机制定好,且 §2-§5 模板化到位。
