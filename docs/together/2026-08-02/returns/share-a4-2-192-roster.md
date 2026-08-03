# return — A4-2 / #192 roster 收敛(P1 · P1.5 · P2;P4 deferred)

> **Task:** A4-2 —— `:members` roster 收敛(#192 双真相源)+ #1665 撤销完整性
> **Branch:** `feat/socialware-share-a4-2`
> **PR:** #1655(**已转 ready**;接替 #1620 —— 它的 base 分支随 #1606 合入被删而连带关闭)
> **Dev:** jjkysy(+ Claude)
> **returned_at:** 2026-08-02 16:20 +0800
> **deadline:** —(非当日 plan 项,跨多日推进)
> **deadline_status:** `deferred`(P4 一条整体延后,理由见 §3 —— 其余三段完成)

## 机器返回闸(不是散文断言)

- **CI 绿(PR head `74e29d268`)**:https://github.com/ezagent42/ezagent/actions/runs/30741080738 (`CI: success`)
  另:`Protect dev-together skill: success` / `Dev Together Return Advisory: success`
- **rebase base:** `origin/main` @ **`00f4b3f5b`** —— 本分支 **落后 0 / 领先 9**;rebase 后**重新编译 + 重跑**过,不是"合上了就算":
  - `apps/ezagent_domain_identity/test/{ezagent/entity_caps,invariants}` → **84 tests, 0 failures**
  - `reconcile_after_load_test.exs` + `member_cap_removal_test.exs` → **13 tests, 0 failures**

---

## 1. 做了什么(对照 Allen 2026-07-31 的五条裁决)

| Allen 的要求 | 状态 | 落点 |
|---|---|---|
| **①a** 给 `GranteeIndex` 加**内部机制入口**,不走 `manages?` | ✅ | `grantees_of_internal/1..3`(`grantee_index.ex:143`)+ 白名单 ratchet `test/invariants/grantee_index_mechanism_entry_test.exs`(**当前为空**,先建闸再让消费者入列) |
| **①b** 对外 `grantees_of` 保持 `manages?` 不变 | ✅ | `grantee_index.ex:115` 原样;另**新加** action 维过滤 + K4 provenance 过滤 |
| **①c** `ActionSet.Session.Membership.members_of(session)` | ❌ **未写** | 归 P4,见 §3 |
| **①d** roster 退化成该投影、实体不碰 cap 表 | ❌ **未换源** | 归 P4,见 §3 |
| **②** prod cutover epoch 已激活 → 换源前提满足 | ✅ 已记录 | 设计 §2.4 已按此改写(并说清 #189 代码合了但**按设计 DORMANT**、翻 epoch 是运维动作) |
| **③** 撤销完整性**单开** + 排在换源**之前** | ✅ | **issue #1665** 已开;修复已实现(本 PR),排序符合 |
| **④** 顺序:第1步 → 撤销完整性 → 第2步 → 第4步 | ✅✅✅ / ❌第4步 | P1 ✅ · P1.5 ✅ · P2 ✅ · **P4 deferred** |
| **⑤** #1619 按更正后方向做 | ✅ 设计已批 / ❌ **实现未开始** | 另一 PR,不在本 return 范围 |

### 三段代码(每段都有判别性测试 + 红在前绿在后实测)

**P1 —— 在途 cap 纳入 roster 投影**(`reconcile.ex:138`)
`member_cap_holder?/3` 由 `EntityCaps.load/1`(**只看已落库**)改用 **`EntityCaps.effective_caps/1`**(已落库 ∪ 在途)。
入会授予是 `:async` **出于必然**(在 `handle_join` 内同步授予会死锁 session 创建),所以永远有一段"人已加入、钥匙还在 outbox"的窗口;roster 正是 `Resolver` 的 `valid_member?` 扇出依据 → 该成员被丢出收件人集合。
**红在前绿在后**:改回 `load/1` → 断言失败;换回 → 通过。
**危害口径已按实证收窄**:`MembershipConvergence`(`behavior/identity.ex:290`/`:767`)在钥匙落地时由持有人自己 `add_self`,**成员身份会自愈** —— 真正丢的是**窗口内那几条消息**(无消息级补投,对 agent 成员尤其可见),不是永久失联。

**P1.5 —— 撤销完整性(#1665,安全修复)**(`member_cap.ex:253/:282`)
入会发**四把**钥匙(`:receive` + `:send`/`:leave`/`:attach` + `:subscribe_from`),而 leave/remove **只撤 `:receive`**。残留的 `:send`/`:attach` 在发送路径上**没有任何东西挡**:`Verifier` 的 `@non_cap_actions` 对 `ActionSet.Session` 不含 `:send`/`:attach`,`handle_send/2` 除 cap 外**零成员校验** ⇒ **已退出成员仍能发言/传附件**。
修法保守:**先撤权威的 `:receive`,只有它成功才撤参与档** → REMOVE 的「失败即中止、成员完整保留」契约**一字未动**(与 #1670 Q2 记录的该调用点契约一致);参与档 best-effort(失败记 Logger + telemetry),**永不比修之前更糟**。
**防再漂移**:把动作清单提成 `Membership.chat_action_pairs/0` + `publisher_action_pairs/0`,**发放侧与撤销侧共用同一份定义** —— 原缺陷成因正是"发在一处、撤在另一处"。
**红在前绿在后**:改回只撤一把 → "departed member must NOT keep session.send" 当场失败。

**P2 —— 反向索引补齐 + 机制入口**(`grantee_index.ex` / `store.ex:1147`)
① action 维过滤(列一直在写、从不读 → 分不出"持 `:receive` 的成员"与"只持 `:join` 的被邀请者")
② K4 provenance 过滤(镜像 `Capability.granted_by_entity?/1`)
③ **`revoke_provisioning`/`tombstone` 补 reindex** —— 它俩是仅有的两个不 reindex 的 Store 写者,行残留、正确性全靠读侧兜
④ `grantees_of_internal` + ratchet
**均不影响现有生产行为**(`grantees_of` 至今零生产调用点)。domain_identity **全套 651/0**(③ 动的是共享写路径,故跑全套)。

---

## 2. DoD reconciliation(逐行)

| # | DoD 行(来自设计 §5 + Allen 裁决) | 状态 | 证明 / 待决 |
|---|---|---|---|
| 1 | `grantees_of` 加 action 维过滤 + 单测 | **met** | `grantee_index_test.exs` "action filter narrows to one action";同 target 下 `:receive`/`:join` 两持有者,behavior-only 返回两个(证明 fixture 有区分力),加 action 后各返一个 |
| 2 | 加 provenance 过滤 | **met**(附诚实说明) | 同文件 "system-granted row is EXCLUDED"。**正规发放路径今天产不出 `system://` 授予者**(签名由 `{:held_by, issuer}` 盖章;系统 mint 用具名 `user://system/admin`=实体授予)⇒ 本条是**与 reconcile 的防御性 parity**,不是修已观测到的行 |
| 3 | 补 `revoke_provisioning`/`tombstone` 的 reindex | **met** | 同文件 "CLEAR the grantee's index rows in-transaction";断言**行数为 0**(读侧断言两种情况都会过、证明不了);红检通过 |
| 4 | 处理 pending absorb outbox(在途 cap) | **met** | P1;红在前绿在后 |
| 5 | 明确 epoch 语义 | **met** | 设计 §2.4 重写;prod 已激活(Allen 实测)⇒ 前提满足 |
| 6 | 内部机制入口(不走 `manages?`),对外 arity 不变 | **met** | `grantees_of_internal` + ratchet;`grantees_of` 的 `manages?` 未动 |
| 7 | **`Membership.members_of/1` + roster 换源**(Allen ①c/①d) | **deferred** | **见 §3 —— 交 lead 的开放决策** |
| 8 | 双向集合相等回归(7 条逐条断言) | **partial** | 过报侧(`:join`-only / 离会残留 / provenance / 撤销墓碑 / admin wildcard)已由 P1.5+P2 的测试覆盖;**"换源后"的集合相等回归随 P4 一起 deferred** |
| 9 | M-9 回归(`holds_member_cap_over?` 不变) | **met** | 未触碰该谓词;13/0 |
| 10 | 闸全绿 | **met** | CI success(URL 见上);本地 `ci.fast` 真闸全过(33 个失败**全是**文件扫描型 invariant 的 60s 超时 = 已知 WSL2 环境 artifact,零真实断言失败) |

**Method friction(方法摩擦,供 lead 在 review 提炼):**

1. **任务名把手段写死了,害我把手段当要求。** 任务叫「`:members` 投影到 `grantees_of`」,我据此假定"必须用反向索引",于是围绕它造出一个"甲/乙/丙三选一"的架构取舍,还拿去请示。**而 #192 的要求是「roster 别再当第二真相源」,没规定查询方向。** 建议:handoff 的标题/DoD 用**目标**措辞,手段放"建议实现"里。
2. **我两次拿自己的推理去覆盖已拍板的决定**(先是"方向是删 Mount",后是"反向索引不是要求")。教训已记:**人类明文批准 > 已合 main 的代码/注释 > 已合的计划文档 >> 未合并分支的主张**;判方向前先 `gh pr view` 看它是不是既成事实。
3. **危害定级两次说过头**(先把"离会残留"判成只是难看 —— Allen 纠正为安全洞;后把"在途漏投"说成永久丢失 —— 实证是会自愈)。**先下结论再补证据**是本轮反复出现的毛病。
4. **"红在前"必须真跑**。P1.5 第一版测试是**空过的**(join 后没调 `MemberBackfill`,那个"成员"压根没有 `:send`),是我写的**预条件断言**("否则这个测试什么都没证明")把它抓出来的。建议把"预条件断言"写进 handoff 标准。
5. **Loop C 监控曾是哑的**:`gh pr checks` 走 GraphQL,本 PAT 403 → 静默轮询到超时,**沉默看起来跟"还在跑"一模一样**。改走 Actions API(`gh run list`)才有效。建议记进操作指引。

---

## 3. Deferred + 开放决策(交 lead)

### D1 —— **P4(roster 换成 `Membership.members_of` 反向投影)整体延后**

**不是做不动,是 main 上新落的两份权威计划让它与既有契约相抵触:**

- **`#1670` DeliveryOutbox FINAL plan** 硬口径:**「pending delivery 的属主是接收方 —— 表是共享存储,drain 与 apply 都是 per-receiver」**、**「outbox 坐在 generation 闸之下,只管交付收敛、从不决定授权」**;并把 **`grantee_index.grantees_of` 列为「读侧」**(与 dispatch 验签并列,按 target 当前 active `key_id` 过滤)。
- **`docs/together/tasks/caps-consolidation-1501.md`**:**status = review(rework 中),验收项全部未勾** —— 「effective view 要**同时读 held + pending**」是**正式契约但尚未收敛**。

**推论**:反向索引是**只认"已落库"**的读面;拿它当 roster 的源,与「有效权限 = 已落库 ∪ 在途」的契约**相抵触**,并会**回吐 P1 刚关掉的窗口**(反向不可枚举在途:outbox 按**收钥匙的人**归档、cap 封在不透明 `payload`,无法按"钥匙指向哪个资源"反查;混合方案也不成立 —— 在途的人根本不在候选集里)。

**我先前提的第三条方案(授予入 outbox 时就写反向索引)据此撤回** —— 它把接收方拥有的在途状态塞进按 target 归档的索引,**违背 #1670 的第一条硬口径**。

**请 lead 裁**:
- **(甲)** 认可"正向派生已满足 #192"(roster 已只由 caps 派生、无独立写者:M-8 精确投影 + `MembershipConvergence` 自愈 + P1 纳入在途)⇒ **A4-2 就此收口**,`members_of` 换源不做;
- **(乙)** 仍要换源 ⇒ 需先由 **#1501 / outbox 那条线**决定"反向索引要不要同样满足 held ∪ pending",**P4 挂在其后**;
- 无论哪条,**本 PR 的三段与该决定无关,可独立合**。

### D2 —— #1665 的修复**必须尽快合**
**该漏洞在 `origin/main` 上仍然活着**(现读:`revoke_membership` 仍只撤一把;`:send`/`:attach` 不在免验签白名单;`handle_send` 无成员校验)。修复只在本 PR。**这是本次 return 里唯一有时效性的一项。**

### D3 —— 已识别、明确留给 Group B 的
`Mount→Provision/Share 改名 + 删 MountRow 表` / `unmount 取 actions 脱 MountRow` / `backfill 改派生`:计划文档原文即「碰 kanban 消费者…归后续(或 Group B 一起)」。
**删表前必须先解的点(实证)**:`access: :read`/`:operate` **只存在于挂载表的列**(`mount_row.ex:62`),cap 上没有该字段;两者在 cap 层只差"发了哪些动作",而那份只读动作清单住在 **kanban 策略层**(`board_provision.ex:83 @default_read_actions`)⇒ **"读挂载不扩散"无法从 cap 派生**,删表前需先定 tier 怎么表达。

---

## 4. Merge request

- **合什么**:PR **#1655**(`feat/socialware-share-a4-2` → `main`),9 个 commit,**已转 ready**。
- **含**:P1(在途 cap 纳入 roster)· **P1.5 = issue #1665 安全修复** · P2(反向索引补齐 + 机制入口 + ratchet)· 设计文档与两份 A2-2 return 记录。
- **前提**:已 rebase 到 `origin/main` `00f4b3f5b`,**零落后**;CI 绿(URL 见顶部);本地重验 84/0 + 13/0 + domain_identity 全套 651/0。
- **次序**:与任何其它在飞 PR **无文件重叠**(main 的 30 个新 commit 里只有 #1652 碰过 `grantee_index.ex`,且在写路径、与本 PR 的读路径正交,已验证共存)。
- **建议**:**优先合 #1665 那段**(线上仍存在的可写漏洞);P4 的决定不挡本 PR。
