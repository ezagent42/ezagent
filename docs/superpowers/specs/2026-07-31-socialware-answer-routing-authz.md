# Socialware Answer Routing + Completion Authz — the OUTBOUND half of the socialware protocol

**Status:** SPEC rev 2 (design only — no implementation in this PR)
**Coordinator:** cc · **Review gate:** codex (adversarial, pre-impl — this touches the Cap axis)
**Rev 2:** addresses the codex adversarial review on PR #1667 (verdict NEEDS-WORK).
Per-finding changelog in §8.
**Companion:** `docs/superpowers/handoffs/2026-07-28-socialware-receiver-foundation-handoff.md`
(the INBOUND half). Together they form one socialware interaction protocol.
**Evidence baseline:** read-only review of `origin/main` @ `9da32994f`; all
file:line references re-verified for rev 2. Re-anchor before implementing.

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
`always → front-desk` / `always → autoservice`, `rule_set: default, position: 0`)
— so a FRESH session from today's seed manifests routes correctly. The live
defect is confined to sessions **pinned to pre-declaration content** (the
official site) plus the structural gaps that let that state exist:

1. **Nothing requires the declaration.** A manifest with answering agent roles
   and no `routing_rules` passes conformance (`Ezagent.Socialware.Conformance`)
   and publishes cleanly. The failure mode is silent: the session works for
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

### 1.2 Defect B — completion authz has no convention, and the declared lane cannot mint it

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
  channel today.

On the official site, the answer agent (`llm` role) is owned by the human
founder (`OfficialSiteSeed` resolves a real non-admin user as owner; role-slot
materialization spawns agents under the session owner as `granted_by` —
`SessionInstaller.install/4` reads `Session.owner/1` and hands it to
`DefinitionAgents.materialize_definition_agents/5`). The recipe grants no
`Agent.Complete` cap to anyone. So the driver's `admin ≠ owner` and holds no
stored cap → `:unauthorized`. The chain worked only in dev setups where the
session owner happened to be admin.

The composition-cap lane (`operates` edges) is the right mint mechanism — but
it CANNOT mint this cap today. Two structural blockers, both with covering
tests on main:

- **`Agent.Complete` is ownerless.** `data_owner/1` returns `:no_owner` for
  every concrete instance (`apps/ezagent_domain_agent/lib/ezagent/behavior/
  agent/complete.ex:29-34` — "cap-only Behavior; no per-entity data").
  `CompositionCaps.assert_target_owner/2` rejects ownerless targets before
  ISSUE (`composition_caps.ex:552-560`; test `composition_caps_test.exs:63-79`).
- **`Agent.Complete` is not in the target agent's effective behavior set.**
  Agent base/curl sets omit it (`entity/agent.ex:150-191`), and
  `assert_target_conformance/3` requires the target's LIVE action to resolve to
  the declared behavior (`composition_caps.ex:573-583`; failure test
  `composition_caps_test.exs:105-121`).

So Defect B is three-layered: no convention says who calls completion; the
driver substitutes admin; and even a declared `operates` edge for `Complete`
fails materialization. All three are in scope here.

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
    answers: chat        # NEW — this role replies to plain session traffic
```

- `answers` is a role-level **typed** protocol declaration (shape in C2), not a
  routing rule — it states intent, and conformance checks that the intent is
  backed by mechanism (C2, C3).
- **Fail-closed rule for public surfaces:** a manifest with
  `visibility_policy.web_anon_access: true` AND at least one `fill: agent` role
  MUST either mark ≥1 role with `answers` or declare the explicit opt-out
  `answering: none` at top level. A public, agent-inhabited page that is silent
  about answering is a conformance ERROR — silence caused the live defect, so
  the protocol makes silence unrepresentable. Non-public manifests (e.g. kanban,
  `web_anon_access: false`) may omit the marker entirely.

### C2 — Every answerer has a declared, ENABLED, covering delivery rule

`answers` is typed, so coverage is checkable per declared kind:

```yaml
answers: chat                        # answers plain (unmentioned) session chat
answers: { events: [page_action] }   # conditional: answers typed events only
```

(`answers: true` is NOT a valid value — ambiguous intent was one of the review
findings; the parser rejects it with a pointer to the two typed forms.)

Coverage requirements, checked at publish (conformance) and at runtime (§4.2/§4.3):

1. **`answers: chat`** — the manifest MUST declare a `routing_rules` entry whose
   receiver is that role (`{:role, name}` — role receivers only; no instance
   URIs in declarations) and whose matcher is **UNCONDITIONAL — normally
   `always`**. A conditional matcher (`mention`, `from_role`, `text_contains`,
   …) does NOT satisfy `answers: chat`: a plain, unmentioned visitor question
   must match. `position`/`rule_set` are ordering concerns, not correctness
   concerns — conformance requires matcher coverage, NOT `position: 0`.
2. **`answers: {events: [...]}`** — for each declared event type there MUST be a
   rule targeting the role whose matcher covers that event type (the
   `event_type` matcher, F1 — until F1 lands this form is reserved and
   conformance rejects it as `not_yet_supported`, which keeps intent
   unambiguous without faking coverage).
3. **Enablement is part of coverage.** The declared rule materializes
   `enabled: true`. At runtime, three non-green states are DISTINCT and the
   audit (§4.3) must not conflate them:
   - `missing` — rule absent (never installed / deleted): reconcile installs it.
   - `drifted` — rule present under the template identity but receivers or
     matcher differ from declaration: reconcile heals it.
   - `admin_disabled` — rule present, matching, but `enabled: false` set by an
     operator: **by design, reconcile preserves it** (disabled-wins, per the
     DefaultRules migration precedent). This session is red-by-choice; the
     audit reports it as such and CANNOT auto-green it — only an explicit
     operator re-enable can.
4. **A skipped answerer is a red session.** Role materialization deliberately
   records-and-continues when a role lacks credentials
   (`definition_agents.ex:154-162`, Chain C). If the skipped role is an
   `answers` role, the session cannot answer; §4.3 reports it (`skipped_role`)
   with the repair command. Conformance cannot catch this (it is a runtime
   condition); the audit is the gate.

The `MentionRouting` `system_default` (`always → [$session_users, $mentions]`)
remains the default for **ad-hoc member sessions only**. An answering socialware
MUST NOT rely on it — it is normatively documented as "notification +
mention-gating", never "answer delivery".

### C3 — Completion authority is a declared `operates` edge over a cap-only subject

The completion chain (`answering role → LLM-provider role`) is a **declared
composition edge**, the same mechanism autoservice uses for kb
(`apps/ezagent_web/priv/socialware_seed/autoservice/manifest.yaml:14-18`):

```yaml
roles:
  - role_name: front-desk
    answers: chat
    operates:
      - role: llm
        behavior: Ezagent.ActionSet.Agent.Complete
        action: complete
  - role_name: llm
    fill: agent
    recipe: hello.llm
    flavor: curl
```

The lane fits: `CompositionCaps.reconcile_session/5` builds the target-agent
cap, issues it as the target owner, and absorbs it into the **source role
member** (issue+store, the cbac-done-right shape); the absorbed artifact lands
in the holder's identity slice — exactly where `authorize_complete`'s
`Kind.holds_cap?/3` reads. But it is **not materializable today** (§1.2
blockers). This spec resolves both, without inventing a new authz mechanism:

- **C3a — `Agent.Complete` becomes a concrete-owner, non-dispatchable cap
  subject.** `Complete.data_owner/1` returns the agent's owner for a concrete
  instance — the SAME authority `authorize_complete` uses as its fast-path
  (`AgentLineage.spawned_by`, which is also the credential owner under C4's
  default policy). The grant root for ISSUE is therefore the owner of the
  target agent, preserving the #161 owner-authority chain.
- **C3b — `CompositionCaps` learns cap-only subjects.** A Behavior may declare
  itself **cap-only** (authorization subject with no dispatchable action — a
  registry-level declaration on the Behavior, e.g. `@cap_only true` surfaced
  via `CapabilityRegistry`). For a cap-only subject, target conformance =
  "target is an Agent-Kind instance and the behavior declares the action as a
  cap subject" — it does NOT require `BehaviorSet.resolve_action/3` on the
  live behavior set. Explicitly: we do NOT mount the no-op `handle_complete/2`
  into the agent's effective behavior set merely to satisfy conformance —
  mounting a fake dispatchable action to pass a gate would falsify the gate.
  Dispatchable subjects keep today's strict live-resolution conformance
  unchanged.
- **C3c — storage barrier: no routable answerer before its cap is stored.**
  `absorb_cap/2` is a fire-and-forget cast (`apps/ezagent_domain_identity/lib/
  ezagent/identity.ex:146-179`; durable via the capability delivery outbox —
  the ②/#207 durability lane — but confirmation is not awaited), while
  `reconcile_session/5` persists the binding as `active` BEFORE `absorb_active`
  runs (`composition_caps.ex:228-232`). As-is, the answer role could become
  routable while the driver's stored cap is still in flight → visible
  `:unauthorized` failures on a "healthy" session. Normative rule: **an
  `answers` role is not answer-routable until its completion cap's absorption
  is CONFIRMED.** Mechanism (§3.2): composition activation gains a confirm
  step — the binding is persisted `pending` and flipped `active` only on
  absorption acknowledgement (the outbox row is the durable intent; the ack is
  the barrier); create-time answering-role rule install is sequenced after
  activation, and §4.2's tests await the barrier rather than sleeping.
- **C3d — driver identity.** The completion driver calls as the **answering
  role member** (front-desk), never `User.admin_uri()` — the caller must be
  the entity that HOLDS the absorbed composition cap. Details in §3.4.
- `caller == owner` remains a valid fast path (an owner driving its own
  agent), but is no longer load-bearing for any answering socialware.

### C4 — Ownership: session owner and agent owner are SEPARATE policies

Rev 1 overloaded `owner_policy` with agent ownership; that cannot work —
`Definition.owner_uri/2` derives the **session** owner from `owner_policy`
(`definition.ex:196-200`), and `SessionInstaller` reuses that session owner as
the role-agent owner/granter (`session_installer.ex:17-43`). Changing
`owner_policy` to a system type would change the session owner, violating the
#1576 founder contract. So:

- **`owner_policy` is untouched** — it governs the SESSION owner only.
  `{type: installer}` stays the only variant; the founder stays session owner.
- **NEW `agent_owner_policy`** governs role-agent lineage at materialization:
  - `inherit` (default) — role agents are owned by the session owner (today's
    behavior, unchanged). The role-slot model decision (2026-07-05) holds: the
    installer's agents spend the installer's credentials; ownership follows
    credential liability.
  - `{type: platform}` — role agents are owned by the deployment's **dedicated
    platform principal**: a distinct, accountable, non-admin entity provisioned
    by deployment boot. Resolved at install time by one function (never an
    authored instance URI — `Definition.owner_policy/1`'s "definitions cannot
    name participants" rule extends to this field). **`User.admin_uri()` is
    explicitly forbidden as the resolution**: making admin the agent owner
    widens the `caller == owner` fast path so that EVERY admin-caller
    completion succeeds, silently bypassing the C3 edge this spec exists to
    require.
- **v1 adoption: `inherit` everywhere, including the official site.** C3 alone
  fixes Defect B with no ownership change: the founder owns both role agents,
  the install is owner-authorized, the operate edge mints under the founder's
  grant root, and the driver authorizes via the stored cap regardless of
  ownership. `{type: platform}` becomes adoptable only once the dedicated
  principal exists (cap-signing §G line); no lane in this spec waits on it.
- **No re-own operation is specced, because none is needed.** Rev 1's migration
  step 2 assumed a "sanctioned re-own operation" — it does not exist:
  `AgentLineage` is append-only/set-once and rejects a different creator
  (`agent_lineage.ex:52-59, 92-105`). A real re-own would have to atomically
  cover lineage supersedure, credential ownership (`:api_keys.creator_uri`),
  target authority, revocation of the old owner's caps, and composition-cap
  reissue. That is its own spec if `{type: platform}` retrofit is ever wanted;
  this spec's migration path (§6) never re-owns.
- **Presented-cap seam: rejected for this relation, with scope.** A direct
  function COULD accept and cryptographically verify presented cap artifacts —
  converting `complete/3` into a dispatched Invocation is not the only way, so
  rev 1's "would require" was too strong. But doing either creates a SECOND
  authorization seam beside the stored-cap read for a relation that is durable
  and declared (role→role, lifetime of the session). The stored composition
  grant is the smaller design — chosen, not forced.

### C5 — Config-reconcile is a first-class lane that REUSES the existing upgrade machinery

The platform gains a **config-only reconcile** for existing sessions — the
missing symmetric half of agent-repair. Two modes with sharply separated
contracts:

- **`:repair` (same-revision, freeze-pinned).** Re-materialize config from the
  session's PINNED revision. Fully frozen means fully frozen:
  `pin_installs_from_session/2` today lets an install ref with no session
  record resolve LIVE (`installation.ex:160-163` — "a never-installed ref is
  not grandfathered"). Correct for create-adjacent lanes; wrong for repair.
  **Repair operates on the session-owned install record set ONLY: a template
  ref with no session install record is reported as `unpinned_ref` and
  EXCLUDED — repair never resolves anything live.** Heals `missing`/`drifted`
  rules (C2.3) against the pinned declaration; preserves `admin_disabled`.
  Idempotent; callable by the `repair_orchestrator/1` surfaces
  (owner/operator; workspace-owner gate).
- **`:upgrade` (re-pin, delegating).** The ONLY path by which a definition
  upgrade reaches an existing session — explicit operator/owner action, never
  a side effect of publish. **It is defined as a delegation to the existing
  upgrade machinery, not a second source of truth:**
  `Ezagent.Orchestrator.Tools.Migration.migrate_session/2` already replaces
  members/rule sets/prompts/legends, repoints installs via
  `Installation.repoint_template_installs/4` (the sole explicit pin-advance
  path, `installation.ex:252-280`), and finalizes the pin. `:upgrade` = that
  pipeline + the C2/C3 reconcile steps (§3.3). Blast radius is thereby
  resolved, not deferred (rev 1 open question 3, now closed): **a "config-only"
  upgrade exists only as a proven-safe fast path** — the reconciler diffs the
  pinned revision against the target revision restricted to config-bearing
  fields (routing_rules, legends, prompt templates, operates, answers); if ANY
  non-config field differs (behavior sets, recipes, roles, installs), the
  config-only lane REFUSES and the operator must run the full
  `migrate_session/2` upgrade. Install records never claim a revision whose
  non-config content the session does not actually run.

Shared reconcile semantics (both modes):

- **Managed-row selection is by provenance, not creator.** Reconcile touches
  only routing rows with `source == "system_default"` (the RuleStore column
  that exists for exactly this, `rule_store.ex:43-49`); rows created by
  session-local admins (`source == "admin"`) are NEVER added/updated/deleted
  by reconcile, even when `created_by = session_uri` collides.
- **Disabled state survives matcher healing.** Matcher drift is healed by
  delete+re-add under the same identity (no `update_matcher` today); the
  re-add explicitly carries the prior `enabled` value — healing a disabled
  rule's matcher must not silently re-enable it.
- **Prompt/legend provenance.** Template-materialized prompt/legend keys are
  recorded with provenance (`template@revision`) at install and reconcile
  time. Reconcile replaces/deletes ONLY provenance-marked keys (a key removed
  by the new revision is deleted; a drifted one is replaced); session-local
  additions (no template provenance) are untouched. Without provenance,
  "removed template key" and "local addition" are indistinguishable — that
  ambiguity was a review finding; the marker removes it.
- **Removed installs are tombstoned.** `repoint_template_installs/4` only
  advances refs still present in the target content. An upgrade that REMOVES
  an install ref must tombstone the session's install record (the
  `retract_session_installs/2` lane), so the session's record set stays the
  authoritative enumeration `:repair` depends on.
- **Actor vs authority are separate parameters.** Re-running
  `CompositionCaps.reconcile_session/5` takes the AUTHENTICATED actor (who
  invoked reconcile — operator or owner) and the ACCOUNTABLE configurer /
  grant authority (the target-agent owner per C4) as distinct inputs; the
  actor is authorized to trigger, the owner authority signs the mint.

---

## 3. Mechanism

### 3.1 Manifest / Definition schema (additive)

- `Definition.role`: optional `answers` — typed: `chat` |
  `{events: [event_type]}` (C2; bare `true` rejected).
- `Definition`: optional top-level `answering: :none` opt-out marker.
- `Definition`: optional `agent_owner_policy` — `inherit` (default) |
  `%{type: :platform}` (C4). `owner_policy` is unchanged.
- `operates` whitelist gains `Agent.Complete`/`:complete` as a permitted
  behavior/action pair (mirroring the kb `query` entry), marked **cap-only**
  (C3b): conformance for this pair checks the target is an agent role, not
  live-action resolution.
- `Ezagent.ActionSet.Agent.Complete`: `data_owner/1` resolves the concrete
  instance's owner (C3a) instead of `:no_owner`; the Behavior is declared
  cap-only in the registry. `handle_complete/2` stays unmounted.
- Version-hash extends over the new fields (write-once/hash-checked template
  machinery accommodates extra fields, per team-routing-unification §3.7).

### 3.2 Session create (activation barrier added)

Create-time materialization already installs declared rules
(`install_template_rule_sets/4`) and reconciles composition edges
(`SessionInstaller.install/4` → `CompositionCaps.reconcile_session/5`). C1-C3
add declarations, not a new create path. Two behavioral additions:

- Rule-install failure stays loud (inside `finalize_fresh_session`'s
  with-chain, rolls back the create).
- **Composition activation is barriered (C3c):** bindings persist `pending`;
  the absorption ack flips them `active`; the `answers` role's delivery rule
  is enabled only after its completion-edge bindings are `active`. A binding
  stuck `pending` (grantee not ready) leaves the durable outbox row AND a
  non-routable answerer — degraded loudly, visible to §4.3, never a
  half-authorized live answerer.

### 3.3 Reconcile (`SessionCreator.reconcile_session_config/2` — NEW)

```
reconcile_session_config(session_uri, mode, actor_uri) :: {:ok, summary} | {:error, term}
  mode :: :repair | :upgrade
```

1. Resolve template content:
   - `:repair` → the session-owned install record set, fully frozen (C5);
     refs without session records → `unpinned_ref` in summary, excluded.
   - `:upgrade` → config-bearing diff against the target revision; if clean,
     advance pins via `Installation.repoint_template_installs/4` and proceed
     config-only; if not clean, `{:error, {:requires_full_upgrade, diff}}` —
     the operator runs `Migration.migrate_session/2` (which itself calls back
     into steps 2-5, keeping ONE implementation).
2. Diff declared `routing_rules` against installed rows with
   `source == "system_default"` under identity `(created_by = session_uri,
   rule_set, position)`:
   - `missing` → `RuleStore.add/5` (source `system_default`, workspace-scoped,
     identical to create).
   - `drifted` (receivers) → `RuleStore.update_receivers/3`; (matcher) →
     delete+re-add same identity, carrying `enabled` (C5).
   - `admin_disabled` → matcher/receivers healed if drifted, `enabled: false`
     preserved, reported.
   - system_default rows no longer declared → delete (`force: true`).
   - `source == "admin"` rows: never touched.
3. Reconcile legends + prompt templates by provenance-marked subset (C5).
4. Re-run `CompositionCaps.reconcile_session/5` (already reconcile-shaped:
   replaces the session's binding set, revokes unsupported) with actor and
   owner authority as separate parameters (C5); C3c barrier applies.
5. `RuleStore.load_into_registry/1` once, at the end.
6. Authorization: `:repair` — the `repair_orchestrator/1` surfaces. `:upgrade`
   — the session owner, or a platform operator for platform-seeded
   socialwares (it changes what the session runs).

`repair_orchestrator/1` becomes a composition of this + the existing agent
lane, eliminating the current partial overlap where repair reinstalls missing
rules but cannot heal drift.

### 3.4 Driver identity (hello, and the generic rule)

- `Generator.call_llm/3`: caller = the session's answering role member URI
  (resolve via `EzagentPluginHello.Members.role_uri(session_uri, "front-desk")`
  — the same seam it already uses to resolve `"llm"`; fail loud if
  unresolvable — no admin fallback). Same change in any other completion
  driver (`concierge` path included).
- Generic protocol rule for future socialwares: **a completion driver's caller
  is the session role member on whose behalf it acts** — the holder of the
  absorbed composition cap. Framework code never substitutes a platform
  principal for a role actor.
- `authorize_complete/4` is exposed as a public predicate
  `Ezagent.Entity.Agent.completion_authorized?(caller_uri, agent_uri)`, and
  the private production path DELEGATES to it (one implementation, asserted by
  §4.2 — never a test-only reimplementation).

---

## 4. Enforcement

### 4.1 Conformance (static, import lane — fail-closed at publish)

`Ezagent.Socialware.Conformance.check_candidate` additions:

- `web_anon_access: true` + ≥1 agent role + no `answers`/`answering: none`
  declaration → ERROR (C1).
- `answers: chat` role with no ENABLED-by-declaration rule targeting it whose
  matcher is unconditional → ERROR (C2.1 — matcher coverage, not position).
- `answers: {events: [...]}` → ERROR `not_yet_supported` until F1 `event_type`
  matchers land (C2.2).
- `answers` role whose recipe declares an LLM-provider role dependency but no
  `operates` edge for `Agent.Complete`/`:complete` → ERROR. (v1: explicit
  edges only; recipe-dependency inference stays open, §7.)
- `answers: true` (untyped) → ERROR with the two valid forms.

### 4.2 Invariant tests (runtime)

**What is red on main today — stated precisely.** hello and autoservice
manifests already declare `always` rules (`hello/manifest.yaml:29-35`,
`autoservice/manifest.yaml:23-29`), so FRESH-session routing is green on main.
The red-on-main edge is COMPLETION, in three layers: (1) hello declares no
`Complete` operate edge; (2) adding the edge fails materialization
`:operate_target_ownerless`; (3) fixing ownership alone fails
`:operate_target_not_conformant` (unmounted). The pre-declaration official
site cannot be modeled by a fresh session at all — it needs its own pinned
fixture. Hence four tests:

1. **Routing invariant (regression guard — green today, keeps it so).** Create
   a session per answering seed manifest; build a plain, unmentioned visitor
   `Message`; `Resolver.resolve_with_ctx/4` (real role_resolver seam) MUST
   include the `answers` role's member among recipients. Asserting through the
   Resolver makes the gate mean "a visitor message actually reaches the
   answerer" — subsuming rule presence, enablement, workspace scoping, and
   role resolution.
2. **Completion invariant (RED on main — the Defect B proof).** For the
   manifest-with-edge fixture: session create succeeds, composition bindings
   reach `active` (await the C3c barrier — no sleeps, no asserting through
   the fire-and-forget cast), and
   `completion_authorized?(front_desk_member, llm_member)` passes via the
   STORED cap with `caller ≠ owner` pinned in the fixture (fast-path excluded
   by construction). On today's main this fails at materialization (layer 2/3
   above) — the test doubles as the blocker regression proof.
3. **Production-path driver test (guards the caller, not just the
   predicate).** A predicate-only test is evadable: `completion_authorized?`
   can pass while `Generator` still calls as admin. Drive the ACTUAL answer
   chain (`Generator.complete/3` → `request_completion/5`) against a fixture
   whose only authorization route is the stored composition cap (caller ≠
   owner; no admin caps), observing the caller the driver passes (assert at
   the `request_completion` seam). Green requires BOTH the driver-identity
   change (§3.4) and the stored cap. Await the C3c barrier before driving.
4. **Legacy-pinned fixture (the official-site shape).** A session materialized
   from a PINNED pre-declaration revision (no routing rule, no edge):
   §4.3 audit reports it non-compliant (`missing` + no completion authz);
   `reconcile_session_config(:upgrade)` heals it; audit greens. This is the
   Defect A regression proof and the migration rehearsal.

### 4.3 Deployed-session audit (ops)

`mix ezagent.socialware.answer_audit` — enumerate sessions of answering
socialwares (install records → definitions with `answers` roles), run the §4.2
routing/completion predicates read-only, and classify each non-green session:

```
missing | drifted | admin_disabled | skipped_role | pending_cap | unpinned_ref
```

with the reconcile command that fixes it — except `admin_disabled`, which is
red-by-choice (C2.3) and reports the operator re-enable instead: the audit
never claims reconcile will green a session it deliberately won't. This is the
migration driver and the post-deploy check.

---

## 5. Symmetry with the inbound receiver protocol

| | INBOUND (receiver foundation) | OUTBOUND (this spec) |
|---|---|---|
| Interaction | visitor structured submit | agent answer |
| Transport | `page_action` channel event → `session.page_action` | session routing pipeline → `chat.receive` → completion → Turn/Surface |
| Who is authorized | confirmed member, exact `session.page_action` cap | answering role member, stored `Agent.Complete` composition cap |
| Authority mechanism | the ONE CapBAC (member participation tier) | the ONE CapBAC (declared operates edge, issue+absorb, barriered activation) |
| Declared where | socialware defines `event_type`s + catalog action bindings | socialware declares typed `answers` + covering rule + operates edge |
| Fail-closed default | anon = browse-only; no submit without cap | mention-gated default; no answer delivery without declared rule; no completion without stored grant; no routable answerer before cap storage |
| Core provides | envelope, dispatch, cap mechanism, transport | Resolver/RuleStore, role receivers, composition-cap lane, reconcile |

Same design law on both legs: **the socialware declares; the platform
materializes and enforces; nothing rides an ambient default.** A visitor's
`page_action` submit (inbound) lands as a typed Message; C2's delivery rule is
what routes that Message to the answerer; C3 is what lets the answerer think;
the existing Turn/Surface path publishes the reply — closing the loop the
receiver handoff opens. When F1 (`event_type`) lands, `answers: {events: […]}`
activates and C2 matchers target typed events, keeping both halves on one
vocabulary.

---

## 6. Migration — existing broken sessions

Two lanes, split by **lifecycle class** — a durable, declared property, never
inferred from a socialware's name:

- **`lifecycle: seed_owned`** — replaceable, platform-provisioned content with
  no user data to preserve (official site, demos). **Destructive re-seed is
  the canonical migration:** tear down and recreate session, role agents,
  pins, routing, and composition caps from the CURRENT seed. This is the same
  contract canary/beta's deploy-time reflow already exercises.
- **`lifecycle: user_data`** — sessions bearing real messages, turns,
  memberships, user-installed instances. **Reconcile-in-place only:** pinned
  `:repair`, or an explicit `:upgrade` (§3.3). Destructive re-seed is
  forbidden here — user-installed answering sessions cannot be re-seeded at
  all.

The class is recorded as durable policy/metadata at provision time (seed
provisioning stamps `seed_owned` on the sessions it creates; everything else
defaults to `user_data` — fail-safe toward preservation). Rev 1's blanket
rejection of destructive re-seed is replaced by this split.

**Lifecycle-contract change, made intentional:** `OfficialSiteSeed` is
absence-gated today (`official_site_seed.ex:29-36` — `:present →
:already_provisioned`). Adopting destructive re-seed for `seed_owned` domains
changes that contract: the seed gains a reconcile-or-recreate decision driven
by the stamped lifecycle class + a seed-revision comparison (present-and-
current → no-op; present-and-stale + `seed_owned` → recreate). This is a
deliberate contract change, called out here so it is reviewed as one — not an
incidental side effect.

**Order of operations (official site, stable):**

1. Ship C1-C4 (declarations + cap-only subject + barrier + driver identity).
2. `answer_audit` → the official site reports `missing` + no completion authz
   (the legacy-pinned fixture, §4.2.4, is this state in a test).
3. Re-seed it destructively under its `seed_owned` stamp (or, if the
   deployment declines the contract change, `reconcile_session_config(session,
   :upgrade)` reaches the same end state — both paths are specced; re-seed is
   canonical).
4. Verify: `answer_audit` green + one live e2e visitor question on canary.

No step re-owns agents (C4: v1 is `inherit` everywhere; ownership migration
would need the re-own op that does not exist and is out of scope).

---

## 7. Open questions (for codex re-review)

1. **Completion-dependency inference (§4.1):** should conformance infer "this
   answers-role needs a Complete edge" from the recipe (recipe declares an LLM
   provider role dependency), or stay with explicit `operates` declarations
   only (v1)?
2. **`answers` on non-agent fills:** is `answers: chat` meaningful for a
   `fill: human` role (a human-staffed help desk)? v1 restricts it to
   `fill: agent`; flag if the restriction should be lifted.
3. **Cap-only subject surface (C3b):** is the registry-level `cap_only`
   declaration the right home, or should it live on the `operates` whitelist
   entry only? (Registry-level proposed: the property belongs to the Behavior,
   not to one consumer of it.)

Resolved since rev 1 (previously open): matcher-coverage semantics (now
normative, C2); upgrade blast radius (now a refusal contract, C5);
platform-principal identity (dedicated principal or nothing — admin forbidden,
C4).

---

## 8. Rev 2 changelog (per codex finding)

| Codex finding | Resolution |
|---|---|
| 1. C3 not materializable (ownerless subject; unmounted behavior; absorb race; admin driver) | C3a concrete-owner cap subject; C3b cap-only validation in CompositionCaps, no fake mount; C3c pending→active absorption barrier + non-routable-until-confirmed; C3d/§3.4 front-desk caller |
| 2. C4 conflates session/agent ownership; admin owner broadens fast-path; re-own op doesn't exist; presented-cap overclaim | `agent_owner_policy` separate from `owner_policy` (founder stays session owner); admin forbidden as agent owner; v1 = `inherit` everywhere so NO re-own needed (real re-own requirements enumerated, deferred); presented-cap wording softened to "smaller, not only" |
| 3. C2 evadable (conditional/disabled/skipped answerers pass) | Typed `answers` (`chat` requires enabled unconditional matcher; events form typed + gated on F1); `position: 0` dropped as correctness; audit tri-state `missing`/`drifted`/`admin_disabled` (+`skipped_role`), disabled never auto-greened |
| 4. C5 repair leaks live refs; upgrade duplicates machinery; blast radius; row selection; provenance; tombstones; actor split | Repair = session-record set only, `unpinned_ref` reported; upgrade delegates to `migrate_session/2`/`repoint_template_installs/4`; config-only lane REFUSES on any non-config diff; `source == system_default` selection; enabled-carrying matcher heal; prompt/legend provenance; install tombstones; actor vs owner-authority params |
| 5. Enforcement claim false (fresh routing already green; predicate test evadable) | §4.2 restates red/green precisely (red = completion layers 1-3); routing test kept as regression guard; production-path driver test observes actual caller; `completion_authorized?` delegation; barrier-awaited asserts; separate legacy-pinned fixture |
| 6. Migration blanket-rejected destructive re-seed | §6 split: `seed_owned` → destructive re-seed canonical; `user_data` → reconcile-in-place; class = durable stamped metadata, never name-inferred; OfficialSiteSeed absence-gate change made an explicit contract change |
