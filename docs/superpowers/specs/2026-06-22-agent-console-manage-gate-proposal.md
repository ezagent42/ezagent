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
- **Alice 没有这把钥匙。** 她作为 owner 只有一把 **Manage 钥匙**，但这把钥匙配的锁是「删除/重配**编排器这个 agent**」——**不是**「会话内部加成员/改路由」那些锁。

> **缺口一句话：活会话内部那些管理锁，只有编排器有钥匙，operator 没有。** 所以 Console 拿 Alice 的钥匙去开「加成员」的锁 → 对不上 → 拒绝。

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
2. **有人为了让它跑、偷偷绕过授权 →（危险，而且 world 里已经在这么干了）** 后端调查发现 world 现在两处就是：`save_session_template` **自己伪造一把 write 钥匙**、routing **传空钥匙**。这些「能跑」，但**绕过了 operator 真实权限**——审计记的主体是错的，谁改的查不出来。
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
| 1 | owner 的 Manage 钥匙是 **`action: :any`、作用在编排器 agent 上**（所以"扩 Manage 的 action"会被它自动全覆盖 → 过度授权风险） | `grep -n "Behavior.Manage :any\|cap(:agent, Manage" apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex` | 命中 `materializer.ex:117` 附近："Grant the session owner a `Behavior.Manage :any` cap OVER the orchestrator" |
| 2 | 活会话工具授权在**编排器的 `{:within_session,S}`** 钥匙上，operator 不持有 | `grep -n "within_session, S\|preflight_within_session_cap" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 命中 cap #1 注释（~`:37`）+ `preflight_within_session_cap`（~`:878`） |
| 3 | 运行时授权是 **`ctx.caps` OR `holds_cap(caller)`**（所以空 caps 不必然 fail-closed；硬 fail-closed 要靠显式 gate） | `sed -n '395,415p' apps/ezagent_core/lib/ezagent/kind/runtime.ex` | 见 `granted_via_ctx_caps?` 与 `granted_via_holds_cap?` 两个分支，OR 关系 |
| 4 | 编排器**不是授权关卡**：`handle_send` 只验发送方 `:send`，从不验发送方的 Manage/owner 权；编排器随后用**自己**的 caps 干活；且新用户 `default_caps=[]`（门槛=会话成员，不是 owner） | `sed -n '432,460p' apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` ; `grep -n "def default_caps" apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` ; `grep -n "list_caps_for" apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex` | `handle_send` 无 sender-authority 检查；`user.ex:175` `default_caps(workspace) → []`；`session_manager.ex:352` 重建的是 orchestrator 的 caps |
| 5 | `add_managed_member` 的 `role_name` 是**新成员别名**，无"未知 role"失败（demo 把它写错了） | `sed -n '134,160p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 唯一前置失败是 `preflight_within_session_cap`；role_name 直接用于 spawn，不做查找 |
| 6 | `{:unknown_member_role,r}` 其实是 **`define_rule_set_rule` 的 receiver 解析**错误，不属于 add member | `grep -n "unknown_member_role\|resolve_role_receiver" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 命中 `:619` 的 `{:error, {:unknown_member_role, role_name}}`，在 `resolve_role_receiver` 内 |
| 7 | `remove_member` 未知 role 返回 **`{:ok, :already_removed}`**（幂等，不是拒绝） | `sed -n '407,420p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | `nil -> {:ok, :already_removed}` |
| 8 | same-URI 重生的真实错误原子是 **`:same_member_uri_use_reconfigure`** | `grep -n "same_member_uri_use_reconfigure\|reject_same_uri_swap" apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex` | `:429` 返回 `{:error, :same_member_uri_use_reconfigure}` |
| 9 | `define_legend` **不校验** member_set / bound_rule_set（demo 编了校验失败态） | `sed -n '705,732p' apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` | 直接 `Map.put` 写入并 dispatch `set_legends`，无任何存在性校验 |
| 10 | `TemplateTags` 是 **`put/5`/`move/6`、无条件直写 DB、无 cap gate**（demo 虚构了 `tag/3` + Template cap） | `grep -n "def put\|def move\|Unconditional" apps/ezagent_core/lib/ezagent/template_tags.ex` | `put/5`（注释 "Unconditional"）、`move/6`；无 `tag/3`、无 caller/caps 参数 |
| 11 | 审计只有**单个 caller**、`trace_id: nil`（双主体 + 关联需改 schema） | `grep -n "trace_id\|caller =\|defp build_row" apps/ezagent_core/lib/ezagent/audit.ex` | `build_row` 里 `trace_id: nil` + 单 `caller`，无 operator/execution 字段 |
| 12 | world 现存的伪造授权 shortcut（不加 gate 就会被复制/继续） | `grep -n "session_template_write_cap\|caps: \[" apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex` ; `grep -n "caps: MapSet.new()" apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex` | `workspace_plugin_actions.ex:204` 自铸 `session_template_write_cap`；`conversation_actions.ex:253` routing dispatch 传 `caps: MapSet.new()` |

## 6. 两阶段协议（需 Allen sign-off）
```
operator action (world Console, structured args)
        │
  [PHASE 1 — AUTHORIZATION GATE]   ctx.caller = operator
        │  verify operator holds a Manage cap covering THIS op on THIS session
        │    (§7 — enumerated action, NOT action:any)
        │  + verify the live session ↔ orchestrator binding
        │  ── missing/!covered → FAIL CLOSED {:error, :manage_unauthorized},
        │     operator identity still recorded
        ▼
  [PHASE 2 — EXECUTION]            ctx.caller = orchestrator
        │  server-side reconstruct orchestrator caps
        │    (Identity.list_caps_for(orchestrator_uri) — session_manager.ex:352);
        │    world NEVER supplies execution caps/principal
        ▼
  Tools.<op>(args, caller: orchestrator, caps: reconstructed, session_uri, ...)
        │
  [AUDIT]  record BOTH authorized_operator_uri + execution_principal_uri
        │  + a correlation id linking the gate to every child dispatch
```
Non-negotiables: two distinct `ctx.caller`s (operator at gate, orchestrator at dispatch); world never assembles/forwards execution caps (confused-deputy); fail-closed with operator identity preserved.

## 7. Manage scope & granularity (open core question — handoff §4)
Mechanism (i) = "extend `Behavior.Manage`'s authorized actions to cover the session-management tool surface." Risk (evidence §5#1): the owner's held Manage cap is **`action: :any`** scoped to the orchestrator instance — so naively adding Manage actions makes that one key auto-cover them all (silent widening). Therefore:
- No generic `execute_tool(tool_name)`; no reliance on `action: :any`.
- The gate authorizes a **specific, enumerated, session-scoped Manage action** per op, against a server-side allowlist.
- **Before opening a second management concern**, migrate the owner grant off `action: :any` to **enumerated action caps**.
- One-Manage-vs-per-concern-split does NOT need a new cap **axis** (the `action` axis already expresses concern); it touches the grant sites + `Manage.required_caps` (domain). MVP = one Manage behavior, enumerated actions + allowlist.

## 8. Audit schema change (required; cannot be mocked)
Add `authorized_operator_uri`, `execution_principal_uri`, `front_door` (cc-bridge | world-console), `request_id`/`trace_id` (gate → every child dispatch), and the authorizing Manage-cap identity/provenance. Arguments = summaries only; never API keys / prompt secrets / path credentials. (Today: single `caller`, `trace_id: nil` — evidence §5#11.)

## 9. The shared seam: `ToolRunner` (handoff §5)
`ToolRunner.invoke(op, args, derived)` where `derived = %{caller, caps, session_uri, workspace_uri, owner}` is produced by a **server-side** resolver from the session↔orchestrator binding (reuse `run_tool_op/3` normalization — `session_manager.ex:382-467`). Two front doors, shared execution kernel, **NOT** shared auth: cc = bridge-token + binding (`run_tool/4`); world = the Phase-1 Manage gate + operator provenance. World must NOT call `SessionManager.run_tool/4`.

## 10. Open decisions for Allen (blocking the LIVE half)
1. Approve the two-phase protocol (§6) as the Console's LIVE authority mechanism.
2. Manage granularity (§7): one enumerated-action Manage for MVP (migrate owner grant off `action: :any` before a 2nd concern), or go straight to per-concern caps?
3. Audit schema (§8): approve the dual-principal + correlation fields + migration.
4. Read-side authority: even MVP read-only topology needs an authorized read path (not raw `Kind.get_slice`/`RuleStore.list`).
5. Retire the world forged-authority shortcuts (evidence §5#12) now or separately?

## 11. Must-not-violate (existing invariants)
- All grants stay at the `Ezagent.Identity.Grant` chokepoint; `granted_by` is a real entity (Decision #154); the gate adds **no** new `system://` principal.
- CapBAC is never bypassed — the gate is an **additional** authorization step in front of existing dispatch authz.
- `world-coordination.md`: the Console surface stays additive.

## 12. Also (reference hygiene)
`references/capbac.md` §3 reads as if empty `ctx.caps` always fails closed; the dispatch path is `ctx.caps` **OR** `holds_cap(caller)` (evidence §5#3) — the "fails closed" statement is specific to the **grant chokepoint**. A clarifying edit is queued (pending the dev's go) so the protocol's fail-closed claim (enforced at the Phase-1 gate, not assumed from empty caps) is precise.
