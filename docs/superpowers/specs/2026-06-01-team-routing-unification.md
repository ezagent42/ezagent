# Team Routing Unification — Rule-Sets, Prompt Templates, Legends, and Member-Provenance

**Date**: 2026-06-01
**Status**: spec **rev 2** — incorporates codex adversarial review (1 CRITICAL + 4 HIGH + MEDs) and Allen's design decisions. Pending final review → writing-plans.
**Supersedes**: the orchestrator-private `agent_slot` mechanism (clean cutover, §3.8).

## 1. Motivation

Building the live `传话游戏` relay (cc → codex → curl, each appending a line,
mirrored to a Feishu group) surfaced four problems that are really **one
entangled design gap**:

1. **Agents in a flow don't know they're in the flow.** A worker only sees the
   previous hop's raw message. Making models self-propagate protocol in the
   message body is fragile — gpt-5.5 botched an off-by-one and skipped a hop.
   The routing table should carry role context, not the message.
2. **No place to attach that context** — a rule has `matcher` + `receivers` +
   `enabled`, nothing for "what to tell the receiver".
3. **`@`-mention is asymmetric** — works for session **members** (default
   `always → [$session_users, $mentions]` rule + member-filtered `$mentions`),
   but the relay's **slot workers** aren't members, so `@` silently went nowhere.
4. **Two parallel mechanisms** ("slot worker" vs "session member") for the same
   thing — an agent participating in a session.

The unifying insight (Allen): a "slot" is **a member with extra facets**; a
multi-agent flow is **a named set of single-receiver routing rules sharing a
prompt template**, optionally fronted by a **legend** (a user-facing handle that
collapses the team and triggers its flow).

## 2. Current state (code-grounded; confirmed by codex review)

- **Routing rules** (`RuleStore`, table `MentionRouting`): flat rows
  `{matcher_data, receivers :: [String.t()], enabled, workspace_uri, source,
  created_by, applies_to_users}`. **No `rule_set` / `position` /
  `prompt_template_ref`**, no rule grouping. `Behavior.Routing.add_rule` accepts
  only `{table, matcher_json, receivers}` and does NOT enforce single-receiver.
- **`Resolver.resolve/4` returns only `[URI.t()]`** (`resolver.ex:158/163/188`);
  `query_table/3` collapses `{matcher, value}` → `receivers_of(value)`. **No
  caller knows which rule matched** — the load-bearing gap for prompt injection.
- **Delivery**: `Behavior.Chat.handle_send/2` iterates recipients;
  `dispatch_receive_call/3` passes the unchanged `%Message{}`. Agent delivery
  (`AgentBridge`) builds a payload text (a natural injection point); the
  **user-receive branch stores only message ids** in `last_received` /
  `recent_messages` (`chat.ex:526/567/573/585`) — the visible body is the shared
  persisted message, NOT a per-recipient render.
- **Slot workers**: `template_working_copy.agent_slots` stores
  `{slot_name, source_agent_template_uri, live_worker_uri, generation}`
  (`chat.ex:367/373`). `update_agent_template`/rollback/respawn depend on the
  **source-template URI + live-worker URI + generation counter**
  (`tools.ex:192/647/747`, `agent.ex:272`). Slot workers are NOT members.
- **Session members**: chat slice `:members` = `{URI, %{online: bool}}` — no
  provenance, no creator/owner, no role-name alias.
- **Mentions are concrete URIs**: `Matcher.mention/1` matches strings present in
  `message.mentions` (`matcher.ex:142`); LiveView/Feishu bare mentions resolve
  against live member/agent URIs. **No session-scoped symbolic handle** exists.
- **SessionTemplate** content = `{agent_slots, routing_rules,
  orchestrator_template_uri, default_workspace_uri}` (version-hashed). **Members
  are NOT in the template**; `create_session/3` joins only
  `[effective_owner, orchestrator_uri]` (`ezagent_domain_chat.ex:512/604`).
- **`Ezagent.Message` is a plain value struct** — NOT a Kind, no lifecycle/hooks.
- **Capability action-axis is DONE/merged** — `Capability` has `:action`
  (default `:any`), `matches?/2` treats it as a 5th dimension (PRs #503/#426).
  (rev-1 wrongly called it pending.)

## 3. Design

### 3.1 Member facets (absorbing the slot)

A member becomes `{URI, meta}`; `meta` carries (besides `online`):

- **`provenance`** — URI of the creating/owning principal (user or orchestrator
  agent). GENERAL. **Single job: management authority** — who may
  reconfigure/remove this member AND edit the routing rows that reference it. Cap
  `{:manages, provenance_uri}` with **action `:manage`** (using the *existing*
  action-axis) authorises it. Orchestrator workers = members whose provenance is
  the orchestrator.
  > "Who an agent replies to" is NOT a facet — it is routing: "only reply to
  > owner" = a rule `from(agent) → [owner]`; management authority gates who edits
  > those rows. A private agent's default is just a default owner-only routing
  > rule at creation. (Dynamic cases like "reply to whoever @'d me" use the new
  > `$sender` variable — §3.2.)
- **`role_name`** *(optional)* — stable human alias (e.g. `"relay-cc"`) decoupled
  from URI. Rules/legends target a member by role_name; the binding
  `role_name → current URI` survives respawn. (The slot's stable-naming power.)
- **`in_session_template`** *(bool, default false)* — whether this member is
  captured in the **SessionTemplate** snapshot (`Ezagent.Entity.SessionTemplate`,
  §3.7). When the template is instantiated/forked, `true` members are recreated;
  `false` members are runtime-only. (E.g. relay team = `true`; a transient guest
  = `false`.) (Renamed from rev-1 `in_template` for clarity.)
- **Spawn-source state** *(for spawned/managed members — codex HIGH)*:
  `source_template_uri`, `live_worker_uri`, `generation`. This is the state the
  old `agent_slots` tuple carried; the member model MUST carry it so the
  member-level equivalents of `update_agent_template` (spawn a new generation,
  repoint routes, terminate old worker), rollback, persistence, and collision-free
  respawn keep working. A plain user-invited member (no spawn) leaves these nil.

A member with provenance `:any`-equivalent, no role_name, no spawn-state,
`in_session_template: false` = today's plain member. Backward-compatible.

### 3.2 Dynamic matcher / template variables (NEW — Allen #1, codex MED)

The matcher algebra (`from/text_contains/mention/in_session/and/or/not`) plus the
receiver magic tokens (`$session_members/$session_users/$mentions`) cannot express
**dynamic audience** ("reply to whoever addressed me") or feed dynamic templates.
Add:

- **`$sender`** receiver token — expands to the matched message's sender
  (member-filtered like the other magic tokens). Enables "return to the prior
  hop's sender" purely in routing.
- **Template variables** sourced from the matched message + receiver:
  `{sender}`, `{flavor}`, `{body}`, `{session}`, `{sent_at}`. v1 set is fixed +
  documented; extensible later. (No `$self`-loop: `$sender` excludes the receiver
  itself, fail-closed, to avoid an agent replying to itself.)

### 3.3 Rule-Set (schema + API change — codex HIGH)

A **Rule-Set** is a named, ordered group of single-receiver rules forming one
flow. This is NOT free on the flat schema; it requires:

- **New columns** on `routing_rules`: `rule_set` (name, nullable), `position`
  (int), `prompt_template_ref` (name, nullable).
- **`Behavior.Routing.add_rule` gains** `rule_set` / `position` /
  `prompt_template_ref` params and **enforces single-receiver** when `rule_set`
  is set (multi-receiver fan-out = an explicit broadcast rule, §3.6 B).
- **`RuleStore.load_into_registry/1` + `Resolver`** publish + carry the
  `prompt_template_ref` (and rule identity) into the match result — see §3.5.
- A set's optional **entry** rule (fired by a legend `@`-trigger).
- Existing flat rules have all-nil new columns → unchanged behaviour.

### 3.4 Prompt template + delivery transform — **path A** (Allen)

A **named, reusable** template rendered onto the message delivered to a rule's
receiver. **v1 is path A: no new abstraction.** At the *existing* per-recipient
delivery step, the delivery code calls one render function with the matched
rule's template (if any):

```
render_for_recipient(message, recipient, matched_rule_ctx) :: rendered
```

- **Templated** (Allen ①+②): placeholders from §3.2; engine deliberately simple
  (flat substitution over the fixed variable set); `{body}` MUST appear
  (validated at template-write) so the original is never dropped.
- **Named + shared**: rules reference a template by name (`prompt_template_ref`);
  a whole rule-set reuses one template. Storage: a session-scoped
  `prompt_templates` map (open question §8.1: workspace-level registry later).
- **Two delivery sites, ALL members** (Allen ⑤): agent delivery renders into the
  payload text; **human delivery renders a display/render-time suffix** (NOT
  stored per-recipient — resolves codex MED-2). So "all members" holds without
  per-recipient storage.
- **NOT a hook system.** A registered/ordered/pluggable delivery-hook subsystem
  (call it "B") IS a new abstraction and is **explicitly deferred** (§7). v1
  writes the render as a *single function* at the seam so B can slot in later IF
  a second transform (footer, redaction) ever appears — YAGNI.

### 3.5 Matched-rule threading (CRITICAL — codex)

Prompt injection is per-flow/per-rule (the "you are in 传话游戏" context is bound
to the matched rule, not the receiver), so the delivery transform MUST know which
rule matched. Today `Resolver.resolve/4` returns bare `[URI]` and the fan-out
loses the rule. Required change:

- `Resolver.resolve` returns **`[{recipient_uri, matched_rule_ctx}]`** (or a
  recipient→ctx map), where `matched_rule_ctx` carries at least
  `prompt_template_ref` + rule id. Back-compat: a thin helper returns the old
  `[URI]` for callers that don't need context.
- `Behavior.Chat.handle_send/2` fan-out + `dispatch_receive_call/3` thread
  `matched_rule_ctx` to the per-recipient delivery, which calls
  `render_for_recipient/3` (§3.4).
- When two rules deliver to the same recipient: the rule-set/single-receiver model
  (§3.3) makes this rare; if it occurs, the higher-`position` (or first) rule's
  template wins (deterministic; documented). No concat in v1.

### 3.6 Legend + dedicated resolution layer (codex HIGH)

A **Legend** = `{name, member_set (URIs/role_names), bound_rule_set, fold: bool}`.

- **UI**: folded legend members collapse into one legend entry (declutter —
  Allen). They remain first-class members (individually `@`-able, snapshot-able).
- **`@legend` semantics**: **(A) default** — triggers the bound rule-set's entry
  rule. **(B)** — a rule-set may be a pure broadcast (entry fans to all members):
  just one kind of rule-set, not a separate mechanism.
- **Resolution layer (NOT raw mentions)**: a legend is a session-scoped *symbolic
  handle*, not a member/agent URI, so it CANNOT ride `Matcher.mention/1` (which
  matches concrete URIs) without silent-drop/wrong-target risk. Introduce a
  **legend registry** (session-scoped `name → {member_set, bound_rule_set}`); the
  mention parsers (LiveView + Feishu) resolve a legend name to "trigger its entry
  rule" via this registry BEFORE the URI-mention path. Legends are
  session-scoped; nesting is out of scope (v1).

### 3.7 SessionTemplate + create_session materialization (codex HIGH)

`SessionTemplate` content gains `members` (those `in_session_template: true`),
`prompt_templates` (the named map), and `legends`; `agent_slots` is removed
(§3.8). Version-hash extends over the new fields (the write-once/hash-checked
`Behavior.Template` accommodates extra fields). **But the live instantiate path
must change**: today `create_session/3` joins only `[owner, orchestrator]` — it
MUST materialize the template's `members` (recreate spawned members from their
`source_template_uri`, register provenance/role_name, install rule-sets +
prompt_templates + legends) so an instantiated/forked template actually produces
the team. This is the load-bearing contract change codex flagged.

### 3.8 Slot retirement — clean cutover (Allen: no backward-compat)

`Orchestrator.Tools` `add_agent_slot` / `remove_agent_slot` /
`update_agent_template` / `write_matcher(receiver_slot_names)` and slot-name
routing are **removed** and replaced by:

- **add member** with `provenance = <orchestrator>` (+ `role_name`,
  `in_session_template`, spawn-source state) — lineage-bounded authority via
  `{:manages, provenance}` (action `:manage`).
- **define rule-set rules** targeting members by `role_name`, with
  `prompt_template_ref`.

The orchestrator MCP tool surface is **rewritten** to these member+rule-set tools
(clean cutover — existing orchestrators are re-tooled; this is a deliberate
breaking change, not a nil-default). Existing SessionTemplates' residual
`agent_slots` are dropped (dev environment; no production templates to preserve).
The retired `prompt_override` no-op param is superseded by `prompt_template_ref`.
The `remove_agent_slot` silent-prune footgun (PR #519 observability) is subsumed:
rule-sets are the explicit add/remove unit; member removal reports its rule-set
impact.

## 4. Worked example — 传话游戏

- **Legend** `传话游戏`: `member_set = [relay-cc, relay-codex, relay-curl]` (by
  role_name), `fold: true`, `bound_rule_set: "telephone"`.
- **Members** (relay agents): `provenance = <creator>`, role_name set,
  spawn-source state (template/generation), `in_session_template: true`.
- **Rule-set `telephone`** (single-receiver each, shared template
  `telephone_hop`): entry `mention(传话游戏) → relay-cc`; `from(relay-cc) →
  relay-codex`; `from(relay-codex) → relay-curl`.
- `telephone_hop` = `"你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。"`.
- User `@传话游戏` → legend registry resolves → entry rule fires → cc receives msg
  rendered with `telephone_hop` → replies → routed to codex → … → curl. Agents are
  members (individually `@`-able); the legend+rule-set+template+members snapshot
  into a SessionTemplate for reuse.
- **User→user footer** (the same machinery): a rule `always (from $user) →
  $session_users` with template `"{body}\n\n（该消息由 {sender} 于 {sent_at}
  发送）"` — agents get it in payload, humans see it as a render-time suffix.

## 5. Decisions

| # | Decision | Choice |
|---|----------|--------|
| ①/② | injection shape + static/templated | **Templated**, vars `{sender}/{flavor}/{body}/{session}/{sent_at}`; v1 engine flat-substitution, `{body}` required |
| ③/④ | multi-receiver / multi-rule | **Rule-set of single-receiver rules**, shared **named** template; needs schema/API change (§3.3) |
| ⑤ | injection scope | **All members**, two delivery sites (agent payload / human render-suffix) |
| A/B | `@legend` | **A** (trigger rule-set) default; **B** (broadcast) = a rule-set variant |
| dyn | dynamic audience/vars | **Add `$sender` token + template vars** (§3.2) |
| transform | delivery mechanism | **Path A** (render at existing delivery seam, single function); **hook subsystem B deferred** |
| provenance | scope | **General member facet, single job** = management authority over member + its routing rows; uses existing action-axis (`:manage`) |
| slots | migration | **Clean cutover**, no backward-compat; MCP tools rewritten |

## 6. Migration / cutover

Clean cutover (Allen). New member fields default nil/false → plain members
behave as today. Existing flat rules (nil new columns) unchanged. System-default
`always → [$session_users, $mentions]` + `$mentions` filtering unchanged. Old
SessionTemplates load with empty new fields; residual `agent_slots` dropped. The
orchestrator MCP tool surface is replaced (deliberate breaking change — no live
production orchestrators to preserve).

## 7. Out of scope (v2+)

- **Delivery-hook subsystem (B)** — registered/ordered/pluggable transforms. v1
  ships one render function at the seam; B is the explicit future generalization
  (Allen's Claude-Code-hooks direction).
- Rich template language (conditionals/loops/partials) — v1 flat substitution.
- Nested / cross-session legends.
- Workspace-level shared template registry (v1 = session-scoped map).
- The general "message matched no worker → silent default fan-out" observability
  gap (todo #9 part b) — reduced in blast radius here, tracked separately.

## 8. Resolved decisions (Allen approved the recommendations 2026-06-01)

1. **Template storage** → **session-scoped `prompt_templates` map** for v1. A
   workspace-level shared registry is a future option (§7), not v1.
2. **role_name uniqueness/scope** → **unique per session**.
3. **`{:manages, provenance}` over routing rows** → **reuses the existing
   capability machinery** (`Ezagent.CapabilityRegistry` + `Kind.holds_cap?` →
   `Identity.list_caps_for/1` → `Capability.matches?/2`, with the action axis).
   No new mechanism. Only additions: (a) declare a `:manage` action on the
   relevant Behavior(s); (b) routing-row edit actions cap-check
   `{:manages, provenance}` scoped to the affected member's provenance.
4. **Spawn-source state placement** → **member `meta` fields** (provenance /
   role_name / in_session_template / source_template_uri / live_worker_uri /
   generation). If the chat slice grows heavy in practice, a side table keyed by
   member URI is the fallback (decide in the plan if measured).
5. **Resolver return-shape** (§3.5) → decided in the implementation plan after a
   caller audit; default to a **recipient→ctx map** plus a back-compat `[URI]`
   helper, choosing whichever least disturbs existing `resolve/4` callers.

## 9. Testing / verification

- **Resolver/matcher**: rule-set single-receiver routing; `$sender` expansion
  (excludes self, member-filtered); matched-rule ctx is returned + threaded.
- **Delivery transform**: template render (placeholders, `{body}`-required
  validation); agent payload site; human render-suffix site; two-rules-same-
  recipient determinism.
- **Member facets**: `{:manages, provenance}` (action `:manage`) authorises member
  + its routing rows, denies non-owners; "only reply to owner" expressed purely as
  a routing rule routes correctly; role_name → URI rebinding across respawn;
  spawn-source/generation round-trip for update/rollback/respawn;
  `in_session_template` snapshot + **create_session materialization** round-trip
  (instantiate a template → the team actually appears).
- **Legend**: `@legend` resolves via the registry → entry rule fires; a legend
  name does NOT mis-route through the URI-mention path.
- **Invariant gate** (`feedback_completion_requires_invariant_test`): a test that
  FAILS if a slot-style mechanism reappears OR if a rule-set flow requires
  model-computed routing.
- **Scenario 34 (Allen)**: the live tier — the 传话游戏 round-trip in the bound
  Feishu group (real cc/codex/curl), expressed purely via legend + rule-set +
  templates (no baton) — **must pass e2e**, AND the full suite must show **no
  functional regression** (the cutover touches Resolver/Chat/RuleStore/templates/
  orchestrator-tools, so the existing routing/mention/chat/orchestrator e2e
  scenarios must stay green).
