# 「两把钥匙」权限模型——kanban/socialware 下半场补齐的依据

- 日期:2026-07-20
- 读者:用户本人 + Allen / gaga / zyli
- 性质:设计底稿(讨论用),不是 spec。所有机制主张附 file:line 实证,已逐条核对。
- 背景:kanban socialware(PR #1020 系列)上半场把"板子作为数据 + assistant 作为脑"的形态跑通了;下半场要补的不是功能,是**权限判定**——本文说清补在哪、按什么规则补、谁补哪块。

---

## ① 两把钥匙:现状与漏洞

### 模型(白话)

对同一份数据(比如一块 kanban 板),一个人手里其实有**两把钥匙**:

1. **直接钥匙 = 数据 cap**。cap(capability)是 ezagent 里的授权凭证:一张签了名的"许可条",写明"持有者 X 可以对实例 Y 做动作 Z"。你自己敲 CLI / 点 UI 删板,系统查的就是这把。
2. **间接钥匙 = 驱使 assistant 的权**。你在聊天里 @assistant 说"把板删了",assistant 替你动手。你并没有出示数据 cap,你行使的是"能让 assistant 干活"这个权利。

**健康的模型里两把钥匙应该同步**:你对板没有删权,那么不管你亲手删还是叫 assistant 删,都应该被拒。

### 现状:第二把钥匙没有锁孔

现状是**成员资格 = 第二把钥匙全开**,链条上三个环节都查不到"提要求者对数据的 cap":

1. **chat/@ 驱使 assistant 时零 cap 检查**。session 的默认路由规则(system_default)只看两件事:你是不是 session 成员、agent 是不是被 @ 到(mention-gated)——
   `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/default_rules.ex:15-23`(matcher `{:always}`,receivers `$session_users` + `$mentions`)。
   消息投递到接收方时,ctx 里干脆**不带发送者的任何 cap**(`caps: MapSet.new()`),接收授权查的是**接收方自己**的成员 cap,发送者对数据有没有权从不过问——
   `apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex:294-305`。
2. **assistant 用自己的 token 行事**。cc 编排 agent 出生时被铸一枚**它自己身份**的 CLI token 塞进环境变量 `EZAGENT_USER_TOKEN`——
   `apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex:334-337`(env 名定义在同文件 :24)。
   kanban 动作脚本从这个 token 自解析身份、加载 **assistant 自己**持有的 cap 去 dispatch——
   `apps/ezagent_web/priv/skills_seed/kanban-assistant/scripts/kanban_dispatch.exs:16-23`。
   换句话说:不管谁在聊天里下令,落到板上的动作永远是"assistant 以 assistant 的钥匙"在做。
3. **verifier 是单主体的,cap 必须签给出示者本人**。core 的 cap 校验只认一个 caller(presenter),且签名校验在模式匹配层面就要求 cap 的 grantee 等于出示者——
   `apps/ezagent_core/lib/ezagent/cap/verifier.ex:73-79`,`apps/ezagent_core/lib/ezagent/cap/authority.ex:98-102`(`grantee_uri: presenter` 同变量绑定)。
   所以"assistant 出示用户的 cap"在现有 core 里天然不成立——这不是 bug,是设计:Decision #137(ARCHITECTURE.md:3191)明确 v0 不做 delegation,v1 只加了 scope-tuple 的**收窄型** bounded delegation(`{:within_session, _}` / `{:spawned_by, _}`),"替另一个主体持钥匙"的转授/代持从未开过口子。

### 漏洞本质

**两把钥匙不同步**:第一把(数据 cap)有完整的铸造/签名/校验体系,第二把(驱使权)完全没有锁孔。于是任何 session 成员——哪怕对板一个 cap 都没有——都能通过 @assistant 让 assistant 用 assistant 的钥匙替他删板。上半场 e2e 里 admin 代跑掩盖了这个洞(memory `kanban-as-role-mechanism-authoritative`);下半场要正面补。

---

## ② 目标模型:路 A 为主,路 B 粗闸可叠加

**判权恒等式(核心规则,全文只有这一条)**:

> assistant 替人动手前,恒查"**提要求者本人**对目标数据的 cap"。有则做,无则拒并回话。

### 路 A(收敛到一把钥匙,推荐)

思路:间接钥匙不再独立存在——驱使 assistant 干活时,系统把"提要求者本人的直接钥匙"拿出来过一遍正常校验。两把钥匙收敛成一把,天然不会不同步。

**样板已经在仓里跑通**:hello 的 kanban 委托胶水,以真实 sender 为主体、要求 sender 本人持有(或是 admin)目标 cap,走 `Ezagent.Cap.issue` 的 grant 校验,**不改 core 一行**——
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex:198-206`(`{:held_by, sender_uri}` / `{:admin, sender_uri}` 二分,issue 出的 cap grantee 就是 sender 本人,verifier 单主体假设完全不被触碰)。

**最小缺环只有两个**:

1. **cc-headless 桥丢了 sender**。信封上其实一直有发送者:Payload 结构里 `sender_uri` 是 enforce key(`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/payload.ex:9`),agent 投递层也如实填了 meta `"sender"` 和 `sender_uri`(`apps/ezagent_domain_agent/lib/ezagent/behavior/agent/delivery.ex:62,90`)。PTY 桥(cc flavor)把整个 meta 透传给了 claude 侧(`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_adapter.ex:23` → `apps/ezagent_plugin_cc/priv/python/ezagent_mcp_bridge.py:110-117`)。**唯独 cc-headless 桥只取 `payload.text`,sender 在这一跳被丢掉**——
   `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/cc_headless_bridge_adapter.ex:24-26`。这是 gaga 的地盘(headless 桥归属)。
2. **服务端要有"以已认证消息 sender 为 caller"的入口**。即一个 on-behalf 入口:assistant 转述"用户 U 要删板"时,服务端以 **U** 为判权主体走 `{:held_by, U}` 的 issue 校验。信任前提是"sender 来自平台已认证投递链,不是 assistant 口头自报"——这条信任决策要 **Allen 点头**,但实现上不动 verifier(hello 样板已证明)。

### 路 B(两把钥匙同步铸销,可叠加的粗闸)

思路:第二把钥匙也变成真 cap——cap 体系可以表达"驱使 assistant 做某类动作"为 target(instance-scoped cap 形状是现成的,kanban 板 cap 就是这么长的),给板发数据 cap 时同步铸一张"驱使 cap",收回时同步销。

现实约束:

- **驱使路上没有查 cap 的挂点**——如 ① 所示,mention 扇出处零检查,要在 domain 层新开锁孔(动 `default_rules` / delivery 扇出),侵入面比路 A 大。
- **同步车道是现成的**:person-scope 挂载表(PR #1458)+ 入会补发 MemberBackfill(PR #1462,七处加人入口全接)已合进 main,"发/收数据 cap 时顺带发/收驱使 cap"有现成的搭车点。
- **粒度天花板**:chat 是自然语言,锁孔只能判到"你能不能驱使这个 assistant"这种粗粒度,判不了"这句话意图是删板还是读板"。细粒度判定终归要回落到路 A 的"动手前查提要求者数据 cap"。

**结论**:路 A 是判权主干;路 B 适合日后作为叠加的**粗闸**(比如"非板相关成员连驱使权都没有,消息根本不进 assistant"),不是本轮必做。要不要做留在 ⑥。

### 澄清一个岔路:MCP 化不是现状

有一种直觉是"把 kanban 做成 MCP 工具,靠 MCP 层做权限"。事实:kanban 的 MCP 化**未发生**——recipe 明写没有 MCP kanban 工具(`apps/ezagent_web/priv/socialware_seed/kanban/recipes.yaml:36-38`);#1452 是 headless 载入 agent 自身 `.mcp.json`,#1453 是 provider 凭证、不是用户代持。将来若做 MCP 工具化,per-action cap 对齐同样按 ② 的恒等式走(见 ④)。

---

## ③ 三个场景怎么落

### (a) kanban socialware 单用

- **板主**在聊天里让 assistant 删板:assistant 动手前,plugin 侧以"消息 sender = 板主"为主体走 `{:held_by, 板主}` 校验 → 板主持有板 cap → 通,删。
- **非板主成员**同样下令:校验查的是**他本人**的板 cap → 没有 → **assistant 拒并回话**("你对这块板没有删除权限",话术见 ⑥),而不是默默替他删。
- 与现状的差异只在"assistant 动手前多一道以提要求者为主体的判权",assistant 自己的 token/cap 链路不变。

### (b) 组合 socialware(官网 = hello + kanban)

- 组合胶水(hello 页面上的 kanban 委托操作)**以真实用户身份判权**——正是 `kanban_delegation.ex:198-206` 的 issue_ctx 模式,已跑通。
- 但这份胶水**家错了**:`kanban_delegation.ex` / `kanban_published_read.ex` 物理住在 `apps/ezagent_plugin_hello/` 下——权限模式是对的,归属是污染(hello 是独立 sw,不该焊着 kanban 字面;同 memory `infra vs 业务层分离` 的教训)。
- 落法:按用户已定方向,sw 独立成套(plugin + agent + manifest),**"官网"作为第三个组合 sw** 声明 hello 和 kanban 为成员,这两份胶水从 hello 迁出、住进官网 sw。迁移是搬家不是重写,判权模式原样保留。

### (c) 新建 agent 的 socialware(如 kanban + dev-together)

- 下级 agent(比如 dev-together 拉起的 worker)自身对板**零钥匙**。
- 它试图借 assistant 之手动板:同一条恒等式生效——"提要求者(worker agent)本人对板无 cap" → 拒。
- **关键性质:同一条规则覆盖人与 agent,无特例**。judgment 主体是"消息 sender",sender 是人是 agent 不影响判法;想让 worker 能动板,就走正路给它发板 cap(#1458/#1462 车道),而不是给 assistant 开后门。

---

## ④ 要造的件与分工

| 谁 | 件 | 说明 |
|---|---|---|
| **gaga** | headless 桥 sender 透传 | `cc_headless_bridge_adapter.ex:24-26` 补上 sender(信封上现成:`payload.ex:9`、`agent/delivery.ex:62,90`;PTY 桥 `bridge_adapter.ex:23` → `ezagent_mcp_bridge.py:110-117` 是已透传的参照) |
| **Allen** | on-behalf 入口的信任规则 | 拍板"以已认证消息 sender 为判权 caller"这条信任决策;**不动 verifier**(hello 样板证明不需要)。顺带定:这算不算 Decision #137 bounded delegation 的接续条目,进 Decision Log |
| **我们(kanban 线)** | ① assistant 动手前判权的 plugin 侧接线(issue_ctx 模式复用,`{:held_by, sender}` 恒查);② 官网 sw 拆分(胶水从 hello 迁出);③ 将来 MCP 工具化时 per-action cap 对齐同一恒等式 | plugin 层动作,不碰 core/domain |
| **zyli** | 拒权时的 UI 回话 | 被拒不能 silent(CLAUDE.md"不要 silent 失败"),要在 chat/UI 上给提要求者一句明确回话;话术见 ⑥ |

依赖关系:gaga 的透传是"我们"接线的前置(headless 场景拿不到 sender 就没法判);Allen 的信任规则是全局前置但不阻塞样板内(hello 模式)先行验证。

---

## ⑤ 不做什么

- **跨 workspace 一族不做**。用户已裁"先不考虑";workspace 嵌套语义未定,判权恒等式先在单 ws 内闭合。
- **不改 core verifier**。单主体 + cap 签给出示者(verifier.ex:73-79 / authority.ex:98-102)原样保留;路 A 全部在 grant/issue 侧和 plugin 侧完成。
- **不做用户 token 代持**。assistant 不拿用户的 token 冒充用户行事(#1453 的 provider 凭证也不是代持);判权靠"以 sender 为主体重新 issue",不靠身份冒用。

---

## ⑥ 开放问题(2026-07-20 用户已裁,未定处单独标注)

1. **agent 自主行动 = 定时/cron 场景**。"无人驱使的自主行动"实指定时任务(定时巡板、整理、主动提醒)。用户方向:**判权按数据属主(建者)的 cap 判**——定时触发落到板上的动作,授权依据是数据属主对板的 cap,不是 agent 自己另立一套;且猜测**仅 session owner 能持有这类调度能力**(建定时任务本身也是一种权)。

   **仓内查验结论(2026-07-20 grep `apps/*/lib`)**:
   - **无现成"session 内定时任务"机制,agent 也没有创建定时任务的入口**。没有任何 ActionSet 暴露 schedule/cron/timer 类 action(grep `action :.*(schedul|timer|cron|remind|periodic)` 零命中);无 Oban(`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/sweeper.ex:8-9` 明说 Oban 不在依赖树,`Process.send_after` 是仓内既有 idiom)。
   - 仓里全部周期触发都是 **infra/plugin 自有 GenServer 自心跳**(`Process.send_after` 给自己发消息),代码/app env 写死间隔,不是任何 principal 运行时可创建的:core 侧如 `apps/ezagent_core/lib/ezagent/idempotency/sweeper.ex:47`、`apps/ezagent_core/lib/ezagent/cap/delivery_outbox/sweeper.ex:28`、`apps/ezagent_core/lib/ezagent/audit/writer.ex:73`、`apps/ezagent_core/lib/ezagent/kind/server.ex:299`(snapshot tick);domain 侧如 `apps/ezagent_domain_agent/lib/ezagent/agent/retirement_sweeper.ex:187`、`apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding/sweeper.ex:65`、`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex:345`;plugin 侧如 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex:94,119`(轮询 tick)、`apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:73`(收件轮询)。
   - **定时触发后 dispatch 身份,仓内有两个相反先例**:
     - kanban MiroSync tick → **系统 admin 身份**:`miro_sync.ex:16`(注释明说"dispatch 身份 = 系统 admin,对齐 EM Worker 先例")、`:175-186`(`caller = sys_caller()`,`Cap.issue_for_action({:admin, caller}, ...)`)、`:193`(`sys_caller` = `Ezagent.URI.user(:system, :admin)`)。**用户已定性(2026-07-20):这是错的,不作先例**——它是权限系统落地之前的存量开发功能,根本没考虑判权;唯一可参照的方向是 email inbound 的"映射回真实 principal 当 caller"。将来做正式调度机制时,MiroSync 这类 admin 心跳按数据属主方向收敛,列存量债。
     - email 收件轮询 → **映射出的真实 principal 身份**:`apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:137-142,178`(`ctx: %{caller: principal_uri, caps: decision.caps}`,caller 是按收件地址映射出的用户,不是系统)。这是"数据属主/真实主体判权"方向的现成参照。
   - **待验证/待 Allen**:调度机制本身(谁能建、建在哪、怎么持久化、触发时如何拿数据属主的 cap)完全未设计;"仅 session owner 可持调度"是用户猜测,未验证;定时场景下"以数据属主为 caller"算不算 Decision #137 bounded delegation 的又一接续条目,需 Allen 拍板。

2. **粗闸路 B:先不做**(用户已裁)。等 MCP 工具化落地后再议——届时 per-action cap 对齐(见 ② 岔路澄清)天然提供细粒度锁孔,再评估"驱使权铸成 cap"是否还有增量价值。但权限模型本身要沉淀为**全局开发者指南**:先出 handoff 文档(`docs/together/2026-07-20/handoffs/sw-permission-guide.md`,已写),后内化为 sw 开发 skill / CI gate,让以后每个写 sw/plugin 的人不用重走本轮讨论。

3. **拒权话术:不新造**(用户已裁)。统一走 **G5 ErrorSignal 结构化错误机制**(后端 #1451/#1456/#1463,前端 #1450,zyli/ruihua 线)——拒权就是一种 ErrorSignal:plugin 侧判权失败时发结构化 ErrorSignal(错误类型 + 缺什么 cap),前端按既有口径渲染,不散文拼话术、不静默失败。zyli 的件相应从"定话术"收窄为"确认拒权 ErrorSignal 的渲染路径已覆盖"。

---

*实证核对说明:文中全部 file:line 于 2026-07-20 在 worktree `kanban-progress-board`(基于 main #1462 合并后)逐条读码核对;Decision #137 原文见 ARCHITECTURE.md:3191。*
