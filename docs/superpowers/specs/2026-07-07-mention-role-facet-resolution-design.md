# Bare @mention resolution by role facet — design

**Date**: 2026-07-07 · **Status**: DRAFT (T3, from jjkysy #1201 handoff item ④, coordinator-verified HOLDS)
**Scope**: session-domain / world plugin only. Independent of T1/T2. Forward-compat contract with orchestration spec A-2 (auto-prefix) declared in §5.
**Authority**: `docs/together/2026-07-06/handoffs/system-mechanism-feedback.md` item ④ + Appendix B row ④; role-slot model `docs/superpowers/specs/2026-07-05-socialware-role-slot-model-design.md` (P2: role lives ONLY on the membership edge); orchestration spec `docs/superpowers/specs/2026-07-06-orchestration-as-socialware-design.md` (A-2 install-time auto-prefix).

---

## 1. X — the problem

**Mention resolution must resolve the identities humans actually address. The
`role_name` facet is a first-class member identity — the role-slot model made
it so — but the mention resolver predates that model and only tries the two
pre-role legs (URI path segment, display name).**

The role-slot model (P1–P3, landed) deliberately made instance identity
anonymous and role identity primary:

- Materialized role-slot agents get **PLANNED (UUID) URIs**:
  `SessionCreator.DefinitionAgents.planned_agent_uri/1` —
  `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex:380-384`
  (`Ezagent.URI.agent(Ecto.UUID.generate())`; the `@doc` states the intent:
  "Definition declarations intentionally carry only role data; the runtime
  chooses a UUID instance URI").
- **`display_name` degrades to the UUID** for these agents:
  `Ezagent.EntityPresenter` "Falls back to the URI path segment" when no
  profile name exists
  (`apps/ezagent_domain_identity/lib/ezagent/entity_presenter.ex:10,30`), and
  `member_options/1` builds its `"display_name"` from exactly this presenter
  (`conversation_data.ex:176`). A role-materialized agent has no profile → both
  existing legs collapse to the same unusable UUID string.
- The name a human actually sees and types is the **role**: the members panel
  and role slots surface `role_name`, the routing table addresses `{:role,
  name}`, `from_role` matches on it (#1212), and per-session uniqueness is
  enforced at join (`Membership.do_join/5` via `Members.role_name_conflict/3`,
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:28-50`).

Yet typing `@advisor` in the conversation composer resolves to nothing:
`resolve_member_name/2` tries URI-segment then display-name, both miss, and
the token is silently dropped from `mentions`. Runtime reproduction: #1190
`kanban-full-loop-r2/03a-*` probes (`@kanban-assistant` → `mentions: []`).

**Failure mode is worse than "nothing happens".** `Behavior.Session` derives
recipients from `msg.mentions` **or all members when mentions is empty**
(`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:16-17`). A failed
bare mention therefore silently converts a targeted address into the
empty-mentions path — in a fan-out session, a broadcast; in a mention-gated
session, whatever the routing table does with an unmentioned message. The
sender's intent is lost with no signal (the existing dropped-mention notify at
`session.ex:628-639` only fires for URIs that *did* parse but aren't members —
a never-resolved token is invisible to it).

The workaround (full-URI mention `@entity://…/agent/<uuid>`) works but is
exactly the instance-addressing posture the role-slot model retired.

### 1.1 Verified evidence vs the handoff's cited lines (current main `dcabf6174`)

| Handoff claim | Verified on current main |
|---|---|
| UUID leg `definition_agents.ex` ~:383 | **HOLDS, minor drift**: `planned_agent_uri/1` body at `definition_agents.ex:380-384`. |
| World 2-leg path `conversation_data.ex` ~:762-782 | **HOLDS, minor drift**: `resolve_member_name/2` at `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:768-782`; bare parse `parse_bare_mentions/2` :758-765; URI parse `parse_uri_mentions/1` :750-756. |
| Precedent `members.ex:24-29` | **HOLDS, two-file split**: the :24-29 range matches `EzagentPluginHello.Members.role_uri/2` (`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex:24-31`), which delegates to the canonical domain resolver `Ezagent.ActionSet.Session.Members.role_name_to_uri/2` (`apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex:83-89`). Both exist; the domain function is the canonical precedent. |
| "display_name is often a uuid" (handoff marked 未证实) | **NOW SUBSTANTIATED** via the `EntityPresenter` fallback chain above — for profile-less UUID agents, `display_name == URI path segment == uuid`. |

## 2. Surface inventory — every place a mention is resolved or produced

| # | Surface | Where | Current legs | Verdict |
|---|---|---|---|---|
| S1 | **Server-side parse (LOAD-BEARING)** | `conversation_data.ex` — `parse_mentions/2` :285-291 → `parse_uri_mentions/1` :750-756 + `parse_bare_mentions/2` :758-765 → `resolve_member_name/2` :768-782; invoked from `build_message/4` :325-333 (server-authoritative — client recipient lists are never trusted) | explicit `@entity://` URI; bare token → URI path segment, else display_name; unique-or-nothing | **CHANGE HERE.** This is the single choke point: what lands in `msg.mentions` is what the domain recipient resolver consumes. The member rows it matches against (`member_options/1` :171-190) **already carry `"role_name"`** (:186, read off the membership-edge facet) — the data is present, the resolver ignores it. |
| S2 | **World autocomplete (React)** | `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` — `mentionMatches` :256-269 (filters by `uriSegment` + `display_name` only), insertion token = `uriSegment(m.uri)` (:1266-1272, inserts `@<last-path-segment>` — for role-slot agents, the UUID) | filter: segment/display; insert: segment | **CHANGE.** Same rows, same gap: `role_name` arrives in the `members:update` payload (`conversation_actions.ex:837-856` `push_members/1`) and is ignored. Also the *insert* form must become role-aware (§6). |
| S3 | **ezagent_web LV composer hook** | `apps/ezagent_web/assets/js/hooks/mention_autocomplete.js` — filters by uri/display_name, inserts the **full URI** | insert-full-URI → resolves via S1's explicit-URI leg | **UNAFFECTED for correctness** (full-URI mentions always resolve); shares the discoverability gap (can't filter by role). Optional parity change, builder-verify whether this surface is still live (§9). |
| S4 | **Programmatic role addressing** | `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:368-372` — `EzagentPluginHello.Members.role_uri(session_uri, "orchestrator")` | role facet (the precedent, in production) | **NO CHANGE** — this is the pattern S1 adopts. |
| S5 | **Feishu channel mention parse** | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex` — resolves `@name` against **live KindRegistry agent names**, not session members | registry name-suffix | **OUT OF SCOPE** — different addressing domain (channel-level, pre-session). Noted so the enumeration is total; no role facet exists at that layer. |
| S6 | **Legend names** | `mention(<legend_name>)` routing matcher fires through the Resolver (`behavior/session.ex:547`); legend names ride `legend_triggers`, never `:mentions` (`apps/ezagent_core/lib/ezagent/message.ex:102`) | separate namespace | **NO CHANGE**, but legends share the bare-`@` token space with roles — collision posture defined in §4.4. |

The old LiveView plugin parser that S1's docstring calls its "port" origin no
longer exists in-tree (`parse_bare_mentions` greps to world only) — S1 is the
sole free-text session mention parser.

## 3. Design — a third leg, tiered

### 3.1 Change

`resolve_member_name/2` (S1) gains a **role leg**: match the bare token
against each member row's `"role_name"` (exact, case-sensitive — role names
are machine-checked identifiers, unlike display names). The legs become
**ordered exact-match tiers**, first non-empty tier wins, each tier keeps the
existing unique-or-nothing guard:

```
tier 1: URI path segment == token      (unchanged, stays first)
tier 2: role_name == token             (NEW)
tier 3: display_name == token          (unchanged, demoted below role)
```

No new data plumbing: `member_options/1` rows already carry `"role_name"` from
the membership-edge facet. The change is confined to the private resolver in
`conversation_data.ex` plus the two UI surfaces (§6).

### 3.2 Why tiers, not a pooled match

Alternative considered — pool all exact matches across all three facets and
require global uniqueness. Rejected: any *new* member joining could break a
previously-working mention (a display_name equal to an existing member's
segment turns a resolving token into ambiguous-nothing). Tiering makes early
legs immune to later-leg noise: every token that resolves today via segment
resolves to the same URI after this change (**strict backward compatibility**,
pinned by the existing parse tests which must pass unmodified).

### 3.3 Convergence with receivers — evaluated, NOT forced

The task asks whether mentions and `{:role,name}` receivers should share one
resolution helper. Evaluation:

- Receivers resolve on the **domain-side members map** (`%{%URI{} => meta}`
  with atom-key facets) via `Ezagent.ActionSet.Session.Members.role_name_to_uri/2`.
- S1 resolves on **presenter rows** (`[%{"uri" => string, "display_name" =>
  …, "role_name" => …}]`) because it must also match display names, which only
  exist at the presenter layer.

Forcing one function means either dragging presenter concerns into the domain
ActionSet or making world re-read the raw slice and re-derive display names —
cross-layer coupling to deduplicate a five-line filter. **Decision: converge on
the data source, not the function.** Both paths already read the same
authoritative `:session` slice members map (`member_options`' docstring pins
this: "the same source the server-side mention parse uses… can't drift"), and
the role leg matches the **same edge facet** `role_name_to_uri/2` matches. That
shared substrate is the invariant worth having; a shared function body is not.
(If a later refactor gives the domain a presenter-independent member-row shape,
revisit — noted as non-blocking.)

### 3.4 Semantics guarantee

The role leg resolves the role **to the member URI currently holding it** at
parse time — a mention is an addressed message to the present occupant, which
is exactly the role-slot model's contract (role on the edge, reassignable;
`{:role,name}` receivers behave identically). After reassignment, old
messages' `mentions` keep the old occupant's URI: mentions are historical
facts about who was addressed, not live role pointers. This matches receiver
behavior (resolution at send time) and needs no new storage.

## 4. Precedence and ambiguity rules (normative)

- **R1 — Tier order**: segment > role_name > display_name. First tier with ≥1
  candidate decides; lower tiers are never consulted.
- **R2 — Unique-or-nothing per tier**: within the deciding tier, candidates
  dedupe by URI; more than one distinct URI ⇒ resolve to nothing (never
  guess). Preserved from the current resolver.
- **R3 — Role-vs-display collision**: member B holds `role_name: "advisor"`,
  member C has `display_name: "advisor"` ⇒ `@advisor` resolves **B** (tier 2
  beats tier 3). Rationale: role_name is session-unique by construction
  (`role_name_conflict/3` at join); display_name is free-form and collidable.
- **R4 — Segment-vs-role collision**: member A's URI segment is `advisor`
  (e.g. a hand-named agent), member B holds role `advisor` ⇒ `@advisor`
  resolves **A** (tier 1). Deterministic; the autocomplete's shadow check
  (§6, U3) prevents the UI from ever *producing* a shadowed role token, so
  this arises only from hand-typed text — and there it keeps today's meaning.
- **R5 — Role tier ambiguity**: two members with the same role_name cannot
  coexist (join-time uniqueness), but the resolver keeps the R2 guard anyway
  (defense against a stale/duplicated snapshot ever reaching the parser —
  fail to nothing, never misroute).
- **R6 — Unresolved token stays plain text**: a bare token no tier resolves
  (including an **unfilled role slot** — an unfilled role has no member row,
  so it cannot match) contributes nothing to `mentions`. No error, no
  synthetic placeholder URI. This is the current documented behavior for
  unknown names ("unknown @name resolves to nothing" test) extended verbatim
  to roles; the no-silent-misfire guarantee is delivered by the autocomplete
  (which never offers unfilled roles — they aren't members) plus the invariant
  test pinning the plain-text outcome. Deliberately NOT chosen: erroring the
  send (breaks legitimate `@` text — emails, handles quoted in prose) or
  parking the mention until the slot fills (a live role pointer contradicts
  §3.4's resolution-at-send-time semantics).
- **R7 — Legend collision posture**: legend names and role names share the
  bare-`@` token space but different mechanisms (S6: legends ride
  `legend_triggers`/routing matcher, never `:mentions`). This spec does not
  unify them; it only requires that adding the role leg not change legend
  behavior. A role_name shadowing a legend name resolves as a member mention
  in `mentions` *and* whatever legend machinery independently does with the
  text — same superposition that exists today for a display_name shadowing a
  legend. Builder-verify confirms no interference (§9-V5); a uniqueness check
  between the two namespaces is out of scope (would belong to Definition
  conformance, cross-referenced not designed here).

## 5. Forward-compat with orchestration A-2 (install-time auto-prefix)

A-2 (orchestration spec, "Namespace [A-2]") makes installers rewrite short
role names to `def:role` form (`hello:advisor`); short names remain the
author-local reference and the UI shows short name + source badge. Two
consequences this design absorbs **now** so prefixed names cannot break it:

- **F1 — Verbatim edge match**: the role leg matches whatever string is on
  the membership edge. When A-2 lands and edges carry `hello:advisor`, a
  `@hello:advisor` token matches with zero resolver change. The leg has no
  parsing/normalization of the role string.
- **F2 — Tokenizer must admit `:` without breaking today's text**: the bare
  token class (`@([A-Za-z0-9][A-Za-z0-9._-]*)`, `conversation_data.ex:761`)
  excludes `:`. Design: extend to an **optional single colon-joined tail** —
  `@([A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?)` — and
  resolve **longest-token-first**: try the full colon-bearing token through
  the tiers; if nothing resolves, retry with the pre-colon head. Properties:
  `@advisor: hi` (punctuation) never captures the colon (no word char after
  it) — today's behavior intact; `@hello:advisor` pre-A-2 falls back to the
  `hello` head (today's exact behavior); post-A-2 the full token wins.
  Deterministic, no flag day. The same longest-first rule applies in the
  autocomplete filter.
- **F3 — Short-name dual-read is an A-2-time decision, not this design**:
  A-2's compat window ("dual-read… prefix derivation is deterministic")
  implies `@advisor` may later need to resolve a uniquely-suffix-matching
  `*:advisor` edge. The tier structure accommodates it as a tier-2 sub-rule
  (exact role match, else unique suffix match) without reordering anything —
  explicitly **deferred to A-2's builder**, recorded here so neither spec
  blocks the other.
- **F4 — Badge consistency**: §6's source badge is the same UI element A-2's
  impl-constraint mandates ("short name + source badge rather than the full
  `hello:advisor`") — one component, two specs satisfied.

## 6. Autocomplete UX (S2, and S3 parity)

- **U1 — Filter includes role**: `mentionMatches` adds `role_name` to the
  match predicate (rows already carry it). An entry matched by role renders
  the **role name as the primary label with a "role" source badge**; entries
  matched by segment/display render as today. Badge presentation follows the
  A-2 impl-constraint (short name + source badge; post-A-2 the badge carries
  the definition source, e.g. `hello`).
- **U2 — Insertion prefers the role token**: selecting a role-matched entry
  inserts `@<role_name>` — the human-legible, role-slot-canonical form —
  instead of today's `@<uuid-segment>`.
- **U3 — Shadow check before inserting a role token**: the client replays the
  §4 tiers over the member rows it already holds; if `@<role_name>` would NOT
  resolve to the selected member (R4 shadow by someone's segment), insert the
  full `@entity://…` URI instead (always unambiguous via S1's explicit-URI
  leg). The check is a pure function over data the component already has — no
  round-trip. This closes the only path where the UI could mint a token that
  the server resolves to a different member than the one the user clicked.
- **U4 — Unfilled roles never appear**: autocomplete lists members only; an
  unfilled slot has no member row. (The members panel separately shows open
  human slots via `human_role_slots/1` — display concern, not mention
  addressing; unchanged.)
- **U5 — S3 (ezagent_web hook) parity is optional**: it inserts full URIs, so
  it stays correct without change. If touched, only U1's filter+badge apply
  (never U2 — that surface has no server-side member context guarantee).
  Builder decides after V4 (§9) establishes whether the surface is retained.

## 7. Invariant tests

Home: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs`
(pure, DB-free, async — same harness as the existing parse pins; fixture rows
gain `"role_name"` keys). These are the "fails when the goal is unmet" gates:

- **T1 — Role resolves (the headline invariant)**: member row with
  `role_name: "advisor"` (display_name a UUID string, segment a UUID) ⇒
  `parse_mentions("ping @advisor", members)` returns exactly that member's
  URI. Fails on current main.
- **T2 — Precedence R3**: role holder B + display_name-"advisor" member C ⇒
  `@advisor` → B only.
- **T3 — Precedence R4**: segment-"advisor" member A + role holder B ⇒
  `@advisor` → A only.
- **T4 — Unfilled role / R6**: no member carries `role_name: "builder"` ⇒
  `@builder` → `[]` (plain text, no misfire, no error).
- **T5 — R5 defensive guard**: two rows sharing a role_name ⇒ `[]`.
- **T6 — Backward compat**: every existing test in the module passes
  unmodified (segment and display legs byte-identical for role-less rows).
- **T7 — F2 tokenizer**: member with edge `role_name: "hello:advisor"` ⇒
  `@hello:advisor` resolves it; absent such a member but with a member
  resolvable as `hello`, `@hello:advisor` resolves the `hello` head;
  `@advisor: hi` (trailing punctuation) behaves exactly as `@advisor`.
- **T8 — E2E (one, thin)**: re-run the #1190 r2 probe shape — a role-slot
  materialized session, `@<role_name>` from the world composer, assert the
  stored message's `mentions` contains the materialized agent URI and the
  agent's receive path is invoked. This is the reproduce-first gate; T1 is its
  fast regression twin.

UI (S2): a component-level test for U3's shadow check if the React harness
supports it, else covered by T8 + builder-verify V3.

## 8. Non-goals

- Feishu channel mention resolution (S5) — different addressing domain.
- Legend/role namespace unification (R7 — conformance concern, elsewhere).
- Live role pointers in stored mentions (§3.4 — resolution is at send time).
- A-2 short-name dual-read (F3 — belongs to the A-2 builder).
- Receiver/mention shared helper (§3.3 — shared substrate suffices).

## 9. Builder-verify notes

- **V1 — Line anchors**: all file:line cites verified on main `dcabf6174`
  (2026-07-07) but WILL drift; anchor by function name (`resolve_member_name/2`,
  `parse_bare_mentions/2`, `member_options/1`, `mentionMatches`, `uriSegment`).
- **V2 — role_name reaches the client**: confirm `"role_name"` survives both
  member-row transports — the initial `data-world-state` embed and the
  `members:update` push (`conversation_actions.ex` `push_members/1`) — and is
  non-nil for a role-slot materialized member in a live session (facet written
  at `session.join`; nil for facet-less joins is expected and fine).
- **V3 — React test harness**: check whether `apps/ezagent_plugin_world/assets`
  has a JS test runner; if not, U3 is covered by T8 and a manual probe —
  don't build a harness for this.
- **V4 — S3 liveness**: determine whether the ezagent_web SessionEditor
  composer (mention_autocomplete.js) is still a shipped surface post-world
  migration before spending U5 effort.
- **V5 — Legend non-interference (R7)**: in a session with a legend registered,
  confirm adding the role leg changes nothing about `legend_triggers` /
  `mention(<legend>)` matcher behavior.
- **V6 — Token charset**: world's bare-token class is ASCII-leading while
  Feishu's parser is Unicode-aware for CJK legend names. If role_names may be
  CJK (check Definition conformance rules for role_name charset), the S1 token
  class must widen to the Unicode class — decide from what conformance
  actually permits, don't guess.
- **V7 — T8 fixture**: build the E2E on a definition-materialized session
  (PLANNED-URI member with a role facet), not a hand-joined member with a
  pretty name — the latter passes through the display leg and proves nothing.
