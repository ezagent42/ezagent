# return(PR + 上报)— B2′ 收尾:PR #1695 待评审 + 一条已合入代码不满足自身验收项

> **Task:** `agent-ssh-credential-b2` 的收尾 —— 补 `#1688`/`#1693` 之间掉下来的部分
> **PR:** [#1695](https://github.com/ezagent42/ezagent/pull/1695)(6 commits,base `2a6b0579a`,已 rebase 到最新 main)
> **Dev:** gaga
> **status:** open,待评审 · **head:** `548fa4fc2`

---

## 1. 本 PR 做了什么

**① 设计文档曾与 main 的实际行为相反。** `#1693` 把撤销从「下次 spawn 生效」改成**即时**,但它**零改动 `docs/superpowers`**。于是 1b 设计 §6.2 有数小时写着四句作废的话,其中一句是「这是 B2′ 的**固有属性**,不是本实现的缺陷」—— 而 Allen 恰恰判定它值得修。已重写为按路径分列的生效时机表,并补 §6.2.2 说清**仍然成立**的那部分:已被 agent 进程读进内存的 key 追不回来,所以运维语义是「撤销即刻切断后续使用,但不保证正在进行中的那一次 git 操作失败」。

**② 补了一条 `#1693` 的 hook 结构上够不着的路径。** `handle_sync_recipe_binding/2` 做的是**整集替换**(`set_caps_effect(reconciled.caps)`),而 `#1693` 的钩子按「被移除的那一条 cap」做模式匹配 —— 没有「那一条」可匹配。已补,判据是比较替换前后该 agent 的 `:read_ssh_key` cap **identity-key** 集合,变化即擦。

**③ 订正三份错误论证的残留。**

## 2. 如实标注:② 是**防御性**的,不是修一个可达 bug

实施 brief(我写的)断言「`Ezagent.Cap.verified_set/2` 会因 authority generation 变化丢掉 cap」——**这句是错的**,由实现者复核推翻、我亲自复验:`Ezagent.Cap.storable_for?/2`(`apps/ezagent_core/lib/ezagent/cap.ex:347-359`)**纯结构判定**,只查签名/`key_id` 非空 + `grantee == receiver`,**从不读 generation**。追遍所有 cap 写入入口,**没有当前可达的生产路径**能让一条健康持有的该 cap 经这条 reconcile 消失或改指向。

**结论随之改变,不只是论据改变**:`:sync_recipe_binding` 与 `EntityCaps.persist/2` **今天都不可达**,而我先前对两者做了相反处置。已改成一致分级 —— 分级线是**「有没有真实的触发形状」**,不是「可不可达」:前者有活的生产调用链(`RecipeCapBinding.sync_live/1` ← `definition_agents.ex:452/506/789`)只是数据流今天走不到,故保留防御性 hook(判据与内部机制解耦,将来自动成立);后者**零部署触发点**,不挂,记 follow-up。

两条测试分支都需要**反事实输入**才跑得起来,这一点已在代码与测试里就地标注,不让后人误以为复现了真实生产场景。

## 3. ✅ 2026-08-04 已定并实施(原"🔴 需 Allen 裁决"缺口 —— 走的是下方 B 方案):一条**已合入代码不满足自身验收项**的缺口

> **2026-08-04 更新**:本节原文把这条缺口标成"需 Allen 裁决",并在 §3.1 摸清三条路的代价后**未实施任何一种**。**现已实施 §3.1 的 B 方案**(给 `Ezagent.ActionSet.Sandbox` 加 `:wipe_git_identity` action,两个 identity handler 改发 `{:dispatch_after_commit, %Ezagent.Cmd{}}`)。下面到 §3.1 结尾的分析**原样保留**(它记录了决策依据 —— 三条路的代价对比、B 为什么被选中),但结论段(第 40 行"deferred 桶只收 `:dispatch`/`:saga`,不收 MFA"、"当前 effect 文法里没有 post-commit 的 MFA 通道,真修得扩文法")有一处**判断错误,已订正**:见下方"2026-08-04 订正"标注。**未新增 effect 类型**,权威 9 种 effect 集不变 —— 用的是文法里本来就有的 `:dispatch_after_commit`。

`{:effect, {mod, fun}, args}` 是**同步 MFA**,在 `Ezagent.Kind.Runtime.handle_dispatch` 内执行;持久提交 `commit_and_notify/3` 在其**之后**(`apps/ezagent_actor/lib/ezagent/kind/server.ex:939-947`)。

**这不只是文档与代码不一致 —— 它违反 `tasks/ssh-revoke-wipe.md` 上写明的验收项。** 该卡 Handoff prompt 评审关注点 ② 逐字要求:

> 「`:cap_revoked` 到达时序 —— 撤销与 wipe 的原子/顺序保证(**撤销先入 ledger 再触发 wipe,不允许 wipe 先于撤销可见**)」

而 `#1693`(**已在 main**)的实现**正好相反**:wipe **可以**先于撤销变得持久可见。该验收项在卡上仍是**未勾**状态,代码却已合入。

**失败场景**:reconcile 移除 `read_ssh_key` → wipe 已删 key → 随后 snapshot 提交失败 → `server.ex` 保留**旧的 caps** ⇒ agent 仍被授权、key 已被擦,进行中的 git 操作被打断。

**三点查证结论**:

1. **~~`deferred` 桶只收 `:dispatch`/`:saga`,不收 MFA `:effect`~~(`runtime/effects.ex`)—— ~~当前 effect 文法里没有 post-commit 的 MFA 通道,真修得扩文法。~~**
   > **2026-08-04 订正(判断错误,不是措辞问题)**:这条把两个不同的桶混为一谈了。`:dispatch` 是**提交前**在 handler 内跑的 inline 桶(`execute_dispatches/2`);真正的 post-commit 桶是 `dispatches_after_commit`,由 `{:dispatch_after_commit, %Ezagent.Cmd{}}` 效果类型填充(`effects.ex:19,124-125,171-176`),`Kind.Server` 只在 `commit_and_notify/3` 返回 `:ok`/`:not_durable` 之后才把它交给 `Ezagent.Kind.DeferredDispatch.enqueue/1`(`server.ex:947-955`)。**这个通道本来就存在**,不收任意 MFA 是真的,但结论"真修得扩文法"是错的——不需要扩;需要的是把 `GitIdentityRuntime.wipe/1` 包成一次真实 dispatch(见下方 B 方案,现已实施)。
2. **`#1693` 与本支用的是完全相同的 effect 形状** —— 这条**不是本支引入的**,本支只是把同一形状用到第三个 handler。(2026-08-04:两处已一并迁移到 `{:dispatch_after_commit, _}`。)
3. **失败方向是安全的**:caps 回滚 + key 被擦 ⇒ agent 仍持 cap,**下次 spawn 重新物化**(§6.1 自愈),净代价是一次进行中的 git 操作。反向(commit 成功而 wipe 失败)由 §6.1 的下次 spawn 清理兜底。(2026-08-04:这条风险本身**已解除** —— 提交失败时 wipe 现在根本不会被 dispatch,不再有"key 已擦但 caps 回滚"这个窗口;三点里这条描述的是修复前的残余风险,不是修复后的状态。)

**本 PR(#1695)当时的处置**:按 CLAUDE.md「实施期发现架构问题 → 暂停 → 上报 → 等 Allen」,**只订正文档表述 + 显式标记待裁决**;**未扩文法、未把 wipe 改写成 `:dispatch` 绕过、未动 `ezagent_actor` runtime**。**2026-08-04 后续**:走 B 方案(§3.1)—— 新增 `Sandbox.wipe_git_identity` action + 两处 handler 改发 `{:dispatch_after_commit, _}`,同样未扩文法、未动 `ezagent_actor` runtime,只是这次不再"绕过"而是"接上"了本来就存在的通道。

### 3.1 可行性摸底(本 PR #1695 当时已做,便于裁决 —— 当时**未实施任何一种**;**2026-08-04 已实施 B,见上方 §3 顶部更新**)

为了不把一道开放题扔出去,我把三条路的代价查清了:

| 方案 | 改什么 | 代价 | 是否需新 Decision |
|---|---|---|---|
| **A. 扩 effect 文法** | 新增第 10 种 effect(如 `{:effect_after_commit, mfa, args}`);动 `ezagent_actor` 的 `effects.ex` 分桶 + `server.ex` 在 `commit_and_notify` 后执行 | runtime 改动,此后**每个 Behavior 作者都会看到**这个新 effect | **是** —— CLAUDE.md 的 9 种 effect 是权威集 |
| **B. 走既有 deferred 通道**(**2026-08-04 已实施,见下方"落地记录"**) | 给 `Ezagent.ActionSet.Sandbox` 加一个 `:wipe_git_identity` action;两个 identity handler 把 `{:effect, ...}` 换成 ~~`{:dispatch, ...}`~~ **`{:dispatch_after_commit, ...}`**(2026-08-04 订正:本行原文写的 `{:dispatch, ...}` 是提交前同步执行的 inline 桶,不是本节想要的那个;真正的 post-commit 桶要用 `{:dispatch_after_commit, ...}`,下面"B 的三条支撑事实"第 2 条描述的其实一直是后者,原表格这格打错了) | 一个 action + 其 cap;两处调用点(`#1693` 一处 + 本支一处);**落地后发现的额外代价**:`:wipe_git_identity` 不能像 `Session.add_self` 那样用空 `ctx.caps` 走 `@non_cap_actions` 豁免(那份 allowlist 被 `cap_signing_architecture_test.exs` 钉成"closed and exact",扩它是本次修复不打算打开的架构面)——两处 handler 改为现场用 `Ezagent.Cap.issue_for_action({:admin, admin}, target_uri, action_uri)` 铸造一枚真实签名 cap 塞进 Cmd 的 `ctx.caps`(纯内存签名,无落盘副作用,与 `ezagent.agent.grant_git_identity.ex:160` 已用的手法一致) | **否**(铸造 cap 用的是既有 `Cap.issue_for_action` 机制,不是新机制;唯一被认真考虑过又放弃的"新机制"是扩 `@non_cap_actions`,放弃了) |
| **C. 不改** | 改写 `ssh-revoke-wipe` 卡的关注点 ② | 零 | 否 |

**B 的三条支撑事实**(均已核):

1. `Ezagent.ActionSet.Sandbox` **已经挂在 Agent Kind 上**(`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:154`),且**已经在自己的 destroy 路径里调 `GitIdentityRuntime.wipe/1`** —— 它本来就是拥有这份清理职责的 ActionSet,加一个 action 是**回归归属**而不是新造概念。
2. `DeferredDispatch.enqueue/1` 在 `commit_and_notify` **成功之后**才被调用(`apps/ezagent_actor/lib/ezagent/kind/server.ex:947-955`);**提交失败则根本不会 enqueue** ⇒ 顺序保证天然成立,正是卡上关注点 ② 要的那条。
3. **顺带修一个边界问题**:当前形状是 **Identity Kind 直接对 Agent 的 sandbox 目录做文件操作**。改成 dispatch 后,跨 Kind 的副作用走 P14 认可的唯一通道。(`GitIdentityRuntime` 在 core、domain 可调,所以今天不算硬违规;但**作用对象是另一个 Kind 的 sandbox**,B 让这件事名正言顺。)

**B 的已知代价**:deferred 是 fire-and-forget,失败只记日志 —— 但**当前的 `:effect` 也是**(effect 异常被收集、不使 dispatch 失败),所以这一点**没有变差**。

**裁决结果(2026-08-04):走 B。**

- **B(已实施)** —— 不需新 Decision、顺序保证天然成立、顺带把跨 Kind 副作用放回 dispatch 通道。`#1693` 与本支两处一起迁移到 `{:dispatch_after_commit, _}`;`Ezagent.ActionSet.Sandbox` 新增 `:wipe_git_identity` action(`kind: :agent` 轴,cap-gated,`modes: [:cast]`);鉴权用 `Cap.issue_for_action({:admin, admin}, ...)` 现场铸造真实签名 cap,不扩 `@non_cap_actions`。
- **A** —— 未采用。语义最直白,但要动 runtime 且扩权威 effect 集,B 已经把"提交后才执行"这个语义做到了,不需要再付这份代价。
- **C** —— 未采用(问题本身可修,不必降级验收标准)。

**执行归属**:该缺陷在 `#1693`(卡 owner = allen,codex 执行),`board.yaml:50` 里 gaga 的人轨描述含「**SSH 撤销面**」—— 两处口径不一致的记录见 §4(本 return 原文,未改看板);B 方案由 gaga 轨的后续任务(`feat/b2-prime-closeout` 分支之后的收尾)落地。

## 4. 📋 上报:`tasks/ssh-revoke-wipe.md` 的 commit 归属记错了(**本 return 不改看板**)

卡上把 `feat/ssh-revoke-wipe`(head `868ba5cba`)的交付物列为 `K3 84dba69b6` / `K5+K6 85fb6414e` / `K4 868ba5cba`。

**这三个 sha 属于 `feat/agent-ssh-credential`** —— 是那支整支终审的 K1–K6 修复波,经 **`#1688`** 合入(已核:`868ba5cba` 不在 `origin/main` 祖先链上,squash 合并)。真正的 `feat/ssh-revoke-wipe` 是 **`57818e651`**("wipe materialized git identity when read_ssh_key cap is revoked"),经 **`#1693`** 合入(`gh pr view 1693` 核过 `headRefName` 与 `mergedAt`)。

连带两处状态已旧:

- `ssh-revoke-wipe` 标 **wip / 待评审合入** —— 实际 `#1693` 已于 08-03 04:47 UTC merge
- `agent-ssh-credential-b2` 验收第 4 条「撤销即擦除 follow-up 按序合入」**未勾** —— 实际已满足

**未改任何看板文件**:归属对调需要人确认哪个是哪个,且看板是生成物。

## 5. 合并验证(机器闸)

已 rebase 到 `2a6b0579a`(含 `#1690` 看板提交),`head 548fa4fc2`:

| gate | 结果 |
|---|---|
| `mix ci.fast` | **EXIT=0**,702+5+39+8+1 = 755 tests / 0 failures |
| `mix ezagent.arch.scan` | 仅 `no_flavor_refs_in_core: count=1`(scanner 自命中,既有) |
| `mix ezagent.uri_query.scan` | 1 violation @ `grantee_index.ex:182`(既有,见 §6) |
| `mix ezagent.check_invariants.lifecycle` | 2 violations(既有) |

`agent_git_identity_test.exs` **36/36**。措辞:**本支无新增红**,不是「gate 全绿」。

**复审**:codex 独立复审判**不通过**(2 Important + 1 Minor),已全部修复。其中最值得记的一条 —— 我在注释里加的「重签名不会误擦」这个断言**根本没被测到**(测试两侧放的是同一个 struct)。补测后红演示:把判据改成比较原始 `MapSet` → **36 条里恰好 1 条红,就是新加的那条**,旧那条仍绿,当场证明它从来抓不到该变异。

复审同时**独立确认**:identity-key 判据边界正确(重签名不触发、顺序与重复无关);过擦(新增也擦)是可辩护的 fail-closed;分级理由站得住;我的撤回本身准确。

## 6. Follow-ups(不阻塞)

- **`uri_query.scan` 在 main 上有一条既有红** —— `grantee_index.ex:182`,**不在任何基线清单里**,今天差点被当成本支引入。建议补进基线记录。
- **`EntityCaps.persist/2`** —— 零部署触发点,未挂 wipe hook。等它真有生产调用点再说(§6.2.1 已记)。
- 前一支整支终审留的 Minor(`:any` 通配那条测试名不副实、若干行号漂移、telemetry metadata 不对称、上游 spec 叠了 5 层「已被取代」标注可读性下降)。

## 7. 方法论(一条值得跨轨道推的)

这条线上**每一次「我写的为什么」被独立复核,都能挖出东西** —— 累计八次:一个不存在的 API、三条恒真断言、一条无法实现的验收项、一条写反的退出码前提、两次数错违规站点、一条不满足自身验收标准的退路,以及本轮这条**结论也跟着变**的可达性误判。

逼出它们的是同一条硬性要求:**「按失败场景把实现改坏 → 如果测试仍然绿,那是真实发现,报告,不要硬凑」**。八次里没有一次是靠"仔细看"发现的。

另一条观察:**设计文档的「论据段」是没有任何 gate 覆盖、且 per-task 复审结构上看不到的盲区** —— `CapMint` 那条错误论证在代码注释是对的、文档是错的,两者当面矛盾了整整五个 task 无人发现,直到整支终审逐条读源码才抓出来。
