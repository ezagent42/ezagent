# Socialware Answer Routing + Completion Authz — the OUTBOUND half of the socialware protocol

**Status:** SPEC (design only — no implementation in this PR)
**Coordinator:** cc · **Review gate:** codex (adversarial, pre-impl — this touches the Cap axis)
**Companion:** `docs/superpowers/handoffs/2026-07-28-socialware-receiver-foundation-handoff.md`
(the INBOUND half). Together they form one socialware interaction protocol.
**Evidence baseline:** read-only review of `origin/main` @ `9da32994f`. All file:line
references were re-resolved at this commit; re-anchor before implementing.

---

## 1. Problem

The receiver-foundation handoff defines how a structured interaction ENTERS a
session (page → typed submit → `session.page_action` → routing pipeline). It is
silent on the return leg: **how an answering agent's reply is ROUTED back into the
session, and how that agent's LLM completion is AUTHORIZED.** That silence is not
hypothetical — the official site (`session://ezagent/hello/ezagent-official`)
shipped an answer chain that never replied. Two independent defects, both proven
on live prod:

### 1.1 Defect A — delivery is mention-gated by default, and nothing requires an override

The `system_default` routing rule is `always → ["$session_users", "$mentions"]`
(`EzagentDomainInstanceMessage.DefaultRules`, per
`docs/superpowers/specs/2026-05-22-mention-gated-routing.md`). `$session_users`
expands to **User-Kind members only** — agents are structurally excluded
(`Ezagent.Routing.Resolver.expand_receiver/7`, `user_uri?/1` filter,
`apps/ezagent_core/lib/ezagent/routing/resolver.ex:357-372, 588-590`). An agent
receives chat **only when @-mentioned** (`$mentions`). An anonymous visitor
typing a plain question mentions nobody → the answering agent hears nothing →
no reply, ever.

A team socialware is *expected* to override this by declaring per-session
routing rules in its manifest (`routing_rules:` → `{:role, name}` receivers,
installed at create by
`EzagentDomainInstanceMessage.SessionCreator.TemplateTeam.install_template_rule_sets/4`,
`.../session_creator/template_team.ex:319-353`). hello and autoservice both do
(`apps/ezagent_web/priv/socialware_seed/{hello,autoservice}/manifest.yaml`:
`always → front-desk` / `always → autoservice`, `rule_set: default, position: 0`).
But this is a **convention with no protocol rule behind it**:

1. **Nothing requires it.** A manifest with answering agent roles and no
   `routing_rules` passes conformance (`Ezagent.Socialware.Conformance`) and
   publishes cleanly. The failure mode is silent: the session works for
   mentions, and a public page whose visitors never mention anyone is dead.
2. **No config-reconcile path exists for existing sessions.** Rules are
   installed at session create (and on `repair_orchestrator/1`, which routes
   through `materialize_template_team/4` → `materialize_template_config/3`).
   But repair is **freeze-pinned**: `Installation.pin_installs_from_session/2`
   (`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:146-178`)
   re-pins the template content to the revision the session was created with —
   by design (a later publish must not mutate existing sessions). So a
   definition upgrade that ADDS a routing rule can never reach an existing
   session; and `install_one_rule/5`'s identity check
   (`RuleStore.find_by_identity/4` on `(created_by=session_uri, rule_set,
   position)`) is existence-only — it never compares receivers/matcher, so
   drifted or hand-mangled rules are not healed either. Agent-repair exists;
   config-reconcile does not.

The official site is the intersection: created before/outside the manifest's
rule declaration, pinned there forever, no reconcile lane to fix it.

### 1.2 Defect B — completion authz has no convention

hello's answer chain drives the LLM through
`EzagentPluginHello.Generator.call_llm/3`
(`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex:523-543`),
which calls `Ezagent.Entity.Agent.request_completion/5` with
`caller = Ezagent.Entity.User.admin_uri()`. Authorization
(`authorize_complete/4`,
`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:539-565`) passes iff:

- `caller == owner` (the agent's `AgentLineage.spawned_by`), OR
- caller **HOLDS a STORED** `cap(:agent, Ezagent.ActionSet.Agent.Complete,
  :complete, agent_uri, ws)` — read via `Kind.holds_cap?/3` from the caller's
  identity slice. Presented `ctx.caps` are NOT consulted; `complete/3` is a
  plain function call, not an `Invocation` dispatch, so there is no presented-cap
  channel at all. The TurnDriver "mint-and-present" pattern
  (`.../turn_driver.ex:89-131`) cannot be reused as-is.

On the official site, the answer agent (`llm` role) is owned by the human
founder (`OfficialSiteSeed` resolves a real non-admin user as owner; the
role-slot materialization spawns agents under `granted_by = session owner` —
`DefinitionAgents` moduledoc, `.../session_creator/definition_agents.ex:38,70`).
The recipe grants no `Agent.Complete` cap to anyone. So the driver's
`admin ≠ owner` and holds no stored cap → `:unauthorized`. **No convention says
who owns answering agents or how the driver is supposed to be authorized** — the
chain worked only in dev setups where the session owner happened to be admin.

### 1.3 One protocol, half specified

The inbound half is fail-closed and declared (exact `session.page_action` cap,
catalog-bound envelope, server-derived caller). The outbound half is ambient and
undeclared (default routing that excludes agents; a driver identity chosen by
whatever the plugin hardcoded). This spec closes the asymmetry.

---

## 2. Conventions (normative)

### C1 — An answering socialware DECLARES its answerers; silence is invalid

A socialware whose agents answer the session MUST declare this in its manifest:

```yaml
roles:
  - role_name: front-desk
    fill: agent
    recipe: hello.front-desk
    flavor: hello
    answers: true        # NEW — this role replies to session traffic
```

- `answers: true` is a role-level marker. It is a **protocol declaration**, not
  a routing rule — it states intent, and conformance checks that the intent is
  backed by mechanism (C2, C3).
- **Fail-closed rule for public surfaces:** a manifest with
  `visibility_policy.web_anon_access: true` AND at least one `fill: agent` role
  MUST either mark ≥1 role `answers: true` or declare the explicit opt-out
  `answering: none` at top level. A public, agent-inhabited page that is silent
  about answering is a conformance ERROR — silence caused the live defect, so
  the protocol makes silence unrepresentable. Non-public manifests (e.g. kanban,
  `web_anon_access: false`) may omit the marker entirely.

### C2 — Every answerer has a declared delivery rule; mention-gating is only the ad-hoc default

For every `answers: true` role, the manifest MUST declare at least one
`routing_rules` entry whose receiver is that role (`{:role, name}` — role
receivers only, per the role-slot model: no instance URIs in declarations) and
whose matcher covers plain, unmentioned visitor traffic. Recommended canonical
shape (exactly what hello/autoservice already declare):

```yaml
routing_rules:
  - matcher: { type: always }
    receivers: [front-desk]
    rule_set: default
    position: 0
```

- The `MentionRouting` `system_default` (`always → [$session_users,
  $mentions]`) remains the default for **ad-hoc member sessions only**. An
  answering socialware MUST NOT rely on it — it is normatively documented as
  "notification + mention-gating", never "answer delivery".
- Conditional answerers stay expressible: `answers: true` requires *a* rule
  targeting the role; the matcher may be narrower than `always` (e.g. a
  `page_action`-typed matcher once F1 `event_type` lands — see §5 symmetry).
  Conformance validates coverage structurally (rule exists, receiver is the
  role, rule_set/position well-formed); it does not attempt matcher semantics.

### C3 — Completion authority is a declared `operates` edge, exercised by the role member

The completion chain (`answering role → LLM-provider role`) is a **declared
composition edge**, using the mechanism autoservice already uses for kb
(`apps/ezagent_web/priv/socialware_seed/autoservice/manifest.yaml:14-18`):

```yaml
roles:
  - role_name: front-desk
    answers: true
    operates:
      - role: llm
        behavior: Ezagent.ActionSet.Agent.Complete
        action: complete
  - role_name: llm
    fill: agent
    recipe: hello.llm
    flavor: curl
```

- Materialization: `Ezagent.Socialware.CompositionCaps.reconcile_session/5`
  (`apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex`)
  already mints declared `operates` edges as narrow capabilities — ISSUE
  completed before the binding projection persists, verified artifacts absorbed
  by the **source role member** (the cbac-done-right issue+store shape). The
  absorbed artifact lands in the holder's identity slice, which is exactly
  where `authorize_complete`'s `Kind.holds_cap?/3` reads. The needed cap shape
  (`cap(:agent, Ezagent.ActionSet.Agent.Complete, :complete, <llm agent uri>,
  <ws>)`) is representable as an operate edge today. **No new authz mechanism
  is introduced** — this is the existing lane pointed at the completion action.
- Driver rule: **the completion driver calls as the answering role member, not
  as admin.** `Generator.call_llm/3` (and any future driver) resolves its own
  session role URI (it already does, for narration — `builder_uri/1`) and
  passes THAT as `caller_uri` to `Agent.request_completion/5`. The ambient
  `User.admin_uri()` caller is removed. `authorize_complete` then passes via
  the stored composition cap regardless of who owns which agent.
- `caller == owner` remains a valid fast path (an owner driving its own agent),
  but is no longer load-bearing for any answering socialware.

### C4 — Ownership of answering agents

Two lanes, by who instantiates:

- **User-installed socialwares (default): `owner_policy: {type: installer}`
  stays** — the role-slot model decision (2026-07-05) holds: the installer's
  agents spend the installer's credentials; ownership follows credential
  liability. C3 makes the answer chain work here with no ownership change: the
  installer owns both role agents, the install is owner-authorized, the operate
  edge mints cleanly (#161 owner-authority chain intact — the grant root is the
  owner of the target agent, and no unowned caps are created: every minted
  artifact has a grantee that absorbs it).
- **Platform-seeded socialwares (the official site class): RECOMMENDED
  `owner_policy: {type: system}` (NEW policy type)** — the platform principal,
  resolved at install time by the deployment (never an authored instance URI, so
  the "definitions cannot name participants" rule is preserved —
  `Definition.owner_policy/1` continues to reject any declared `owner_uri`,
  `.../socialware/definition.ex:552-563`). Justification against #161:
  ownership follows credential liability, and a platform-seeded answering
  agent's credential IS a platform deploy-env key (hello's `llm` role:
  `flavor: curl`, `provider: deepseek` — a deploy-env provider key, not the
  founder's login). Founder-owned platform agents are the mismatch that
  produced Defect B: the boot-seed lane runs as system, repair/install lanes
  run as system, drivers historically ran as system — while authority hung off
  a human who is in none of those loops. System ownership also makes the
  boot-seed's composition-cap mint owner-authorized without a human actor
  (`CompositionCaps.assert_install_authorized/3` requires an owner-authorized
  install when edges are declared). The **session** owner stays the founder
  (#1576 contract untouched) — this policy governs the *agent* Kinds' lineage
  only.
- **Alternative (noted, not recommended):** keep founder ownership everywhere
  and rely purely on C3's stored grant. Workable — C3 alone fixes Defect B —
  but it leaves platform lanes (boot seed, repair-as-system) needing the
  founder's authority for owner-gated operations on platform infrastructure,
  which is the same human-in-the-platform-loop smell, deferred rather than
  removed.
- **Rejected alternative: presented-cap seam.** Extending `authorize_complete`
  to accept presented `ctx.caps` would require turning `Agent.complete/3` into
  a dispatched Invocation and would import the TurnDriver's
  `Cap.issue_for_action({:admin, admin}, …)` ambient-admin mint into the
  answer path — widening the very pattern the strict-verify re-architecture is
  retiring. Stored grants via the existing composition lane are strictly
  smaller.

### C5 — Config-reconcile is a first-class lane, symmetric to agent-repair

The platform gains a **config-only reconcile** operation for existing sessions
(the missing symmetric half of `repair_orchestrator/1` /
`install_session_socialware/1`):

- Spawns nothing; touches routing rules, legends, prompt templates, and
  composition-cap edges only.
- Two modes, preserving the freeze-pin invariant:
  - **repair mode (same-revision):** re-materialize config from the session's
    PINNED revision (`pin_installs_from_session/2` unchanged). Heals deleted /
    drifted rules against what the session was created with. Safe to run
    idempotently (boot, repair, operator).
  - **upgrade mode (re-pin):** explicitly re-freeze the session's install
    records to the CURRENT published definition revision, then reconcile config
    against it. This is the ONLY path by which a definition upgrade reaches an
    existing session's config — an explicit operator/owner action, never a
    side effect of publish (freeze-pin stays inviolate).

---

## 3. Mechanism

### 3.1 Manifest / Definition schema (additive)

- `Definition.role`: optional `answers: boolean` (default `false`).
- `Definition`: optional top-level `answering: :none` opt-out marker.
- `Definition.owner_policy`: new `%{type: :system}` variant;
  `Definition.owner_uri/2` resolves it to the deployment's platform principal
  (today `Ezagent.Entity.User.admin_uri/0`; the resolution point is one
  function so a dedicated platform principal can replace it later).
- `operates` edges already support the needed shape; `Agent.Complete`/
  `:complete` is validated as a permitted operate behavior/action pair
  (conformance whitelist addition, mirroring the kb `query` entry).
- Version-hash extends over the new fields (write-once/hash-checked template
  machinery accommodates extra fields, per team-routing-unification §3.7).

### 3.2 Session create (no flow change)

Create-time materialization already installs declared rules
(`install_template_rule_sets/4`) and reconciles composition edges
(`SessionInstaller.install/4` → `CompositionCaps.reconcile_session/5`). C1-C3
add declarations, not a new create path. The one behavioral addition: when the
manifest declares `answers` roles, the create-time rule install failing is
already loud (rules install inside `finalize_fresh_session`'s with-chain and
roll back the create) — that stays; the composition-edge mint failing degrades
loudly per the existing CompositionCaps degrade model and becomes visible to
the gate (§4).

### 3.3 Reconcile (`SessionCreator.reconcile_session_config/2` — NEW)

```
reconcile_session_config(session_uri, mode) :: {:ok, summary} | {:error, term}
  mode :: :repair | :upgrade
```

1. Resolve template content: `:repair` → freeze-pinned
   (`pin_installs_from_session/2`); `:upgrade` → `freeze_template_installs/2`
   against current published revisions, then **advance the session's install
   records** to the new pins (append-only ConfigStore pointer advance, same
   lane `retract_session_installs/2` uses).
2. Diff declared `routing_rules` against installed rows by the existing
   identity `(created_by = session_uri, rule_set, position)`:
   - missing → `RuleStore.add/5` (source `system_default`, workspace-scoped —
     identical to create).
   - present but drifted (receivers or matcher differ from declaration) →
     `RuleStore.update_receivers/3` (matcher drift: delete+re-add under the
     same identity; `update_receivers` today covers receivers only). An
     admin-disabled rule keeps `enabled: false` (disabled-wins, per the
     DefaultRules migration precedent).
   - installed-by-this-session but no longer declared → delete
     (`force: true`; they are this session's own materialized rows).
3. Reconcile legends + prompt templates by full replace of the
   template-declared subset (session-local additions untouched).
4. Re-run `CompositionCaps.reconcile_session/5` (already reconcile-shaped:
   replaces the session's binding set, revokes unsupported).
5. `RuleStore.load_into_registry/1` once, at the end.
6. Authorization: `:repair` is callable by the same surfaces that may call
   `repair_orchestrator/1` (owner/operator; workspace-owner gate). `:upgrade`
   requires the session owner (it changes what the session runs) or a platform
   operator for `owner_policy: system` socialwares.

`repair_orchestrator/1` becomes a composition of this + the existing agent
lane, eliminating the current partial overlap where repair reinstalls missing
rules but cannot heal drift.

### 3.4 Driver identity (hello, and the generic rule)

- `Generator.call_llm/3`: caller = the session's answering role member URI
  (resolve via `EzagentPluginHello.Members.role_uri(session_uri, "front-desk")`;
  fail loud if unresolvable — no admin fallback). Same change in any other
  completion driver (`concierge` path included).
- Generic protocol rule for future socialwares: **a completion driver's caller
  is the session role member on whose behalf it acts.** Framework code never
  substitutes a platform principal for a role actor.

---

## 4. Enforcement

### 4.1 Conformance (static, import lane — fail-closed at publish)

`Ezagent.Socialware.Conformance.check_candidate` additions:

- `web_anon_access: true` + ≥1 agent role + no `answers`/`answering: none`
  declaration → ERROR.
- `answers: true` role with no `routing_rules` entry targeting it → ERROR.
- `answers: true` role whose completion chain requires a provider role (recipe
  declares an LLM dependency) with no `operates` edge for
  `Agent.Complete/:complete` → ERROR. (v1 approximation: hello-class manifests
  declare the edge explicitly; the recipe-dependency inference is an open
  question, §7.)

### 4.2 Fresh-session invariant test (runtime — the red-today gate)

New umbrella test (per answering seed manifest — hello, autoservice):

1. Create a session from the manifest (normal `Workspace.create_session` lane +
   `install_session_socialware`).
2. **Routing invariant:** build a plain, unmentioned visitor `Message`;
   `Resolver.resolve_with_ctx/4` (with the real role_resolver seam) MUST
   include the `answers` role's member among recipients. Asserting through the
   Resolver (not by inspecting RuleStore rows) makes the gate mean "a visitor
   message actually reaches the answerer", which subsumes rule presence,
   enablement, workspace scoping, and role resolution.
3. **Completion invariant:** for the answering role member as caller and the
   provider role member as target, the `authorize_complete` predicate MUST pass
   (exposed as a public `Ezagent.Entity.Agent.completion_authorized?(caller,
   agent_uri)` so the test asserts the exact production gate, not a
   reimplementation).
4. Both assertions red on today's main for a session materialized the way the
   official site was (pre-declaration pinned content / admin-caller driver) —
   the test doubles as the Defect A/B regression proof.

### 4.3 Deployed-session audit (ops)

`mix ezagent.socialware.answer_audit` — enumerate sessions of answering
socialwares (install records → definitions with `answers` roles), run the two
§4.2 predicates read-only, report non-compliant sessions with the reconcile
command to fix each. This is the migration driver and the post-deploy check.

---

## 5. Symmetry with the inbound receiver protocol

| | INBOUND (receiver foundation) | OUTBOUND (this spec) |
|---|---|---|
| Interaction | visitor structured submit | agent answer |
| Transport | `page_action` channel event → `session.page_action` | session routing pipeline → `chat.receive` → completion → Turn/Surface |
| Who is authorized | confirmed member, exact `session.page_action` cap | answering role member, stored `Agent.Complete` composition cap |
| Authority mechanism | the ONE CapBAC (member participation tier) | the ONE CapBAC (declared operates edge, issue+absorb) |
| Declared where | socialware defines `event_type`s + catalog action bindings | socialware declares `answers` role + delivery rule + operates edge |
| Fail-closed default | anon = browse-only; no submit without cap | mention-gated default; no answer delivery without declared rule; no completion without stored grant |
| Core provides | envelope, dispatch, cap mechanism, transport | Resolver/RuleStore, role receivers, composition-cap lane, reconcile |

Same design law on both legs: **the socialware declares; the platform
materializes and enforces; nothing rides an ambient default.** A visitor's
`page_action` submit (inbound) lands as a typed Message; C2's delivery rule is
what routes that Message to the answerer; C3 is what lets the answerer think;
the existing Turn/Surface path publishes the reply — closing the loop the
receiver handoff opens. When F1 (`event_type`) lands, C2 matchers may target
typed events (`event_type_matches`), keeping the two halves on one vocabulary.

---

## 6. Migration — existing broken sessions

**Recommended: reconcile-in-place.** For each non-compliant session
(§4.3 audit; the live official site first):

1. `reconcile_session_config(session, :upgrade)` — re-pin to the current hello
   definition revision (which declares the `always → front-desk` rule and the
   new `operates` edge), install the rule under the session's own identity,
   mint+absorb the completion cap.
2. If the deployment adopts `owner_policy: system` for the official site:
   re-own the two role agents to the platform principal (lineage update via
   the agent domain's sanctioned re-own operation — an explicit migration step,
   not part of reconcile). C3 works without this step; it is the C4 cleanup.
3. Verify: `answer_audit` green + one live e2e visitor question on canary.

**Rejected: destructive re-seed.** The official site carries live turn/message
history and its owner-membership caps; `OfficialSiteSeed` is absence-gated by
design (it refuses to touch an existing page). Re-seeding also does not
generalize — user-installed answering sessions cannot be re-seeded at all.
(Canary/beta's deploy-time reflow re-runs the seed anyway; the reconcile lane is
what fixes STABLE, and keeps fixing sessions created before any future
definition upgrade.)

---

## 7. Open questions (for codex review)

1. **Matcher-coverage semantics (C2):** conformance checks a rule targeting the
   answerer exists; it does not prove the matcher covers unmentioned visitor
   traffic (e.g. an `always` vs a narrow `text_contains`). Is structural
   presence + the §4.2 runtime Resolver assertion (which DOES prove coverage
   for the plain-message case) sufficient, or should conformance require
   `rule_set: default, position: 0` to be `always`-matched for
   `web_anon_access` socialwares?
2. **Completion-dependency inference (§4.1):** should conformance infer "this
   answers-role needs a Complete edge" from the recipe (recipe declares an LLM
   provider role dependency), or stay with explicit `operates` declarations
   only (v1)?
3. **Upgrade-mode blast radius:** `:upgrade` re-pins ALL installs of the
   session, not just routing config. Should v1 restrict upgrade-reconcile to
   config-bearing fields (rules/legends/prompts/operates) while leaving
   behavior-set pins untouched, deferring full behavior upgrades to a separate
   session-upgrade design?
4. **Platform principal identity (C4):** `{type: :system}` resolves to
   `User.admin_uri()` today. Should the resolution introduce a dedicated
   non-admin platform principal now (strict-verify direction) or defer to the
   cap-signing §G line?
5. **`answers` on non-agent fills:** is `answers: true` meaningful for a
   `fill: human` role (a human-staffed help desk)? v1 restricts it to
   `fill: agent`; flag if the restriction should be lifted.
