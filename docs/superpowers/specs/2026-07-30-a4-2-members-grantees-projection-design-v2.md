# A4-2 — `:members` roster 投影到 `grantees_of`（v2，对齐已合并的 A2-2）

- **status**: proposed — design-first。v1（2026-07-29）写于 A2-2 返工前；本 v2 按**已合并 main 的 A2-2** + XY 复核后的**确定结论**重写。
- **task**: A4-2（URI-share 统一授权：两步 `:members` 迁移的第二步）
- **base**: main `5af26bfd5`（A2-2 #1606 已合）
- **依赖**: A2-2（已合，`EntityCaps.GranteeIndex.grantees_of/4`）——**需扩它加 action 维过滤**（见 §2 定论）

---

## 0. 一句话

把 `:members` roster 从**每次 activate 全 workspace 扫候选 + 逐个滤持 receive-cap**（`Reconcile.reconcile_after_load/2`）的手算反查，换成 `grantees_of(S, <caller>, <caps>, Session, :receive)` 一条索引查询。M-9 授权谓词不动。

## 1. 现状（已合并 main，file:line）

- **改写目标** = `Ezagent.ActionSet.Session.Reconcile.reconcile_after_load/2`（`reconcile.ex`）：`candidate_uris/1` 枚举 session workspace 内每个 user/agent，`member_cap_holder?/3` 逐个匹配**精确** `cap(:session, Ezagent.ActionSet.Session, :receive, S, ws)`（`member_cap/2`）。单一生产接入点 = `behavior/session.ex` activate seeds `reconciled_members`。
- **M-9（不碰）** = `Ezagent.Session.MemberReceive.holds_member_cap_over?/3`：held-cap 扫 + 完整 `Cap.authorize`。roster ⟂ authz。
- **A2-2 反向索引（已合）** = `GranteeIndex.grantees_of(target, caller, caller_caps, behavior \\ :any)`（`grantee_index.ex:114`）：挂 `EntityCaps.Store` 写咽喉同事务派生；**收呈交认证 caps `caller_caps`（不认自由 URI）**，过 `Authority.manages?/3`；按 target active key_id + **grantee identity active**（holder-lifecycle）双过滤；**只按 behavior 过滤、无 action 维**。

## 2. **确定结论（XY 复核实证）：action 过滤是必需的 → 必须扩 A2-2**

v1 曾一度怀疑"可能不用加 action 过滤"。**实证推翻——必须加**：

member/participant 对同一个 S 持**多个** concrete `behavior: Session` cap：
- `:join` — `provision_join_authority`（`membership.ex:542-611`）在 **join 之前**独立发 `cap(:session, Session, :join, S)`（spec §3.1「join 从不在 mounted tier」）。
- `:receive` — join 通过后发（`membership.ex:66`）。
- `:send/:leave/:attach` — participation tier（`@member_chat_actions`，`membership.ex:538/1167`）。

**关键**：被邀请但未接受的 **pending joiner 持 `cap(:session, Session, :join, S)` 但无 `:receive`**（持久状态）。而 reconcile 匹配**精确 `:receive`**。所以 `grantees_of(S, …, Session)` 只按 behavior **会多收 pending joiner** ≠ reconcile 集 → **必须给 grantees_of 加 action 维过滤**，A4-2 调 `grantees_of(S, …, Session, :receive)`。

（注：owner/admin 的 manage cap 是 `behavior: Ezagent.ActionSet.Manage`（`creator_grant.ex:24`）**不是 Session**，本来就被 behavior filter 挡掉——v1 拿它当理由是错的，真理由是 `:join`。）

## 3. 提议改动

**3.1【A2-2 层，必需】给 `grantees_of` 加 action 过滤**
索引表 `cap_grantee_index` 已有 `action` 列（`grantee_index.ex:50`）。加 `grantees_of(target, caller, caller_caps, behavior \\ :any, action \\ :any)` + `maybe_filter_action`。A2-2 已合，直接在其上加（新 PR 改 grantee_index.ex + 加 action 过滤单测）。

**3.2【A4-2 层】reconcile 无 user caller + grantees_of 收呈交 caps —— 怎么过 `manages?/3`**
合并版 grantees_of 要 `caller_caps`（呈交的认证 caps）。但 reconcile 在 `activate/2`（Kind 重启）跑，**系统内部、无 user caller、无呈交 caps**。方案：
- (a)【推荐】加 `grantees_of` 的 **trusted-internal 变体**（如 `grantees_of_internal/3`，绕 `manages?` 但只许 in-VM `%{caller: :vm_internal}` 类可信路径调）。reconcile 是 §4.4 有界系统读、非外部枚举，`manages?` 是防**外部**枚举 grantee 的威胁模型，系统 reconcile 不在其内。
- (b) reconcile 用 canonical system-admin 的 caps 作 `caller_caps`。
→ 交 Allen 定；倾向 (a)。

**3.3 generation 语义（白捡的改进）**：合并版 grantees_of 按 target active key_id 过滤 + grantee-active 过滤 → **被撤销 / offboard 的成员自动从 roster 掉出**。现手算 reconcile 读 live cap 不过 generation（stale-tolerant）。这更正确（roster = staleness-tolerant delivery targeting，撤销者不该是投递目标，符合 invariant #20「caps win」）。DoD 显式测撤销后 roster 收敛。

## 4. M-9 保持

A4-2 只改 `reconcile_after_load`（delivery-targeting 投影 seeding），不碰 `holds_member_cap_over?`（receive/read 授权谓词，完整 `Cap.authorize`）。roster ⟂ authz → M-9 天然保持。

## 5. DoD

- `grantees_of` 加 action 过滤（A2-2 层）+ 单测（同 (target,grantee) 持 `:join` 和 `:receive` → `grantees_of(…, Session, :receive)` 只返 `:receive` 持有者）。
- `reconcile_after_load` 走 `grantees_of(S, <trusted>, <caps>, Session, :receive)`，删手算 workspace 扫。
- **集合相等回归**：workspace 含 {receive 持有者 / **:join-only pending joiner** / admin all-`:any`(不入索引) / 撤销后前成员}，断言新 roster == 手算除撤销者（§3.3）。
- **M-9 回归**：`holds_member_cap_over?` 行为不变。
- 闸：check_invariants(#M-9)/gate.arch/format 全绿；reconcile never-crash fail-safe 保留。

## 6. 开放问题（交 Allen）

1. §3.2 trusted-internal 变体（推荐）vs 传 system-admin caps？
2. §3.3 generation 语义变化（撤销成员从 roster 掉出）接受为改进？
