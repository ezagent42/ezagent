# return(merge 记录)— A4-2 / #192 roster 收敛 + #1665:PR #1655 已合 main

> **Task:** A4-2 —— `:members` roster 收敛(#192 双真相源)+ #1665 撤销完整性(write-after-leave 安全修复)
> **Branch:** `feat/socialware-share-a4-2`
> **PR:** [#1655](https://github.com/ezagent42/ezagent/pull/1655)(接替 #1620)
> **Dev:** jjkysy(+ Claude)
> **merged_at:** 2026-08-03 09:43 +0800 · **merge SHA:** `da8a26bc1b950978a8f97ac523ca0aee96928f25`(已核在 `origin/main` 上)
> **前序 return:** `docs/together/2026-08-02/returns/share-a4-2-192-roster.md`(随本 PR 一并合入)

## 合入内容(三段,对照 08-02 return 的 DoD 全部 met/partial 已核销)

- **P1 —— 在途 cap 纳入 roster 投影**:`Reconcile.member_cap_holder?/3` 由 `EntityCaps.load/1`(只看已落库)改读 `EntityCaps.effective_caps/1`(已落库 ∪ 在途 outbox),关掉"人已加入、钥匙还在途中"窗口内的丢投递。红在前绿在后实证。
- **P1.5 = #1665 安全修复**:leave/remove 从只撤 `:receive` 一把改为撤销**整个参与档**(`:receive`/`:send`/`:leave`/`:attach`);发放侧与撤销侧共用同一份动作清单(`Membership.chat_action_pairs/0` + `publisher_action_pairs/0`),堵掉已退出成员继续发言/传附件。REMOVE 的「失败即中止」契约未动(先撤 `:receive`,参与档 best-effort)。
- **P2 —— 反向索引补齐 + 机制入口**:`grantees_of` 加 action 维过滤 + K4 provenance 过滤;`revoke_provisioning`/`tombstone` 补 reindex(此前仅有的两个不 reindex 的 Store 写者);新增 `grantees_of_internal/1..3`(不走 `manages?`)+ 白名单 ratchet invariant(当前为空,先建闸)。

## 合并时的拍板(Allen,裁 D1)

**(甲)成立:正向派生已满足 #192,A4-2 就此收口,P4 换源不做。** roster 已只由 caps 派生、无独立写者(M-8 精确投影 + `MembershipConvergence` 落地自愈 + P1 纳入在途);reconcile 是低频路径,正向 `effective_caps` 查询代价可接受。`Membership.members_of` 反向投影换源**不实施**,#192 关闭口径 = 本 PR 三段。

## 合并验证(机器闸)

- merge commit `da8a26bc1` 在 `origin/main`(本 return 写前已核 ancestry)。
- 合入前 CI 绿(PR head `74e29d268`):https://github.com/ezagent42/ezagent/actions/runs/30741080738
- 合入前本地重验(rebase 到 `00f4b3f5b` 后重编译重跑):domain_identity entity_caps/invariants **84/0**;reconcile_after_load + member_cap_removal **13/0**;domain_identity 全套 **651/0**;M-9 收信谓词未触碰。

## Follow-ups(合并时 review 记录的三条遗留,均不阻塞)

1. **agent-at-join 发放仍硬编码 `[:send, :leave, :attach]`** —— 未走 P1.5 提的共享动作清单,与"发放/撤销共用一份定义"的防漂移意图不齐;后续对齐。
2. **冷成员 remove 跳过撤销 + P1 在途可经 `ensure_deliverable` 把被移除成员"复活"回 roster** —— 撤销完整性在冷成员路径上仍有缺口,且在途 absorb 与 remove 的交互会产生再入。**需单开 issue 跟踪**(本 return 落盘时未开)。
3. **provenance 过滤谓词是 `system://` 字符串前缀匹配,不是结构性判定** —— 与 `Capability.granted_by_entity?/1` 的 parity 是防御性的;若未来出现同前缀的非系统授予者会误滤,宜改结构判定。

另:issue **#1665 在 GitHub 上仍为 OPEN**,其修复已随本 PR 合入 main —— 可关闭。

## 不再引用

- "P4 换源 + `:members` 降级纯投影" —— 被 (甲) 裁决关闭,勿再排期。
- 08-02 return 中"授予入 outbox 时就写反向索引"的方案 —— 已在该 return 撤回(违背 #1670「pending delivery 属主是接收方」口径)。
