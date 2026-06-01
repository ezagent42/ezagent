# Loom 重设计 — session-scoped、v0worker、保存为模板

- 日期:2026-06-01
- 状态:设计已定,实施中
- 取代关系:扩展(不取代)`2026-05-29-frontend-plugin-integration.md` + `2026-05-29-loom-sdk-bridge.md`;`POST /loom/api/chat` 在本设计被**删除**。

## 0. 一句话

`/loom` 从"全局独立前端"变成"per-session 的视图":**对话只有一份(在 session)、页面源码只有一份(在编排器 slice + session chat 历史里以 `<span type="page_update">` 形式权威化)、视图两种(chat / loom)**。AI 生成页面的能力(原"v0")从前端 `/api/chat` 直连 DeepSeek 改成 session 团队里的 `LoomV0Worker`,由编排器分类后 dispatch。

## 1. 已定决策

| # | 决策 |
|---|---|
| C1 | `plugin_loom` 保留为全局 OTP 插件;`/loom/:ws/:sid` 仅对**由 loom 模板建出的 session** 生效。 |
| C2 | LoomSession team:`loomorch + policy + company + loomv0`(v0 共存,不替代)。 |
| C3 | 用户必须 `@` 才能触发(默认 mention-gated)。直接 @worker 允许(dev 期不限制)。 |
| C4 | loom 视图的左侧聊天框 = session compose,**@-autocomplete**(同 `/sessions` compose)。 |
| C5 | v0 收到的任务**带最近 N 条对话上下文 + 当前源码**(编排器在 dispatch 时拼)。 |
| C6 | 页面源码权威源 = session chat 历史里最近一条 `<span type="page_update">`;编排器 slice 缓存。 |
| C7 | 前端**不保留任何被渲染的页面源码**(删 `useAppStore.DEFAULT_CODE` + 删整个 `useAppStore`)。空 session 由编排器在 `post_init` 时 emit seed page_update(`Prompts.loom_seed_source`)。 |
| C8 | `POST /loom/api/chat` **删除**(不再被任何前端代码使用)。 |
| C9 | "保存为模板":单 Template Class `LoomSavedSession`(`session.loom-saved`)+ form 里 "已存模板" 下拉。后端新表 `loom_saved_templates`。 |
| C10 | 修改 worker / 改动编排器(2 号需求)**deferred**;v1 模板快照只含 team flavor 默认配置 + page source。 |

## 2. 架构 / 数据流

```
                  用户 @loomorch_<sid> "把按钮改成圆角"
                                 │
                          session chat.send(mentions=[loomorch])
                                 │
                                 ▼
                     ┌──── LoomOrchestrator ────┐
                     │  decompose(LLM):分类       │
                     │   → 改页 → 派 v0,task 拼   │
                     │      {recent_history,      │
                     │       current_source,      │
                     │       user_request}        │
                     └────────────┬───────────────┘
                                  │ Cmd.new(v0_uri, :send, %{message:...}, ...)
                                  ▼
                          LoomV0Worker.handle_receive
                                  │ DeepSeek(page_gen_system_prompt, ...)
                                  │ extract jsx 代码块
                                  ▼
              chat.send 进 session,body =
              <span type="page_update">{"source":"<新 jsx>","summary":"按钮改圆角"}</span>
                                  │
        ┌─────────────────────────┼─────────────────────────────┐
        ▼                         ▼                             ▼
   LoomOrchestrator       session chat 持久化           WebPlug /stream SSE
   handle_receive 看到     + 飞书摘要镜像                       │
   sender=v0worker,                                             ▼
   span=page_update                                  LoomBridge(宿主页)
   → {:set, :loom_source, new_src}                  识别 page_update span
                                                    → 提取 source
                                                    → 推回沙箱 → Sandpack 重渲染

(空 session 由 LoomOrchestrator.post_init emit seed page_update,
 sender=自己,不触发自循环 — 在 handle_receive 过滤 sender !== self)
```

## 3. ESR 改动清单

### 3.1 删除

- `EzagentPluginLoom.WebPlug` 里 `post "/api/chat"` 路由 + `sanitize_messages/normalize_role` helpers(原 ai-ui-builder 左聊天的 DeepSeek 代理,新方案不再使用)。
- `EzagentPluginLoom.Prompts.page_gen_system_prompt/0` **保留**(v0worker 用)。

### 3.2 新增

**`Ezagent.Entity.LoomV0Worker`** Kind:type_name `:loomv0`,URI 模式 `entity://agent/<ws>/loomv0_<sid>`。仿 `Ezagent.Entity.LoomWorker`。

**`Ezagent.Behavior.LoomV0Worker`** Behavior(参考 `LoomWorker`):
- `state_slice`:`:loomv0`(role / system_prompt 覆盖位等;v1 用默认即可)。
- `action :receive` + `handle_receive(args, ctx)`:
  1. 把消息当成 orchestrator 派来的 task(text 里编排器塞了 `current_source` + `user_request` + `recent_history`)。
  2. mention 守卫(`addressed_to_self?`)。
  3. 拼 DeepSeek 消息:`system = Prompts.page_gen_system_prompt()`,`user = "Current source:\n```jsx\n...\n```\n\nRecent chat:\n...\n\nRequest:\n..."`。
  4. `DeepSeek.chat([system, user], thinking_disabled: true, temperature: 0.7)`。
  5. 抽首个 jsx 代码块(helper);summary 取 LLM 回复中代码块之外的第一段(若无则用 user_request)。
  6. emit `{:dispatch, Cmd.new(session_uri, :send, %{message: page_update_message(...)}, ctx)}`。
- `required_caps` 钉 `:loomv0`(同 LoomWorker)。

**`Ezagent.PluginLoom.Template.LoomV0Worker`** Template Class(同 `LoomWorker` 风格)。

**`EzagentPluginLoom.Application`**:
- `agent_flavors` 加 `%{flavor: "loomv0", kind: LoomV0Worker, template_class: Template.LoomV0Worker}`。
- `template_classes` 加 `LoomV0Worker`、`LoomSavedSession`。
- `behaviors` 加 `{Ezagent.Entity.LoomV0Worker, :receive, Ezagent.Behavior.LoomV0Worker}`。

**`Ezagent.PluginLoom.Template.LoomSavedSession`**(`session.loom-saved`):
- `form_fields`:`session_name`(text)+ `saved_template`(select,运行期填值 = 当前 workspace 的 `loom_saved_templates` 行)。
- `instantiate/3`:读 saved row → 起 session(同 LoomSession.spawn_session)→ 按 row 的 team_snapshot spawn 成员(URI 模式里 `$sid` 替换为 session_name)→ orchestrator 启动后 post_init 用 saved source 作为 `:loom_source` 初值 → emit 首条 seed page_update。
- 实现细节:orchestrator 的 `init_slice/1` 接 `:initial_loom_source` arg;LoomSavedSession spawn 时通过 `SpawnRegistry.spawn(uri, args)` 传入 saved source。

**`Prompts.loom_seed_source/0`**:返回字符串,内容 = 原 `useAppStore.DEFAULT_CODE`(欢迎页 `<h1>欢迎使用 Loom...</h1>`)。

**`Span.@known_types`** 加 `"page_update"`。

**Loom saved templates 表**:
```
table: loom_saved_templates
- id: bigserial PK
- workspace_uri: text NOT NULL
- name: text NOT NULL  -- unique with workspace_uri
- team_snapshot: text NOT NULL  -- JSON: {members: [{flavor, name_pattern}]}
- source: text NOT NULL          -- the jsx
- created_by: text                -- caller URI
- inserted_at / updated_at
- unique index (workspace_uri, name)
```
落在 `apps/ezagent_plugin_loom/priv/repo/migrations/...`(或 ezagent_core repo 路径,实施时定;loom plugin 在 mix.exs 已有 ezagent_core 依赖)。

实际上 ezagent_core 是 repo 持有者;迁移放 `apps/ezagent_core/priv/repo/migrations/` 或 plugin 自己的 priv?**选**:放 plugin 自己的 priv/repo/migrations,跟 ExternalMirror.BindingRow 同模式(实施时 check)。schema 模块 `EzagentPluginLoom.SavedTemplateRow` 在 `apps/ezagent_plugin_loom/lib/ezagent/saved_template_row.ex`。

### 3.3 改动

**`Ezagent.Behavior.LoomOrchestrator`**:
- `init_slice/1`:接 `:initial_loom_source` arg(默认 = `Prompts.loom_seed_source()`),slice 加字段 `:loom_source`。
- 新增 `post_init/2` 或 `on_ready/2` 回调:emit 一条 seed page_update 进 session(`{:dispatch, Cmd.new(session_uri, :send, %{message: build_page_update_message(self, loom_source, "初始页")}, ctx)}`)。
- `handle_receive`:在现有 worker_deliverable / user_turn / ignore 分支之外加一条 — sender 是 v0worker 且 body 含 `<span type="page_update">` → `{:set, :loom_source, extracted_source}`(纯缓存,不再发新消息,避免循环);同时**不**当 worker_deliverable 计入 pending(它不是 dispatch 的 ref_id 链)。
- `decompose` 阶段(LLM 派发提示词):列出 workers 时给 v0 加描述("`v0`:处理任何关于**生成/修改本会话页面**的请求,带 current_source");其他保持。
- 当 dispatch 出 `to: "v0"` 的 task 时,task 文本里**塞**:`Recent chat:` + 最后 5 条 session 消息文本片段 + `Current source:` + `slice.loom_source` + `Request:` + user 原文。
- `worker_label/1` 给 `loomv0_*` 返回 `"v0"`。

**`Ezagent.PluginLoom.Template.LoomSession`**(`session.loom`):
- `instantiate/3`:在 spawn orchestrator + policy + company 之外,额外 spawn `entity://agent/<ws>/loomv0_<name>`。
- spawn orchestrator 时传 `:initial_loom_source = Prompts.loom_seed_source()`(via SpawnRegistry args)。
- form_fields 不变。

**`EzagentPluginLoom.WebPlug`**:
- 删 `post "/api/chat"`。
- 新增 `post "/api/:ws/:sid/save_template"`:body `{name: "..."}`;调 `SavedTemplate.save(ws, sid, name)` helper:
  - 读 orchestrator 的 `:loom_source`(via `Ezagent.Kind.get_slice` 同 Chat behavior 那种公共读)。
  - 抓 session 当前 chat 成员列表(同上)。
  - 构造 team_snapshot json:每个成员推回到 `{flavor, name_pattern}`(flavor 从 AgentFlavorRegistry 反查 entity URI;name_pattern 把 sid 替换成 `$sid`)。
  - `EzagentPluginLoom.SavedTemplateRow.insert(...)`。
  - 返回 `{ok:true, name: saved_name}` 或 `{ok:false, error}`。

**`EzagentPluginLiveview.Admin.SessionEditor`**:
- 头部加按钮 "切换视图(chat / loom)"(仅对 loom session 显示);维护 `@view_mode` 在 socket assigns。
- 头部加按钮 "保存为模板"(仅对 loom session);触发 LV event → prompt 输入名字 → fetch POST `/loom/api/:ws/:sid/save_template`(同源)→ flash 反馈。
- loom 视图渲染:左半 = 当前 session compose + 历史 + EzagentMessage 渲染(复用已有);右半 = `<iframe src="/loom/:ws/:sid?mode=embed">` 复用已 vendor 的 dist 的 Sandpack 部分。**简化**:loom 视图直接 = 现有 `/loom/:ws/:sid` 页面(整个 dist iframe 嵌入)。LV 切到 loom 视图就显示这个 iframe;chat 视图就显示原 ChatWindow。

> **简化 trade-off**:不在 LV 里重画 Sandpack,而是 iframe 嵌入已经 build 好的 loom dist 页面(它本身就是 chat + Sandpack 双栏)。这意味着 loom 视图下 chat 部分其实是 dist 内部的 ChatPanel,跟 LV 的 ChatWindow 不共享 React 状态;但**两边数据源都是同一份 session chat history**,所以始终一致。优点:不需要在 LV 里塞 Sandpack。

## 4. 前端改动清单(Desktop ai-ui-builder)

### 4.1 删除

- `lib/store/useAppStore.ts` — 整个删。
- `lib/ai/deepseek.ts` + `lib/ai/system-prompt.ts` — 不再使用(逻辑搬到 ESR 侧;系统提示词在 ESR 的 `Prompts.page_gen_system_prompt`)。
- `app/api/chat/route.ts` — 永久删(原本是 standalone dev 用的)。
- `package.json` 依赖清理:`@ai-sdk/deepseek`、`@ai-sdk/openai`、`ai` 可删(仅 useChat 用过)。
- README 相应段落清理。

### 4.2 大改

**`components/chat/ChatPanel.tsx`**(原来用 useChat):
- 去掉 `useChat` / DeepSeek 路径。
- 改成 session compose:
  - 维护 `messages` 状态,初始 = `await getHistory()`;之后 `onMessage(cb)` 追加新帧。
  - 输入框:打 `@` 触发成员下拉(成员列表从一个新的轻量 endpoint 读:`GET /loom/api/:ws/:sid/members` → `[{uri, label}]`)。
  - 提交:`await sendMessage({ text: input })`(SDK)。
  - 渲染消息:用户的 → 普通气泡;非用户(agent) → `<EzagentMessage frame={m} />`。
  - 不再有 `extractCode` 路径(那是旧 DeepSeek-driven 取代码的逻辑)。

**`components/preview/PreviewPanel.tsx`**:
- 把 `code` 来源从 `useAppStore` 改成 prop `source: string`(由父组件传)。
- 删 `useAppStore` 引用。

**`app/page.tsx`**:
- 维护 `const [source, setSource] = useState('')`(初始空)。
- `useEffect` 挂 `mountLoomBridge({ onSource, onMessage })`;onSource 回填 setSource。
- 把 source 传给 PreviewPanel。

**`lib/sandbox/loom-bridge.ts`**:
- 增加 `onSource(callback)` 注册接口;桥的内部在解析消息流(SSE)+ getHistory 时,识别 `<span type="page_update">` 体内 source,callback 推回。
- 暴露 `mountLoomBridge({ onSource?, onMessage? })`(都可选)。

**`lib/sandbox/ezagent-ui.ts`**:
- `BODY` 映射加 `"page_update"`:渲染 notice 卡 "页面已更新:<summary>"(可选折叠显示源码 diff,v1 只显示 summary)。

### 4.3 不变

- `lib/sandbox/platform-sdk.ts`(SDK 真实现)。
- `ezagent-ui.ts` 其余卡片渲染(services/companies/...)。
- `app/layout.tsx`、`next.config.mjs`、tailwind 等。

## 5. 关键数据格式

### 5.1 `<span type="page_update">` 体
```json
{
  "source": "export default function App() { ... }",
  "summary": "按钮改成圆角"
}
```
- 由 `Span.normalize/1` 同样的 wrap 路径产生(`Span.span("page_update", obj)`)。
- 编排器或 v0 都用同样的格式;sender 区分主体。

### 5.2 `loom_saved_templates.team_snapshot` JSON
```json
{
  "members": [
    {"flavor": "loomorch",   "name_pattern": "loomorch_$sid"},
    {"flavor": "loomworker", "name_pattern": "loomworker_$sid_policy"},
    {"flavor": "loomworker", "name_pattern": "loomworker_$sid_company"},
    {"flavor": "loomv0",     "name_pattern": "loomv0_$sid"}
  ]
}
```
LoomSavedSession.instantiate 替换 `$sid` 为新 session 名,逐个 spawn。

## 6. 错误处理 / 边界

- v0 调 DeepSeek 失败 → emit notice span("生成失败:<原因>"),不写 source。
- v0 输出无 jsx 代码块 → 同上,fallback notice。
- 编排器分类把 page-mod 错误分到 policy/company → policy/company 当作普通业务回复(不写 source);用户可手动 `@loomv0 ...` 跳过。
- saved_template name 重复 → 后端返回 `{ok:false, error: "name taken"}`。
- 空 session 没有任何 page_update(seed 还没发) → 前端显示加载态;seed 到达后渲染。

## 7. 测试 / 验证

- ESR:loom 插件已有 28 个测试;新增最少:
  - LoomV0Worker handle_receive 的 mention 守卫 + jsx 提取 + emit shape(DeepSeek mocked)。
  - SavedTemplateRow CRUD。
- 编译需通过:`mix compile` exit 0;loom 测试 `mix test` 0 failures。
- 手动 e2e:
  1. 删 demo3,从 LoomSession 模板新建 demo-v0。
  2. 打开 `/loom/system/demo-v0` → Sandpack 渲染 seed 页。
  3. 左聊天打 `@loomorch_demo-v0 把按钮改深色` → 几秒后 page_update 到 → Sandpack 重渲染 + 卡片显示 "页面已更新:..."。
  4. 头部 "保存为模板" → 取名 `demo-v0-template` → flash 成功。
  5. `/workspaces/system` → Add template 选 `session.loom-saved`,saved_template 下拉选 `demo-v0-template`,session_name `demo-v0-clone` → 提交 → 新 session 起来,Sandpack 直接渲染 saved source。

## 8. 实施顺序

1. ESR:Prompts seed source / Span 加 page_update。
2. ESR:LoomV0Worker Kind + Behavior + Template + flavor 注册。
3. ESR:LoomOrchestrator 改造(init_slice + post_init + handle_receive + decompose v0 介绍 + worker_label)。
4. ESR:LoomSession.instantiate 追加 v0worker spawn + seed source 传参。
5. ESR:WebPlug 删 /api/chat;暂不加 save_template(分两批避免一次过载)。
6. 编译 + 跑 loom 测试。
7. 前端:删 useAppStore / lib/ai / app/api/chat;改 page.tsx / PreviewPanel / loom-bridge / ezagent-ui;ChatPanel 改 session-compose + autocomplete。
8. build + vendor + 编译 / 测试。
9. 手动 e2e(走到 page_update 渲染),修问题。
10. 再回 ESR 加 save_template:loom_saved_templates 迁移 + schema + LoomSavedSession Template + WebPlug 端点 + LV "保存" 按钮。
11. ESR 再编译;前端 LV 视图切换按钮加上;再 e2e。
12. 全部 commit + push(并入 PR #480 或新 PR,届时定)。

## 9. 不做(v1 不在范围)

- 用对话改动/创建 worker(2 号需求,显式 deferred)。
- 撤销/版本管理客户端态(session chat 历史已是审计/反悔通道)。
- 多人协作冲突解决(并发同时 page_update 时取后到为准,v1 不做合并)。
- saved template 的导出文件 / 分享外部(只是 workspace 内部记录)。
