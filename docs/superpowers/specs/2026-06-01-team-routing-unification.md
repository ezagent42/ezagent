# Team Routing Unification — Rule-Sets, Prompt Templates, Legends, and Member-Provenance

**Date**: 2026-06-01
**Status**: spec (design approved in principle by Allen via Feishu; pending written review + codex adversarial review)
**Supersedes the need for**: the orchestrator-private `agent_slot` mechanism (see §6 Slot Retirement)

## 1. Motivation

Building the live `传话游戏` relay (cc → codex → curl, each appending a line,
mirrored to a Feishu group) surfaced four problems that turned out to be **one
entangled design gap**:

1. **Agents in a flow don't know they're in the flow.** A worker only ever sees
   the previous hop's raw message. cc happened to recognise the trigger word;
   codex/curl just "continued the conversation". Making models self-propagate
   protocol instructions in the message body is fragile — gpt-5.5 botched an
   off-by-one and skipped a hop. The routing table should carry the role context,
   not the message.
2. **There is no place to attach that context.** A routing rule today has
   `matcher` + `receivers` + `enabled` — no field for "what to tell the receiver".
3. **`@`-mention is asymmetric.** `@`-mentioning a normal session **member**
   auto-routes (the system-default `always → [$session_users, $mentions]` rule +
   the member-filtered `$mentions` magic token). But the relay workers are
   orchestrator **slot workers**, deliberately *not* members, so `@`-mention never
   reached them — the message matched no worker rule and silently went nowhere.
4. **Two parallel mechanisms** ("slot worker" vs "session member") for what is
   essentially the same thing — an agent participating in a session — with
   different management, naming, snapshot, and routing semantics.

The unifying insight (Allen): a "slot" is just **a member with three extra
facets**, and a multi-agent flow is just **a named set of single-receiver routing
rules that share a prompt template**, optionally fronted by a **legend** (a
user-facing handle that collapses the team and triggers its flow).

## 2. Current state (code-grounded, 2026-06-01)

- **Routing rules** (`Ezagent.Routing.RuleStore`, table `MentionRouting`): flat
  rows of `{matcher_data, receivers :: [String.t()], enabled, workspace_uri,
  source, created_by, …}`. `receivers` is already a LIST (multi-receiver capable).
  **No "rule set" / grouping concept** — the relay is 3 independent rows related
  only by shared session scope.
- **No prompt/context field** on a rule.
- **Slot workers**: `Orchestrator.Tools.add_agent_slot/write_matcher` record named
  slots in `template_working_copy.agent_slots`, spawn workers under the
  orchestrator's lineage (cap #2 `{:spawned_by, orch}`), route by slot-name. Slot
  workers are NOT session members.
- **Session members**: the chat slice `:members` is `{URI, %{online: bool}}` —
  **no provenance, no creator/owner, no stable role-name alias**.
- **SessionTemplate** content = `{agent_slots, routing_rules,
  orchestrator_template_uri, default_workspace_uri}` (version-hashed). **Members
  are NOT snapshotted** — they are joined at runtime by `create_session/3`.

So today the three "slot powers" (lineage-bounded management, stable name→URI,
template snapshot) exist ONLY on slots; members have none of them. The design
below moves those powers onto members and retires slots.

## 3. Design

### 3.1 Member gains three facets

A session member becomes `{URI, meta}` where `meta` carries (in addition to the
existing `online`):

- **`provenance`** — the URI of the principal that created/owns this member
  (a user, or an orchestrator agent). GENERAL, not orchestrator-specific.
  Provenance drives two independent policies:
  - **(a) Management authority** — who may reconfigure/remove this member. A cap
    `{:manages, provenance_uri}` (generalising the slot's `{:spawned_by, orch}`)
    authorises management. Orchestrator workers are simply members whose
    provenance is the orchestrator.
  - **(b) Audience / reply scope** *(Allen 2026-06-01)* — an optional policy on
    the member constraining whom it interacts with: `:any` (default — current
    behaviour), `:owner_only` (only receives from / replies to its provenance
    principal), or `{:allowlist, [uri]}`. Example: a user-created private agent
    set to `:owner_only` replies only to its creator. Enforced at routing time
    (the Resolver drops the member as a recipient when the sender is outside its
    audience scope) — fail-closed, no silent broadening.
- **`role_name`** *(optional)* — a stable, human-meaningful alias
  (e.g. `"relay-cc"`) decoupled from the agent's URI. Routing rules and legends
  may target a member by `role_name`; the binding `role_name → current URI`
  survives respawn (the URI may change, the role-name does not). This is the
  slot's stable-naming power, lifted onto members.
- **`in_template`** *(bool, default false)* — whether this member is captured in
  the SessionTemplate snapshot (see §3.5). Lets a template carry "this team's
  members" as well as its rules.

`provenance` with audience scope `:any` and no `role_name` / `in_template` = a
plain member (today's behaviour). Fully backward-compatible.

### 3.2 Rule-Set

A **Rule-Set** is a named, ordered group of routing rules that form one logical
flow. Properties:

- Each rule in a set has **exactly one receiver** (a member URI or `role_name`).
  (Multi-receiver fan-out is expressed as multiple rules, or a dedicated
  broadcast rule — see §3.4 (B).) This removes the "one rule, many receivers"
  ambiguity.
- Rules in a set may **share a named prompt template** (§3.3) — "multiple rules,
  one template" replaces "one rule, multiple receivers + one injection".
- A set has an optional **entry** rule (the rule a legend `@`-trigger fires).
- Mechanically: add a nullable `rule_set` (name) + `position` to the routing-rule
  row, and a nullable `prompt_template_ref`. A "set" is the rows sharing a
  `rule_set` name within a session scope. (No new table required for v1; a
  `rule_sets` metadata row may come later for entry/ordering if convention proves
  insufficient.)

### 3.3 Prompt Template

A **named, reusable** template applied to the message delivered to a rule's
receiver:

- **Templated** *(Allen ①+②)*: supports placeholders `{sender}`, `{flavor}`,
  `{body}`, `{session}` (extensible). **v1 keeps the engine deliberately simple** —
  a flat `String.replace/3`-style substitution over a fixed, documented variable
  set; NO conditionals/loops/partial language. `{body}` MUST appear (validated at
  template-write time) so the original message is never silently dropped.
- **Named + shared**: templates are referenced by name from rules, so a whole
  rule-set's hops can reuse one "you are in <flow>, append one short line"
  template. (Storage: a `prompt_templates` map in the session's working copy /
  template, keyed by name. Reusable across rules in the session.)
- **Scope = all session members** *(Allen ⑤)*: injection applies to every member
  receiver — like an email-forward footer — not only agent receivers. (Rationale:
  a human teammate may also benefit from "[forwarded via <flow>]" context; and
  scoping to "agents only" was an unnecessary special case.) The Resolver/delivery
  path applies the matched rule's template to the delivered payload per receiver.

### 3.4 Legend

A **Legend** is the user-facing handle for a team/flow:

- Shape: `{name, member_set (URIs/role_names it collapses), bound_rule_set,
  fold: bool}`.
- **UI**: members under a folded legend are collapsed into the single legend
  entry in the member list (solves "100 agents clutter the list" — Allen). They
  remain first-class members (individually `@`-able, snapshot-able, scoped).
- **`@legend` semantics** *(Allen A/B — A is the chosen default)*:
  - **(A) default** — `@legend` triggers the legend's **bound rule-set** (fires
    its entry rule; e.g. `@传话游戏` → entry → chain runs).
  - **(B) special case** — a rule-set MAY be a pure broadcast (entry rule fans out
    to all members); that is just one kind of rule-set, not a separate mechanism.
- A legend is itself a routing target: `@legend` resolves via a rule
  `mention(legend) → entry`. Legends are session-scoped; nesting is out of scope
  for v1.

### 3.5 Template snapshot includes members

`SessionTemplate` content gains a `members` list (those with `in_template: true`)
alongside `agent_slots` (which is removed — see §6) and `routing_rules` (now
including `rule_set`/`prompt_template_ref` fields) + a `prompt_templates` map +
`legends`. So a template captures the whole team: who's in it, how they route,
what role context each hop gets, and the legend that fronts it — reusable via
fork/instantiate. (Version-hash extended over the new fields.)

## 4. Worked example — 传话游戏 in the unified model

- A **legend** `传话游戏` with `member_set = [relay-cc, relay-codex, relay-curl]`
  (by `role_name`), `fold: true`, `bound_rule_set: "telephone"`.
- Three **members** (the relay agents), each with `provenance = <the creator>`,
  a `role_name`, audience scope `:any`, `in_template: true`.
- A **rule-set** `telephone`:
  - entry: `mention(传话游戏) → relay-cc`
  - `from(relay-cc) → relay-codex`
  - `from(relay-codex) → relay-curl`
  - all three rules reference shared **prompt template** `telephone_hop`:
    `"你在玩传话接龙。下面是目前的内容：\n{body}\n请只追加一句简短的话。"`
- User `@传话游戏` (default A) → fires the entry rule → cc gets the message +
  the `telephone_hop` template context → replies → routed to codex → … → curl.
  Each agent is also individually `@`-able (they're members). The whole legend +
  rule-set + templates snapshots into a SessionTemplate for reuse.

Compare to today: 3 ad-hoc slot workers + 3 hand-written sender rules + a
model-computed baton protocol that broke at the weakest model.

## 5. Resolved decisions

| # | Decision | Choice |
|---|----------|--------|
| ① / ② | injection shape + static/templated | **Templated**, placeholders `{sender}/{flavor}/{body}/{session}`; v1 engine deliberately simple (flat substitution, `{body}` required) |
| ③ / ④ | multi-receiver / multi-rule | **Rule-set of single-receiver rules**; rules **share a named template**; no multi-receiver-per-rule, no concat ambiguity |
| ⑤ | injection scope | **All session members** (email-footer model), not agents-only |
| A/B | `@legend` semantics | **A** (trigger bound rule-set) is default; **B** (broadcast) = a rule-set variant |
| — | provenance | **General member facet** → drives management authority AND audience/reply scope; slot's `spawned_by` is the orchestrator special case |

## 6. Slot retirement

`Orchestrator.Tools` `add_agent_slot` / `remove_agent_slot` / `write_matcher` /
slot-name routing collapse into:

- **add member with `provenance = <orchestrator>`** (+ optional `role_name`,
  `in_template`) — same lineage-bounded authority via the generalised
  `{:manages, provenance}` cap.
- **define rule-set rules** targeting members by `role_name`.

This removes the slot↔member duplication and the `@`-mention asymmetry (orchestrator
workers are now members). The `remove_agent_slot` silent-rule-prune footgun
(todo, partially addressed by PR #519) is subsumed: rule-sets give an explicit
unit to add/remove, and member removal's effect on rule-sets is reported.

NOTE: the existing `prompt_override` parameter on `add_agent_slot` (currently a
no-op placeholder) is superseded by the rule-set prompt-template mechanism.

## 7. Migration / backward-compat

- Members default to `provenance: nil` (or the session owner), audience `:any`,
  no `role_name`, `in_template: false` → identical to today.
- Existing flat rules have `rule_set: nil`, `prompt_template_ref: nil` → behave
  exactly as now (no template applied).
- The system-default `always → [$session_users, $mentions]` rule is unchanged;
  `$mentions` member-filtering is unchanged.
- Existing SessionTemplates (no `members`/`prompt_templates`/`legends` keys) load
  with those defaulting empty.
- Orchestrator-spawned slots: provide a one-time shim that reads existing
  `agent_slots` as members-with-provenance during the transition, OR a clean
  cutover (no live slots persist long-term). Decide in the implementation plan.

## 8. Out of scope (v2+)

- Rich template language (conditionals/loops/partials) — v1 is flat substitution.
- Nested legends; cross-session legends.
- A dedicated `rule_sets` table with first-class entry/ordering metadata (v1 uses
  a `rule_set` name + `position` column + convention).
- The broader "message matched no worker → silent default fan-out" observability
  gap (todo #9 part b) — related but tracked separately; this spec reduces its
  blast radius (members + `$mentions` cover the common case).

## 9. Open questions (for review)

1. **Audience-scope enforcement point**: Resolver-level recipient drop (proposed)
   vs a member-side guard. Resolver keeps it declarative + central; confirm.
2. **Template storage**: a `prompt_templates` map on the session working
   copy/template (proposed) vs a workspace-level named-template registry (more
   reuse, more surface). v1 = session-scoped map; flag if workspace reuse is wanted.
3. **role_name uniqueness/scope**: unique per session? per legend? (proposed: per
   session.)
4. **Cutover vs shim** for existing slots (§7).
5. **Cap shape** for `{:manages, provenance}` — does it compose with the pending
   capability action-axis work (separate todo), or stand alone first?

## 10. Testing / verification (to expand in the plan)

- Resolver unit tests: rule-set single-receiver routing; prompt-template
  application (placeholders, `{body}`-required validation); audience-scope drop
  (owner_only / allowlist fail-closed); legend `@`-trigger → entry.
- Member-facet tests: provenance management cap; role_name → URI rebinding across
  respawn; `in_template` snapshot round-trip.
- The invariant gate (per `feedback_completion_requires_invariant_test`): a test
  that FAILS if a slot-style mechanism reappears OR if a rule-set flow requires
  model-computed routing. The **live tier** remains the 传话游戏 round-trip in the
  bound Feishu group (real cc/codex/curl), now expressed purely via legend +
  rule-set + templates (no baton).
