# Socialware "operator / two-view" — baked-in or composed? (analysis, not impl)

**Question (the lead's framing).** When socialware was designed, did it "simply
reproduce" the autoservice scenario — bake in an **operator** concept: an
external surface (hello / Slack-style adapter) that *curates* the conversation
for the customer, while in the backend a human operator (真人客服) sees the
**full** bot↔customer conversation, can `@mention` the bot to direct it, and the
bot can **escalate to a human takeover** — with the whole backend invisible to
the homepage customer? Or is that flow already **composed** from generic
primitives (recipe/responsibility + routing + visibility), with no first-class
"operator" thing in the core?

**Answer in one line.** The flow is **substantially composed already** — there
is **no `operator` Kind, role atom, view-class, or cap** in the code; "operator"
is *emergent* from (a) a membership/surface-gated **unfiltered read** and (b)
three concrete CapBAC verbs (`:claim` / `:settle` / `:approve`). The **only**
genuinely baked-in residue of the autoservice scenario is **(1) a name leak**
— the visibility atom `:operator_only` (semantically "internal/backstage") and
the `operator_tree` / "Operator SessionView" labels — and **(2) one hardcoded
policy**: `Turn.handle_open` always opens `mode: :auto` and
`initial_visibility(:auto) -> :external_visible`, so the auto-publish-vs-hold
decision is wired into the turn FSM instead of being a session config /
responsibility. So the lead's *strong* hypothesis ("baked-in operator, simply
reproduced autosvc") is **false on the structural claim** and **true only on the
naming + one default-policy claim**.

This is a code-cited research note. It changes no code. All citations are against
`origin/main` (worktree base `67b49303`). Pairs with the prior session notes
[`autoservice-flavor-agnostic-reframe.md`](./autoservice-flavor-agnostic-reframe.md)
(same layer-separation method) and the
[weekend-session-process](./2026-06-26-weekend-session-process.md) program log.

---

## 0. The de-baking program this note continues

This session has been **methodically removing vertical/business concepts from
the generic core** — the operator/two-view question is the next instance of an
already-running program, not a new idea:

- **#1037 — customer → anon-user + external visibility.** The `:customer_*`
  visibility atoms were renamed to `:external_*` and a `no_customer_concept`
  invariant added (`apps/ezagent_core/test/invariants/no_customer_concept_test.exs:51,120`).
  "business concept out of generic core" (weekend-session-process §"Landed").
  **`:operator_only` is the symmetric leak that #1037 did *not* finish.**
- **F7 (remove member / delete session)** was deliberately built as a Session-
  owned, **agent/user-isomorphic** `remove_participant` primitive (owner-gated)
  — explicitly *"NOT an operator-borrows-orchestrator's-cap problem"*
  (weekend-session-process §"Landed"). Same instinct: refuse "operator" as a
  special; express it as a generic owner-gated primitive.
- **#1047 comms-unify** collapsed chat + external onto **one**
  `SessionFeedChannel` over the ExternalMirror `:pull` substrate
  (`comms_substrate_elimination_test.exs` asserts only `SessionFeedChannel`
  remains; both `socialware:chat_feed:*` and `socialware:external:*` route
  through it). The "two views" are already **one transport, two registered pull
  adapters** differing by delivery discipline + visibility filter.

So this note's recommendation is "finish the #1037 rename and lift one policy,"
not "redesign socialware."

---

## 1. Current state — what is baked vs what is composed

### 1a. The "operator" actor is NOT a thing in the code

A repo grep finds **no** `operator` role atom, view-class, Kind, or cap:

- `Ezagent.Role` (`apps/ezagent_core/lib/ezagent/role.ex`) — the flavor-agnostic
  recipe — has no operator role; `RoleRegistry` (now
  `Ezagent.Agent.RoleRegistry`, relocated core→domain_agent by #1048 with a
  `no_role_concept_in_core` gate) seeds `orchestrator` and flavor roles, not
  "operator".
- `Ezagent.Capability` has no `:operator` cap. The authority an "operator"
  exercises is the **concrete behavior verbs** below.
- The only `operator`-named *modules* are `EzagentDomainSocialware.PageView` and
  `EzagentPluginHello.PageView`, each documented as *"Operator SessionView"* —
  but that is a **render-target label**, not a distinct view-class (see 1c).

The word "operator" in the codebase has **two unrelated senses** — keep them
apart or the analysis goes wrong:

| Sense | Meaning | Example | De-bake? |
|---|---|---|---|
| **Trust/deploy** | the human self-hosting ezagent | "ezagent stays operator-only → single-container topology"; `script` is "operator/code-only" (#1048 OQ-1) | **No — legitimate, keep** |
| **Autosvc role** | the 真人客服 backend human who observes + takes over | `:operator_only`, "Operator SessionView", `operator_tree` | **Yes — this is the leak** |

### 1b. The "two views" = two reads differing only by a visibility filter

There is no operator-view *class*. There are two **read queries** over the same
`messages` table, and a render contract that exposes both:

| View | Read primitive | Filter | Backs |
|---|---|---|---|
| **Internal ("operator")** | `MessageStore.recent_in_session/2` (`message_store.ex:141`) | **none** (full conversation) | world console — `Ezagent.World.ConversationData.load_messages/1` (`conversation_data.ex:184`) |
| **External (chat app)** | `MessageStore.chat_visible_recent/2` (`message_store.ex:268`) | `visibility == :external_visible` (live) | `Ezagent.Socialware.ChatFeed.snapshot/2` (`chat_feed.ex:81`, `external_visible?/1`) |
| **External (surface app)** | `MessageStore.committed_external_visible/2` (`message_store.ex:189`) | `external_visible` **AND** settlement-`committed` | `Ezagent.Socialware.ExternalFeed` (`external_feed.ex:51`) |

Note the external read is **two** disciplines, not one: a *chat* app curates by
**per-message visibility only** (live); a *surface/page* app curates by
**visibility + a settlement-committed approved pointer** (`Surface.external_tree/1`
reads `surface.approved`, `surface.ex:122-124`). "Curation" is therefore already
parameterized, not a single baked rule.

The `recent_in_session` read carries no operator gate — `message_store.ex:185`
comments: *"operator/admin reads continue to use the full internal feeds."* The
read asymmetry is purely **which surface you arrived through** (world console vs
`/socialware/chat`) plus **session membership** — #1037 flipped external read-auth
from a token to membership ("tightening not widening"). It is **not** behind a
`:claim`/`:approve` cap (the world conversation read runs `self_join` then
`ConversationData.state_for`, `world_live.ex:90-96`; no cap on the read path).

### 1c. The render contract already abstracts internal-vs-external

`Ezagent.UI.SessionView` (`session_view.ex`) declares **one** view with **two
render TARGETS**:

- `render/1` — the internal LiveView render (the "operator" view).
- `external_render?/0` + `external_render/1` — the optional json-render
  `external_tree` the SPA consumes (the "customer" view).

The moduledoc is explicit: *"The internal and external renders are two TARGETS
behind ONE view declaration (spec §3.4, option A)."* `external_render?` defaults
to `false` (`@optional_callbacks`), so a view is internal-only unless it opts
into an external target. **This is the correct, already-composed shape** — the
two-view-ness is a per-view declaration, not two hardcoded classes. The only leak
is the *label* ("Operator SessionView", `Surface.operator_tree/1` vs
`external_tree/1`).

### 1d. Per-message visibility — a REAL primitive (binary external/internal)

`Ezagent.Message.visibility :: :external_visible | :operator_only`
(`message.ex:73,119`, Ecto.Enum default `:external_visible`). This is **not** an
operator concept that de-bakes away — it is the **load-bearing curation
primitive**, and it is non-derivable for two reasons that a coarser model cannot
reproduce:

1. **It is a mutable revocation lever, not just a static tag.** An operator can
   flip a committed message *back* to `:operator_only`
   (`MessageStore.mark_visibility/2`), and `ExternalFeed.approved_attachment?/2`
   re-checks it at *serve time* — so flipping a message dark **kills an
   already-minted download token** (`external_feed.ex:293`). You cannot get this
   from "which adapter rendered it"; the authority must live per-message.
2. **It survives cross-session forwarding** (the copy+ref model windows on
   `routed_at`) — a forwarded copy carries its own visibility.

**Caveat to name, not hand-wave:** the enum is **binary** — it bakes in a
*single* external audience (external vs internal). The lead's vision has *several*
external adapters (hello, Slack, …). If two external surfaces ever need
*different* curations of the same session, binary visibility is insufficient and
this becomes a real (not cosmetic) generalization to an audience set / per-adapter
projection. Today every external adapter shares one `external_visible` slice, so
binary is sufficient and generalizing now is YAGNI — but it is the one place the
"keep the primitive" verdict has a future expiry date.

### 1e. The human-takeover / escalation — generic verbs, not an operator special

The escalation flow is three CapBAC verbs on the session behaviors, dispatchable
by **any cap-holder** (no operator entity):

| Verb | Behavior | Cap | Effect |
|---|---|---|---|
| `:claim` | `Turn` (`turn.ex:49`, handler `:320`) | `[:claim]` | composed turn → `mode: :copilot, status: :awaiting_human`; `hold_visibility` marks the turn's messages `:operator_only` |
| `:settle` | `Turn` (`turn.ex:57`) | `[:settle]` | `prepare_settlement` → `flip_visibility` marks them `:external_visible` |
| `:approve` | `Surface` (`surface.ex:20`) | `[:approve]` | advance the approved page pointer (surface apps) |

`handle_claim(%{by: by})` records *whoever claimed* as `owner` (`turn.ex:320`) —
"the human" is a parameter, not a baked role. This **is** the autoservice
takeover, but expressed generically: it is "an entity with the `:claim` cap moves
a turn into human review, which holds its output internal until an entity with the
`:settle`/`:approve` cap releases it."

### 1f. The ONE genuinely baked-in policy

`Turn.handle_open` **always** opens `mode: :auto` (`turn.ex:246`) and reads no
session config; `initial_visibility(%{mode: :auto}) -> :external_visible`,
`_ -> :operator_only` (`turn.ex:615-616`). Precisely stated, the current policy is:

> **Auto-publish by default. A turn's output goes external immediately. It is held
> internal ONLY after a human actively `:claim`s that turn. There is no session-
> level knob to make a session review-by-default.**

That is the autoservice *policy* hardcoded into the turn FSM. A "supervised"
socialware app (every bot reply held for operator approval before the customer
sees it — a plausible autosvc tier) is **not expressible** today without code: it
would require `handle_open` to consult the session's responsibility/config to
decide the initial mode. This is the real composition gap.

### Verdict

| Aspect | Baked-in? | Evidence |
|---|---|---|
| "operator" as Kind / role / view-class / cap | **No (composed)** | no operator atom in role.ex / RoleRegistry / capability.ex |
| operator vs external **read** | **No (composed)** | filter-or-not over one table; membership/surface-gated, no cap |
| operator vs external **render** | **No (composed)** | one `SessionView`, two render targets (`session_view.ex`) |
| bot↔customer routing / @mention | **No (composed)** | rule-sets (`define_rule_set_rule`) + `Message.mentions` |
| human-takeover / escalate | **No (composed)** | generic `:claim`/`:settle`/`:approve` verbs+caps; "the human" is a param |
| per-message visibility | **Real primitive — keep** | revocation lever + survives forwarding (`external_feed.ex:293`) |
| the atom **name** `:operator_only` / `operator_tree` | **BAKED (name leak)** | symmetric to the finished `:customer_*`→`:external_*` #1037 rename |
| **auto-publish-vs-hold default** | **BAKED (policy)** | `handle_open` hardcodes `mode: :auto`, no config read (`turn.ex:246`) |

The lead's "simply reproduced autosvc, baked-in operator" read: **structurally
wrong** (no operator thing exists), **right about the residue** (the naming and
the single default-policy are an un-generalized autosvc reproduction).

---

## 2. The generic decomposition

The full flow expressed purely as compositions over existing primitives:

| Autosvc element | Generic composition | Status today |
|---|---|---|
| bot's behavior | **recipe** (`Ezagent.Role` axis A — skills + persona) | composed |
| operator identity | **responsibility** (axis B membership `role_name`, e.g. `"supervisor"`/`"observer"`) + a **cap bundle** `{:claim, :settle, :approve, read-unfiltered}` | *emergent today; could be a named responsibility* |
| external surface curates | external `SessionView` target + the **visibility filter** | composed |
| operator observes the full conversation | the **unfiltered read** (`recent_in_session`) — a READ, needs no routing | composed |
| operator `@mentions` the bot to direct it | a `Message` with `mentions` + a rule-set rule `{from: operator} -> bot` | composed (`define_rule_set_rule`) |
| bot escalates to a human | a rule-set rule `{from: bot, on: <signal>} -> operator-responsibility`, **or** the bot dispatching `:claim` | composable |
| backend invisible to customer | per-message `visibility` filter on the external read | composed |
| **review-by-default (held until approved)** | the session's **responsibility/config** sets the initial turn mode | **NOT composable today — `handle_open` is hardcoded** |

### What de-bakes cleanly vs what is a real primitive

**De-bakes (currently hardcoded specialness that is just composition):**

1. **The name `:operator_only`.** Rename to `:internal` (or `:backstage`). It is
   literally "not external"; the binary is external-vs-internal. Symmetric to the
   already-completed `:customer_visible`→`:external_visible` rename. Pure rename.
2. **The auto-publish-vs-hold default** (`turn.ex` `handle_open` mode +
   `initial_visibility`). Lift into session config / a responsibility attribute,
   so a "supervised" app holds-by-default and an "auto" app publishes-by-default
   *without code*. This is the one substantive de-bake.
3. **The "operator" labels** (`operator_tree`, "Operator SessionView" docstrings)
   → "internal" render target. Cosmetic.

**Does NOT de-bake — keep as a genuine primitive (do not hand-wave away):**

1. **Per-message visibility** (binary external/internal). It is the revocation
   lever (§1d) and survives forwarding. A composition cannot reconstruct it from
   adapter identity. *Rename only.* (Future expiry: multi-external-audience →
   generalize to an audience set; YAGNI today.)
2. **The settlement hold→approve→flip state machine** + `:claim`/`:settle`/
   `:approve` verbs and their caps. This *is* the takeover mechanism; it is
   already generic (no operator entity). Keep as-is.
3. **The `SessionView` two-target render contract.** Already the right
   abstraction. Keep; relabel only.

So "operator" decomposes into **two independent things the current code already
separates** — (a) a **read asymmetry** (membership/surface-gated, no cap) and
(b) a **write/takeover authority** (`:claim`/`:settle`/`:approve` caps). The only
thing missing to call the decomposition "complete" is naming (b)'s cap bundle a
first-class **responsibility** and lifting the §1f default into config.

---

## 3. The change + blast radius

### Change set

**C1 — rename `:operator_only` → `:internal` (or `:backstage`).** Touches the
Ecto.Enum value + every reader/writer + the DB-stored string + the invariant.
Files (≈15–18):

- `apps/ezagent_core/lib/ezagent/message.ex` (enum, typespec, default doc)
- `apps/ezagent_core/lib/ezagent/message_store.ex` (`mark_visibility`,
  `chat_visible_recent`, `committed_external_visible*`)
- `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`
  (`hold_visibility`, `initial_visibility`)
- `apps/ezagent_domain_session/lib/ezagent/socialware/settlement.ex`
  (`flip_visibility`, `hold_visibility`)
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed.ex`
  (`external_visible?/1`), `external_feed.ex` (docs)
- two migrations carry the stored string: `…20260618000400_…visibility…exs`
  and `…repo_pg/…20260622000000_pg_baseline.exs` (default `"external_visible"`,
  unchanged; existing `"operator_only"` rows need a **data migration**)
- `apps/ezagent_core/test/invariants/no_customer_concept_test.exs` (extend to
  forbid `:operator_only` too — make it `no_customer_concept` **and**
  `no_operator_visibility`), plus ~6 test files.

**Risk: M.** It is a persisted enum value → a one-shot data migration
(`UPDATE messages SET visibility='internal' WHERE visibility='operator_only'`)
plus a fail-closed default. Mechanical but wide; the §0 weekend log shows
rename-collisions across parallel branches are the top regression source — so do
it as **one atomic PR**, not parallel.

**C2 — lift the auto/hold default into session config.** `handle_open` consults
the session's responsibility/config (e.g. a `review_policy: :auto | :supervised`
content key, or "has a member with the supervisor responsibility") to set the
initial `mode`; `initial_visibility` keys off that instead of `mode: :auto`
hardcode. Files (≈2–3): `turn.ex` + a config key reader + the session
template/content schema. **Risk: S.** Behavior-preserving when the default is
`:auto` (today's behavior).

**C3 (optional, defer) — name the operator cap bundle a first-class
responsibility** + relabel `operator_tree`/"Operator SessionView" → "internal".
Files: cosmetic across `session_view.ex` doc, `page_view.ex` ×2, `surface.ex`.
**Risk: S, cosmetic.**

### Overall scope: **M**, low-medium risk

No structural surgery — the structure is already generic. The size is driven
entirely by C1's breadth (a persisted-enum rename), not by any redesign.

### Reconciliation with the just-merged work

- **#1059 recipe/responsibility split.** Already separated axis A (recipe) from
  axis B (responsibility = membership `role_name` + `{:role,name}` routing), with
  **no structural forcing** `role_name == recipe-name`
  (`recipe_responsibility_lockin_test.exs`), and **deferred** the `Role`→`Recipe`
  *symbol rename* to a next phase. **C1's `:operator_only`→`:internal` rename
  should ride that same deferred-rename phase** (one rename window, one
  collision-audit). "operator as a responsibility" (C3) is *exactly* an axis-B
  `role_name` — fully consistent.
- **#1048 role-as-data.** Roles are `ConfigObject` data, `RoleRegistry` relocated
  to `domain_agent` behind `no_role_concept_in_core`. An "operator/supervisor"
  responsibility as data (a role_name + requested caps) fits this model directly;
  C2's config key is data, not code-policy — same direction.
- **#1047 comms-unify.** Chat + external already share one `SessionFeedChannel` /
  `:pull` substrate, two adapters differing by discipline + visibility filter. C1
  is just a value rename on the filter both adapters apply — no transport change.
  Reinforces that the "two views" are composed at the substrate.

---

## 4. Pre-prod recommendation: **adjust now, scoped + phased**

Socialware is **not in production**. The decisive factor: **C1 renames a
persisted enum value** — doing it *after* prod means a live data migration over
real message history; doing it *now* is a dev-only `db.reset`. That asymmetry
makes C1 a clear adjust-now. C2 is cheap and removes the only real composition
gap. C3 is cosmetic and should be deferred (YAGNI; it is already composed).

**Phasing:**

- **Phase 1 (do now, ride the #1059 deferred-rename window) — C1.** Rename
  `:operator_only` → `:internal`/`:backstage` as one atomic PR; extend the
  `no_customer_concept` invariant to also forbid `:operator_only`; data-migrate
  existing rows (dev: `db.reset`). Finishes the #1037 symmetry. **Highest value
  pre-prod.**
- **Phase 2 (do now, small) — C2.** Lift the auto/hold default into session
  config/responsibility so "supervised" socialware apps are config, not code.
  Default `:auto` preserves today's behavior; add a `:supervised` path + one test
  (a held-by-default turn stays internal until `:settle`).
- **Phase 3 (defer) — C3.** Name the `{:claim,:settle,:approve,read-unfiltered}`
  bundle a first-class `"supervisor"` responsibility and relabel
  `operator_tree`/"Operator SessionView" → "internal". Do it lazily when a second
  consumer needs the named responsibility (e.g. when the operator approve/claim
  flow gets a UI/CLI — see §5 gaps). Already composed, so no urgency.

**Do NOT** touch the trust/deploy sense of "operator" (§1a) — that is correct.

---

## 5. Interface inventory — orchestration surface coverage

`exists` = first-class; `partial` = reachable but indirect/awkward or scope-
mismatched; `missing` = no surface.

| Capability | Code API | CLI (`mix ezagent …`) | UI (world / SPA) |
|---|---|---|---|
| **Author public_view app** (define the app) | exists — `SessionTemplate.create/3`, `persist_version_as_system/2` | exists — `ezagent.workspace.add_template <ws> <name> --json` | exists — world *Session templates* panel ("Public socialware app" checkbox) |
| **Create a live session** | exists — `Workspace.create_session/3` | exists — `ezagent.workspace.create_session` | exists — world `session.create` (`SessionsTable.tsx`) |
| **Edit / re-point a session** (migrate to new template version) | exists — `Orchestrator.Tools.Migration.migrate_session/2`; `ConfigActions.system_set_working_copy/2` | partial — `ezagent.session.migrate_slice` (slice migration, not template re-point) | partial — `session.orchestrator.restart`; no general "migrate session" action |
| **Define a recipe / role** | exists — `Ezagent.Role`, `Agent.RoleRegistry`, `AgentTemplate` | partial — `ezagent.agent.create` (uses a role); no `role`-define task (no `template://…/role` spawn branch yet) | partial — template panel authors agent/session templates; no dedicated role editor |
| **Define a responsibility** (member `role_name`) | exists — `Tools.add_managed_member/4`, `Membership.do_join` | partial — `ezagent.workspace.add_member` is a **workspace** member, not a session-member `role_name`; session add only via invite | partial — `session.invite` (joins a member; `role_name` not first-class in the form) |
| **Set routing rules** | exists — `Tools.define_rule_set_rule`, `define_legend`, `define_prompt_template` | **missing** — no `mix ezagent` routing task | exists — `session.routing.add` / `session.routing.toggle` (world Conversation) |
| **Set message visibility** (curate / hold / release) | exists — `MessageStore.mark_visibility/2`; auto via `Settlement.flip_visibility`/`hold_visibility` | **missing** | **missing** — no manual operator "hold/approve message" control; only automatic via settlement |
| **Human takeover / approve** (`:claim` / `:settle` / `:approve`) | exists — Turn `:claim`/`:settle`, Surface `:approve` verbs | **missing** | **missing** — world Conversation has no claim/approve/settle action |
| **Assign / remove members & roles** | exists — `add_managed_member`, `remove_member`, `remove_participant` (F7) | partial — `ezagent.session.list_participants` / `remove_participant` exist; **no session add-participant task** | exists — `session.invite` / remove (world) |

**The standout gap:** the **human-takeover / approve / manual-curate** flow — the
very heart of the autoservice "operator" scenario — exists **only as behavior
verbs**. There is **no CLI and no UI** to `:claim` a turn, `:approve`/`:settle`,
or manually flip a message's visibility. The world Conversation surface shows the
unfiltered read but cannot *act* on the takeover loop. So today the "operator"
can *watch* (read) and *talk* (`chat.send` + `@mention`/routing), but cannot
*take over* through any product surface — the takeover is reachable only by raw
dispatch. (Routing-rule authoring also has no CLI, only code + world UI.)

This gap *reinforces* the §4 recommendation: when this loop is surfaced (UI/CLI),
that is the natural moment to name the `"supervisor"` responsibility (Phase 3),
since the surface needs a stable handle to gate on.

---

## 6. Codex adversarial-review verdict

> *(filled in below after the review run; see the commit appending it.)*

---

## 7. Open questions for the lead

1. **Rename target:** `:operator_only` → `:internal` or `:backstage`? "internal"
   pairs cleanly with "external"; "backstage" reads better for the autosvc story.
   (Recommend `:internal` for the external/internal symmetry.)
2. **Bundle with #1059?** Should C1 ride the deferred `Role`→`Recipe` symbol-
   rename window (one collision-audit, one rename PR), or land standalone first?
3. **Multi-external-audience horizon (§1d caveat):** is more than one external
   surface curating the *same* session a near-term need? If yes, binary
   visibility needs to become an audience set *before* prod, which upgrades C1
   from "rename" to "generalize" (M→L). If no, keep binary (YAGNI).
4. **Supervised-by-default (C2):** express the initial-mode policy as a session
   **content key** (`review_policy`) or **derive it** from the presence of a
   `"supervisor"` responsibility member? (The latter is more "composed" but
   couples open-time to membership reads.)
5. **Surface the takeover loop (§5 gap) now or later?** Naming the `"supervisor"`
   responsibility (Phase 3) is best done *with* the UI/CLI that needs it — is
   that in scope pre-prod, or is raw-dispatch acceptable until then?
