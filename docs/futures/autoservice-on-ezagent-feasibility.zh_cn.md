# AutoService 职能落在 ezagent 上 — 可行性 / 缺口分析

> **状态**: 活文档(working doc),实施期持续更新
> **创建**: 2026-05-29
> **目的**: 评估"基于 ezagent 现有理念与框架,在不改 core/domain 的前提下,实现 AutoService 的职能"——哪些能做、哪些缺失、最小可行体到什么程度,作为后续分析与实施的基准。
> **范围基准**: AutoService 侧只参照 `AutoService-dev-a/docs/architecture/autoservice-overview.md`(2026-05-26 现状),**只看在用的新流程,回避已废弃代码/逻辑**(见 §2 的废弃清单)。ezagent 侧权威源为 `.claude/skills/ezagent-developer/references/design-principles.md`(P1-P27)+ `ARCHITECTURE.md`。

---

## 0. 约束与"不添加代码"的两种解读

实施前必须先定义清楚"不添加代码",两种解读结论完全不同:

- **解读 A — 字面零代码**: 只用现成 plugin(cc / feishu / liveview)+ 配置(Workspace / Session / Template / 路由规则 / Capability 授权)+ dispatch。能做出来的是一个**最小客服 bot**(见 §4)。
- **解读 B — 不改 core/domain,但可写 plugin**: 这是 ezagent 自己的哲学(**P1 北极星** = "加扩展就写一个隔离 plugin,永不碰 core")。按此解读,AutoService 大部分职能**可实现,但都属于"写新 plugin",不是零代码**。这是 ezagent 设计上**预期**的扩展方式。

> 本文用 ✅(零代码可达) / ⚠️(部分,需配置 + 少量取舍或补页面) / ❌(缺失,需按 P1 写新 plugin/domain)三档标注。

---

## 1. 关键架构错配(实施前必须正视)

AutoService 是**客户在等回复**的客服/销售场景(req/resp + 流式安抚);ezagent 的根理念是 **router,没人在等结果**(`ARCHITECTURE.md` §1.2 差异 1)。

- **不是 blocker**: Feishu inbound 已用 `:call` 模式把回复同步冒泡回人(P18),客服场景照此走即可。
- **是真缺口**: AutoService 的 **Pipeline v2** 核心价值正是"边等边安抚/填充 + 超时兜底 + 熔断"这套**时序编排**(deepseek 即时安抚 → filler loop 每 N 秒 → cc 主回复 → 45s 硬超时道歉 → 连败 3 次熔断回退)。ezagent 的 dispatch 是单路径,`:call` 只够把**最终**回复带回,不提供"等待期间的多段流式输出"原语。这是离现成能力最远、又最不可省的一块。

---

## 2. AutoService 当前职能清单(只列在用的)

参照 overview 现状,**以下为当前在用**:
- 通道: Web chat(`/ws/customer` + ASR/TTS)、general bot(`/chat/{tid}` SSE,CINNOX 兼容)、Voice(`/ws/voice`,e2e/split)。**Web chat 是首选/所有新功能主战场**。
- Pipeline v2: deepseek 快慢双模 + filler + KB MCP(cc 内部 tool call)+ 超时 + 熔断。
- cc_pool: 多角色 Claude 进程池,按 `(tenant_id, role)` sticky 复用,发布后 recycle。
- 4 层 Soul(L0 框架 / L1 平台 / L2 行业 / L3 租户)+ 模板槽位渲染;4 层 Skill。
- KB: per-tenant sqlite,`kb_type` 分 `product_knowledge`(可检索)vs `flow_directive`(内部规则,**永不返客户**);URL/文件抓取。
- triage: LLM 意图分类 → 命中 `flow_directive` 注入 prompt。
- CR 驱动 sandbox→release: CR 收集 / 实时 diff / lint / 红色二次确认 / 版本指针 flip / cc_pool recycle / 回滚。
- Admin Portal V2: 租户 + 平台双视角,master_admin/tenant_admin RBAC。
- 人工接管: `/ws/operator` console、takeover、direct_transfer、handoff。
- 输出指令: `[线索]` / `<handoff/>` / `DIRECT_TRANSFER` / `[SENTIMENT]` 集中注册解析。
- Dream: 半自动改进建议审核。
- 计费 / SLA / canary / alerts / observability。
- 存储两棵树: git monorepo(工程内容)+ 租户数据仓(`.autoservice/data/`,**不入 git**);**新增租户走 `/api/admin/onboard/start`**。

**以下为已废弃,分析时回避**(overview §3.3 + 附录 A):
- "三层 fork 架构"(per-tenant fork 仓库)→ 已切"两棵树 + onboard"。
- 旧存储路径: `runtime/sandbox/<tid>/`、`.autoservice/sandbox/`、`.autoservice/released/v<N>/`、`.autoservice/current/`、`plugins/<tid>/skills/`。
- Feishu 通道 = legacy,**停止同步新功能**(仅单租户 IM,要恢复需补 ModelRouter/triage/tenant 注入)。
- `CLAUDE.md` 开头 "Three-layer fork-based framework" 表述 = stale。
- V1 admin `/legacy/*`、弃用 env(`PLACEHOLDER_ENABLED` 等)、`CRSource.DOCS_REGEN`。

---

## 3. 映射表: AutoService 当前职能 → ezagent 现成能力

### 3.1 能直接落地 / 部分落地(✅ / ⚠️)

| AutoService 当前职能 | ezagent 现成对应 | 程度 |
|---|---|---|
| 多租户隔离(两棵树 / onboard,非 fork) | Workspace Kind + `workspace_uri NOT NULL` 结构隔离(P17/P21) | ✅ 一租户 = 一 workspace,与当前 onboard 模型同形 |
| 内容两棵树(git 工程内容 vs 租户数据仓) | 工程内容 = domain/plugin 代码 + seed Template;租户数据 = per-workspace DB 行 + content-addressed template `@<hash>` | ✅ 概念对齐(当前模型) |
| 身份 / 登录 / RBAC(master/tenant admin) | `ezagent_domain_identity`(User/Tokens/ApiKeys/Credentials)+ Capability CapBAC(P15) | ✅ admin 隔离 = workspace cap scoping |
| cc 主回复 + cc_pool(多角色 sticky) | `ezagent_plugin_cc` 的 cc agent(`entity://agent/cc_<name>`),每 workspace 多个长期 agent 进程 | ✅ Pipeline v2 的 cc 那一格 |
| KB MCP 注入机制(cc_pool 自动注入 `autoservice_kb`) | orchestrator MCP infra(`mcp_server/registry/channel`)+ cc plugin `mcp_config_writer` | ✅ **管道**强匹配(KB 内容/检索仍缺,见 §3.2) |
| 会话上下文 + 历史 | Session Kind(routing context owner)+ `MessageStore`(单一真相源) | ✅ |
| 管理后台外壳 | `ezagent_plugin_liveview` + `ezagent_domain_ui`(IdeShell/组件) | ⚠️ 壳在,业务页面缺 |
| 配置 recipe + 版本/快照(released/snapshots/pointer) | SessionTemplate/AgentTemplate 内容寻址 + fork=配置 only(P26) | ⚠️ 有版本/快照原语,无 CR 工作流 |
| 审计 / 遥测 | core `Audit` + 每次 dispatch `:start/:stop/:exception`(P19/P22) | ⚠️ 原始遥测在,billing/SLA 聚合缺 |
| 人工接管(operator) | User Kind 作 Session 成员,dispatch 支持人当 Principal | ⚠️ primitive 在,接管语义/console 缺 |

### 3.2 缺失,需按 P1 写新 plugin/domain(❌)— 按优先级

| 缺口 | 现状重要性 | 为什么现成框架不够 | 落地方式(P1) |
|---|---|---|---|
| **Web chat 客户通道 + `/chat` SSE(CINNOX 兼容)** | ⬆️ 当前**主通道** | ezagent web 入口是 LiveView(admin dogfood),无品牌化客户 widget、无 SSE/CINNOX adapter | 新 adapter plugin(Phoenix transport,P12/P13) |
| **Pipeline v2 编排**(快慢双模 + filler + 45s 超时 + 熔断) | 每条消息核心路径 | dispatch 单路径,无"边等边流式输出"原语 | 新 orchestrator Behavior |
| **语义 triage → flow_directive 注入** | 每轮预处理 | Matcher 只有结构 leaf(from/mention),无 LLM 意图分类 | 新 Behavior(分类)+ 动态路由 |
| **KB 存储 + 检索**(per-tenant sqlite、product/flow 分流红线、URL/文件抓取) | cc 的知识来源 | 只有 MCP 管道,无 KB 实体/检索/抓取 | 新 plugin:KB MCP server 实现 |
| **4 层 Soul 合成**(L0/L1/L2/L3 优先级覆盖 + `{{slot}}` 渲染) | prompt 组装方式 | Template 是单层 config,无分层 merge / 模板渲染 | 新 domain:分层 prompt resolver |
| **CR 沙箱→发布工作流**(CR 收集 / 实时 diff / lint / 红色二次确认 / 回滚 / cc_pool recycle) | 管理员改配置唯一路径 | 有内容寻址 template,无 CR 生命周期 | 新 domain + LiveView 页面(大头) |
| **输出指令解析**(`[线索]`/`<handoff/>`/`DIRECT_TRANSFER`/`[SENTIMENT]`) | reply 后处理 | reply 就是一条 Message,无 tag→副作用 | 新 Behavior(reply 后处理),handoff = dispatch 到 operator |
| **Voice**(ASR/TTS、e2e/split、豆包/MLX) | 独立通道(Pipeline v2 不覆盖) | ezagent 无任何语音 | 新 adapter plugin |
| **Dream 自我演进** | admin 功能 | 纯业务 | 新 plugin(可复用 cc agent) |
| **Billing/SLA/canary/alerts** | 运营 | 只有原始遥测 | 新 domain(消费遥测) |

---

## 4. 最小可行体(MVP,纯配置零代码 — 解读 A)

> **目标租户**: `cinnox`(对齐 AutoService 真实参考客户)。
> **目标**: 一个租户、一个客服 agent、web 文本通道、**会话路径通**。只用现成 plugin(cc / liveview / identity)+ 配置 + 一个 soul 文件,**不写 Elixir**。
> **main 重评(2026-05-29)**: PRs #462-#473 的新 Behavior 契约(`invoke/4` 删除、改 action 宏 + effects + `:dispatch_returning`)**不影响纯配置 MVP**(配置路径不写 Behavior)。唯一需修正的认知:**cc agent 的 soul = 文件系统里的 `CLAUDE.md`,不是 Template 的 inline 字段**(见步骤 3)。

### 4.1 组成(全部是配置/数据,不是代码)

| 件 | 具体 URI / 路径 | 用现成的什么 | 作用 |
|---|---|---|---|
| 租户 | `workspace://cinnox` | Workspace Kind | 隔离边界(白送多租户) |
| 客服 agent | `entity://agent/cinnox/cc_support` | cc agent(`cc.agent` Template Class) | 真正回话的 Claude 进程 |
| soul | `cc_support` 的 `claude_config_dir/CLAUDE.md` | cc plugin per-agent config dir | 系统提示词(**单层**,文件) |
| 会话 | `session://<type>/cinnox/<conv-id>`(type 取决于 Template Class,如 generic) | Session Kind + `MessageStore` | 多轮上下文 + 历史持久化 |
| 通道 | LiveView IM dogfood 前端 | `ezagent_plugin_liveview` | 客户在浏览器发消息 |
| 登录 | magic link / 密码 | `ezagent_domain_identity` | 客户/管理员认证 |
| 路由 | RuleStore 一条规则 → `cc_support` 当默认 receiver | `Ezagent.Routing.*` | 客户消息投到 agent(绕开 mention-gating) |
| 权限 | 客户 User → `chat.send` 到该 session;`cc_support` `default_caps` 含回复 | Capability(AgentTemplate `default_caps`) | CapBAC 放行 |

### 4.2 一条消息的完整路径(会话怎么通)

```
客户在 LiveView 输入
   → dispatch chat.send 到 session://<type>/cinnox/<conv>
   → Routing.Resolver 解析规则 → 命中 cc_support
   → chat.receive 投给 entity://agent/cinnox/cc_support
   → cc agent 经 AgentBridge(WS)把消息喂给 Claude 进程
   → Claude 产出回复 → agent dispatch chat.send 回 session
   → MessageStore 落历史 + notify → LiveView 流式显示
```

### 4.3 "基础 soul 加载"在纯配置下到底是什么

**不是填模板字段,是放一个文件**:在 `cc_support` 的 per-agent `claude_config_dir` 里写一份 `CLAUDE.md`(= 客服人设/口径/红线),agent 实例化时随 `--settings` / `CLAUDE_CONFIG_DIR` 加载。已有先例:orchestrator 的 role-bootstrap(`cc_agent.ex` `apply_orchestrator_role_bootstrap/2`)就是"拷一棵 skill 树 + 往 CLAUDE.md 追加提示"。所以 MVP 的 soul = **一份 markdown,零 Elixir**。
> 注:AgentTemplate 的 slice 只存 `working_directory / claude_config_dir / settings_path / mcp_config_path / api_key_helper / default_caps`,**明确不含 prompt/model/tools**——这些都在指向的 config dir 里。

### 4.4 落地步骤(用现成手段)

1. 起 BEAM,确保 **cc AgentBridge 能连**(运维前提,见 4.6)。
2. 建 Workspace `cinnox`(admin LV / CLI / dispatch)。
3. 准备 `cc_support` 的 config_dir,写好 `CLAUDE.md`(soul)。
4. seed cc agent —— 参照现成 mix task `ezagent.demo.seed_cc_agent` / `seed_cc_sandbox`,指向上面的 config_dir + workspace。
5. seed 一条路由规则,让 `cc_support` 成为该 session 的默认 receiver(**避开 mention-gating**)。
6. 授 cap:客户 User 能 `chat.send` 到 session;agent `default_caps` 含回复 cap。
7. 打开 LiveView IM,登录,发消息,验证回复回来。

### 4.5 边界

**MVP 给你**: 多轮 AI 对话、持久历史、租户隔离、登录鉴权、一个 web 文本通道、人工兜底。
**MVP 没有**: KB 检索、triage、4 层 soul、CR 发布、Pipeline v2(安抚/填充/超时熔断)、SSE/CINNOX、语音、Dream、计费。

### 4.6 必须正视的运维/接线前提(诚实说)

- **cc agent 回复走 AgentBridge,不是纯 Behavior dispatch** —— 需要一个真实 Claude Code 进程连上 WS(运维前提,非代码,但"启动 BEAM" ≠ 自动就有)。
- **mention-gating**:默认规则只投 `$session_users` + `$mentions`;agent 不被 @ 就收不到 `chat.receive`,表现为"静默不回"。MVP 必须 seed 让 agent 当默认 receiver 的规则(步骤 5),否则会误判为坏了。
- **LiveView 是 admin/dogfood IM,不是品牌化客户 widget** —— 演示/内测够用;对外要换通道(进缺口区,需写 adapter plugin)。

---

## 5. 结论速记

- **零代码骨架可达**: 多租户 + 鉴权 + 会话 + 单 cc agent + 一个文本通道 + 人工兜底 + MCP 注入管道。命中 Workspace/Identity/Session/cc-plugin/MCP-infra,且对齐 AutoService **当前**的两棵树 + onboard 模型(非废弃 fork)。
- **价值层全是缺口**: web/SSE 客户通道、Pipeline v2 编排、语义 triage、KB 检索、4 层 soul、CR 发布 —— 都得按 P1 写新 plugin/domain。其中**通道**与 **Pipeline v2 编排**是离现成能力最远、最不可省的两块。

---

## 6. 待决问题 / 下一步

- [x] **路线确认**: 先走解读 A —— §4 纯配置 MVP(租户 `cinnox`),实证零代码会话路径。
- [x] **把 §4 MVP 真正配置跑通**(workspace → cc agent + soul → 路由规则 → LiveView 验证回复)—— **2026-05-29 完成,且超出 §4**(见 §7)。
- [ ] **下一步走解读 B**: 最小 AutoService + KB 写 plugin —— Phase 1(收口成可复现 plugin)进行中,见 §7.4。
- [ ] 缺口路线(解读 B)优先级: **web/SSE 通道 adapter** vs **Pipeline v2 编排 Behavior**(二者最高优先)。
- [ ] Pipeline v2 的"流式安抚/填充"是否要进 ezagent 的 dispatch 模型,还是限定在 adapter 层?(涉及是否触碰 router 根理念,可能需 Allen review,见 CLAUDE.md grill 文化)
- [ ] KB 红线(`flow_directive` 永不返客户)在 ezagent 的 MCP server 端如何用 Capability 表达?

> 下一步动作敲定后,在本文件追加对应章节(逐缺口的 P1 落地设计),保持本文为单一基准。

---

## 7. 实施评估(2026-05-29 追加 — MVP 实证后)

### 7.1 §4 MVP 实际结果:做到了,且超出文档

纯配置 MVP 在**更新后的 main(`8a8db6a`,含 #462-473 新契约)**上跑通,并比 §4 多做了三件事:

- ✅ §4 全部:`workspace://cinnox` + 用户(admin/op/alice/bob)+ cc agent + soul(CLAUDE.md)+ session + 路由 + 登录 + LiveView 回复路径。
- ➕ **KB 检索(闭了 §3.2 KB 缺口的一部分)**:为 cc 加了一个 `kb_search` **stdio MCP sidecar**,直接复用 AutoService 的真实 `query_expansion`(中英扩展)+ trigram FTS + `kb_type='product_knowledge'` 红线过滤。中文提问经扩展命中英文 KB,实测产品类问题能取知识作答。**这是 P1-clean 的**(python sidecar 挂给 cc,不碰 core/domain)。
- ➕ **fast/slow 双 agent**:fast=deepseek(用真实 `prompts.py` 的 ACK prompt,改纯文本输出)、slow=cc(CINNOX soul + kb_search)。路由让客户消息同时投两者。**这是 Pipeline v2 的退化版**(有 ack + 答案,**无**定时 filler / 45s 超时 / 熔断 / fast_phase·cc_phase 状态机)。
- ➕ **cc 提速**:`ANTHROPIC_MODEL=sonnet` + `MAX_THINKING_TOKENS=0`(对齐 AutoService cc_pool 的 `thinking={"type":"disabled"}` + sonnet/haiku),消除 Opus + 扩展思考的 ~24s 卡顿。

### 7.2 让 cc 在本机(WSL)跑起来的三个前提(诚实记录)

§4.6 只提了"AgentBridge 要连"。实测在 WSL 上还踩了三个,全部解决:

1. **erlexec env 崩** — BEAM 的 WSL `PATH`(~3KB,含 Windows `/mnt/*` + CJK 目录名)超 erlexec 限制 → 所有 PTY/cc agent spawn 即崩。修:启动用精简 PATH(去 `/mnt/*`);根治在 `ezagent_domain_pty` 的 `build_env` 加 env 净化(**Tier-2 domain 改动,见 7.3**)。
2. **`uv` 没装** — esr-bridge + kb_search MCP 都靠 `uv run --script` 拉起 → 必须装 uv(`~/.local/bin`)。
3. **claude 卡"信任此文件夹"对话框** — 新 cwd 首次启动 claude 弹 trust 提示,cc 的 auto-prompt 扫描器只认 dev-channels,不认 trust → claude 永远不初始化 MCP → `:no_bridge`。修:`domain_pty` 的 `default_auto_prompts` 加一条 trust 自动确认(**Tier-2 domain 改动**)。

### 7.3 触碰 domain 的两处(需独立 review,不混入 plugin)

cc-on-WSL 的根治靠两处 `ezagent_domain_pty` 改动:(a) `build_env` env 净化;(b) trust-folder auto-confirm。二者**惠及所有 cc agent,不止 autoservice**,属 domain_pty 合理改进 —— 但按 grill 文化应**独立 PR + Allen review**,不埋进 autoservice plugin。Phase 1 分支会携带它们(否则 demo 在 WSL 上跑不起来),但保持为**独立 commit**便于将来单独提取。

### 7.4 下一步:Phase 1(收口)→ Phase 2(补硬缺口)

- **Phase 1 — 把脆 MVP 收口成可复现 plugin(进行中)**:`feat/autoservice-cinnox` 分支(原 = 解读 B-lite:已有 plugin 外壳 + customer/operator LiveView + CustomerSession facade + 角色 caps + seed,但停在旧 main、未含 KB)rebase 到新 main,并**吸收 MVP 全套**(kb_search MCP + query_expansion + cinnox soul/flows + fast ACK prompt 全部 in-tree 进 `priv/`;sonnet/关思考启动 env 固化进 seed/脚本)。产出:**干净 checkout + 一条命令重建 demo**。落地 P6(完成=可复现/有不变式)。
- **Phase 2 — 补最硬两块(Pipeline v2 需 Allen)**:
  - **Pipeline v2 编排**:经新契约确认,`handle → {:ok, result, [effects]}` 是单次同步返回,`:dispatch_returning` 阻塞 —— **没有"边等长任务边定时多段输出"的原语**。只能落成**有状态 sidecar 进程**(每会话/轮一个 TurnOrchestrator GenServer:发 ack → `Process.send_after` filler 定时器 → 异步触发 cc → cc 回复到达即取消 + 45s 兜底)。它**能留在 plugin 层**(P1-clean),但"算不算违反 router 根理念"是理念级判断 → **先出设计草案过 Allen,再写码**(承接 §6 第 5 条待决)。
  - **web/SSE 客户通道 adapter**:若要超出 LiveView dogfood、对外品牌化(P12/P13 adapter plugin)。
- **§6 待决回应**:KB 红线(`flow_directive` 永不返客户)—— MVP 已在 **MCP server 的 SQL 层**用 `kb_type='product_knowledge'` 过滤强制(与 AutoService 同),**无需** Capability 表达;Capability 粒度对 sidecar MCP 属过度设计。

### 7.5 复现性风险(Phase 1 要消除的)

当前 MVP 几乎全是**树外运行时件**(启动 env + uv + kb 文件 + DB seed + 我手写的 kb_search MCP),**不可从干净 checkout 复现**,换机/重启易丢。Phase 1 的核心交付正是把这些固化进分支(plugin `priv/` + seed task + run 脚本),这也是"进插件"相对纯配置 MVP 的首要价值。
