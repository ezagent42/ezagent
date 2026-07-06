# Orchestration as a Socialware — Reference Design

**Status:** rev2 — the reference design for Allen's socialware mental model
(2026-07-06 discussion). This is the DESIGN BASELINE for later planning, not an
implementation plan; milestones at the end are sequencing sketches only.
rev1 codex architecture review: UNSOUND (1 BLOCKER: `requires` vs (session,ref)
install identity; 2 MAJOR: role namespace contradiction, from_role staleness;
1 MINOR: hop-state home) — all four resolved in rev2, marked `[A‑n]`.
**Lineage:** role-slot P1–P3 (#1180/#1185/#1194) · hello substrate migration B'
(#1208 + its spec) · manifest track (#1164) + manifest-YAML spec
(`2026-07-06-config-governance-unify-and-manifest-yaml.md`) · jjkysy #1201 findings
(D⑦, G⑨, G⑩ are subsumed here) · Agent Console lifecycle (#1132).

---

## 1. The mental model (normative)

A socialware composes **declared entities + declared routing + plugin-provided
tools**. Orchestration is not an app-private engine; it is a capability the
platform offers as a socialware.

1. **`orchestrator` is itself a socialware** — it provides the operating surface
   and agent-tools for: adding agents/members, editing the routing table, and
   assigning roles. (Layering guard in §2: it *packages* framework primitives; it
   does not own them.)
2. A socialware that needs multi-agent coordination **`requires` the orchestrator
   socialware** (socialware→socialware dependency, §6).
3. It **declares its entities**: roles with recipe/flavor for agent slots, and
   human slots for user-filled roles (`fill: :human`, shipped in P3).
4. It **declares routing rules** — deterministic table entries; decisions agents
   make are *encoded in the messages they emit*, not interpreted by a routing-time
   engine.
5. Tools that roles need are **code, shipped by plugins** the socialware `uses`,
   loaded via the recipe/compose path.

### The hello reference example (normative shape, not the current implementation)

```yaml
name: hello
requires: [orchestrator]          # §6 — socialware dependency (NEW)
uses: [ezagent_plugin_hello]      # plugins: code contributions
roles:
  - {role_name: builder,   fill: agent, recipe: hello-builder,   flavor: np}
  - {role_name: responser, fill: agent, recipe: hello-responser, flavor: np}
  - {role_name: viewer,    fill: human}
routing_rules:
  # viewer's messages go to the responser (single front desk):
  - match: {type: from_role, arg: viewer}
    receivers: [role: responser]
  # the responser ENCODES the build decision in its own message;
  # the table only transports it:
  - match: {type: and, items: [{type: from_role, arg: responser},
                               {type: text_matches, arg: "^\\[need-build\\]"}]}
    receivers: [role: builder]
```

- `builder`'s tools (`hello-component-loader`, `json-render-parser`) come from
  `ezagent_plugin_hello` via its recipe. The builder's *product* is the page
  (artifact plane, Surface/Turn) — not chat messages. Chat plane and artifact
  plane stay separate.
- `responser` is the **single egress** toward the viewer. Single-outlet design is
  what makes the external surface controllable (§5).
- **There is NO runtime intent-classification agent.** The responser (already an
  LLM) decides and self-tags; routing stays deterministic. This retires the
  app-private orchestration engine pattern (`HelloOrchestrator`'s engine layer)
  without needing the stock cc-orchestrator to gain app tools.

## 2. Layering guard (the bootstrap rule)

**Primitives stay framework; the orchestrator socialware only packages them.**

- Framework/domain owns, forever: session membership (`session.join`/leave),
  role materialization (`materialize_template_team`) and `session.assign_role`,
  the routing table substrate (RuleStore/RoutingRegistry/Resolver/Matcher), the
  socialware install machinery (Installation/DefinitionRegistry/governance).
- The `orchestrator` socialware packages, on top of those primitives:
  the **operator views** (the Agent Console surfaces: team wizard, role
  assignment, routing editor) and the **agent-facing tools** (today's ~12
  orchestrator MCP team/version tools, moved down to plugin contributions).
- Why the guard is load-bearing: if installing ANY socialware required the
  orchestrator socialware's machinery, installing the orchestrator socialware
  itself would be circular. Install/routing/role must work bare (framework), and
  the orchestrator socialware is "just another app" that makes them ergonomic.

Consequence for the stock cc-orchestrator: its special spawn path
(`Session.ensure_orchestrator` from the hardcoded
`template://system/agent/cc-orchestrator`) retires once its two halves are
re-homed — tools → plugin contributions consumed by an orchestrator-role recipe;
console → the orchestrator socialware's views. The dead
`orchestrator_template_uri` field becomes moot rather than fixed: template choice
collapses into the role's recipe/flavor like every other member. Transitional
sessions may keep `ensure_orchestrator` until the default SessionTemplate
installs the orchestrator socialware (M2).

## 3. Routing protocol

### 3.1 Matcher vocabulary — grep already exists (correction of record)

The shipped matcher AST (`Ezagent.Routing.Matcher`) already covers the model:
`{:mention, t} | {:from, uri} | {:text_contains, s} | {:text_matches, regex} |
{:in_session, uri} | {:always}` plus `and/or/not` combinators, JSON-serialized in
RuleStore. `"[need-build]" prefix → builder` is expressible TODAY:
`and([from(responser), text_matches("^\\[need-build\\]")])`. **No new matcher is
required for v1 of the model.**

Two additions earn their place later, as hardening — not as gaps:

- **`{:from_role, role_name}` — a RUNTIME matcher, symmetric with the receiver
  side** `[A‑3]`. Today `{:from, uri}` binds to a concrete member; role slots mean
  membership is an edge that can be re-assigned (`session.assign_role` mutates the
  member facet only), so any install-time rewrite of `from_role` → concrete `from`
  goes STALE the moment a role is re-assigned — rev1's rewrite interim is
  withdrawn. Receivers already resolve role-on-edge at delivery time; the sender
  side must do the same: `from_role` is evaluated at match time against the
  session's members (the resolver already receives member inputs alongside the
  message). One resolution model on both sides of the rule; rules survive
  re-assignment and fork by construction.
- **Structured message tag** — `[need-build]` free-text is LLM-discipline-fragile
  (variants, dropped brackets). A `message.tag` field set by an emit-tool, with a
  `{:tag, name}` matcher, is more reliable AND makes conflict analysis exact
  (§3.2: finite tag vocabulary ⇒ precise edge predicates). Free-text matchers
  remain supported; tags are the recommended authoring surface once available.

### 3.2 Conflict analysis — the role-DAG check (Allen Q2: yes, viable)

Rules form a directed graph: **nodes = declared roles** (plus `viewer`-class
human roles and External), **edges = rules** (source = the `from`/`from_role`
constraint, target = each receiver; text/tag predicate annotates the edge).
Install-time static analysis (a new Conformance check) over that graph:

| analysis | verdict policy |
|---|---|
| **Cycle detection** | cycle whose edges have NO text/tag predicate (pure from/mention/always) → **reject install** (guaranteed loop); cycle with predicated edges → **warn** (predicate may break it at runtime — conservative) |
| **Double-delivery** | two edges from the same source whose predicates can both hit (e.g. overlapping substrings, `always` + anything) → **warn** with the rule pair |
| **Dead role** | declared role with no in-edge and no out-edge → **warn** (probably a Definition bug) |
| **Unknown receiver** | edge target not a declared role/member → **reject** (already a Conformance check today — `routing_receivers_resolve`) |

Precision note: with free regex predicates the analysis is conservative
(overlap ≈ undecidable in general → warn generously); with tag predicates it is
exact. `requires` (§6) runs the same analysis over the MERGED rule set of all
composed socialwares — this is where cross-socialware conflicts get caught.

**Runtime backstop (defense in depth): hop budget.** `[A‑4]` Hop state lives ON
THE MESSAGE ENVELOPE — a `hops` metadata field alongside the existing
`visibility` field (`Ezagent.Message` already carries per-message metadata that
persists through delivery; hop count is the same class of data). Origin messages
start at a small budget (e.g. 8); each table-forwarded RE-EMISSION decrements it;
at 0 the delivery is dropped AND traced (§3.3). The table enforces the check; the
message carries the state — "table property" means the enforcement point, not the
storage. Static analysis can be fooled by predicates; the budget cannot. This
generalizes the loop-guard #1208 hand-built inside hello into a guarantee every
socialware inherits.

### 3.3 Routing trace (debuggability as a first-class feature)

Every table decision records: message id, rule id (or `no_match`), receivers,
hop count, drop reason (`hop_exhausted` / `no_match` / guard). Surface it in the
operator console (the message's "journey"). Rationale: declarative routing is
*easier* to debug than in-process dispatch code — but only with a trace; without
one, silent drops (the D⑦ class) are strictly worse to diagnose. The trace is
also the observability primitive the conflict warnings point at ("rule 12 and
rule 17 both fired for message X" is visible, not inferred).

## 4. Where agent judgment lives

The table never calls a model. Judgment lives at the endpoints:

- **responser** (app-declared role): interprets the viewer, decides
  reply-vs-build, encodes the decision (tag/prefix) in its OWN emission.
- **builder** (app-declared role): consumes `[need-build]`, drives the artifact
  plane via plugin tools.
- The **orchestrator socialware's** agent tools mutate the TABLE and the TEAM
  (add member, add rule, assign role) — administration, not per-message brokering.

An app that genuinely wants an LLM broker can still declare one as a role and
route through it — that's a choice expressed in data, not a framework mandate.

## 5. Visibility model (Allen Q3 framing — adopted)

**In-session content is full-visibility for members. The controlled boundary is
the External projection.**

- Session members (incl. the operator console) see everything, including
  `[need-build]` internal relays. No per-rule routing visibility exists — the
  routing layer is visibility-agnostic.
- **The primitive already exists**: `Ezagent.Message` carries
  `:external_visible | :internal` visibility today, and the external projections
  (chat_feed / public_view) already project over visibility+auth. The BASE case —
  keep internal relays out of the anonymous feed — is therefore expressible NOW:
  the responser/builder relay emissions ride `:internal`. What is future work is
  the richer filter vocabulary (by sender-ROLE and/or tag) for apps that need
  finer projection shaping than the boolean; that lands in the projection layer,
  never in the router.
- The External surfaces (public_view / chat_feed / world public feed — where
  hello's real anonymous visitors live) are **projections**, and projections
  filter. The hello external feed projects only the viewer↔responser exchange;
  internal relay traffic is excluded by message visibility (base) or the
  projection's role/tag filter (extension), not by the router.
- This lands on the existing architecture (SessionView/projection IS the
  surface); no new mechanism class. The D⑦ finding (public-face @mention
  silently dropped) is re-read under this model: External ingress/egress are
  projection-boundary concerns, to be specified per external surface — the
  in-session table stays uniform.

## 6. `requires:` — socialware→socialware dependency (the G⑨ slot)

New Definition field `requires: [socialware-name]` (distinct from `uses:`
[plugins/code]). Semantics:

- **Install composition:** installing S into a session ensures each R ∈
  `requires(S)` is installed there first (recursively; reject cycles at
  Conformance). The required socialware's views/tools become available in the
  session; its roles materialize per ITS definition.
- **Version model `[A‑1]` — ONE installed revision per (session, ref), by
  design.** The install identity IS `(session, ref)` (idempotent record,
  session-global repoint) — `requires` does not fight that with per-dependent
  locks; it adopts it as the invariant: **a session holds exactly one revision of
  any socialware, shared by all dependents** (flat, npm-hoist-style). Conflict
  policy, fail-closed: if S2's `requires` pins R at a hash incompatible with the
  R revision already installed (by S1 or directly), S2's install is REJECTED with
  a version-conflict error naming both dependents — the operator resolves by
  repointing/upgrading, never by silent coexistence. `repoint` of R stays
  session-global and now REVALIDATES every installed dependent's conformance
  against the new revision before flipping — a repoint that would break a
  dependent fails closed with the dependent named. No new lock identity is
  introduced; the invariant + two checks are the whole mechanism.
- **Namespace `[A‑2]` — roles are a SHARED session-global namespace, not
  per-definition.** (rev1 claimed `(definition, role_name)` identity; that
  contradicts shipped semantics — role slots are plain `role_name` and session
  membership enforces per-session role-name uniqueness. rev2 adopts reality.)
  Composition therefore means: the merged role set of all composed definitions
  must be collision-free — **duplicate `role_name` across composed definitions is
  an install-time Conformance rejection** (the author renames). The flip side is
  a feature: because the namespace is shared, S's rules may route TO a role R
  declares (cross-socialware addressing by role name) with zero extra mechanism —
  which is exactly what `requires orchestrator` is for.
- Rule sets merge for the session table; the merged set goes through the §3.2
  conflict analysis at install.
- **Failure mode:** missing/unpublishable required socialware ⇒ install fails
  closed (same posture as `uses` plugin checks today).

Out of scope here (registered open question): cross-socialware CONTENT protocol
(when S's role wants to address R's role directly — the G⑩ collaboration-protocol
layering). The `requires` mechanism must not accidentally answer it; first
version composes installation + table, nothing more.

## 7. What exists vs. what's new (delta table)

| model element | status |
|---|---|
| roles/recipe/flavor declaration, incl. `fill: :human` | ✅ shipped (P1–P3) |
| routing_rules in Definition → session table | ✅ shipped (#1208 path) |
| grep-class matchers + combinators | ✅ shipped (`text_contains`/`text_matches`/`and/or/not`) |
| plugin tools via `uses` + recipe/compose | ✅ shipped (manifest track) |
| governance publish/install/freeze-pin | ✅ shipped |
| operator console surfaces (team/role/routing) | ✅ exists as Agent Console — needs re-homing, not rebuilding |
| `from_role` RUNTIME matcher (sender-side role resolution) | 🆕 |
| structured message tag + `{:tag, _}` matcher | 🆕 hardening (optional v1.5) |
| role-DAG conflict analysis in Conformance | 🆕 |
| hop budget + routing trace | 🆕 |
| External projection filters (per app surface) | 🆕 per-surface work (hello first) |
| `requires:` socialware deps | 🆕 (G⑨) |
| orchestrator socialware (tools→contributions, views, default install) | 🆕 (M2) |
| `ensure_orchestrator` retirement | 🆕 (end of M2) |

## 8. Hazards and their answers (settled in this design)

1. **Routing conflicts** → §3.2 static role-DAG analysis at install (reject hard
   cycles, warn predicated ones) + §3.2 hop budget at runtime + §3.3 trace.
2. **Free-text protocol fragility** → grep matchers are v1 (they exist, they
   work); structured tag is the recommended hardening, and upgrades analysis
   precision as a side effect. Not a blocker for the model.
3. **Visibility** → not a routing concern; External projections filter (§5).
4. **Debuggability** → routing trace first-class (§3.3); the console shows
   message journeys; conflict warnings reference rule ids visible in the trace.
5. **Bootstrap circularity** → §2 layering guard: primitives framework-owned;
   orchestrator socialware is packaging only.
6. **Composition explosions** (`requires` diamond/upgrade skew) → freeze-pin +
   explicit repoint; merged-table conflict analysis at install; cycles rejected.

## 9. Milestone sketch (for the LATER planning pass — not commitments)

- **M1 — protocol & safety on the existing table:** runtime `from_role` matcher ·
  role-DAG Conformance check · hop budget (Message-envelope hop state) · routing
  trace · hello's internal relays ride `:internal` visibility + external-projection
  filter. *Outcome: Allen's hello shape is authorable and safe with today's
  matchers.*
- **M2 — orchestrator socialware:** tools → plugin contributions · orchestrator
  Definition (views = console) · default SessionTemplate installs it ·
  `ensure_orchestrator` retirement. (#169 reframed; subsumes the
  `orchestrator_template_uri` decision item from #1208 — the field retires with
  the path.)
- **M3 — `requires`:** field + install composition + merged conflict analysis +
  pin/repoint semantics. (G⑨ mechanism half; G⑩ content protocol stays open.)
- **Dogfood throughout:** hello re-expressed per §1 at each milestone boundary;
  its manifest.yaml (the #158+Q2 spec's import lane) is the distribution vehicle.

## 10. Explicit non-goals

- Per-message LLM routing in the table (never).
- Solving the G⑩ cross-socialware content/addressing protocol here.
- Renaming/moving routing substrate modules (works as-is).
- Retiring free-text matchers (tags are additive).
