# Bare @mention resolution by role facet — design

**Date**: 2026-07-07 · **Status**: SOUND (T3, from jjkysy #1201 handoff item ④, coordinator-verified HOLDS)
**Review**: codex adversarial R4 = SOUND (zero BLOCKER, zero MAJOR). Review trail: R1=3 MAJOR (Feishu scope, public-view, U2/F4) → all fixed; R2=1 MAJOR (F2 fallback guard member-rows-only) → fixed; R3=1 MAJOR (F2 guard missed unfilled open slots) → fixed via combined role-name set; R4 confirmed internally consistent across all 8 rules, 8 tests, 4 forward-compat claims. 4 MINOR polish applied (T7 case count, T7c wording, §7 harness seam, §3.1 surface count).
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

Minimal data plumbing: `member_options/1` rows already carry `"role_name"` from
the membership-edge facet. The change is confined to the private resolver in
`conversation_data.ex` plus the S2 UI surface (plus optional S3 parity if
retained, §6). One exception: the F2
head-fallback guard (§5) needs the **open role slot names** from
`human_role_slots/1` (already in the world view-model) passed alongside member
rows — this lets the guard detect colon-bearing role names that are declared
but unfilled. The resolver does not match against unfilled slots; the extra
data is consumed only by the F2 guard predicate.

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

### 3.5 Feishu mention pipeline — out of scope for this round, documented for follow-on

S5 (Feishu channel mention parse, `mention_parser.ex`) is **OUT OF SCOPE**
for this design round — it resolves `@name` against live `KindRegistry` agent
names, a different data source from the session member rows S1-S4 use. The
S5 table row and non-goals are correct as written.

However, codex R1 correctly identified that Feishu's mention pipeline is NOT
purely pre-session: `inbound_dispatcher.ex` extracts mentions before session
lookup (~:89), then **re-extracts after session is known** for legend-aware
mentions (~:278-283, ~:317-329). The session-aware re-extraction path
already resolves session legends (`mention_parser.ex` ~:108-129) — it has
the session context needed to resolve role names from member rows.

**Follow-on**: after this world-plugin work lands, the same `role_name`
member-edge facet can be plumbed into Feishu's session-aware re-extraction
path. The data source is identical (membership-edge `role_name`), only the
parser function differs (`mention_parser.ex` vs `conversation_data.ex`).
Builder-verify note V8 records the exact code locations.

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
- **R8 — External/public-view path is a different surface**: R6 applies to
  the world composer path (S1, `conversation_data.ex` `resolve_member_name/2`).
  The public/external socialware posting path (`SessionFeedChannel`,
  `session_feed_channel.ex`) does NOT go through S1's parser. Read-only
  adapters return explicit errors before mention resolution (~:42-45);
  participatory posts go through adapter fallback (~:230-249, ~:279-282)
  with a default fallback that forcibly addresses the orchestrator by role
  (~:352-374). An anonymous/public visitor typing `@builder` therefore never
  reaches `resolve_member_name/2` — the existing adapter-fallback routing
  handles it. The role leg added in this spec has zero effect on the
  external path. If role-aware addressing is later desired for public
  visitors, the work belongs to Feishu's session-aware re-extraction path
  (§3.5 follow-on) or a dedicated SessionFeedChannel role resolver — not this
  world-plugin change.

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
  the tiers; if nothing resolves, retry with the pre-colon head.
  **Head-fallback guard (R2/R3 fix)**: the head fallback is ONLY active
  when the session's **combined role-name set** (filled member-edge
  `role_name` values PLUS open human-slot `role_name` values from installed
  definitions, surfaced via `human_role_slots/1` at
  `conversation_data.ex:192-214`) contains ZERO colon-bearing strings. If
  ANY role_name (filled or unfilled) contains `:`, the session is in A-2
  mode — colon-bearing tokens are role-name references — no head fallback;
  unresolved stays plain text (R6). This closes the R3 counterexample:
  `hello:advisor` is an unfilled open slot (no member row), `hello` member
  exists → F2 guard sees the open slot's `:` → head fallback suppressed →
  `@hello:advisor` → plain text (correct — the user meant the role, not
  `hello`). Properties: `@advisor: hi` (punctuation) never captures the
  colon (no word char after it) — today's behavior intact;
  `@hello:advisor` pre-A-2 (no colon-bearing roles anywhere in session)
  falls back to the `hello` head (today's exact behavior, safe because no
  role reference can be misinterpreted); post-A-2 `@hello:advisor` resolves
  the full prefixed edge value if filled, stays plain text if unfilled/
  typoed (R6, no silent misfire). Guard is session-local, requires no
  cross-session state; open slot names are already in the world view-model
  (`human_role_slots/1`). The same longest-first rule and guard apply in
  the autocomplete filter.
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
- **U2 — Insertion inserts the edge value verbatim**: selecting a role-matched
  entry inserts `@<role_name>` where `<role_name>` is the exact string on the
  membership edge — the human-legible, role-slot-canonical form. Pre-A-2 this
  is the short name (e.g. `@advisor`); post-A-2 the edge carries the prefixed
  form and the text inserted is `@hello:advisor`. The resolver matches the
  same edge value (F1), so insertion and resolution stay byte-identical. The
  **autocomplete dropdown display** (F4) may show the short name with a source
  badge for readability, but what lands in the composer text is the full edge
  value — the same string the resolver sees.
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
gain `"role_name"` keys; the F2 guard tests (T7c-T7e) require a second
fixture parameter: the combined set of open-slot role names, mirroring
`human_role_slots/1` passed at `build_message/4` call site). These are the
"fails when the goal is unmet" gates:

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
- **T7 — F2 tokenizer + head-fallback guard**: five sub-cases:
  - T7a: member with edge `role_name: "hello:advisor"` ⇒ `@hello:advisor`
    resolves it (full colon-token match, tier 2).
  - T7b: `@advisor: hi` (trailing punctuation) ⇒ behaves exactly as
    `@advisor` (regex never captures the colon — no word char after it).
    - T7c: pre-A-2 guard — zero colon-bearing role names in the combined
    set (no filled member role_name with `:`, no open slot role_name with
    `:`), no member matches `hello:advisor`, but a member resolves as
    `hello` via segment or display ⇒ `@hello:advisor` falls back to the
    `hello` head (safe — no role reference can be misinterpreted).
  - T7d: post-A-2 filled guard — at least one member has a colon-bearing
    role_name (e.g. `role_name: "hello:builder"`), no member has
    `role_name: "hello:advisor"`, but a member resolves as `hello` via
    segment ⇒ `@hello:advisor` ⇒ `[]` (colon token is a role reference,
    head fallback suppressed, R6).
  - T7e: post-A-2 unfilled guard (R3 fix) — zero members carry a
    colon-bearing `role_name`, but an open human slot has
    `role_name: "hello:advisor"` (from an installed definition, surfaced
    via `human_role_slots/1`), a member resolves as `hello` via segment
    ⇒ `@hello:advisor` ⇒ `[]` (guard sees the open slot's `:` →
    head fallback suppressed → plain text). This closes the
    counterexample where the R2 guard (member-rows-only) would have
    permitted the fallback.
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
  (2026-07-07) but WILL drift; anchor by function name. Codex R1 verified:
  world resolver body is `conversation_data.ex:770-778` (not :768); React
  insertion is `Conversation.tsx:278-283` (`uriSegment` at :1268-1272); LV
  hook filters at `mention_autocomplete.js:71-76`, inserts full URI at
  `:154-178`. Anchor by: `resolve_member_name/2`, `parse_bare_mentions/2`,
  `member_options/1`, `mentionMatches`, `uriSegment`.
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
- **V8 — Feishu follow-on (§3.5)**: after this world-plugin work lands,
  plumb `role_name` into Feishu's session-aware re-extraction path:
  `inbound_dispatcher.ex` ~:278-283 and ~:317-329 (post-session legend-aware
  mention re-extraction) + `mention_parser.ex` ~:108-129 (session legend
  resolution). The membership-edge `role_name` is the same data source;
  resolution logic mirrors the world tier but operates on Feishu's parser
  member representation (not `member_options/1` rows). Defer to a separate
  task — this spec does not design the Feishu change.
- **V9 — A-2 from_role routing validation (cross-spec, codex R2)**: world
  routing's `valid_role_name?/1` in `conversation_routing_form.ex` ~:146
  currently rejects `:` — A-2's `hello:advisor` role names require
  widening the validator. This is an A-2 implementation concern (the
  orchestration spec's builder owns it), but the mention-resolution SPEC
  depends on the widened validator for `{:role, "hello:advisor"}` receivers
  to route correctly. Cross-reference in the A-2 impl plan.
- **V10 — U2 post-A-2 insertion test (codex R2)**: §7 tests parser behavior
  and broad E2E; add an explicit assertion or UI-level check that post-A-2
  the autocomplete inserts the full `@hello:advisor` edge value (not the
  short name). If the React harness supports it, a component test; otherwise
  covered by T8 E2E with a colon-bearing role definition.
- **V11 — Autocomplete F2 guard parity (codex R3)**: F2 states the
  longest-first rule and head-fallback guard also apply in the autocomplete
  filter, but §7 only pins parser T7 and U3 shadow-check. Either add a
  component test for the autocomplete-side F2 guard, or explicitly mark as
  builder-verify (manual probe or covered by T8 E2E). Also: no explicit
  segment-tier ambiguity test (R2 unique-or-nothing within segment tier);
  today's existing parse tests may cover this — builder confirms.
