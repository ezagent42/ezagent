# Agent 层边界评估 —— recipe+flavor 是否应外切,ezagent 只留 role?

**日期:** 2026-07-09
**状态:** 设计研究(只读分析,未改任何代码)。所有代码引用均在 worktree 中对 `origin/main`(`3eaceeabf`)核对。
**加载技能:** `ezagent-developer`(design-principles、three-tier-structure、capbac)。
**英文版(权威):** [agent-layer-boundary-evaluation.md](agent-layer-boundary-evaluation.md) —— 平行维护,保持同步。
**并行姊妹文档:** CapBAC/RBAC 边界评估(auth 层)。两篇合起来回答:**ezagent 的复杂度是本质的还是引入的 —— 在 AUTH 层和 AGENT 层?** 见 §5 交叉引用。

---

## 0. 待验证的假设

Lead 的直觉(源自与队友的讨论):

> "agent 这块我们可能搞复杂了 —— recipe 和 flavor 切到外面单独的系统可能好一点,ezagent 内只保留 role."

改述:**把 `recipe`(agent 怎么造出来)+ `flavor`(cc/codex/curl 执行后端)切到一个单独的"agent 系统";ezagent 内只保留 `role`** —— 责任槽位、`{:role,name}` 路由、session/编排/成员(人 + agent 在被路由的会话里)。

本文用代码证据诚实检验它。结论(§6)是**有分寸的,不是是/否**:Lead 的**诊断**(痛点集中在 agent 层)**成立**;Lead 的**药方**(切成一个外部独立系统)**过头了** —— 正确的切法是 in-repo 的硬化边界,因为 agent 的**控制面**(spawn/凭证铸造/cap 授予/生命周期)与 ezagent 的**本质** CapBAC + Kind 机制焊死,而只有**投递面**今天才是真正外置的。

---

## 1. 三个概念,精确定义(来自代码)

代码库里这套分类已经很清晰(GLOSSARY 决策 #155,`docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`)。一句话模型,Allen 原话(`apps/ezagent_core/lib/ezagent/agent/recipe.ex:6-7`):

> **沙盒的内容是 RECIPE;沙盒怎么被装载是 FLAVOR。**(Allen 2026-06-14)

责任是第三个正交轴:**role_name**(轴 B)—— *谁*填槽位,由 `{:role,name}` 路由。

### 1.1 RECIPE —— "agent 怎么造出来"(config-as-data,轴 A)

- **是什么:** 一个 **flavor 无关**的结构体 —— `skills`、`plugins`、`prompt`(人设)、可选 `script`、`behaviors` 子集、`requested_caps`、`session_template` 引用、不透明 `config` 包。作为 **ConfigObject**(L2 数据)存于 `config://<ws>/recipe/<name>`。`Ezagent.Agent.Recipe.new/1` **拒绝**任何写了 flavor 字段的 recipe(`:flavor/:kind/:bridge_adapter/:template_class`,`recipe.ex:34,94-116`)—— 同一个 recipe 必须在 cc/codex/curl 上一致组合。
- **足迹:** ~2031 行专用模块。拆分:
  - **core(552 行):** 只有数据原语 —— `recipe.ex`(336)、`recipe/cap_mint.ex`(124)、`recipe/compose.ex`(92)。flavor 无关结构体 + recipe×flavor 组合原语。
  - **domain_agent(1305 行):** 全部*逻辑* —— `recipe_registry.ex`(509,over `Socialware.ConfigStore` read-through)、`recipe_materializer.ex`(283)、`recipe_resolver.ex`(155,冷重启 read-model)、`recipe_attributes.ex`、`recipe_behavior_fold.ex`、`grant_recipe_caps.ex`(234)。
  - **domain_session(130 处 grep):** 几乎全是 recipe *作为数据字段*出现在 socialware 角色槽里(`%{role_name, recipe, flavor}`,`socialware/definition.ex:36`),不是 recipe 逻辑。
- **交织判定:** **core 拥有数据原语;domain_agent 拥有全部逻辑。** Recipe *本来就是数据* —— 一个可 fork、内容寻址的 ConfigObject。"把 recipe 抽到外部存储"近乎 **no-op**:存储本身已经是外部形态。recipe-as-data 的治理是一等 CR 关切(决策 #158,`ConfigGovernance.Agent`:stage→preview→publish-pointer-flip→rollback)。

### 1.2 FLAVOR —— "cc/codex/curl 执行后端"(装载器)

- **是什么:** 把 recipe 内容装载进活 agent、并把消息送达它的运行时后端。两个传输类(`agent_bridge/adapter.ex:29-37`):
  - `:subprocess_ws` —— cc、codex:通过 **Phoenix.Channel WebSocket** sidecar 触达的子进程(claude TUI / codex)。回复是**异步**的(→ `session.send`)。
  - `:in_process_sync` —— curl:无子进程,进程内 HTTP 往返同步返回 `{:ok, result}`;agent 读**自己**的 `:api_keys` slice(`agent_bridge.ex:72-103`,`complete/2`)。
- **足迹:**
  - **core(119 行 flavor 无关接缝):** `kind/template/flavor_hook.ex`(59)、`plugin/flavor_publish_hook.ex`(60)。加上 §1.2.1 的更深交织。
  - **domain_agent(563 行 flavor 簇):** `agent_flavor_registry.ex`(271)、`agent_flavor_resolver.ex`(175,ETS + snapshot,防死锁)、`agent_flavor_attributes.ex`(80)、两个 publish/template hook。
  - **domain_agent_bridge(整个 app,1408 行):** 传输契约 —— `agent_bridge.ex`、`adapter.ex`、`adapter_registry.ex`、`channel.ex`、`socket.ex`、`payload.ex`、`token_store.ex`、`registry.ex`。这是投递接缝。
  - **插件(~850 行适配器):** cc(254+67)、codex(174+28)、curl(182)、py(100)、hello(45)。
- **解析间接层:** 每个消费者都经 `Ezagent.UriQuery.resolve(:flavor, agent_uri)` 触达 flavor —— `:flavor` resolver 由 *domain_session* 注册(`uri_query_resolvers.ex:15`),委派进 `AgentFlavorResolver`(domain_agent)。core 甚至带一个**强制扫描器**(`uri_query/scan.ex`),若代码从 URI 名前缀读 flavor 而非经 UriQuery,则构建失败。
- **交织判定:** **执行确实在真接缝后 —— 但 flavor 并非气密封闭。** 后端执行(bridge + 适配器)干净地落在插件 + domain_agent_bridge,只经 UriQuery 间接触达。但仍有**两处真实泄漏**(§1.2.1、§1.2.2)。

#### 1.2.1 Flavor 泄漏进 core —— 作为凭证键字段(最深交织)

凭证级联(`Ezagent.Credential.*` 在 `ezagent_core`,任务 #17)**以 flavor 为键**:
- `credential/workspace_shared_source.ex:21,48` —— `field(:flavor, :string)` + `validate_required([… :flavor …])`。
- `credential/user_default_source.ex:51,91` —— 同上;user-source 指针键 `(owner, workspace, flavor)`。
- `credential/resolver.ex:81,378` —— 有序层集是 **flavor-base → workspace → user → session**;`resolve_layers` 经 `UriQuery.resolve(:flavor,…)` 选凭证源。

即**凭证存储与选择在 core 里结构性地以 flavor 为键。** 这是最深的 agent↔core 交织,也是凭证隔离问题(§4)的关键。

#### 1.2.2 Flavor 泄漏进 domain_session —— 作为 spawn 输入

session 需要知道 agent 的 flavor 来*物化*它(不是为了*路由*到它):`agent_module_resolver.ex`、`session_creator/template_resolver.ex`(flavor→Kind/Template Class)、`definition_agents.ex`/`template_team.ex`(spawn = recipe × 声明的 flavor)、`domain/agent.ex`(`resolve(:flavor)` 决定 PTY 支撑)。

### 1.3 ROLE / 责任 / SESSION —— "要保留的层"

- **是什么:** 责任槽(`role_name`:bot/reviewer/orchestrator/supervisor)、`{:role,name}` 路由,以及整个 session/成员/会话/编排面。
- **足迹:** core 路由原语 1280 行(`routing/receiver.ex` 48、`matcher.ex` 358、`resolver.ex` 618、`legend.ex` 256);domain_session 26,748 行(非测试)。
- **对 flavor/recipe 的耦合:** **路由原语 flavor/recipe 无关。** core `routing/*` 零 flavor/recipe 引用(除一个装饰性 `:flavor` prompt 渲染变量)。`{:role,name}` 纯经 session 成员元数据把 role_name→成员 URI —— **路由从不查 agent 的 flavor 或 recipe。** 耦合在上一层、*spawn 时*,角色槽是数据三元组 `%{role_name, recipe, flavor}`。
- **交织判定:** **三者中最干净。** 路由不需要知道 agent 怎么造的。recipe+flavor 只在成员*被创建*时进入 session 域,与消息*被路由*的时刻干净分离。这一层适合保留。

### 1.4 AgentBridge 是否已是那个接缝?

**部分是 —— 它是*投递*接缝,不是*控制*接缝。**

`Ezagent.AgentBridge` 暴露一套适配器中介的干净接口,已近似 `send(handle,msg)→reply`:`deliver`/`deliver_with_flavor/3`(送 payload)、`complete(agent_uri, prompt)→{:ok, text}`(curl 同步补全)、`Ezagent.AgentBridge.Adapter` behaviour(`flavor/0`、`transport_class/0`、`deliver/2`;每 flavor 适配器在插件里)。这**就是**外部运行时式契约:cc/codex 适配器今天已在跟*进程外*子进程用 WebSocket 通信。

**但控制面直接穿过接缝伸进 core 原语。** `deliver_ensuring/3` 的自愈路径(`agent_bridge.ex:270-309`,`default_heal`)伸进:`Ezagent.SpawnRegistry.spawn/1`、`Ezagent.SnapshotStore.latest/1`(读持久化 Sandbox slice)、`Ezagent.Kind.normalize_slice_view/1`、`template_class.ensure_subprocess_alive/2`。

即 bridge 能*投递*给外部 agent,但*让它活着*要直接驱动 ezagent 的 Kind/Snapshot/Spawn 机制。**AgentBridge 是投递接缝,其控制面与 core 焊死。** 这个区分驱动整个结论。

---

## 2. 近期痛点真正落在哪(诚实检验)

判别器(统一适用):**哪一层的代码承受了硬工程改动** —— 不看症状在哪冒头,不看工单标签。这让一张凭证工单在其修复是成员门时落进 session 列。

### 2.1 事件归属

| # | 事件 | 层 | 证据 |
|---|---|---|---|
| 1 | **create_session 5s 超时** —— 每次 boot 首个 socialware 安装;冷 agent 的 `activate` 供给重子进程并把同步 `ReadyGate.await` 拖过 create 派发预算。修复=去 await,改缓冲 `:cast`(fire-and-forget) | **AGENT**(传输/供给) | `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:672-691`;ReadyGate saga #505;解耦 spec #912;PR #1202 |
| 2 | **技能分发 P1–P3** —— release 打包 `SkillRegistry` + seed 通道 + fold 进 config 物化;skills 由 recipe/definition 声明并物化进 agent home | **AGENT**(recipe→物化) | #1251→SPEC #1254→impl PR #1266;"publishable unit 是 socialware Definition" |
| 3 | **cc/codex/curl flavor 分化 + config_schema** —— 各 flavor 配置字段完全不同;flavor 逻辑曾**泄漏进 core**;北极星"加 flavor = 加插件,零 core 改动" | **AGENT**(flavor) | spec `docs/together/2026-06-25/specs/A-agent-flavor-config-unification.md`(D4 去泄漏 core,`no_flavor_refs_in_core` arch gate);`@callback config_schema/0` in `apps/ezagent_core/lib/ezagent/kind/template.ex`;决策 #160 |
| 4 | **#1256 agent 生命周期复杂度** —— 三层 agent/entity/flavor 映射、**fresh-spawn 全路径 12 连锁位**、**switch/reset 六版状态机**、传输门控就绪 | **AGENT**(生命周期/spawn) | `docs/together/2026-07-08/agent-entity-flavor-mapping-and-lifecycle.zh_cn.md`;`stack.md:12,38`("明日头号");后被判 reuse-join 分支误报→下沉到 session 准入门 #1269 |
| 5 | **py 冷 uv 供给** —— 新容器首个 np/py 成员冷跑 `uv`(numpy/sympy ~9.6s)同步卡在 create;修复=延到 `activate/2` | **AGENT**(供给) | PR #1259;9.6s 见 `template_spawn.ex:677-681` |
| 6 | **凭证隔离(GitHub #1178 / issue #161)** —— 跨 owner 加成员走准入:`:pending_members`、不授 member-cap、不挂进 `:members`,直到成员 owner 批准("owner 的凭证不被花") | **ROLE/SESSION**(成员/准入)—— *以凭证隔离立项,但工程是 session 成员门* | PR #1178 `handle_join/do_join` + `:pending_members`;`admission_gate_test.exs`。(GitHub issue #161 ≠ GLOSSARY 决策 #161) |
| 7 | **cc/np 子进程 restart 孤儿**(决策 #127/#128) | **AGENT**(生命周期/传输) | GLOSSARY #127/#128 —— PidFile reaper + `ensure_subprocess_alive` |
| 8 | **PTY/Python phase 状态机**(决策 #126) | **AGENT**(生命周期) | GLOSSARY #126 —— `:starting/:running/:dead` + LV badge |
| 9 | **per-agent ApiKeys 死锁**(决策 #123/#124) | **AGENT**(凭证) | GLOSSARY #123/#124 —— ApiKeys User→Agent + `reads_sibling_slices` |

**有启发的告诫(事件 6):** 凭证隔离工单是对"凭证=agent 层"这种朴素读法的最强检验 —— 而它证伪了那种读法。修复*完全*被工程化为 session 成员准入门(`handle_join/do_join`、`:pending_members`、跨 owner→PENDING)。按代码落点归类,它是**role/session** 的胜利 —— 且是近期更干净、更自洽的一块,*支持*了假设中"session 层相对干净"的那一半。(这与 §4 完全一致:凭证*授权*是 role 层、留在 ezagent;只有*密钥*随 agent 走。)

### 2.2 决策日志分母(GLOSSARY #120–#161)

同一判别器;中性项披露、不并入 agent。
- **Agent-build 层 —— 9:** #123、#126、#127、#128、#156、#158、#159、#160、#161。
- **Role/session 层 —— 3:** #120(路由整合 + CI gate)、#129(session URI 形状)、#157(SessionTemplate=preset)。
- **中性/框架/横切 CapBAC/UI —— 8:** #121、#122(ExternalMirror,刻意*不*计为 agent 传输)、#124、#125、#147–#152、#153/#154、#155。

### 2.3 比例

两个独立分母收敛:
- **事件清单:** 6 中 5 → ~83% agent(但此清单是预选的 agent 味,量的是清单不是痛)。
- **决策日志(仅明确归层):** 12 中 9 agent / 3 role-session → **75% agent / 25%**(把 8 个中性项当非 agent 则 33% 下限)。

**结论:大约 75–80% agent 层 / 20–25% role-session 层。**

判定靠**深度,不只是数量。** session 层工程真实且非零(#120、listing 去重 #1263、fan-out 隔离 #1252、冷启动持久列表 #1257)——"session 干净"意为"session 修复多为一击即中",非"session 无活"。不对称在于:**agent 层问题是多修订版的连续剧**(ReadyGate #505 ≈ 8 commits + rev4→rev6 spec 系列;#1256 的 12 连锁 + 六版状态机仍在草案;技能分发 研究→SPEC→3 轮 codex→P1-P3;flavor 统一 一整份"去泄漏 core" spec 带 arch gate),而 **session 层修复多为单个 `fix(session)` + 一次 review**。**Lead 的诊断成立:以工程深度衡量,近期痛点集中在 agent 层。**

---

## 3. "抽 recipe+flavor、留 role"实际长什么样

Advisor 的拆解是关键一招:**recipe 与 flavor 的抽取画像相反,且各自都拆成一个声明部分(已可分)+ 一个控制部分(与 core 焊死)。**

### 3.1 两个面

| 面 | 是什么 | 今天在哪 | 可外置? |
|---|---|---|---|
| **声明** | recipe-as-data(ConfigObject);flavor 作可查字符串标签 | L2 ConfigStore;`UriQuery.resolve(:flavor,…)` | **已是外部形态。** recipe 是可 fork 存储;flavor 是字符串。抽取≈no-op。 |
| **投递** | 送消息 / 取补全 | `AgentBridge.deliver`/`complete` + 插件适配器(WS/HTTP) | **已部分外置。** cc/codex 子进程今天就进程外;适配器 behaviour 即接口。 |
| **控制** | spawn(recipe×flavor)→活 Kind;凭证铸造;cap 授予;子进程自愈/生命周期 | `RecipeMaterializer`→`spawn_from_content`;`Credential.Resolver.authorize_and_mint_grant!`;`AgentBridge` 自愈伸进 `SpawnRegistry`/`SnapshotStore`/`template_class` | **与 core 焊死。** 硬骨头。 |

Lead 设想的干净接口 —— `spawn(recipe)→handle`、`send(handle,msg)→reply`、`lifecycle(handle)` —— **投递面已存在**(AgentBridge),**控制面不存在**,因为控制不是对外部运行时的一次调用,而是 ezagent *内部*一场系统中介的授权事务(§3.3)。

### 3.2 是减少复杂度,还是只是搬家?

**声明+投递**面:抽取多为把已干净的接缝**搬到**一个命名边界后 —— 真正删除的不多(recipe 注册表 + flavor 注册表可外移),但那点 LOC(recipe 2031 + flavor 簇 563 + bridge 1408)相对于留下的 26,748 行 session 域很小。

**控制**面:抽到*单独系统***不删除**复杂度 —— 它把复杂度**搬过网络边界、再经回调重新引入**,因为控制面每一步都要 ezagent 的本质机制(§3.3)。这是经典的抽服务负收益:付了边界税,还留着耦合。

### 3.3 硬约束:凭证隔离把控制面粘在 core —— 但是*约束*,不是*否决*

物化事务就是证据。`DefinitionAgents`(`session_creator/definition_agents.ex`)—— 一个 Lead 想保留的**role/session 层**模块 —— 通过每 agent 一场授权中介事务来物化 socialware 声明的 agent 槽:
1. role_name 唯一性(成员),
2. 按 workspace 解析 recipe(`RecipeRegistry`),
3. **spawn = recipe × 声明的 flavor** → `Agent.spawn_from_template_content`,
4. 带 `role_name` facet 的 `session.join`(成员),
5. **最后授予 recipe caps**(`GrantRecipeCaps`,fail-closed),授权**系统中介**(spawn 在 session owner `granted_by` 下,join 在 genesis admin 下)。

步骤 2-3-5 是 agent-build;步骤 1-4 是 role/session;整体是**一场带 join 失败清理的事务**。你无法在步骤 3(spawn)与步骤 4-5(join+授 cap)之间画网络边界而不撕裂事务 —— spawn 外置、join+授予+清理内置,一次部分失败会在边界两侧留下孤儿 worker。

凭证路径把它磨得更利(advisor 更正 —— 这**约束了接口,不否决抽取**):
- `Credential.Resolver` 是**纯**的 —— 只返回*描述符*,并经 `UriQuery` 把 flavor 作**字符串键**读。flavor 是四层里最低那层(flavor-base→workspace→user→session)。
- **授权**机制 —— owner 检查、`authorize_and_mint_grant!`、持久 `GrantRow {agent, source, approved_by, approved_scope, version}`、CapBAC `sandbox.read` 门、"无主权限"(#154)—— 是 **workspace/user/CapBAC**,即 **role 层**,ezagent 保留。

所以边界*穿过*凭证模块:**flavor 必须在接缝两侧保持可查元数据标签;授予/授权留在 ezagent 侧。** 这是**接口需求(flavor 可读),不是否决。** 凭证隔离不禁止抽取 —— 它禁止一次*笨*的抽取(把授权搬出去、或把 flavor 标签藏起来)。

### 3.4 抵抗抽取的耦合(枚举)

- **Socialware `Definition.agents` 物化**(`definition_agents.ex`)—— 上面那场 spawn+join+授予+清理事务。决策 #160:`agents[].flavor` 经 flavor-generic 的 `Recipe.Compose`。这是*驱动* agent-build 的 role 层代码。
- **recipe-as-data 治理**(#158 `ConfigGovernance.Agent/Socialware`)—— CR stage→preview→publish→rollback 与 socialware Definition 治理共用;拆开会 fork 一个刻意统一的机制。
- **技能分发**(P1-P3,刚建)—— skills 是 *recipe 字段*;送进沙盒即 recipe→flavor 物化路径。抽取会移动一个刚稳定的机制。
- **凭证级联**(§3.3)—— core 里 flavor 为键的源选择 + CapBAC 门控的授予授权。最深交织。
- **AgentBridge 自愈/生命周期**(§1.4)—— `SpawnRegistry`/`SnapshotStore`/`template_class` 触达。控制面不是网络调用。
- **`app=socialware, code 从 plugin 来`模型**(#156/#157)—— plugin *就是*代码通道(behaviors/kinds/recipes/flavors);app 是 config-only socialware Definition。一个*外部* agent 系统会是与团队刚承诺的 plugin 通道竞争的*第三条*代码通道。

---

## 4. 凭证隔离 —— 精确权衡这条反论

任务把它设为决定性问题:*能否在不让 ezagent 为凭证/路由理由伸手过界的前提下画出边界?*

**答:投递面能,控制面不能 —— 但"不能"是约束,不是否决。**

- **凭证隔离靠构造达成**(#123/#124):per-agent ApiKeys,agent 读**自己**的 key slice,调用方从不见("the CALLER never sees the API key",`agent_bridge.ex` `complete/2`)。这是*好*隔离,且它活在 Agent Kind 上 —— 即在 agent 运行时**内部**。
- **但准入/授权侧是 role 层**(#154 无主权限、#161 准入门、`authorize_and_mint_grant!`)。*谁被允许*花*哪份*凭证是成员 + CapBAC 问题,在 `session.join` 与授 cap 时决定。

所以凭证故事**跨立**:*密钥*在 agent(随 agent 可抽),*用它的授权*在 ezagent 的 CapBAC+成员(必须留)。一个外部 agent 系统要么(a)持密钥 *并* 重实现授权门(复制 CapBAC —— 姊妹 auth 文档论证 CapBAC 是 ezagent *本质*核心,所以这恰是你不能安全搬的复杂度),要么(b)持密钥但每次花费回调 ezagent 做授权检查(话痨、再耦合)。两者都不删除复杂度。

**这是与姊妹 CapBAC/RBAC 评估的交汇点:** 你无法完全外置 agent 层,*正因为*那个(本质、必须留的)auth 层伸进 spawn+凭证铸造。agent 控制面被 CapBAC 锚在 ezagent,不是偶然。

---

## 5. 选项

| 选项 | 离开 ezagent 的 | 留下的 | 迁移成本 | 凭证隔离允许? |
|---|---|---|---|---|
| **A —— 维持现状** | 无 | 全部 | 零 | 是 |
| **B —— in-repo 硬化边界** | 物理上无;一个*模块*边界:AgentBridge 成为*唯一* agent 运行时接口(投递**加**控制门面),recipe/flavor 注册表封在其后 | 全部代码在 repo;CapBAC/凭证授权不动 | 低–中(多为纪律 + 控制门面 + gate) | **是** —— flavor 保持可查标签;授权留下 |
| **C —— 单独外部系统** | recipe 存储 + flavor 执行 + spawn 控制 | role/session/路由 + CapBAC + 凭证授权 | **高** —— 撕裂物化事务(§3.3),逼 CapBAC 复制或每次花费回调 | **干净地否** —— 控制面抽取逼授权复制或再耦合 |
| **D —— 混合** | *投递*执行硬化为外部式边界(它本已是:cc/codex 子进程);*控制+授权*留 in-repo | role/session + CapBAC + 凭证授权 + spawn/物化事务 | 低–中 | **是** —— 契合现实(执行已外置、控制已内置) |

---

## 6. 结论

**推荐:B,向 D 收敛。** 在 repo *内*硬化 agent 边界 —— 让 `AgentBridge`(投递)+ 一个小的 `Recipe.Compose`/物化门面(控制)成为 role/session 层消费 agent 的*唯一*声明接缝,用 arch-gate 把 recipe/flavor 注册表封在其后(domain_agent 之外不得直接触达 `AgentFlavorRegistry`/`RecipeRegistry`)。这本质上是 **D** 在描述已然为真的现实 —— *执行已进程外;控制+授权已在核内* —— 只是把接缝显式化、强制化,而非用 **C** 把控制搬过网络边界。

**三句话的依据:** (1) Part-2 数据证实 Lead 的*诊断* —— 近期痛点重度 agent 层(子进程生命周期、冷供给、flavor 分化、凭证死锁;两个收敛分母下 ~75–80% agent vs 20–25% role/session,按*工程深度*更悬殊 —— agent 是多修订连续剧,session 是一击即中)。(2) 但 recipe *本已是数据*、flavor 投递*本已进程外*,所以 Lead 想要的接缝多半**已存在**(AgentBridge)—— "抽取"的诚实收益是小删除 + 硬化接口,不是一个新系统。(3) agent *控制*面(spawn→join→授 cap 物化事务、flavor 为键的凭证级联)与 ezagent 的**本质** CapBAC+成员+Kind 机制焊死 —— 凭证隔离约束*允许* in-repo 硬化边界(flavor 保持可查标签)但*禁止*干净外切(会复制 CapBAC 或每次花费再耦合)。**所以:Lead 说对了 agent 层是复杂度与痛点所在,也对了要一条更利的边界 —— 但那条边界是硬化的 in-repo 模块接缝(B/D),不是单独外部系统(C);把 agent 层留在 ezagent 的,正是姊妹文档指认为本质的东西 —— CapBAC。**

### 6.1 若采纳 B/D 的具体下一步
- 加 arch-gate:domain_agent/domain_agent_bridge 之外,不得直接触达 `AgentFlavorRegistry`/`RecipeRegistry`/`template_class` —— 全部经 AgentBridge + 物化门面。
- 把 `RecipeMaterializer.create_agent_from_recipe` + `DefinitionAgents` 事务提升为*那个*命名的"spawn 一个 agent"控制接口;文档化为 `AgentBridge.deliver` 的控制面孪生。
- 在接缝处让 flavor 保持可查字符串标签(经 `UriQuery` 已然如此);**不要**把凭证授权级联移出 core。
- 仅当投递分化(flavor config_schema)增长到值得一个真正的外部执行服务时才重议 —— 那时抽*投递*(D),永不抽控制。
