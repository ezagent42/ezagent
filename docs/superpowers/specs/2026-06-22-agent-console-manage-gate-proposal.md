# Proposal (BLOCKING — needs Allen): the Manage-gate for operator-driven live session management

> **Date:** 2026-06-22 · **Author:** Claude (with the dev) · **Tracking:** task #84
> **Status:** PROPOSAL — blocks the Agent Console MVP (LIVE half). Needs Allen's sign-off on the protocol (§6) + the open decisions (§10) before any mechanism code.
> **Branch:** `agent-console` (doc only). **Referenced by:** `…-agent-console-demo-design.md`.
> **Inputs:** handoff `2026-06-22-agent-console-in-world-handoff.md` §1/§4/§5, research note `2026-06-22-agent-console-backend-research.md` §5, an independent code review (2026-06-22), and the verification in §5.

> **怎么读这份文档**
> **第一部分（§1–§4）是给人看的** —— 用大白话讲清楚：问题在哪、为什么要加、不加会怎样、决定是什么。Allen 读这部分就能一眼知道全貌。
> **第二部分（§5–§12）是给 AI / 工程看的** —— 每条判断都带 `file:line` 和**可复制的核验命令**，你可以直接让你的 AI 逐条跑、确认问题是否真实存在，再看协议细节和待拍板项。

---

# 第一部分 · 问题（人话）

## 1. 一个具体场景 —— 以及我们缺什么

Alice 是 operator（登录 world Console 的人，也是某个 session 的 owner）。她想对一个**正在跑的** team 做事——比如「给这个活会话加一个成员」「加一条路由规则」。

把权限想成**钥匙**：每把钥匙刻了「谁能对什么做什么」，要开一个操作的**锁孔**，你手里得有齿型对得上的钥匙。

- 活会话内部由一个**编排器（orchestrator）**协调，它手里有一把**万能钥匙** `{:within_session, S}` =「会话 S 内部啥都能干」。**今天加成员能成，就是编排器拿这把钥匙开的锁。**
- **Alice 没有这把钥匙。** 她作为 owner 有一把**「管理这个 session」的 Manage 钥匙**（建 session 时就发了），但**加成员/改路由这些工具的锁，认的不是 Manage 钥匙、而是编排器那把 `{:within_session,S}`**——Alice 没有后者。所以 Console 直接拿 Alice 的钥匙去开「加成员」的锁 → 对不上 → 拒绝。

> **缺口一句话：operator 有「管理 session 的授权（Manage）」，但工具的锁只认「编排器的 within_session 授权」——两者之间缺一道桥。** Manage-gate 就是把「Alice 的 Manage 授权」翻译成「工具能执行」的那道桥。

## 2. 为什么要加「Manage-gate」（而不是直接发万能钥匙）

最省事的想法是：把编排器那把万能钥匙复制一把给 Alice。**但很糟**——那等于把「会话内为所欲为」的权力**永久**塞给一个人，范围过大、难收回。

更好的做法是把**两件事分开**：
- **谁有权下令** = 看 Alice 有没有那把 **Manage 钥匙**（粗粒度，人持有）
- **实际以谁的身份执行** = 仍用**编排器的会话授权**去跑（细粒度，会话持有）

**Manage-gate 就是中间那道关卡**：先验「Alice 有没有 Manage 钥匙」→ 有 → 它**不**拿 Alice 的钥匙硬开，而是**让编排器的授权去执行**，同时**记账：这次是 Alice 下令、编排器执行的**。

把「授权」和「执行」分开，才能拿到两样东西：① **双主体审计**（能答出「谁改的这个 team」）；② **可控/可撤销**（撤掉 Alice 的 Manage 钥匙即可，不动会话）。

## 3. 如果不加 Manage-gate，会怎样（三条坏路）

Console 对热操作就只剩三条路，**全是坏的**：

1. **操作直接失败 → 会话控制台这半边废掉。** Alice 永远 `:unauthorized`，Console 只能**只读**——而「管理活会话」正是这个产品的招牌。
2. **有人为了让它跑、偷偷绕过 / 漂移授权 →（危险，而且 world 里已经在这么干了）** 后端调查发现 world 两处：① `save_session_template` **自己伪造一把 write 钥匙**（真·绕过 operator 权限）；② routing dispatch **传空 `ctx.caps`**——这条**不是当前 live 漏洞**（运行时有 `holds_cap(caller)` 兜底，§5#3），而是 **contract drift / 未来债**：它"碰巧"靠 caller 持有的 cap 通过，审计/意图不清晰，该退休、不该复制。两者都让"谁改的"难追责。
3. **或者干脆把编排器万能钥匙发给 operator（过度授权）。** 「能管理 team」悄悄变成「能在这个会话里干编排器能干的一切」，永久、无关卡、难收回。

> 还有一条更隐蔽的：今天「让 operator 在聊天里指挥编排器去改」**也不安全**——编排器不是授权关卡，它对**任何能在会话里发消息的成员**都听话，只靠它的 system prompt（软护栏）挡，且审计只记成编排器。对 socialware/公开会话尤其危险。（证据见 §5 第 4 条。）

## 4. 决定（Allen 方向，机制 i）+ 一句话总结

Console 在 **manage 授权**下运行，**授权与执行分离**：

> operator 由其 **Manage 钥匙授权**；工具在**重建的编排器授权下执行**；操作**同时记 operator + 执行者两个主体**；**缺 Manage 钥匙 → fail-closed**。

这是一道**关卡**，不是一把新万能钥匙。具体协议见 §6。

---

# 第二部分 · 证据与协议（给 AI / 工程确认）

## 5. 可核验的证据清单（claim → 命令 → 预期）

> 下面每条都是上文论断的代码依据。可直接复制命令在仓库根目录跑，确认问题真实存在。Base：`origin/main` 区段（`agent-console` 分支）。

| # | 论断 | 核验命令 | 预期 |
|---|---|---|---|
| 1 | owner 持有**两把 `Manage :any`**：① `:agent` 级（over orchestrator，materializer.ex:117）② **`:session` 级（over the session 本体）**——后者是 gate target，且已是 `action:any`（"扩 action"会被它自动覆盖，见 §7） | `grep -n "Behavior.Manage :any\|cap(:agent, Manage" apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex` ; `sed -n '575,585p' apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`（看到 `grant_creator_manage_cap(:session, session_uri, workspace_uri, caller)` 的 `:session` 实参）; `sed -n '15,32p' apps/ezagent_core/lib/ezagent/creator_grant.ex`（看 `manage_cap/4` 铸 `action: :any`，`granted_by` = caller 真实 entity） | materializer.ex:117「Manage :any OVER the orchestrator」；workspace.ex:577 调用第 1 实参是 `:session`；creator_grant.ex `manage_cap/4` 铸 `Manage`、`action: :any`、`granted_by: caller`（真实 entity）= session 级 Manage:any |
| 2 | 活会话工具授权在**编排器的 `{:within_session,S}`** 钥匙上，operator 不持有 | `grep -n "within_session, S\|preflight_within_session_cap" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 命中 cap #1 注释（~`:37`）+ `preflight_within_session_cap`（~`:878`） |
| 3 | 运行时授权是 **`ctx.caps` OR `holds_cap(caller)`**（所以空 caps 不必然 fail-closed；硬 fail-closed 要靠显式 gate） | `sed -n '395,415p' apps/ezagent_core/lib/ezagent/kind/runtime.ex` | 见 `granted_via_ctx_caps?` 与 `granted_via_holds_cap?` 两个分支，OR 关系 |
| 4 | 编排器**不是授权关卡**：`handle_send` 只验发送方 `:send`，从不验发送方的 Manage/owner 权；编排器随后用**自己**的 caps 干活；且新用户 `default_caps=[]`（门槛=会话成员，不是 owner） | `sed -n '432,460p' apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` ; `grep -n "def default_caps" apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` ; `grep -n "list_caps_for" apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex` | `handle_send` 无 sender-authority 检查；`user.ex:175` `default_caps(workspace) → []`；`session_manager.ex:352` 重建的是 orchestrator 的 caps |
| 5 | `add_managed_member` 的 `role_name` 是**新成员别名**，无"未知 role"失败（demo 把它写错了） | `sed -n '134,160p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 唯一前置失败是 `preflight_within_session_cap`；role_name 直接用于 spawn，不做查找 |
| 6 | `{:unknown_member_role,r}` 其实是 **`define_rule_set_rule` 的 receiver 解析**错误，不属于 add member | `grep -n "unknown_member_role\|resolve_role_receiver" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 命中 `:619` 的 `{:error, {:unknown_member_role, role_name}}`，在 `resolve_role_receiver` 内 |
| 7 | `remove_member` 未知 role 返回 **`{:ok, :already_removed}`**（幂等，不是拒绝） | `sed -n '407,420p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | `nil -> {:ok, :already_removed}` |
| 8 | same-URI 重生的真实错误原子是 **`:same_member_uri_use_reconfigure`** | `grep -n "same_member_uri_use_reconfigure\|reject_same_uri_swap" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex` | `:429` 返回 `{:error, :same_member_uri_use_reconfigure}` |
| 9 | `define_legend` **不校验** member_set / bound_rule_set（demo 编了校验失败态） | `sed -n '705,732p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 直接 `Map.put` 写入并 dispatch `set_legends`，无任何存在性校验 |
| 10 | `TemplateTags` 是 **`put/5`/`move/5`、无条件直写 DB、无 cap gate**（demo 曾虚构 `tag/3` + Template cap） | `grep -n "def put\|def move\|Unconditional" apps/ezagent_core/lib/ezagent/template_tags.ex` | `put/5`（注释 "Unconditional"）、`move/5`（`move(workspace,name,tag,expected_hash,new_hash)`）；无 `tag/3`、无 caller/caps 参数 |
| 13 | 重建 orchestrator **全部** caps 会放大委托：除 within-session 外还有 spawned-by / workspace Template:any | `grep -n "within_session\|spawned_by\|Template" apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex` | `caps.ex:151` 附近多于 within-session 的 caps —— Phase-2 应投影最小子集（§6） |
| 11 | 审计只有**单个 caller**、`trace_id: nil`（双主体 + 关联需改 schema） | `grep -n "trace_id\|caller =\|defp build_row" apps/ezagent_core/lib/ezagent/audit.ex` | `build_row` 里 `trace_id: nil` + 单 `caller`，无 operator/execution 字段 |
| 12 | world 现存的伪造授权 shortcut（不加 gate 就会被复制/继续） | `grep -n "session_template_write_cap\|caps: \[" apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex` ; `grep -n "caps: MapSet.new()" apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex` | `workspace_plugin_actions.ex:204` 自铸 `session_template_write_cap`；`conversation_actions.ex:253` routing dispatch 传 `caps: MapSet.new()` |

## 6. 两阶段协议（v2 — 吸收第二轮复审；需 Allen sign-off）
> **v2 修订（2026-06-22，第二轮复审）：** Phase-1 改为**真 CapBAC dispatch**（不是 world 端旁路检查）；gate target 锁定为 **session 级 Manage cap**（owner 建 session 时已持有，见 §5#1）；Phase-2 **投影最小 cap、校验参数**（不重建 orchestrator 全部 caps）；runner 接口收紧（§9）；request_id 串联补偿 dispatch。

```
operator action (world Console) — 只交 {session_uri, op, structured args}，不交 caps/principal
        │  server 生成 request_id（贯穿 gate + 所有子 dispatch + 补偿）
        ▼
  [PHASE 1 — AUTHORIZATION GATE]   ctx.caller = operator
        │  DISPATCH 一个枚举动作 manage.<op> 到 THIS session（kind=:session,
        │    Behavior.Manage, action=:<enumerated>, instance=session_uri），
        │    由 runtime step 5.5 判定 operator 的 caps —— 走 chokepoint，
        │    NOT world-side list_caps_for + matches?（§9）
        │  + 服务端从 binding 重新校验 session↔orchestrator↔workspace↔owner + liveness
        │  ── 不过 / cap 缺失 → FAIL CLOSED {:error, :manage_unauthorized}，
        │     仍记 operator 身份（§8）
        ▼
  [PHASE 2 — EXECUTION]            ctx.caller = orchestrator
        │  服务端派生执行授权：投影 THIS op 所需的**最小** cap 子集
        │    （不是 list_caps_for(orchestrator) 的全部——避免放大 spawned-by /
        │     workspace Template:any，§5#13）；校验参数（如 source template 属本 workspace）
        │  world NEVER 提供/拼装 execution caps 或 principal
        ▼
  Tools.<op>(args, caller: orchestrator, caps: projected_minimal, session_uri, ...)
        │
  [AUDIT]  记 authorized_operator_uri + execution_principal_uri + matched-cap identity
        │  + request_id 串联 gate / 每个子 dispatch / 补偿 dispatch
```
Non-negotiables：两个 `ctx.caller`（gate=operator / exec=orchestrator）；Phase-1 是**真 dispatch**、不是旁路；world 只交 `{session_uri, op, args}`，绝不交 caps/principal（confused-deputy）；Phase-2 投影**最小** cap、校验参数；fail-closed 保留 operator 身份。

### 6a. "最小 cap 投影" 的精确定义 + 每个 op 的执行权限集（review C2）
**"投影最小 cap" = 从 orchestrator 实际持有的 caps（`Identity.list_caps_for(orchestrator)`）里 SELECT 出本 op 子 dispatch 需要的子集；绝不 *构造* 一个新的窄 `Capability` struct**（构造 = 在 Grant chokepoint 之外铸权限，违反 #154）。所以投影只会"少给"，不会"造新权"。

一个 op 往往触发**多个**子 dispatch、需要**多把** held cap（矩阵每行只画了主 Held/Needed，下面是完整集）：

| op | required_execution_caps（从 orchestrator held 里选） | 参数约束 |
|---|---|---|
| add_managed_member | within-session（join）+ spawned-by（spawn worker，§5#13） | source template **属本 workspace**；失败补偿用同一 spawned-by |
| update_member_template | within-session + spawned-by（regenerate=spawn+leave+join+terminate） | new source 属本 workspace；same-URI 拒 |
| remove_member | within-session（leave）+ spawned-by（terminate） | — |
| add_participant | within-session + spawned-by | **MVP 不开 manifest/path 输入**（路径输入是额外攻击面，review B5） |
| define_rule_set_rule / prompt / legend | within-session（仅一把） | receiver role 必须是 live member |
| update_template / save_template_as | within-session + **Template（within_workspace）** | 写入的目标模板属本 workspace |
| migrate_session | within-session + Template + 多步 | dry-run/plan；MVP 后置 |

**MVP 首条命令 routing-rule-add 只需 within-session 一把**——这是它作为第一刀攻击面最小的原因。

## 7. Manage scope & granularity (v2 — rewritten per review C)
Key fact (v2): the session **owner already holds a session-level `Manage :any` cap over the session itself** (`grant_creator_manage_cap(:session, session_uri, …)`, `behavior/workspace.ex:577`) — in addition to the `:agent` Manage over the orchestrator. So the gate target is the **session Manage cap**, and the owner can *already* satisfy any enumerated `manage.<op>` we add (the `action:any` cap auto-covers it).

That reframes the granularity question — it is a **decision about owner authority, not a silent-widening bug**:
- **Decide first: is the session owner meant to be the session's full manager?**
  - **If yes (likely for MVP):** keep the owner's session `Manage:any`. The enumerated `manage.<op>` actions then exist to **scope the server-side allowlist** (which ops the Console exposes / which a *non-owner, narrowly-granted* operator may invoke) — they do **not** narrow the owner. State this explicitly so "enumerated action" isn't mistaken for owner-restriction.
  - **If no:** the migration off `action:any` must happen **before the FIRST enumerated action ships** (not the second — the first is already auto-covered), and it must be a **session-scoped** re-grant, because `CreatorGrant.manage_cap/4` is **shared** by session/agent/orchestrator grant sites and cannot be bluntly switched to enumerated globally.
- Either way: **no new cap axis** (the `action` axis already expresses concern); **no `execute_tool(tool_name)`**; the per-op gate authorizes a specific enumerated `manage.<concern>` against a server allowlist. One Manage behavior is enough.

### 7a. PROPOSED Manage action registry (review B1 — single source of truth)
These actions **do NOT exist yet** — today `Behavior.Manage` has only `:delete` / `:reconfigure` (`manage.ex:44`). The demo + matrix + traces all use **this** list, marked **PROPOSED**:

| PROPOSED action | covers | gate cap shape |
|---|---|---|
| `manage.member` | add / update / remove member, add participant | `cap(:session, Manage, :manage_member, session_uri, ws)` |
| `manage.routing` | define rule / prompt / legend | `cap(:session, Manage, :manage_routing, session_uri, ws)` |
| `manage.template` | update_template / save_template_as | `cap(:session, Manage, :manage_template, session_uri, ws)` |
| `manage.migrate` | migrate_session | `cap(:session, Manage, :manage_migrate, session_uri, ws)` |
| `manage.read_topology` | read-only topology (review E) | `cap(:session, Manage, :read_topology, session_uri, ws)` |

`{:error, :manage_unauthorized}` is likewise a **PROPOSED** wrapper error (the Phase-1 gate's fail-closed return), not an existing runtime atom. Allen decides the final action set + whether `manage.*` are per-concern (this table) or finer per-op.

## 8. Audit schema change (required; cannot be mocked)
Add `authorized_operator_uri`, `execution_principal_uri`, `front_door` (cc-bridge | world-console), `request_id`/`trace_id` (gate → every child dispatch), and the authorizing Manage-cap identity/provenance. Arguments = summaries only; never API keys / prompt secrets / path credentials. (Today: single `caller`, `trace_id: nil` — evidence §5#11.)

## 9. The shared seam: `ToolRunner` (v2 — non-forgeable API, per review B4)
The **only** world-facing entry is `invoke_console(operator_uri, session_uri, op, args)` — it takes **no caps and no principal**. Inside, it runs the Phase-1 gate, the binding re-verification, the minimal-cap projection, and the execution. The privileged form that accepts already-derived `%{caller, caps, …}` stays **private** (any in-VM caller that could pass forged `derived` would skip Phase-1 — that is the confused-deputy hole). Reuse `run_tool_op/3` normalization (`session_manager.ex:382-467`) **behind** the private boundary.

Two front doors, shared execution kernel, **NOT** shared auth: cc = bridge-token + binding (`run_tool/4`); world = `invoke_console` (Phase-1 Manage gate + operator provenance). World must NOT call `SessionManager.run_tool/4` and must NOT be able to construct execution caps.

## 10. Open decisions for Allen (v2 — the LIVE half cannot ship until these 5 close)
1. **Gate target (§6/§7):** confirm Phase-1 gates on the **session-level** `Behavior.Manage` cap (owner already holds it) — and whether old sessions need a backfill so every live session has a session Manage cap.
2. **Owner authority & `action:any` (§7):** is the owner the session's full manager (keep `Manage:any`; enumerated actions only scope the server allowlist + non-owner operators) — OR migrate off `action:any` (session-scoped, before the first enumerated action ships, not touching the shared `CreatorGrant.manage_cap/4` globally)?
3. **Non-forgeable runner (§9):** approve `invoke_console(operator, session, op, args)` as the sole world entry; raw caps-accepting runner stays private.
4. **Read-side authority (review E — BLOCKING):** MVP read-only topology needs an authorized read path (membership-gated snapshot, or a session Manage `:read_topology` action) — world must stop raw `RuleStore.list` / `Kind.get_slice` (cross-workspace topology leak risk, `conversation_data.ex:57,290`).
5. **Audit schema (§8) — BLOCKING for LIVE MVP** (reconciled: §8 says "required", so it is a blocking decision, not optional): approve the dual-principal (`authorized_operator_uri` + `execution_principal_uri`) + matched-cap identity + `request_id`/`trace_id` correlation fields + the migration. Without it the dual-principal audit (the whole point of the gate) can't be recorded.

Plus (approve the design, mechanics not gating): the two-phase protocol shape (§6); whether to retire the world forged-authority shortcuts (§5#12) now or in a follow-up.

**Reassurance (review B6):** the gate mints no cap and reconstructs already-held caps without going through `Ezagent.Identity.Grant`, so it does NOT violate the grant chokepoint or Decision #154 — provided it adds no new `system://` principal and records the real cap's entity `granted_by`. The real risks are the gate being bypassed (§6 Phase-1 = real dispatch) or the raw runner being exposed (§9).

## 11. Must-not-violate (existing invariants)
- All grants stay at the `Ezagent.Identity.Grant` chokepoint; `granted_by` is a real entity (Decision #154); the gate adds **no** new `system://` principal.
- CapBAC is never bypassed — the gate is an **additional** authorization step in front of existing dispatch authz.
- `world-coordination.md`: the Console surface stays additive.

## 12. Also (reference hygiene)
`references/capbac.md` §3 reads as if empty `ctx.caps` always fails closed; the dispatch path is `ctx.caps` **OR** `holds_cap(caller)` (evidence §5#3) — the "fails closed" statement is specific to the **grant chokepoint**. ✅ Clarified (commit `56902617`) so the protocol's fail-closed claim (enforced at the Phase-1 gate, not assumed from empty caps) is precise.
