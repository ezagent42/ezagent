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

## 3. 🔴 需 Allen 裁决:一条**已合入代码不满足自身验收项**的缺口

`{:effect, {mod, fun}, args}` 是**同步 MFA**,在 `Ezagent.Kind.Runtime.handle_dispatch` 内执行;持久提交 `commit_and_notify/3` 在其**之后**(`apps/ezagent_actor/lib/ezagent/kind/server.ex:939-947`)。

**这不只是文档与代码不一致 —— 它违反 `tasks/ssh-revoke-wipe.md` 上写明的验收项。** 该卡 Handoff prompt 评审关注点 ② 逐字要求:

> 「`:cap_revoked` 到达时序 —— 撤销与 wipe 的原子/顺序保证(**撤销先入 ledger 再触发 wipe,不允许 wipe 先于撤销可见**)」

而 `#1693`(**已在 main**)的实现**正好相反**:wipe **可以**先于撤销变得持久可见。该验收项在卡上仍是**未勾**状态,代码却已合入。

**失败场景**:reconcile 移除 `read_ssh_key` → wipe 已删 key → 随后 snapshot 提交失败 → `server.ex` 保留**旧的 caps** ⇒ agent 仍被授权、key 已被擦,进行中的 git 操作被打断。

**三点查证结论**:

1. **`deferred` 桶只收 `:dispatch`/`:saga`,不收 MFA `:effect`**(`runtime/effects.ex`)—— 当前 effect 文法里**没有** post-commit 的 MFA 通道,真修得**扩文法**。
2. **`#1693` 与本支用的是完全相同的 effect 形状** —— 这条**不是本支引入的**,本支只是把同一形状用到第三个 handler。
3. **失败方向是安全的**:caps 回滚 + key 被擦 ⇒ agent 仍持 cap,**下次 spawn 重新物化**(§6.1 自愈),净代价是一次进行中的 git 操作。反向(commit 成功而 wipe 失败)由 §6.1 的下次 spawn 清理兜底。

**本 PR 的处置**:按 CLAUDE.md「实施期发现架构问题 → 暂停 → 上报 → 等 Allen」,**只订正文档表述 + 显式标记待裁决**;**未扩文法、未把 wipe 改写成 `:dispatch` 绕过、未动 `ezagent_actor` runtime**。

**请裁决**:这条 post-commit MFA 通道要不要建?
- **建** → `#1693` 与本支两处都该迁过去。
- **不建** → `ssh-revoke-wipe` 卡上的关注点 ② 需要改写 —— 当前文法给不出那条保证,卡上不该留一条实现不了的验收项。

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
