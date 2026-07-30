# A4-2 — `:members` roster 投影到 `grantees_of`（v2，独立取证复核后修订）

- **status**: proposed — design-first。v1（2026-07-29）写于 A2-2 返工前；本 v2 按**已合并 main 的 A2-2** 重写，并经**独立只读取证复核**（2026-07-30）修正理由排序 + 补两个此前漏掉的缺口。
- **task**: A4-2（URI-share 统一授权：两步 `:members` 迁移的第二步）
- **base**: main `5af26bfd5`（A2-2 #1606 已合）
- **依赖**: A2-2（已合，`EntityCaps.GranteeIndex.grantees_of/4`）——**需扩它加 action 维过滤 + 补 provenance 缺口 + 新增内部授权门**（§2/§3）

---

## 0. 一句话

把 `:members` roster 从**每次 activate 全 workspace 扫候选 + 逐个滤持 receive-cap**（`Reconcile.reconcile_after_load/2`）的手算反查，换成 `grantees_of(S, …, Session, :receive)` 一条索引查询。M-9 授权谓词不动。

> **v2 复核修订摘要**：结论「必须加 action 过滤」**成立且是硬性的**；但 v2 初稿举的主因（pending joiner）是**最弱**的一条。真正的杀手是**离会成员的参与档 cap 从不撤销**（§2.1）。另发现两个初稿完全没提的缺口：**K4 provenance 过滤会丢失**（§3.2）、**没有任何现成的可信内部路径**（§3.3，`:vm_internal` 在此 API 上不可用、系统主体已被 #154 清空）。

## 1. 现状（已合并 main，file:line）

- **改写目标** = `Reconcile.reconcile_after_load/2`（`reconcile.ex`）。`member_cap_holder?/3`（`:112-142`）用**含 action 的 5 元组** `Capability.identity_key`（`capability/match.ex:74-82`）做**精确**匹配 `cap(:session, Ezagent.ActionSet.Session, :receive, S, ws)`，且先过 `granted_by_entity?/1`（`:118`，K4 provenance）。`candidate_uris/1`（`:83-91`）枚举 workspace 内 users（含 `anon-`）+ agents + workers。生产唯一接入点 = `behavior/session.ex:549-552`（activate）。
  - **`reconcile.ex:98-111` 注释显式说明：故意不用 `matches?/2`** —— 否则 admin 的 wildcard cap 会「re-add admin into `:members` of EVERY session on reload」。**精确匹配、拒 wildcard 是既有的显式设计决定。**
- **M-9（不碰）** = `MemberReceive.holds_member_cap_over?/3`（`member_receive.ex:104-130`）：`action_of(cap) == :receive` + concrete instance + `granted_by_entity?`。**moduledoc（`:33-42`）明写：按稳定的识别字段（`kind: :session` / `action: :receive` / 具体 instance）匹配，而「rather than pinning the concrete `Ezagent.ActionSet.Session` behavior module」。**
- **A2-2 反向索引（已合）** = `GranteeIndex.grantees_of(target, caller, caller_caps, behavior \\ :any)`（`grantee_index.ex:110-136`）：挂 Store 写咽喉同事务派生；收呈交认证 caps 过 `Authority.manages?/3`；按 target active key_id + grantee-active 双过滤；**只按 behavior 过滤、无 action 维**。**目前零生产调用点** —— A4-2 是它的首个消费者，下面三个缺口都是首次暴露、无先例可抄。

## 2. **确定结论：action 过滤是硬性必需**（理由按强度排序，已修正）

### 2.1 主因（稳态、必然、不可逆）：**离会成员的参与档 cap 从不撤销**

- 参与档 `@member_chat_actions [:send, :leave, :attach]`（`membership.ex:538`）映射成 **`{Ezagent.ActionSet.Session, action}`**（`:1167`），以 concrete instance durable `:sync` 落库（`:1241-1258`）；agent 侧同款（`member_cap.ex:141-177`）。
- 离会/移除**只撤 `:receive`**：`leave_effects/2`（`membership.ex:752-765`）→ `MemberCap.revoke_membership`（`member_cap.ex:240-252`），而 `member_cap/2`（`member_cap.ex:348-357`）**就是 `:receive` 一条**；remove 路径（`membership.ex:940-946`/`:996-1002`）同理，`CompositionCaps.deactivate_member` 撤的是另一根轴（`kind: :agent` 绑定行）。
- ⇒ **每个 leave 掉的前成员都 durable 持有 `cap(:session, Session, :send/:leave/:attach, S)` 而无 `:receive`**。behavior-only 过滤会把**所有历史成员原地复活进 `:members`**，直接违反 reconcile 的 M-8 契约（`reconcile.ex:16-22`：返回**恰好**枚举到的 cap 持有者、驱逐每个非持有者）。

### 2.2 佐证：behavior-only 把两根轴的角色**对调**了

权威成员判定（M-9）把 **action 当判别轴、behavior 当不可靠轴**（§1 的 moduledoc 原话）。而 behavior-only 索引过滤恰好反过来：锁 behavior、放开 action。这是方向性错误，不只是漏一类主体。

### 2.3 次因（真实但弱）：`:join` cap 残留

- `:join` 是**单次消耗**的（`member_cap.ex:111-137` `consume_join_entitlement`，join 成功后 revoke）——**所以 v2 初稿说的「pending joiner 持久持 `:join`」措辞不准**。
- 代码里建模的"已邀请未接受" = `:pending_members`（`membership.ex:143-161`），其条件含 `not URI.type?(member_uri, :user)`，**只对 agent/worker 生效**；而 `provision_invited_join_authority`（`:640-656`）对非-user 走 `else -> :ok`，**根本不发 `:join` cap**。
- 真实残留来自**失败/半途的 join**：provision（`:sync` 落库）与随后的 dispatch 之间**无事务、无回滚**（`conversation_actions.ex:1205-1222`、`participants.ex:103-117` 失败只 terminate_worker、不撤 cap）；anon 更硬 —— join cap 直接写进 `users.caps_json`（`anon_user.ex:117-141` born_with），`anon_admission.ex:32-37` 任一步失败即残留，而 anon 恰在 `candidate_uris` 枚举范围内。且 `consume_join_entitlement` 用 `:async` 且把 `{:error, :no_such_actor | :not_ready}` 当成功（`member_cap.ex:123-136`）。

### 2.4 已排除的理由（v1 用错的那条）

owner/admin 的 manage cap 是 `behavior: Ezagent.ActionSet.Manage, action: :any`（`creator_grant.ex:20-31`），**本来就被 behavior filter 挡掉**，不构成理由。

## 3. 提议改动（三处，都在 A2-2 层）

### 3.1【必需】加 action 维过滤 —— 且**不会**误排除 wildcard

- 索引**已存具体 action**：schema `grantee_index.ex:51`、写入 `:176`、`row_id/5` 折进主键 `:204-211`、migration `20260730010000_create_cap_grantee_index.exs`。
- 索引**只收 concrete instance**（`row_attrs/2` 头部匹配 `%Capability{instance: %URI{}}`，`:202` 非具体的返 `[]`）→ **admin genesis wildcard（`instance: :any`）根本不入索引**，这正是索引没被 admin 淹掉的原因。
- `action: :any` + concrete instance 的 cap **会**入索引（存 `"any"`），但**两条权威判定都拒绝它**（§1）。所以加 `where action == "receive"` **精确复刻现有语义、不误排除任何当前成员**；**不加**反而会多收 `Session, :any` 持有者（当前无此发放点，但 behavior-only 会把它变成可利用面）。
- 实现 ≈ 照抄 `maybe_filter_behavior/2`（`:156-161`）写 `maybe_filter_action/2`（~5 行）。注意：(a) `behavior \\ :any` 默认参数，加第 5 个参数要处理默认值歧义；(b) DB index 只有 `[:target_uri, :key_id]`（migration `:26`），behavior/action 是取回后 filter —— session 量级无所谓。
- 顺手：`capability.ex:109-110` docstring 那句 `action: removed` 是 action 轴改造前的**过期残留**，与代码矛盾，可一并修。

### 3.2【必需，新发现】补 **K4 provenance 缺口**

现手算 reconcile 有 `granted_by_entity?/1` 过滤（`reconcile.ex:118`），**索引里没有对应列**（只有裸 `granted_by` 字符串，`grantee_index.ex:190`）。直接换成索引查询会**静默丢掉这道 provenance 过滤**。必须补：加派生列，或按 `granted_by` 判是否 entity URI 后过滤。**这是初稿完全没提的第三个语义缺口。**

### 3.3【必需，需 Allen 拍板】内部授权门 —— **没有现成路径可复用**

`grantees_of` 第一道门是 `Authority.manages?(caller, target, caller_caps)`。reconcile 在 `activate/2` 里跑，系统内部、无 user caller、无呈交 caps。取证结论：

- **`:vm_internal` 不可用**：`manages?/3`（`authority.ex:137-143`）函数头要求 `%URI{} = caller`，catch-all 对 `:vm_internal` 直接 `false` → `grantees_of` 返 `[]`。这与 runtime 层的 `:vm_internal` 旁路（`kind/runtime.ex:382-385,:452`）**不是一套机制**。→ **v2 初稿的方案 (a) 按原样写法不成立。**
- **系统主体已被清空**：`system_principal/catalog.ex:99,:255-280` —— `system://session-internal` 等已按 #154 于 2026-06-19/20 消除，只剩 `system://bootstrap` genesis。→ **方案 (b)「传 system-admin caps」不成立。**
- **测试里手搓的 quadruple-`:any` admin cap witness**（`grantee_index_test.exs:118-133`）**绝不能搬进生产** —— 那正是 CLAUDE.md 安全姿态点名要防的「构造假 admin caps 绕 authz」漂移。
- session 自己是 principal（`entity/session.ex:59-60`，`SelfLicense`），但 self-license 不是 Manage cap；`CreatorGrant.manage_cap` 发给 creator/owner 而非 session 自己 → session 在自己的 activate 里**没有可呈交的 manage 见证**。

**→ 提议新增一条正当的门**：给 `GranteeIndex` 加 **"target 自读" arity** —— 由 target Kind **在自己进程内**查「谁持有指向我的 cap」，以 self-authority 免 `manages?`（概念上等价于 `session/self_add.ex:26-35` 用 `ctx[:authenticated_principal]` 而非 `ctx.caps`）。**这是新决策，交 Allen。**

## 4. M-9 保持

A4-2 只改 `reconcile_after_load`（delivery-targeting 投影 seeding），不碰 `holds_member_cap_over?`（授权谓词）。roster ⟂ authz。

## 5. DoD

- `grantees_of` 加 action 过滤 + provenance 过滤（§3.1/§3.2）+ 单测。
- 新增 target-自读 arity（§3.3，待 Allen 定形）。
- `reconcile_after_load` 走索引查询，删手算 workspace 扫。
- **集合相等回归**（关键场景，逐条断言）：
  1. **离会/被移除的前成员（持 `:send/:leave/:attach` 无 `:receive`）不得出现在 roster** ← §2.1 主因，最关键的一条；
  2. join 失败残留 `:join` 的主体不得出现；
  3. 持 `Session, :any` 的主体不得出现（wildcard 语义复刻）；
  4. 非 entity 授予的 cap 持有者不得出现（provenance）；
  5. admin genesis wildcard 持有者不得出现（本就不入索引，回归保护）；
  6. 撤销后前成员从 roster 收敛（generation 语义，见 §6）。
- **M-9 回归**：`holds_member_cap_over?` 行为不变。
- 闸：check_invariants(#M-9)/gate.arch/format 全绿；reconcile never-crash fail-safe 保留。

## 6. 附带语义变化（白捡的改进，需确认接受）

合并版 grantees_of 按 target active key_id + grantee-active 过滤 → **被撤销 / offboard 的成员自动从 roster 掉出**（现手算读 live cap 不过 generation）。这更正确（roster = staleness-tolerant delivery targeting，撤销者不该是投递目标，符合「caps win」）。DoD §5-6 显式测。

## 7. 交 Allen 的开放决策

1. **§3.3 target-自读 arity 的形状**（唯一可行方向；`:vm_internal`/system-admin 两条已被实证排除）。
2. §6 generation 语义变化（撤销成员从 roster 掉出）接受为改进？
3. §2.1 暴露的**独立于本任务的既有缺陷**：离会成员的 `:send/:leave/:attach` 参与档 cap 从不撤销 —— 是否单开一条修?（A4-2 用 action 过滤能绕开它，但缺陷本身还在。）
