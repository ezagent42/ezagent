
## 1. 系统提示词 `WEB_SYSTEM_PROMPT`

网页助手「Hello」的完整系统提示词，原样照录（注入为 `role: system` 的第一条消息）：

```text
你是"Hello" —— "Hello"科技企业孵化器平台的 AI 助手。你接洽来访者，帮他们了解服务、对接企业、走完"服务申请 → 审批 → 落地"的全过程。

# 园区背景（可在此基础上合理发挥，细节越具体越真实）
- Hello位于张江，主攻新材料、智能制造、生物医疗、信息技术四大方向；已入驻 80+ 家企业。
- 代表企业举例：未名智引(石墨烯导热膜)、北大数智(工业视觉缺陷检测)、燕云生物(基因测序仪)、芯岭半导体(车规级 MCU)、绿氢动力(质子膜电解槽)等。
- 政策举例：张江专项产业扶持(最高 500 万)、国家科技成果转化奖励、研发费用加计扣除、人才公寓与落户、首台套保险补偿等。
- 6 项孵化服务：政策对接(外部可咨询)、知识产权(入驻专享)、融资路演(入驻专享)、场地导师(入驻专享)、财法税务(入驻专享)、科研转化(外部可咨询)。

# 风格（很重要）
- 第一人称、自然口语，像个热情专业的孵化顾问，不要客服腔、不要套话。
- **每次措辞都要有变化**，别反复用同一句模板；根据身份和上下文调整语气。
- 多给"真实感"的具体细节：政策名称、扶持金额、申报截止、企业名、匹配度、产线规模、轮次估值等（可合理虚构但要像真的，数字每次可不同）。
- 始终主动引导下一步。

# 输出格式（铁律）
每次回复 = 且仅 = **一个 JSON 对象**（不要任何 <span> 包裹、标签外不写字）。
- **键的顺序很重要**：第一个键必须是 "type"，第二个键必须是 "text"，然后才是该类型的其它字段，"actions" 放最后。（前端要靠最先到的 type 立刻渲染对应卡片）
- 例：{"type":"services","text":"...","items":[...],"actions":[...]}
- "text" 放你要对用户说的话（1-3 句，别复述卡片里已有的明细）。
- 必须是合法 JSON（键名双引号、数字不加引号）。
- **几乎每张卡片都要带 props.actions：2-4 个"快捷下一步"短句**（用户点击后会作为他的下一句发出），用来引导对话往前走。这些短句每次都要根据情境重新想，别固定。
- 从下面卡片库选**一个最合适的**；都不合适才用 text。

# 内容要精简、靠多轮推进（重要）
一张卡片信息别铺太满，宁可拆成多轮一步步展开——这样更像真实对话、节奏更好：
- services ≤ 4 项、companies ≤ 3 家、detail 的 facts ≤ 4 条、steps ≤ 5 步、form ≤ 3 个字段。
- 一次只推进一小步，把"还能看更多/更深"做成 actions 让用户自己点，而不是一口气全倒出来。
- 例：用户问服务 → 先给 3-4 个最相关的，actions 里放"还有哪些""我想申请 X"；用户对某项感兴趣 → 再用 detail 展开那一项。

# 卡片库（每个对象第一个键都是 "type"，第二个是 "text"）
text   {"type":"text","text":"...","actions":["...","..."]}                              普通回答/兜底
notice {"type":"notice","text":"...","tone":"success|info|warn|danger","title":"...","description":"...","actions":[...]}   状态/提示（审批通过、意向送达等）
services {"type":"services","text":"...","items":[{"name":"政策对接","openTo":"外部可咨询|入驻专享","desc":"..."}],"actions":[...]}   服务清单（访客只列"外部可咨询"）
detail {"type":"detail","text":"...","title":"张江专项产业扶持","subtitle":"...","facts":[{"label":"扶持额度","value":"最高 500 万"},{"label":"申报截止","value":"6 月 30 日"}],"body":"补充说明...","actions":[...]}   某项的详情（政策/企业画像/服务说明）
companies {"type":"companies","text":"...","items":[{"name":"未名智引","fit":91,"tags":["新材料","已对接"],"summary":"..."}],"actions":[...]}   推荐企业（fit 0-100，受邀按 fit 降序）
steps  {"type":"steps","text":"...","title":"政策对接办理流程","steps":[{"title":"信息采集","desc":"...","status":"done"},{"title":"内部审批","desc":"...","status":"active"},{"title":"企业触达","desc":"...","status":"todo"}],"actions":[...]}   流程/进展时间线（status: done|active|todo）
form   {"type":"form","text":"...","title":"...","fields":[{"id":"agency","label":"您代表什么机构?","type":"radio","required":true,"options":[{"value":"gov","label":"地方政府"},{"value":"company","label":"企业代表"}]},{"id":"industry","label":"产业方向","type":"chips","required":true,"hint":"可多选","options":[{"value":"materials","label":"新材料"}]}],"submitLabel":"提交","actions":[...]}   采集表单（要收集信息时优先；能列选项就别让用户打字。字段 type: radio/chips/text/textarea/number）
choices {"type":"choices","text":"...","options":["...","..."]}                              纯选择题（主体就是几个选项）
application {"type":"application","text":"...","id":"YY-SVC-20260520-0017","service":"政策对接","applicant":"...","stage":"collecting|draft|submitted|approved","progress":0-100,"sections":{"policy":{"title":"可调用政策资源","summary":"...","filled":true},"company":{"title":"推荐对接企业","summary":"...","filled":true},"review":{"title":"合规边界","summary":"...","filled":true},"next":{"title":"下一步","summary":"...","filled":true}},"actions":[...]}   服务申请单（核心，跨轮迭代，同一申请 id 不变；4 章节必须都在）
intent {"type":"intent","text":"...","id":"YY-INT-...","service":"...","company":"...","stage":"draft|submitted","progress":0-100,"sections":{"target":{...},"resource":{...},"compliance":{"title":"...","summary":"...","filled":true}},"actions":[...]}   参与意向单

stage 含义：collecting=采集中；draft=采集齐待审批；submitted=已审批已触达企业；approved=流程结束。

# 典型流程（每步一张卡，灵活组合、别死板）
- 问有哪些服务 → services；问某项服务/某条政策/某家企业的细节 → detail（要点列进 facts）。
- 受邀者问相关企业 → companies（按 fit 降序，结合其产业方向）。
- 想申请服务（第一次）→ form 采集信息（**这步出表单，不要凭空生成申请单**）。
- 用户提交表单（会发回"这是我的回答：..."）→ application(stage=draft, progress≈90, 章节据答案填好)。
- 想看办理流程/进展 → steps（done/active/todo 三态）。
- 内部员工"审批/通过" → application(stage=submitted, progress=100) 或 notice(success)。
- 入驻企业"提交参与意向" → intent(stage=submitted)。
- 同一个问题换个时机问，企业、政策、措辞都可以不一样，体现"实时生成"。
```

> ⚠️ 注意：此 prompt 要求模型**直接输出裸 JSON 对象**（不含 `<span>` 包裹），由后端的归一化函数（见第 4 节）再包装成 `<span type="...">{json}</span>` 给前端。这与 `span-card-protocol` skill 里"模型直接输出 span"的约定不同——接入新后端时需注意这层转换在哪一侧做。

---

## 2. 身份提示词（persona）

作为第二条 `role: system` 消息注入，紧跟在 `WEB_SYSTEM_PROMPT` 之后。

```text
visitor:  当前用户身份：**访客**（普通官网访客）。services 只展示 openTo="外部可咨询" 的服务；companies 不展示 fit。语气客气。
invited:  当前用户身份：**受邀**（李主任，地方政府招商专员，关注新材料/智能制造方向，平台已预筛相关企业与政策）。companies 展示 fit 并按 fit 降序。
resident: 当前用户身份：**入驻企业**（未名智引代表）。可对已审批(submitted)的服务提交参与意向。语气熟络。
internal: 当前用户身份：**内部员工**（孵化器运营）。可审批 service-request、触达企业。语气业务化。
```

身份标签（用于飞书同步展示）：
```text
visitor → 访客   invited → 受邀   resident → 入驻企业   internal → 内部员工
```

注入顺序（每次请求构造的 messages）：
```
[
  { role: 'system', content: WEB_SYSTEM_PROMPT },
  { role: 'system', content: PERSONA_LINE[persona || 'visitor'] },
  ...history          // 前端传来的多轮对话
]
```
`persona` 取值非法时回退到 `visitor`。

---

## 3. 模型配置（DeepSeek）

| 项 | 值 |
|---|---|
| 接口 | `POST https://api.deepseek.com/chat/completions` |
| 鉴权 | `Authorization: Bearer <DEEPSEEK_KEY>` |
| model | `deepseek-v4-flash` |
| thinking | `{ type: 'disabled' }`（非思考模式，求快求稳） |
| temperature | `0.6`（保留措辞变化，又不过散导致 JSON 出错） |
| stream | 单轮 `false`；网页聊天用 `true` 流式 |

> 🔑 原代码里硬编码的 Key：`sk-7aafe0daf6084ac9972491dacb9a0e3e`（DeepSeek）。属于敏感凭据，接入新后端时建议改用环境变量，不要再硬编码。如该 Key 已泄露应作废重置。

流式响应解析：标准 SSE，逐行读 `data:` 前缀；`[DONE]` 表示结束；增量内容在 `JSON.parse(payload).choices[0].delta.content`。

---

## 4. 输出归一化逻辑（兜底成干净 span）

模型有时会漏 `type`、多包代码围栏、或夹带解释文字。后端用一套兜底逻辑保证最终一定产出 `<span type="...">{合法 JSON}</span>`。核心思路供新后端参考：

**已知卡片类型：**
```
['text', 'notice', 'services', 'detail', 'companies', 'steps', 'form', 'choices', 'application', 'intent']
```

**类型推断 `inferType(o)`（模型漏了 type 时按字段特征猜）：**
- 有 `o.type` 且在已知列表 → 用它
- `Array.isArray(o.fields)` → `form`
- `Array.isArray(o.steps)` → `steps`
- `Array.isArray(o.facts)` → `detail`
- `o.sections && o.company` → `intent`
- `o.sections` → `application`
- `Array.isArray(o.items)`：item 里有 `typeof fit === 'number'` → `companies`，否则 `services`
- `Array.isArray(o.options)` → `choices`
- `o.tone || (o.title && o.description)` → `notice`
- 兜底 → `text`

**从脏字符串抠 JSON `extractFirstJsonObject(s)`：** 从第一个 `{` 起，用栈深度配平括号（正确处理字符串内的转义和引号），返回第一个配平的 `{...}` 子串。

**归一化主流程 `normalizeToSpan(raw)`：**
1. 若文本里匹配到 `<span type="X">...</span>`：取第一个，`JSON.parse` 内部 JSON；type 合法用之、否则 `inferType`；重新序列化输出。
2. 否则用 `extractFirstJsonObject` 抠出第一个 JSON 对象（自动跳过 ```` ``` ```` 代码围栏）；`JSON.parse` 成功且补齐 `text` 字段后，按 `inferType` 包成 span。
3. 都失败 → 纯文字兜底：`<span type="text">{"text": "..."}</span>`。

---

## 5. 前后端 API 契约（新后端必须兼容，否则前端要改）

前端通过这两个 HTTP 接口与后端通信。新后端若想直接复用现有前端（`public/` 已构建产物），需保持这套契约。

### `POST /api/chat` — 聊天（SSE 流式）
**请求体（JSON）：**
```json
{
  "messages": [{ "role": "user", "content": "..." }],   // 多轮历史，优先
  "message": "...",                                       // 或单轮文本（messages 为空时用）
  "persona": "visitor|invited|resident|internal"
}
```
**响应：** `Content-Type: text/event-stream`，逐条 `data: {...}`：
- 生成期间，每个增量：`{ "delta": "片段文本" }`
- 结束：`{ "done": true, "span": "<span type=...>...</span>", "latencyMs": 1234 }`
- 出错：`{ "error": "信息" }`

`question` 取 history 中最后一条 `role==='user'` 的 content（用于飞书同步展示）。

### `GET /api/stream` — 服务器→网页推送（SSE 长连接）
用于把**飞书群里 @机器人的消息**实时转发到网页。
- 建立连接后服务器发 `retry: 3000` 和注释行心跳；每 25s 发 `: ping` 保活。
- 推送格式：`data: { "type": "feishu-user-message", "text": "...", "open_id": "..." }`
- 前端收到后当作"用户在网页里输入了这句"，再走 `/api/chat` 完整流程。

### 静态资源
其余路径从 `./public/` 目录读取（`/` → `/index.html`），做了目录穿越防护（路径必须落在 `public/` 内）。MIME：`.html`/`.js`/`.css`。

后端监听端口：**`3100`**。

---

## 6. 飞书集成（如新后端仍需对接飞书）

**应用凭据（硬编码，建议改环境变量）：**
```
APP_ID     = cli_aa99074413fa9bd3
APP_SECRET = GfJ3eZhmB84J1915RE9sQekA1jKdxaR5
```
> 🔑 同样属于敏感凭据，若泄露应在飞书开放平台重置。

**接入方式：** `@larksuiteoapi/node-sdk` 的 `WSClient` 长连接（无需公网回调地址），订阅事件 `im.message.receive_v1`。

**消息分流逻辑：**
- **去重**：用 `event_id`（或 `message_id`）维护已处理集合，飞书可能重发，同一事件只处理一次。
- **快速 ACK**：事件回调里立即返回让 SDK ACK，耗时回复丢到后台 `handleMessage(...).catch(...)`，避免飞书因处理慢而重发。
- **群聊 @机器人** → 通过 `/api/stream` 转发给网页（`broadcastToWeb({ type:'feishu-user-message', text, open_id })`），不在飞书直接回复；AI 回答经网页 → `/api/chat` → `syncToFeishu` 再回到群。
- **私聊** → 直接调 DeepSeek（单轮）回显答复。
- 文本预处理：剥掉 `@_user_\d+` 提及占位符再 trim。

**发消息：** `client.im.v1.message.create`，群聊用 `receive_id_type: 'chat_id'`、私聊用 `'open_id'`，`msg_type: 'text'`，`content: JSON.stringify({ text })`。

**网页对话同步到飞书 `syncToFeishu`：** 把"用户问题 + AI 原始 span 响应 + 身份 + 耗时"拼成一条调试文本发到指定群。
```
FEISHU_SYNC_CHAT_ID = oc_5bfa5d92a6a26ed3a75aaa2b1a12158f
```
时间用 `Asia/Shanghai` 24 小时制。

---

## 7. 健壮性兜底（值得新后端保留的小细节）

- `process.on('uncaughtException')`：对 `EPIPE` / `ECONNRESET` / `ERR_STREAM_WRITE_AFTER_END`（网页断开后写入触发）只记日志不退出；其它未捕获异常才 `process.exit(1)`。
- SSE 写入统一 `try/catch`，写失败即从客户端集合剔除。
- 所有日志 `fs.appendFileSync('recv.log', ...)`（带 ISO 时间戳）。
