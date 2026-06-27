<!-- 复制自 scenario-template.md。本条与 01-12 不同:它是**前瞻型分层验收场景**(forward-looking tiered acceptance),不是单次人肉执行流水账。见下「本条特殊说明」。 -->
# 场景 13(验收harness):AutoService 端到端

| 字段 | 值 |
|---|---|
| **状态** | ⬜ pending(Tier 1 部分可跑;Tier 2/3 deferred) |
| **类型** | **前瞻型分层验收场景**(tiered acceptance scenario)——既是 E2E harness,也是 AutoService roadmap tracker |
| **对应设计参照** | `docs/futures/autoservice-v3-reference.md`(能力附录:代码级扫描 + lead 决策"为什么")——⚠️ **当前只在未合分支 `origin/docs/autoservice-v3-reference`,尚未在 main**;下方 `../futures/...` 链接待该分支并入 main 后才解析 |
| **验证面** | 公开 customer chat surface(`/socialware/chat`)+ world 操作员 LV + 审计 |
| **执行人** | zyli / agent-browser |
| **执行时间** | <YYYY-MM-DD HH:MM>(各 tier 分次回填) |
| **环境** | 分支 `<branch>` · commit `<hash>` · server `<url>` |
| **前置 scenario** | 01(登录)· 02(建 agent)· 03(建 session+成员)· 04(往返)· 08(@mention 路由)——本条复用其黄金路径,不重抄 |

---

## 本条特殊说明(为什么它跟 01-12 不一样)

`docs/e2e/` 里 01-12 每条都是**单次真实执行的过去式记录**(「我点了 X、看到 Y」)。本条不是:它把 AutoService 这个**产品**的"端到端能跑通"定义成**一个分层场景**,作为验收 harness——

- **"AutoService 端到端能跑通" = 本场景过 = DoD**,而不是一张孤立 feature 勾选表。
- roadmap 里的每个能力(KB / CR / 计费 / WS 契约 / 语音)降级成**本场景的一个 tiered step**:**只为某个 step 需要才建**(build-only-what-a-step-needs)。
- 因此本条同时是 **roadmap tracker**:下方「能力-状态主表」每行 = 一个 step → 它行使的能力 → 该能力当前状态(done / in-impl / spec'd / not-started)→ 该 step 的机器可判 pass 断言。

**Tier 分期**:

| Tier | 含义 | 当前可跑性 |
|---|---|---|
| **Tier 1** | 核心、近期——大体现可建:customer 到达 surface → 与 agent 聊 → agent **查 KB** 作答 → **操作员**在 console 看/管该 session | **部分可跑**(KB 已合,但缺"会话 agent 暴露 kb_query + 已 ingest 内容的 kb-agent"的 seed 接线;另撞 GAP-1/4/5)。runbook 已填,断言可判。 |
| **Tier 2** | 操作员经 **CR 治理**改 agent config → 批准 → 生效 | **in-impl**(ConfigStore 原语已在,CR workflow 在建)。pass-criteria 已定义,runbook deferred。 |
| **Tier 3** | **计费**记用量;live surface 的 **WS 冻结契约**;**语音** ASR/TTS | **deferred**(计费 not-started;WS 契约 spec'd-partial;语音 spec'd-only)。pass-criteria 已定义,runbook deferred。 |

> ⚠️ **不伪造未发生的执行**:Tier 2/3 的步骤行是「期望步骤 + 能力 + 状态」,不是过去式观察。只有 **Tier 1** 填了 §8 agent-browser runbook 与可判断言;T2/T3 的 runbook 标 **"deferred — pass-criteria 已定义,尚不可跑"**。

---

## 角色

- **customer(匿名访客)**:`public_view` session 的 anon-User(`Ezagent.Socialware.AnonUser`,#51 §4.1),经 `/socialware/chat` 进入,无需登录。
- **AutoService agent**:一个会话 agent(会回显/会调工具),挂在该 session;Tier 1 需它能调 `kb_query` MCP 工具去查 KB。
- **kb-agent**:`kb` 角色 × `native` flavor 的 passive 数据 actor(`entity://<ws>/agent/<kb-name>`),持一份已 ingest 的语料(per-KB sqlite,FTS5)。
- **操作员(session-manager)**:登录的 human(`entity://system/user/admin` 或非 admin),在 world LV(`http://world.localhost:10042`)看/管该 session。

---

## 能力-状态主表(= step 映射 + roadmap tracker)

> 每行 = 一个场景 step。**provenance** 引用 v3 参照 + 实际代码/issue。**状态**:🟢 done · 🟡 in-impl · 🔵 spec'd · ⚪ not-started。
> **pass 断言**用 guide §8.4 谓词(机器可判)。这张表就是 tracker:能力状态变了,改这一格。

| # | Tier | Step(行使的能力) | Provenance(v3 §/issue/文件) | 状态 | Pass 断言(§8.4) |
|---|---|---|---|---|---|
| **S1** | 1 | customer 经 `/socialware/chat?session_uri=<enc>` 进入 public_view session,匿名落地、被 join,看到对话 SPA | `chat_feed_controller.ex`(#51 §4.1 anon-User);v3§1 WS"部分"(角色路由 socket 已有) | 🟢 done | `url~ /socialware/chat` · `visible [data-world-component=conversation]`(或 chat SPA 根) |
| **S2a** | 1 | session 带一条默认 `always → AutoService-agent` 路由规则,**customer 的裸消息**(不打 @handle)就能送达 agent | **路由 CRUD**;scenario-22(routing-crud,🟩);scenario-04 发现"新 session ROUTING=0,无 @ 不送达" | 🟢 done(能力)/ 🟡 需 seed 这条规则 | session 有一条 `always→<agent>` rule(管理面可见 / 审计 dispatch 命中) |
| **S2b** | 1 | customer 发**裸**问题(不知道也不该敲 agent handle),AutoService agent 收到并回一条 | scenario-04/08(往返,🟩);v3§1 附件"已覆盖" | 🟢 done(机制,**前提 S2a 路由规则**) | `text~ [data-sender-kind=agent][data-mine=false] "<答案片段>"` |
| **S3** | 1 | agent 回答时**走 orchestrator 工具循环调 `kb_query`** 检索 kb-agent 语料,答案含 KB 命中片段(带 provenance) | **#1036 kb 角色×native**;`ezagent_plugin_kb/behavior/kb.ex`(FTS5);`orchestrator/tools/kb.ex` + `session_manager.ex:474`(`run_tool_op(:kb_query)`);orchestrator 工具是 **MCP server**,由 **cc-flavor orchestrator agent** 经 MCP bridge 调用(`cc_orchestrator_seed.ex`);v3§2.1 | 🟢 done(KB 引擎+工具已合)/ 🟡 **接线+flavor 缺口**(见下注) | `text~ ... "<只可能来自 KB 语料的片段>"`(答案命中 ingest 的源,非模型先验);辅证:审计有一条 kb-agent 的 `kb:query` `granted` invocation |

> **S3 flavor 判别(关键,决定 Tier 1 今天是否可跑)**:`kb_query` 是 **orchestrator MCP 工具**,只有跑**工具调用循环**的 flavor 能调它。实测代码:① **cc**——经 `cc_orchestrator_seed.ex` 的 orchestrator MCP bridge 暴露该 7-tool 面(含 kb),是唯一现成走工具循环的 flavor,但 **UI-create 坏**(GAP-4)、**PTY 往返 FAIL**(scenario-05);② **curl/DeepSeek**(scenario-07 🟩)是**裸 HTTP 回复、无工具循环**,**不经 `run_tool_op(:kb_query)`**,故**不能做 S3**;③ seeded `py_default` 是 echo、**不能调工具**。→ S3 的 AutoService agent 须是 **cc-flavor orchestrator agent**,并背 cc 的已知 bug(scenario-05/GAP-4)。这是 Tier 1 真正能判 🟩 前的核心阻塞。
| **S4** | 1 | **操作员**在 world Sessions 列表看到该 customer session,Open 进会话页,看到成员名册 + transcript(含 S2/S3 往返) | scenario-03(建 session+成员,🟩)+ scenario-29(admin LV smoke);v3§1 console | 🟢 done | `url~ /sessions` · `attr li[data-kind=agent] data-online=true` · `text~ [data-world-component=conversation] "<S2 的答案片段>"` |
| **S5** | 2 | 操作员发起一个 agent config 变更(改 prompt/skills/绑定的 kb-agent),进入一个 **draft / change-request** | **CR 治理(近期 A)**;原语:`config_store.ex`(不可变 `ConfigObject` append-only + `ConfigPointer`)、`config_evolve.ex`;v3§2.2 "扩展不重建" | 🟡 in-impl(原语🟢;draft 聚合+CR 概念在建) | (deferred runbook)CR 创建后:`attr #world-root data-last-dispatch=ok` + 存在一个 status=draft 的 change-request 引用新 ConfigObject |
| **S6** | 2 | review 门:lint + sandbox-vs-released diff + 二次确认;批准 | CR 治理 review 门;diff 读 ConfigStore + projection;v3§2.2(2) | 🟡 in-impl | (deferred)review 视图显示非空 diff;approve 后 CR status=approved |
| **S7** | 2 | publish 仪式:promote draft → 翻指针(`write_and_point`/repoint **已有**)→ 新 config 生效;(可回滚=repoint 回保留对象) | `config_store.ex` `write_and_point/1` + rollback=repoint(🟢);CR publish 动作(🟡);v3§2.2(3) | 🟡 in-impl(repoint🟢;publish workflow🟡) | (deferred)publish 后 agent 行为反映新 config(如改了 persona,下一轮回复风格变);rollback 后恢复旧对象 |
| **S8** | 3 | 计费:本 session 的每次 agent 调用/KB 检索/token 用量被**记一条用量**,可在看板看到 | **计费(后期 D)**;v3§1"真空白"、§3 D"纯空白零耦合";仓内**无** billing/metering/invoice/quota 模块(仅 `rate_limiter.ex`/`invite_code.ex`) | ⚪ not-started | (deferred)每次 S2/S3 调用产生一条 metering 记录;看板聚合 == 审计 invocation 计数 |
| **S9** | 3 | live surface 走**冻结 WS 契约**:`{v,type,id,ts,ref,payload}` envelope + `client_hello/server_hello` 版本握手 + 语义 close 码 + admin 全局事件端点 | **WS 契约(中期 C)**;机制已有(游标 replay by `committed_seq` + 角色路由 socket)v3§1"部分"/§3 C;缺契约+握手+admin 端点 | 🔵 spec'd(机制🟢,契约形式化🔵) | (deferred)connect 收到 `server_hello{v}`;断线重连按 `committed_seq` idempotent replay 无重复无丢;admin 端点收到全局事件 |
| **S10** | 3 | 语音:customer 说话 → ASR 转文字进 agent;agent 回复 → TTS 出语音 | **语音(后期 E)**;v3§1"空白但已有设计"、§3 E;`IMPLEMENTATION_ROADMAP.md §9c`(`Entity.MediaSession`/`media://`/`MediaSignaling`,record-only 设计);仓内**无**代码;依赖 S9 | 🔵 spec'd(设计在 roadmap,无代码) | (deferred)语音入站转写文本进 transcript;agent 文本回复产出可播放 TTS;媒体面与控制面分离 |

**状态汇总(roadmap 快照)**:Tier 1 = KB 引擎🟢 / 接线🟡;Tier 2 = 原语🟢 / CR workflow🟡;Tier 3 = 计费⚪ / WS 契约🔵 / 语音🔵。

---

## DoD —— 每个 Tier "passing" 的定义(= 验收门)

> 完成 AutoService **不是**勾完一张 feature 表,而是**本场景对应 tier 过**。

### Tier 1 PASS 意味着(核心验收门)
全部成立才算 Tier 1 🟩:
1. **S1**:匿名 customer 经 `/socialware/chat` 进 public_view session,被 join,看到对话面(`visible` 对话根)。
2. **S2a+S2b**:session 带默认 `always→agent` 路由规则,customer 发**裸**问题(不打 @handle)→ AutoService agent 回一条(`text~` agent 气泡含答案)。
3. **S3**(**Tier 1 的灵魂**):答案**确实来自 KB 检索**——含一个**只可能来自已 ingest 语料**的片段(排除模型先验),且审计有对应 kb-agent `kb:query` `granted` invocation。
4. **S4**:操作员在 world console 看到该 session、成员在线、transcript 含上面的往返。

**Tier 1 当前不能直接判 🟩 的诚实结论**:
- KB 引擎(query/ingest/FTS5/cap 隔离)+ orchestrator `kb_query` 工具 **已合**(#1036,有 `kb_role_native_test.exs`),但**缺**把"一个跑工具循环的会话 agent + 一个已 ingest 内容的 kb-agent + 一条默认路由规则 + public_view"接成一条**可经 chat surface 跑通**的 **seed/wiring**。S3 因此是 **spec'd, partially buildable**,不是"今天就过"。
- **S3 的 flavor 阻塞**(核心):能调 `kb_query` 的只有走工具循环的 flavor = **cc-flavor orchestrator agent**(经 orchestrator MCP bridge)。但 cc **UI-create 坏**(GAP-4)、**PTY 往返 FAIL**(scenario-05);curl/DeepSeek 虽 🟩 但**无工具循环、做不了 S3**;py_default 是 echo 调不了工具。→ Tier 1 灵魂步骤目前卡在 cc 的已知 bug 上。
- **撞 S2a 路由**:新建 session 默认 ROUTING=0(scenario-04 发现),裸消息不送达 → 必须 seed `always→agent` 规则,否则 customer 不打 @ 没人回。
- **撞 GAP-1**(New Agent UI 建不出可对话 agent,`py` 缺脚本入口)→ 建 AutoService agent 的前置目前要么走 seeded agent、要么 CLI/seed,不能纯 UI。
- **撞 GAP-5**(无 session/成员 teardown)→ 反复跑会累积 customer session,只能 `mix ezagent.db.reset` 清。
- 这些 caveat 是 Tier 1 真正"全绿"前的已知阻塞,记在此处而非假装干净。

### Tier 2 PASS 意味着
- **S5→S6→S7** 成链:操作员从 console 发起 config 变更 → 落 draft/CR → review 门给出 sandbox-vs-released **非空 diff** + 二次确认 → publish 翻指针 → **agent 行为反映新 config**;且 **rollback = repoint 回保留对象**可逆。
- 硬约束(v3§2.2):**严禁从零重建** rollback/版本机制——必须建在 `config_store.ex` 既有 repoint 原语上。
- 当前:原语🟢,CR workflow🟡 → runbook deferred,但上述 pass 断言已定义,workflow 一落地即可填 runbook 重放。

### Tier 3 PASS 意味着
- **S8 计费**:S2/S3 每次调用都留一条 metering;看板聚合 == 审计 invocation 计数(对账一致)。
- **S9 WS 契约**:connect 收 `server_hello`;断线重连按 `committed_seq` 幂等 replay(无重无漏);admin 端点收全局事件。
- **S10 语音**:ASR 文本进 transcript;agent 回复出 TTS;媒体/控制面分离(roadmap §9c)。
- 当前:计费⚪ / 契约🔵 / 语音🔵 → runbook deferred;pass-criteria 已定义,作为各能力立项时的验收靶。

---

## 实测结果 vs 预期(分次回填)

| Step | 预期 | 实测 | 一致? |
|---|---|---|---|
| S1 | 匿名进 public_view chat,被 join | <回填> | — |
| S2a | session 有默认 always→agent 路由规则 | <回填> | — |
| S2b | customer 裸消息送达 → agent 回一条 | <回填> | — |
| S3 | 答案含 KB 命中片段 + 审计 kb:query | <回填> | — |
| S4 | 操作员 console 看到 session+成员+transcript | <回填> | — |
| S5-S10 | (deferred:对应 tier 立项后回填) | — | — |

## 遗留 / bug

- **Tier 1 接线缺口**(见上 DoD):缺 seeded「会话 agent 暴露 kb_query + 已 ingest kb-agent」链 → S3 暂不可直接判绿。建议补一条 `e2e-autoservice` seed(kb-agent + ingest 一份固定语料 + 会话 agent 绑定),把 S3 变成确定性可重放。
- **GAP-1 / GAP-4 / GAP-5**(`notes/2026-06-26-product-gaps.md`):分别阻塞"UI 建可对话 agent"、"cc UI-create"、"session teardown",均影响 Tier 1 的干净可重复执行。
- **错误可见性**(product-gaps 备注):后端 reject 只落 `data-last-dispatch`,无 toast/inline——customer/操作员看不到为什么,Tier 1/2 的失败模式取证要靠 `data-*` 而非 UI 文案。

## 证据清单(分次回填)

- `evidence/scenario-13/s13-s1-chat-anon-landing-auto.png` — customer 匿名落地 public_view chat
- `evidence/scenario-13/s13-s2-agent-reply-auto.png` — AutoService agent 回复
- `evidence/scenario-13/s13-s3-kb-hit-auto.png` — 答案含 KB 命中片段
- `evidence/scenario-13/s13-s4-operator-console-auto.png` — 操作员 console 看到该 session
- (S5-S10:对应 tier 立项后补)

## 交叉引用

- **能力附录(why)**:`docs/futures/autoservice-v3-reference.md`(代码级扫描 + lead 2026-06-26 决策)——**保留不删**;本场景是 tracker/DoD(what passes),它是能力 rationale(why)。两者互链(见下"supersede 结论")。
- 复用的 E2E 黄金路径:scenario-01/02/03/04/08/29。
- 设计参照来源:#1031(gaga AutoService v3 评估)+ #1024(6 项 parity gap)+ #1036(kb 角色×native)。
- 关键代码:`apps/ezagent_plugin_kb/lib/ezagent/behavior/kb.ex`、`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/kb.ex`、`apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`、`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`、`apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex`。

### supersede 结论(回答 lead 的明确问题)
**不让本场景取代 `autoservice-v3-reference.md`;两者共存、互链**:
- `docs/futures/autoservice-v3-reference.md` → **能力附录**:留住代码级扫描 + lead 决策的"为什么"(KB 为何走 resource+kb 不建 domain、CR 为何是扩展不重建、哪些不抄 v3)。
- 本 scenario-13 → **tracker + DoD**:"什么算过"。
- 这正符合本目录既有的**设计层 / 执行层分离**约定(README:`docs/scenarios/`=设计,`docs/e2e/`=执行)。
- ⚠️ **当前状态**:v3 参照**仅在未合分支** `origin/docs/autoservice-v3-reference`,**尚未在 main**。两件事待该分支并入 main 后做:① 本文对它的 `../futures/...` 链接才解析;② 在 v3 参照顶部加一行回链到本 scenario-13。**见 open question #4。**

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**仅 Tier 1 填可跑步骤**;Tier 2/3 runbook deferred(pass-criteria 已在上方 DoD 定义,workflow/能力落地后再填)。 -->

**前置(自动化,当前未全部满足——见「遗留」)**:干净 seed + scenario-01/02/03 已跑(操作员可登录)。**本场景额外接线**(缺一不可):
- 一个 `kb` 角色×native 的 kb-agent **已 ingest** 一份固定语料(含一段只在语料里出现的 fact);
- 一个 **cc-flavor orchestrator agent** 作 AutoService agent(经 orchestrator MCP bridge 暴露 `kb_query`;**注:cc UI-create=GAP-4、PTY 往返=scenario-05 FAIL,须先解决或用 seed/CLI 绕过**);
- session 设 `public_view: true` + 一条默认 `always→<AutoService-agent>` **路由规则**(否则裸消息 ROUTING=0 不送达,scenario-04);

**此接线落地前 S2b/S3 不可判绿。**
**入口 URL**:customer = `http://localhost:10042/socialware/chat?session_uri=<encodeURIComponent(session-uri)>`;操作员 = `http://world.localhost:10042/sessions`
**额外前置(customer SPA bundle)**:`/socialware/chat` 加载 `/assets/js/customer_app.js`(+ `customer.css`),须先 `mix assets.build`(见 `ezagent-socialware` skill 的 `local-e2e-recipe.md` §0/§3)。
> ⚠️ **selector 来源**:`/socialware/chat`(ChatFeedController)是 **customer React SPA**(`customer_app.js`),**不是** world UI——别用 guide §8.2 的 world 专属锚点。下表 step1 的文本锚点("Your conversation" / "No messages yet." / 复合框)取自 `ezagent-socialware/references/local-e2e-recipe.md`(该 recipe 已 agent-browser 实证**只读视图**)。⚠️ **但 recipe 只证了匿名访客的只读 feed,未证 customer→agent 的 send 往返**(step2-4):composer 存在,但"裸消息发出 → 路由到 agent → 回包回显到 customer SPA"这条链在 customer surface 上**尚无实证**,step2-4 的 user/agent 气泡 selector 视为 **provisional**,首跑前须对 `customer_app.js` 真实 DOM 校正。step6-7(world console)锚点已在 scenario-03/04 实测。

### Tier 1 runbook

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | navigate(customer 匿名进 public_view chat) | `/socialware/chat?session_uri=<enc>` | — | `url~ /socialware/chat` + `text~ <SPA 根> "Your conversation"`(recipe 实证锚点) | `s13-s1-chat-anon-landing-auto.png` |
| 2 | type **裸**问题 + 发送(**不打 @handle**——customer 不知 agent handle;靠 S2a 路由规则送达) | customer SPA composer 输入框(`customer_app.js`,**精确 selector 待校正**) → `keyboard type '<只有 KB 答得出的问题>'` → `press Enter` | `<裸问题>` | customer 自己气泡:`text~ <user 气泡, 待校正> "<问题片段>"` | — |
| 3 | wait agent 回复 | `<customer SPA agent 气泡, 待校正>` | — | **S2b**:`visible <agent 气泡>`(注:customer→agent send 往返尚无实证,见上警告) | `s13-s2-agent-reply-auto.png` |
| 4 | assert 答案含 KB 命中(灵魂断言) | agent 气泡文本 | — | **S3**:`text~ <agent 气泡> "<只可能来自 ingest 语料的片段>"` | `s13-s3-kb-hit-auto.png` |
| 5 | (审计辅证)查 invocations 有 kb:query granted | `mix run --no-start`(scenario-12 同法)或审计面 | — | 存在一条 kb-agent `kb:query` `granted` invocation(关联本 session turn) | — |
| 6 | navigate(操作员 console) | `http://world.localhost:10042/sessions` → 该 session 行 "Open" → `/sessions?session=<enc>` | — | **S4**:`url~ /sessions` + `attr li[data-kind=agent] data-online=true` | — |
| 7 | assert transcript 含 customer 往返 | `[data-world-component=conversation]` | — | **S4**:`text~ [data-world-component=conversation] "<S2b 答案片段>"` | `s13-s4-operator-console-auto.png` |

**断言映射**:S1→step1;S2a→前置路由规则;S2b→step3;S3→step4(+step5 审计辅证);S4→step6+step7。任一 fail = 🟥,不自己改代码修(guide §6)。

### Tier 2 runbook —— **deferred**
pass-criteria 见上「Tier 2 PASS 意味着」(S5 draft/CR → S6 review 门非空 diff+二次确认 → S7 publish 翻指针生效 + rollback repoint 可逆)。CR workflow 落地后照该断言填可执行步骤;**严禁重建 rollback/版本机制**(用 `config_store.ex` repoint)。

### Tier 3 runbook —— **deferred**
pass-criteria 见上「Tier 3 PASS 意味着」(S8 计费对账;S9 WS `server_hello`+幂等 replay+admin 端点;S10 ASR/TTS 媒体面分离)。各能力(计费⚪ / WS 契约🔵 / 语音🔵)立项后填。

**清理**:删本场景自建 customer session + kb-agent(注意 **GAP-5**:当前无 session/成员 teardown 入口,可能只能 `mix ezagent.db.reset` 全量重置)。

---

## 给 lead 的 open questions

1. **本场景落点**:已放 `docs/e2e/scenario-13-...`(执行/harness 层,因 §8 断言+runbook 机制在此目录)。任务原文提到 `docs/e2e/scenarios/`(不存在)——是否要新建该子目录?或本条另在**设计层** `docs/scenarios/36-autoservice-end-to-end/` 也立一份(设计层讲"应该怎样/失败模式")?当前判断:harness 归 e2e/13,设计 rationale 留 v3 参照,不重复。
2. **Tier 1 S3 接线缺口**:是否同意补一条 `e2e-autoservice` seed(kb-agent + 固定语料 ingest + 会话 agent 绑 kb_query + public_view session),把 S3 从"spec'd/partially buildable"变成确定性可绿?这是 Tier 1 真正能判 🟩 的唯一缺口。
3. **GAP-1/4/5 优先级**:Tier 1 的干净可重复执行被这三个 UI 缺口卡(建可对话 agent / cc UI-create / session teardown)。是否在 AutoService Tier 1 验收前先清这三条?
4. **supersede + 合并**:确认 `autoservice-v3-reference.md` 作为**能力附录保留**(不被本场景取代)。它目前**只在未合分支 `origin/docs/autoservice-v3-reference`**——是否把该分支并入 main(这样本文的 `../futures/...` 互链才解析,且可在其顶部加回链)?
5. **Tier 边界**:Tier 1 是否就锁定为「KB 答问 + 操作员可见」?CR(Tier 2)与计费/WS/语音(Tier 3)的分层是否照 v3§3 的近期 A/B、中期 C、后期 D/E 对齐(本表已如此映射)?
