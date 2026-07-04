# hello orchestrator-router 设计

> **Date:** 2026-07-03 · **Author:** zhaomato (via Claude) · **Branch:** `feat/hello-orchestrator-0703`
> **Depends on:** Option ① role×native migration (builder/concierge 已是 `Entity.Agent` + role,同分支)

## 目标

把 hello session 改成:**用户始终对着一个隐形的 per-session LLM 编排器**,由编排器**逐条消息**判断走 page-gen `builder` 还是只读 `concierge`,并**按需拉起**这两个 agent。对用户体验:输入框照旧打字,只是每条消息多一次分类 LLM 跳(可接受的延迟)。

## 为什么不是"框架 cc-orchestrator"

框架 `cc-orchestrator` 结构上是**团队配置器**(装静态规则),**不做逐条内容路由**(role 文档:"NEVER ask a worker to compute the next hop"),且与 socialware 的 Turn/Surface 状态机**无设计好的组合**;native flavor 也无 role-AgentTemplate 支持、persona 不能 per-template 定制。结论:框架编排器给不了"逐条内容路由"。因此用一个 **hello 自有的 `hello.orchestrator` role agent** —— 它是普通 socialware 成员,`:receive` 里做逐条分类+中继,正好落在同一套 dispatch 上,不碰 Turn/Surface。(可行性核查:`docs/together/2026-07-03` 探查,2026-07-03。)

## 架构

新增 role `hello.orchestrator`(native flavor,与 builder/concierge 同机制),`Ezagent.Behavior.HelloOrchestrator`。它是 session 里**唯一直接收用户消息**的成员(隐形默认收件人)。

```
用户打字
  → dispatch_post 一律 mention orchestrator(去掉 web 层 owner/访客分流)
  → HelloOrchestrator.:receive(仅对 user 消息动作)
       · 读 session owner → is_owner?
       · LLM 分类(复用 Generator/DeepSeek 管道):intent + identity
           - 非 owner 成员 → concierge(恒定,安全边界:非 owner 永无改页权)
           - owner → 意图:改页/加内容→builder;提问/导航→concierge
       · ensure 目标 agent 存在(不在则 spawn = 按需增加,identity/归属用)
       · 直接触发目标 agent 的生成逻辑(复用 Generator):
           - builder → `Generator.start(session_uri, text)`(驱动 Surface)
           - concierge → `Generator.concierge_start(session_uri, text, concierge_uri)`(署名 concierge 回复)
  → builder 生成页面上 Surface / concierge 答复 → 用户看到
```

**为什么直接触发 Generator 而非"转投消息给 agent 的 :receive"**:builder/concierge 的 `:receive` 本身只是薄触发器(体内就是调 `Generator.start`/`concierge_start`)。session fan-out 投递到成员 `:receive` 靠**为该成员现铸一枚窄 receive cap**(`delivery.ex:143` `caller: session_uri` + `member_receive_caps`)——若让 orchestrator 走消息转投,它得跨 agent 铸 cap,脆弱。直接调 Generator **产出完全一致**(同样署名、同样驱动 Surface),且 orchestrator 只需持有自己的 `:receive` cap,零跨 agent CapBAC。builder/concierge 仍作为成员存在(identity / @-mention / world 展示 / 模板捕获)。

投递靠现有 **mention 定向**:dispatch_post 只 mention orchestrator,故 builder/concierge 不会经广播额外收到用户消息(它们的 `:receive` 在此模型下由 orchestrator 直调 Generator 取代,成为休眠回退路径)。

## 组件

1. **`Ezagent.Behavior.HelloOrchestrator`**(hello plugin,新 Behavior,`use Ezagent.Lifecycle`)
   - `action :receive, caps: [:receive], modes: [:cast]`(与 builder/concierge 同形)。
   - `handle_receive`:`from_user?` 闸(防环)→ 读 owner → 分类 → ensure+转投。
2. **分类器**(`EzagentPluginHello.Generator` 内新函数,或 `Router` 子模块)
   - 输入:消息文本 + is_owner;输出:`:builder | :concierge`。
   - 复用现有 LLM 后端(`HELLO_LLM_BACKEND`)。**失败保底**:身份规则(owner→builder / 其他→concierge),绝不丢消息。
3. **role 注册**:`application.ex` `roles/0` 增加 `hello_orchestrator_recipe()`(behaviors `[HelloOrchestrator]`,`requested_caps` 含 `:receive` + 转投 builder/concierge 所需 cap;非 passive)。
4. **`App.ensure_app`**:建 + join orchestrator;builder/concierge 不再 eager 建,交给 orchestrator 按需 `ensure_session_builder`/`ensure_session_concierge`(已存在,复用)。
5. **`ensure_session_orchestrator/1`**(新,同 `ensure_session_builder` 套路):给已有 hello session 补 orchestrator 成员(新旧都要)。
6. **`session_feed_channel.dispatch_post`**:目标一律 orchestrator(删 owner/访客分支);mention-gating 不变。owner 判定逻辑从这里下沉到 orchestrator。

## 关键不变式 / 边界

- **"不能说话"闸门完全不动**(web 输入 + socialware 成员校验在 orchestrator 上游):匿名/非成员照样发不了。
- **非 owner 永无改页权**:身份先于意图 —— 非 owner 恒定 concierge,即使 LLM 也不给 builder。
- **防环**:orchestrator 仅处理 user-sender 消息;builder/concierge 产出是 agent 消息 → 被忽略。转投保留 sender=用户,故 builder 的 `from_user?` 通过。
- **builder/concierge 内部零改动**;socialware Turn/Surface 零改动。

## 转投的 CapBAC(实现时坐实)

orchestrator 直接 dispatch 到 builder/concierge 的 `:receive`,需要 `:receive` cap(`:agent` 轴)。实现时确认最干净的授权:orchestrator recipe `requested_caps` 声明该 cap(native `CapPolicy.for_recipe` 放行),或经 session 成员链授权。以现有 session→member fan-out 的授权路径为准。

## 错误处理

- 分类 LLM 失败/超时 → 身份规则保底。
- 目标 agent spawn 失败 → 记 telemetry + 保底转 concierge(只读,安全)。
- orchestrator 自身没起活 → dispatch 经 ReadyGate/SpawnRegistry 复活(与 builder 同)。

## 测试

- **单测(分类)**:owner 改页→builder;owner 提问→concierge;非 owner 任何话→concierge;分类失败→身份保底。
- **单测(防环)**:agent-sender 消息不触发 orchestrator。
- **端到端**:建 session → orchestrator 在场;owner 发"改成蓝色"→页面变;非 owner 发"你们几个人"→concierge 答、页面不变;匿名发不了。
- **回归**:existing-session `ensure_session_orchestrator` 幂等。

## 范围

新 + 旧 session(旧的经 `ensure_session_orchestrator` 补成员;dispatch_post 改动对所有 session 自动生效)。

## 非目标

框架 cc-orchestrator / MCP / add_managed_member / migrate_session / 模板版本化团队(2-agent hello 用不上;若将来要动态团队再评估)。
