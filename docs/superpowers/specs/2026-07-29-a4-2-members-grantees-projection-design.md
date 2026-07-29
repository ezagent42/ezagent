# A4-2 — `:members` roster 投影到 `grantees_of` 反向索引【PROPOSED · 待 Allen 对齐】

- **status**: proposed — design-first。**M-9 授权不变量邻近 + 需扩 A2-2 的 `grantees_of` 机制**,按 grill 文化先对齐再动。
- **task**: A4-2(URI-share 统一授权:两步 `:members` 迁移的第二步)
- **branch**: `feat/socialware-share-a4-2-members`(**stack 在 A2-2 `feat/socialware-share-a2-grantees` 上**,随之 rebase)
- **依赖**: A2-2(#1606 `GranteeIndex.grantees_of`)· 与 #189 GranteeIndex→统一 Store 迁移**需协调**(Allen 已记为 #189 后续)

---

## 0. 一句话

把 `:members` roster 从**每次 activate 全 workspace 扫候选 + 逐个滤持 receive-cap** 的手算反查(`Reconcile.reconcile_after_load/2`),换成 A2-2 反向索引的**一条查询** `grantees_of(S, caller, Session, :receive)`。M-9 谓词不动。

## 1. 现状(grounded,file:line)

**A4-2 唯一改写目标** = `Ezagent.ActionSet.Session.Reconcile.reconcile_after_load/2`(`reconcile.ex:55-77`):
- `candidate_uris/1`(`:83-91`)枚举 session workspace 内**每个** user/anon/agent/worker URI(`InternalReads.users_in_workspace` + `agents_in_workspace`)。
- `member_cap_holder?/3`(`:113-129`)逐候选读 live caps → 滤 `granted_by_entity?` → 取 `identity_key(cap) == identity_key(cap(:session, Session, :receive, S, ws))` 的。
- = target→grantees 手算反查。**单一生产接入点** = `behavior/session.ex:551`(activate seeds `reconciled_members` → 驱动 monitor rebuild)。

**M-9 不变量(A4-2 不碰)** = `Ezagent.Session.MemberReceive.holds_member_cap_over?/3`(`member_receive.ex:102-128`):held-cap 扫 + **完整 `Cap.authorize`**,receive 投递与 read 两个谓词共用。A4-2 只换 reconcile 投影,**M-9 谓词原样保留** → 授权 ground truth 不变。

**A2-2 反向索引** = `GranteeIndex.grantees_of(target, caller, behavior \\ :any)`(`grantee_index.ex:96`):DB 表 `cap_grantee_index`,`persist_entity_caps` 漏斗写,caller 过 `Authority.manages?`,generation 过滤到 active `key_id`。表**已含 `action` 列**(`:37`)但 `grantees_of` 不按它过滤。

## 2. 语义相等性分析(crux — 为什么不是 drop-in)

`grantees_of(S, caller, :session)` **不能**直接复现 reconcile 成员集:

| 维度 | reconcile 手算 | 现 `grantees_of` | 处理 |
|---|---|---|---|
| behavior | `cap.behavior = Ezagent.ActionSet.Session`(索引存 `"Elixir.Ezagent.ActionSet.Session"`) | 传 `:session` 滤 `"session"` | 传**模块** `Ezagent.ActionSet.Session` 即对齐(索引存全模块名) |
| **action** | **精确 `:receive`** | **只滤 behavior、不滤 action** → 含 `:join`/`:manage`-only 持有者 | **必须给 `grantees_of` 加 action 过滤**(见 §3.1) |
| provenance | 滤 `granted_by_entity?` | 索引 `reindex` 存全部 concrete cap,不滤 provenance | §3.2 决策 |
| generation | **不**过滤(读 live cap,stale-tolerant) | **过滤**到 active key_id(revoked 掉行) | §3.3——变化更正确,建议接受 |
| admin `:any` 陷阱(codex BLOCKER,`reconcile.ex:103-109`) | 手动 EXACT-identity 挡 `:any` 混入 | 索引只存 concrete-target cap(`row_attrs` 跳 wildcard,`:157`)→ admin all-`:any` cap **天然不入索引** | ✓ 索引**结构性**更安全,免手动挡 |

## 3. 提议改动 + 决策(交 Allen)

**3.1【必需】给 `grantees_of` 加 action 维过滤**
索引表已有 `action` 列,只需 `grantees_of(target, caller, behavior, action \\ :any)` + 一个 `maybe_filter_action`。A4-2 调 `grantees_of(S, caller, Ezagent.ActionSet.Session, :receive)` 才能取**精确 receive-cap 持有者**(否则 `:join`-only 的 pending 成员会被误算进 roster)。
→ **这动 A2-2 的 `grantee_index.ex`**。**决策**:现在在 A2-2 分支上扩(A4-2 stack 于此),还是等 #189 GranteeIndex→统一 Store 迁移时一并加?(Allen 已记该迁移为 #189 后续)

**3.2 provenance(`granted_by_entity?`)**
reconcile 只认**实体授予**的 member-cap。索引不存 provenance 位。选项:(a) `reindex` 存 `granted_by_entity` bool + `grantees_of` 过滤;(b) 确认 `(S, Session, :receive)` 的 cap **只可能**由实体授予(rule/system 不发这个具体 cap),则无需加位。**倾向先查实证**(b),不成立再 (a)。

**3.3 generation 过滤(语义变化,建议接受)**
reconcile 读 live cap 不过 generation → 被 `revoke_all_to` 撤销的成员**仍留在** roster(stale targeting,靠"caps win"在投递时兜底)。`grantees_of` 过 generation → 撤销成员**从 roster 掉出**。这**更正确**(roster 是"staleness-tolerant delivery targeting",撤销者不再是投递目标符合 invariant #20"caps win"),且镜像 dispatch verifier 的 fresh-gen 读。**建议接受为改进**,DoD 显式测撤销后 roster 收敛。

**3.4 reconcile 无 caller —— H2 门怎么过**
`grantees_of` 的 H2 要求 `caller` MANAGES target。但 reconcile 在 `activate/2`(Kind 重启)跑,**系统内部、无 user caller**。选项:(a) 内部可信变体 `grantees_of` 绕 H2(activate 是可信路径);(b) 传 session 自身/canonical system-admin 作 caller。**倾向 (a)**:加 `grantees_of` 的 trusted-internal 入口(reconcile 是 §4.4 有界系统读,非外部枚举),H2 是防**外部**枚举 grantee 的,系统 reconcile 不在其威胁模型内。**交 Allen 定**。

## 4. M-9 保持论证

A4-2 **只改 `reconcile_after_load`(delivery-targeting 投影的 seeding)**,不碰 `holds_member_cap_over?`(receive/read 授权谓词)。M-9 = 每次 receive/read 都从**持有的 cap** 过 `Cap.authorize` 判定(`member_receive.ex:112-121`),与 roster 投影正交("roster ⟂ authz",`reconcile.ex:8`)。故 roster 换源不改任何授权判定 → **M-9 天然保持**。roster 只影响**投递目标**(谁被推消息),权限仍由持 cap 决定。

## 5. Blast radius(reconcile 结果的下游,§3 map)

单一接入点 `session.ex:551` → `reconciled_members` → monitor rebuild(`:560`)。roster map 下游读者(`session_member_uris`/`SessionReads.members`/world conversation_data/kanban_share_controller 等)读的是**投影内容**;只要 §2/§3 保证 grantees_of 产出**与手算相等的集合**(加 action 过滤后),下游无感。§3.3 的 generation 变化是唯一有意的内容差(撤销者掉出),需 DoD 覆盖。

## 6. DoD(impl 期,本设计对齐后)

- `reconcile_after_load` 走 `grantees_of(S, <caller>, Session, :receive)`,删手算 workspace 扫。
- **集合相等回归**:构造 workspace 含 {receive-cap 持有者 / `:join`-only pending / admin all-`:any` / 撤销后的前成员},断言新 roster == 手算 roster(除 §3.3 撤销者按新语义掉出)。
- **admin 陷阱回归**:持 all-`:any` cap 的 admin **不**进任何 session 的 `:members`(索引结构性保证)。
- **M-9 回归**:`holds_member_cap_over?` 行为不变(receive/read 授权照旧)。
- `grantees_of` action 过滤单测(A2-2 层)。
- 闸:check_invariants(含 M-9 grep #M-9)/gate.arch/format 全绿;`reconcile` 的 never-crash fail-safe 保留。

## 7. 开放问题(请 Allen 裁)

1. **§3.1 action 过滤落点**:现在扩 A2-2 `grantees_of`(A4-2 stack)vs 等 #189 Store 迁移一并加?
2. **§3.4 H2 门**:reconcile 用 trusted-internal 变体绕 H2(推荐)vs 传 system-admin caller?
3. **§3.3 generation 语义变化**(撤销成员从 roster 掉出)接受为改进?
4. **§3.2 provenance**:先实证 `(S,Session,:receive)` 是否只可能实体授予,再决定是否给索引加 provenance 位?
