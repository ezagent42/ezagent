# PoC 发现 —— AutoService 客服能力迁移到 ezagent:Gap 与阻塞

> 2026-06-01。**本 PoC 的核心交付物。** 目标:用**最小代码 + 最小 core 改动**证明
> AutoService 的客服能力能迁移到 ezagent,并把主要的 gap / 阻塞整理给 core team。
> 这就是那份发现清单。证据:最小化的 `customer_chat` 插件(方案 A)已在 ezagent 上跑通,
> 拆成可 review 的 PR:#529(聊天)/ #530(soul 编辑)/ #532(operator + 接管),
> 均编译通过。改动前基线:编译干净,`customer_chat` 28/28 测试,`Mode` 19/19。
> 规格:`15-corrected-minimal-poc-plan`。

## 结论
AutoService 的三大核心客服能力**都能用 ezagent 原生原语迁移跑通**(网页聊天、soul 编辑、
operator 接管)。过程中遇到两个真正的阻塞(一个已修,一个是 core team 决策),一个身份
gap 和一个生命周期 gap **已记录但未修**(按最小 PoC 原则属于范围外),还有一个原本指望
orchestrator 提供、但它做不到的能力。

## ⭐ 元发现 M1 —— ezagent 缺少一档一等公民的「客服 / 简单服务会话」profile
**这是本 PoC 对 core team 最重要的策略性发现。** 下面的三个 gap(G2、G6、G7)**不是
互相独立的,而是同一个根的三个面**:ezagent 的 session / 模板模型是为
**「编排式、已认证、多 agent 的工作区应用」**这种形态设计的。而客服是**另一种形态**:
一个**匿名终端用户**和**单个固定的应答 agent**进行一段**短的、往往临时**的对话。
框架对这种形态没有一等公民支持,所以一个客服垂直应用必须在三条轴上各自绕开它:

| 面 | 轴 | 客服需要 | ezagent 默认 | 我们的绕法 |
|---|---|---|---|---|
| **G2** | 会话**生命周期** | 短 / 临时的每会话 agent | boot-restore 长命 agent | `create_agent` + `remove_template` + GC(和框架对着干) |
| **G6** | 客户**身份** | 匿名 / 访客终端用户 | 已认证 principal(Identity/Capability) | 合成 `entity://user/<ws>/customer_<id>` URI |
| **G7** | agent**组合** | 一个声明式的固定 agent | 仅运行时 LLM-orchestrator(静态 slot 已被移除) | 无 orchestrator 的 plain 模板 + 插件侧 `Routing.add_rule` |

**给 Allen 的建议 —— 打包,而不是各自打补丁。** 与其做四个零散的点修,不如考虑一档
一等公民的 **「service session」profile**,把以下能力作为一个整体特性提供:
(i) **匿名 / 访客 principal**(G6);(ii) **声明式的固定 agent + 路由**模板 —— 恢复
静态 slot 或等价物(G7);(iii) **轻量生命周期** —— 不强制 orchestrator、可选的临时清理
(G2 + G7 里的 `orchestrator: false` / readiness 非致命 / 每 workspace 预置 default 等条目)。
这样客服这类垂直应用就能**原生组合**,而不必在三条轴上各自绕开。(若完整 profile 太大,
每个面更窄的单点修法分别列在 G2/G6/G7 下。)

## 发现清单

### G1 —— cc bridge JOIN(claude 2.1.92)—— 阻塞,已修
每个 agent 全新的 `CLAUDE_CONFIG_DIR` 会触发 2.1.92 的 OAuth 登录界面,而 dialog-gate
超时是致命的 → cc agent 永远 JOIN 不上 esr-bridge(网页聊天卡在 "connecting…")。
已修(commit `b03cb4da`/`65a0732f`,在 `poc/phase-2-customer-service`;原为 PR #524,
按 #510 折进 "cc-agent bring-up" 块后关闭):PtyServer 检测到 OAuth 界面 → 置
`oauth_blocked?`(EagerBridge 返回 `{:error, :oauth_required}` 而不是空转 15 秒);
dialog-gate 超时改为非致命,所以 `kick_loop` 总会跑。
**任何 cc 部署 / demo 的运维注意:** 用 `~/.claude`(模板里不要设 `claude_config_dir`)
或配置 `api_key_helper`,否则会撞上 OAuth 界面。
验证:`grep 'CONNECTED TO Ezagent.AgentBridge.Socket'` + `grep 'JOINED agent_bridge'`。

### G2 —— 匿名 / 每会话客户的 agent 生命周期 —— GAP(已记录)· *M1 的一个面(生命周期轴)*
方案 A 为每个会话起一个全新的 cc agent。ezagent 的 boot-restore 会在重启时把它们**全部
重新拉起**,所以 A 加了一个自定义绕法:`create_agent` → `remove_template`(去掉
boot-restore 注册)→ 临时 GC。这是插件**唯一一处"和框架对着干"**的地方。原生模式
(一个长命 agent 作为 workspace 模板预置、开机时 rehydrate)需要一个
**持久化 / 已登录的客户**来锚定 —— 而 A 的「匿名、每次打开聊天」模型没有这个锚。
**未修**(原生修法需要改客户身份模型或引入有界 agent 池 —— 超出最小可行性 PoC 范围)。
给 core team:ezagent 是否要为短命 / 匿名范围的 agent 提供原生生命周期,还是
「临时模板 + 取消注册」这套舞步就是官方推荐的模式?

**这一点和插件存在的理由 —— 服务大量匿名用户 —— 直接冲突,而且随规模只会更糟,不会更好:**
- 客服是**高基数、短命、匿名**的 agent(每个匿名会话一个 cc)。boot-restore 假设的恰好
  相反:**少量、长命、有主**的 agent,重启时全部 rehydrate。两个模型根本不匹配。
- 「每个 agent 调一次 `remove_template`」本质是**对一个对整个垂直都错误的默认值做逐个
  opt-out**。它在规模上很脆:**任何**一条注册了 agent 却没走到 `remove_template` 的路径
  (异常、流程中途崩溃、新入口、手工 / 测试路径)都会留下一个**永久**注册,每次开机重拉。
  我们对此有**实证** —— 早期实验留下的 `cc_wait_*` agent 在每次 server 启动时都被
  boot-restore(2026-06-02;运维细节见本 PoC 的 leftover-agents 排查 note)。就算每条路径
  都正确,恢复 N 个历史会话也意味着**开机要 O(N) 次 claude-PTY spawn** —— 对真实客服
  部署不可行。
- **因此 M1 的「service session」profile 必须自带一种生命周期,默认不对匿名 / 临时服务
  agent 做 boot-restore** —— 而不是让插件一个一个去取消 boot-restore。这把 G2 从
  「一个已记录的不便」升级为「插件本就为之而生的『匿名多用户』场景的扩展性阻塞点」。

### G3 —— operator 接管需要一个 core 钩子,或纯路由 —— CORE 决策 → Allen
接管通过 `Ezagent.Behavior.Mode`(#511,PR #532)实现:一个原生 Behavior + slice,
**外加 core `Chat.handle_send` 里一个小的抑制钩子**(`:takeover` 期间丢弃发往客户的
agent-sender 消息)。它能工作(PR #532:takeover 测试 4/0,Mode 套件 23/0)。
**存在一个零 core 改动的替代方案** —— 禁用 customer→agent 的路由规则,改用 session 级的
`Ezagent.Behavior.Routing` 原语来路由 customer↔operator(完整分析见
`14-takeover-routing-evolution`)。Routing 也是唯一能表达 **Copilot** 模式的抽象。
**给 Allen 的决策:** 这个 `Chat` 抑制钩子可以接受,还是接管应改写成纯路由(零 core 改动)?

### G4 —— orchestrator 无法提供 soul 编辑或接管 —— 发现
曾设想用 orchestrator 来"免费"获得 soul 编辑 / 接管。它做不到:它是一个 LLM 驱动的
slot / router 引擎(7 个 MCP 工具),没有 prompt 文本编辑能力(它的 `prompt_override`
是个显式 no-op),且与接管正交(接管是 Session `:mode` slice)。它甚至不在客户消息路径上
(`create_session` 为每会话起的那个 orchestrator 一直闲置)。完整分析:
`12-orchestrator-vs-our-capabilities`。(附带发现:每个客服 session 一个闲置 orchestrator
PTY 是浪费 —— 值得一个 `create_session(orchestrator: false)` 的 opt-out。)

### G5 —— soul 编辑 / 客户聊天 fan-out / 能力门禁 —— 无 GAP ✅
- **soul 编辑**原生迁移:`SoulStore` 按 edited→fixture→nil 解析;cc agent 在 spawn 时
  经现有模板的 `soul_path` → `--append-system-prompt-file` 读取;编辑器由 workspace-admin
  **capability** 门禁(`ConfigAuth`、`Capability.matches?`)。无 core 改动。
  (PR #529 存储 / #530 编辑器。)
- **客户→agent fan-out** 走原生 `Routing.Resolver` 默认规则(`$session_users`/`$mentions`)
  —— A 合成一个 `mentions:[cc_uri]` 让客户文本到达 agent。原生,无自定义 router。
- **鉴权**全程使用原生能力模型(operator 的 `Mode.set` cap、config 的 workspace-admin cap)。
  无 core 改动。

### G6 —— 匿名 / 未认证客户 —— GAP / 决策 → Allen · *M1 的一个面(身份轴)*
ezagent 的 Identity/Capability 模型假设**已认证 principal**。A 通过**合成匿名客户 URI**
(`entity://user/<ws>/customer_<id>`)来支持公开网页聊天;客户路由是公开的
(`on_mount: :put_locale`,无登录),而 operator/admin 路由则正确地要求登录。能工作,但
是绕法。**给 Allen 的决策:** 合成客户是官方推荐模式,还是 ezagent 应该有一个原生的
匿名 / 访客 principal?

### G7 —— 没有原生的「固定 agent 团队」/ 无 orchestrator 的组合路径 —— GAP / 决策 → Allen · *M1 的一个面(组合轴)*
在手工测试客户聊天时浮现(第一条消息没有回复)。为了让**一个固定的客服 agent**在 session
里应答,我们不得不面对的完整链条:
1. **每个租户 workspace 没有 `"default"` session 模板** —— 启动时只在 `workspace://system`
   下预置 default 模板(`do_seed_default_session_template` 硬编码)。acme 没有 →
   `create_session(template_name: "default")` → `{:session_template_not_found, "default", "acme"}`。
2. **系统的 `"default"` 模板强制一个 cc-orchestrator。** 在当前 ezagent 里,
   **session 创建时的静态 `agent_slots` / 路由规则 reconcile 已被移除**
   (`session_template.ex:118`,2026-05-31 atomicity 改动):框架把 worker agent 组合进
   session 的*唯一*方式就是**运行时 LLM orchestrator**。plain session 什么都不组合。
3. **而那个 orchestrator 在这里起不来。** 它的模板设了一个隔离的 `claude_config_dir`
   (`cc_orchestrator_seed.ex:228/380`,`api_key_helper: nil`)→ 全新 CLAUDE_CONFIG_DIR →
   **claude 2.1.92 OAuth 界面**(和 G1 同一个坑)→ 永远 not ready → `create_session`
   阻塞 `{:orchestrator_not_ready_within, 90_000}` → session 永不 spawn → `chat.send` →
   `:no_such_actor` → 没有回复。

**我们的修法(无 core 改动):** customer_chat 为每个 workspace 确保一个
**plain(无 orchestrator)的 `"default"` session 模板**(`session_complete?` 本就把
nil-orchestrator 模板当作一个完整的 plain session),并在**插件侧**组合 cc agent + 路由 ——
一条显式的 `Routing.add_rule` customer→cc(取代之前的 mention 合成)。

**给 Allen 的决策(也就是"非得这么重 / 这么多问题吗"这个问题):** 对一个*确定性的、
固定 agent*的垂直应用(客服、固定流水线),LLM orchestrator 是错的工具(多一个 claude
PTY/session、非确定、OAuth 被坑),且**没有原生的声明式路径**。ezagent 是否应提供以下
一项或多项:
- **(a)** 一个声明式的**静态 agent-slot / 固定团队** session 模板(恢复第 2 点移除的东西),
  让一个 session 一出生就带着已知 agent + 路由,无 orchestrator、无需插件侧组合;
- **(b)** 一个 **`create_session(orchestrator: false)`** opt-out(长期搁置的那条 note),
  让调用方不必预置 plain 模板;
- **(c)** workspace 创建时**预置每 workspace 的 default 模板**(这样租户 workspace 不会
  缺 `"default"`);
- **(d)** **orchestrator readiness 非致命 / 快速失败**(对任何调用方来说,卡死的
  orchestrator 上 90 秒硬阻塞都太狠)。

在那之前,customer_chat 的「无 orchestrator plain 模板 + 插件侧路由」是正确的契合方案,
但比一个一等公民的框架路径需要更多额外簿记。

## 这验证了什么(迁移问题的答案)
客户网页聊天、可编辑 soul、operator 接管,都能用 ezagent 的原生原语(Session、Chat、
Behavior、Capability、Routing、cc agent 模板)在 ezagent 上跑通,且 customer_chat 插件
保持在 core 之外 —— **唯一例外**是那个 `Chat` 接管钩子(G3,已标给 Allen)。阻塞要么已修
(G1),要么是 core team 决策(G3);gap(G2 生命周期、G6 匿名身份)已为 ezagent 的
路线图记录在案。**迁移可行。**

## PR 总览与建议 review 顺序(2026-06-02)
6 个开着的 PR 交付本 PoC:PoC 三件套 + 它依赖的 3 个框架改动。每个 PR 的描述都是中文优先
(英文折叠)+ 顶部钉着同一个 review 顺序块;PoC 三件套里嵌了 acme 上的 demo。

**第一组 —— 框架基础(彼此独立,均 → `main`,可并行合):**
1. **#515** formatter DSL 宏注册 —— 解锁 `mix format --check-formatted` 提交门禁
   (否则 fresh checkout 每次提交都被挡)。最先合,trivial。残留决策(Allen):工具链
   版本钉法(`.tool-versions`/`mise.toml`)。
2. **#512** `EagerBridge` —— 在第一条客户消息前绑定 cc agent 的 esr-bridge MCP 的原语
   (修 **G1**)。**#529 依赖它。**
3. **#511** `Behavior.Mode` + `Chat.handle_send` 接管门控 —— Mode 实现。
   **#532 依赖它**(#532 目前打包了它的文件)。

**第二组 —— PoC 三件套(一条 stack):**
4. **#529** PR-1 AI 客户网页聊天(base,→ `main`;概念上建立在 #512 之上)。
5. **#530** PR-2 可编辑 soul(stack 在 #529 上)。无 core 改动(**G5**,无决策)。
6. **#532** PR-3 operator 控制台 + 接管(stack 在 #529 上;**#511** 合并后 rebase 去掉
   打包的 Mode)。承载 **G3** 决策。

按 PR 划分、给 Allen 的决策:**#529** → 是否提供一档一等公民的「service session」profile
(打包 G2+G6+G7;备选 (a)–(d) 见 G7);**#532** → G3 的 core `Chat` 钩子 vs 零 core 的纯路由
(利弊 + Copilot 取舍,见 `14-takeover-routing-evolution`);**#515** → 工具链版本钉法。
#511/#512/#530 无独立决策。

## 待协调
- cc-agent bring-up 合并 PR 的归属(theme-picker + OAuth + EagerBridge)—— 与 hjj 协调,
  按 #510 的 4-track 计划(已在 #512 评论)。
- Mode(#511)先合,然后 PR #532 rebase 去掉打包的 Mode 副本。
