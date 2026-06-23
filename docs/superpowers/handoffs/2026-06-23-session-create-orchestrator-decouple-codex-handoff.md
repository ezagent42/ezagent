# Handoff (codex-reviewed ×3 + Allen-confirmed): de-orchestrator-ize the session — orchestrator as a `role` member + provision-on-route

> **Date:** 2026-06-23 · **From:** Claude (with Allen) · **To:** codex
> **Tracking:** task #90 · **Fixes:** PR #902 · **Base:** `origin/main` @ `3cd5a5a4`
> **Branch:** `fix/session-create-orchestrator-decouple` (worktree
> `.worktrees/fix-session-create-decouple`)
> **Spec (READ FIRST, in full):**
> `docs/superpowers/specs/2026-06-23-session-create-orchestrator-decouple-design.md` (rev6)
> **Status:** Allen-confirmed 2026-06-23. Three `/codex:adversarial-review` rounds
> (rev1→2→4→5) converged from approach-level to wiring-level findings; the loop is
> closed. The remaining wiring (§4.5 readiness contract, §4.6 cap policy) is
> **yours to decide and prove during implementation** — that is what this handoff
> is for. **Do NOT re-litigate the approach.** Load skill `ezagent-developer`.

## 0. Mission (one sentence)

`create_session` must always succeed and return a usable session **regardless of
whether the orchestrator (or any agent member) ever comes up** — by removing the
orchestrator's *specialness* entirely: it becomes an ordinary `role: orchestrator`
member, brought up **lazily by routing** (provision-on-route), with the 90s
wait→kill→rollback gate **deleted**.

## 1. The bug you are killing (root cause, verified on `main`)

`create_session` synchronously ensures the orchestrator → `await_orchestrator_ready/3`
waits up to **90s** (`@orchestrator_readiness_timeout_ms 90_000`,
`entity/session/orchestrator.ex:11`) polling `LiveJoinRegistry.joined?` for the cc
orchestrator's MCP bridge-join. The cc agent hangs at the `esr-bridge` MCP-trust
onboarding dialog → never joins → timeout → `rollback_session/3` **deletes the
`kind_snapshots` row** (`session_creator.ex:~437`) → a later `:session :send`
lazy-spawn returns `{:error, :no_such_actor}` (`invocation.ex:188-194`) →
swallowed by `mode: :cast` + `reply: :ignore` (`conversation_actions.ex:146`). The
outer dispatch budget is only 5s (`invocation.ex:259`), so the caller already timed
out while the server ground toward 90s.

**It is not a capability problem.** The defect is the create→orchestrator coupling
+ the snapshot-deleting rollback. The cc onboarding/MCP-trust auto-dismiss is a
**separate, agent-side concern owned by other devs — OUT OF SCOPE here.** Your job
makes the session robust no matter why bring-up is slow or fails.

## 2. The design in five moves (full detail in the spec §4)

1. **`create_session` is pure (§4.1).** Spawn Session Kind (snapshot in init) →
   bind workspace → join the **owner** → install the SessionTemplate's
   *declaration* (role-targeted rules + legends + prompts + member **declarations**)
   → return `{:ok, uri, %{}}`. No agent spawn, no `ensure_orchestrated_session`, no
   wait, no orchestrator arm. `rollback_session/3` survives **only** for the cheap
   sync steps (snapshot/bind/owner-join) — never for an agent member.
2. **Orchestrator = a `role: orchestrator` member (§4.2).** Delete the dedicated
   `orchestrator_template_uri` field; the orchestrator becomes one entry in
   `SessionTemplate.members`. The destination is half-built already: the
   cc-orchestrator AgentTemplate carries `role: "orchestrator"`, `OrchestratorRole`
   is flavor-agnostic, scenario_32 already asserts "orchestrator is a member."
3. **Role-targeted routing, resolved at route-time (§4.3).** Rules carry the role;
   routing resolves role→live-member at route-time (not materialize-time).
4. **Provision-on-route — the single bring-up primitive (§4.4).** Route resolves a
   declared role with no live member → provision (spawn declared agent + join +
   install its rules, all fast, no wait) → deliver (buffers until ready). Holds the
   existing `:create_session` `:global` lock → idempotent/race-safe; self-heals on
   member death; no boot storm (lazy); preserves the sanctioned system-template →
   tenant-workspace cross-workspace spawn.
5. **Readiness gate DELETED (§4.5).** Remove gate/await/poll/kill +
   `@orchestrator_readiness_timeout_ms` + lifecycle subscribe. **Keep**
   `LiveJoinRegistry` join-marking + `Orchestrator.Health` as the pure status read.

## 3. The three wiring decisions that are YOURS (this is the core of the handoff)

The spec deliberately does NOT pretend these are wired. Each has a crisp
invariant, a mandatory test (the gate), and the **exact code landmines** that are
why it isn't already done. Resolve each; prove with its test.

### 3.1 Transport-readiness = a domain-agent readiness contract (§4.5) — LOCKED to candidate ①

**Allen's call (2026-06-23):** a bounded readiness wait → `:failed` is *what the
domain agent layer should already guarantee* — not a session-special buffer. So:

> A **bridge-backed agent's `ReadyGate` does not flip to `:ready` until its
> bridge/transport has durably joined** (`LiveJoinRegistry`). The wait is
> **bounded**; on timeout the agent goes **`:failed`**. The generic
> `PendingDelivery` (already keyed on Kind `ReadyGate`) then buffers any routed
> message and drains on `:ready`; on `:failed` the buffered send **fails visibly**.

Why this is right: the session domain needs **zero** transport-special code, and
nothing is silently lost (delivered after join, or visible `:failed`; the message
is already in the transcript).

**This is the ONE cross-layer touch — an agent-layer change (`plugin_cc` readiness),
NOT session-domain.** It belongs to the domain.agent readiness roadmap; this work
carries it (PR-C) so the decouple has no silent-loss hole. If the domain.agent
effort lands an equivalent contract first, reuse it and PR-C's agent sub-task
collapses to "verify."

**Landmines (must honor):**
- `PendingDelivery` (`pending_delivery.ex:35-45`) + `invocation.ex:155-158` buffer
  **only** on Kind `ReadyGate` `:not_ready` and return `:ok`. **Do NOT add a second
  buffer** — make the bridge-backed `ReadyGate` stay `:not_ready` until join so the
  existing path covers it.
- `LiveJoinRegistry` (`live_join_registry.ex:81-117`) exposes ONLY
  `mark_joined`/`joined?`/`clear` — **no failed/never-joined signal**. The
  bounded-wait→`:failed` transition is NEW; it must emit a signal the readiness
  lifecycle consumes.
- Kind readiness flips in `kind/server.ex:296-328` (`on_ready`/`activated` runs
  AFTER the `ReadyGate` flip). Hook the **gate flip itself** (gate stays
  not-ready), NOT `on_ready`.

**Gate (test 12):** Agent Kind would be `ReadyGate`-ready but `LiveJoinRegistry`
never joins → routed message is durably held and (a) delivered on join, or (b)
fails visibly when the bounded wait elapses (`:failed`) — **NEVER silently lost.**

### 3.2 Tagged routing receivers — two layers, neither changes meaning (§4.3)

There are TWO receiver layers; they resolve differently today:
- **Template-authored `routing_rules`:** `template_team.ex receiver_to_uri/2`
  (~:360-383) ALREADY resolves a bare receiver string as **magic → role
  (`role_to_uri`) → URI**. So legacy SessionTemplate bare role-names ALREADY mean
  "the role member" today. **Do NOT change their meaning** — only change *when*
  they resolve (route-time, so an absent role resolves-or-provisions).
- **Persisted `RuleStore` receivers** (`rule_store.ex receivers: {:array,:string}`,
  parsed via `Ezagent.URI.new!`): here a bare role string WOULD crash `URI.new!`.
  Add a **tagged form** `{:role,name}|{:uri,uri}|{:magic,token}` + schema/migration
  + `Resolver` dispatch-on-tag + UI/CLI validation. **Dual-read** legacy untagged
  persisted strings as `{:uri,_}`/`{:magic,_}`.

**Invariant:** no receiver — template or persisted — silently changes meaning.

**Gate (test 13):** legacy untagged URI/magic still routes; a `{:role,
"orchestrator"}` persisted receiver resolves/provisions at route-time; a bare role
string never reaches `URI.new!`; a template bare role-name still resolves as a role.

### 3.3 Cap policy — fail-closed, NOT a genesis carve-out (§4.6)

**Invariant (gate, test 14):** the system **orchestrator** role gets its scoped
caps when provisioned; a **tenant-authored** role declaring `behavior: :any` /
`{:spawned_by}` / genesis-backed authority gets those caps **dropped** — it cannot
mint genesis authority by naming it in `requested_caps`.

**Landmines (why it's "not wired" today):**
- `Role.CapMint` (`role/cap_mint.ex:42-48`) needs an **INJECTED policy
  predicate** — it has no built-in policy. Supply the fail-closed policy.
- `OrchestratorRole.requested_caps == []` — must be **populated** with the
  orchestrator scoped-cap set or the role-member grants nothing.
- `caps.ex` grants orchestrator caps via a **genesis/system-backed tag carve-out**
  (`tag_for/2`, direct genesis grants ~:63-73,140-148,163-181). **Replace** it with
  the policy path (whitelist the system orchestrator role; drop the carve-out) or
  the "tenant can't mint genesis" invariant is bypassable.
- `role/compose.ex` does NOT handle caps today — confirm where cap materialization
  actually runs before wiring the policy.

**Out of scope (unchanged):** owner-delegated `{:spawned_by}` (#153/#154) stays
deferred. The role-member keeps today's system/genesis authority *basis*; you only
ensure tenant roles can't reach it via `requested_caps`.

## 4. PR sequencing (green at each step — NOT one PR; spec §12)

Each PR: `mix precommit` EXIT=0 **+** `check_invariants` green. Merge into the task
branch `fix/session-create-orchestrator-decouple` (never `main`); keep rebased on
`main`; **Allen merges the task branch → `main`.**

- **PR-A** — role-member representation **alongside** the existing field (no
  behavior change) + data migration + tests both forms resolve.
- **PR-B** — role-targeted routing rules (dual-read old URI-resolved rules).
- **PR-C** — provision-on-route primitive + lazy bring-up + **the §3.1
  transport-readiness contract (the agent-layer change)**; create still also
  ensures in parallel so this PR is independently verifiable. Tests 4,5,6,7,12.
- **PR-D (ATOMIC FLIP — retarget contracts in the SAME PR, or CI goes red /
  implementers keep an eager path):** flip create to pure + **delete** the gate +
  retarget the `create_session` return meta (drop required `orchestrator_status`),
  `Workspace.create_session` meta + CLI + `HomeLive` flash (drop
  `:ready`/`:pending`/`:failed` arms), AND **Scenario-32 G1** (from "orchestrator is
  a member immediately after create" → "after the first route to `role:
  orchestrator`, the provisioned member is joined"). Tests 1,2,3,11.
- **PR-E** — remove `orchestrator_template_uri` + the `[owner,orchestrator]` arm +
  OTU readers; wire §3.3 cap policy + negative tests; generalize `Health` to
  role-member.
- **PR-F** — de-orchestrator-ize naming + arch-invariant/baseline retargeting (§5
  below) + the §13 completion-gate test (**test 8**); `OrchestratorReadinessPort`
  cleanup.
- **PR-G** — UI: status badge generalized + send-error surfacing + "restart member"
  (tests 9,10) + agent-browser E2E.

## 5. Arch invariants & baselines that WILL go red (in-scope; spec §11)

These are part of the work, not surprises:
- `im_session_agent_acyclic_test.exs` — allowlists stay **empty**. Provision-on-route
  calls DOWN (session→agent, allowed); introduce **no** agent→session dep. Re-verify
  `@allowlist_session_to_mcp []`. After gate deletion, `OrchestratorReadinessPort`
  may become unreferenced → delete it + its allowlist note.
- `oversized_modules_test.exs` + `arch_baseline_manifest.exs` —
  `def_count_orchestrator_tools`, `def_count_session_creator`, LOC caps shift;
  rebaseline with `# arch-cap-bump:` annotations.
- `uri_query/scan.ex` `:orchestrator_derivation` rule — retarget/delete (role-based
  member resolution replaces the `:orchestrator` UriQuery resolver).
- `ezagent.arch.scan.ex` / `check_invariants*.ex` — update orchestrator path
  registrations + `@layer_vocab_words` "Orchestrator" if the namespace changes.

## 6. The completeness gate (spec §13)

"Done" = the **§13 de-orchestrator-ization checklist** is fully resolved: NO
orchestrator-named field/function/branch and NO orchestrator-specific cap
special-casing left in the session domain. **Test 8** mechanizes this (grep/AST gate
over `ezagent_domain_session`, excluding the generic role-member path). This is the
test that fails if any specialness is left behind. Walk the §13 checklist item by
item; each tag (DELETE / GENERALIZE / MOVE→agent / KEEP-rename / MIGRATE-data) is
explicit.

## 7. Hard constraints (don't trip these)

- PostgreSQL-only test suite; **`mix precommit` EXIT= line is authoritative.**
- Behaviors via `use Ezagent.Lifecycle`; never bypass CapBAC.
- The readiness path is compile-bypassed in `:test` → add an explicit
  integration/e2e gate for provision-on-route + no-rollback (unit tests alone won't
  catch a regression of the deleted-gate semantics; spec §10 closing note).
- Honor the audit "hidden couplings" (spec §13): positional `[owner,orchestrator]`
  → role lookup; `orchestrator_uri`-as-readiness-proof → provision-time write
  **before** join (self-register ordering); deterministic `cc_orchestrator-<disc>`
  name → generic member URI + role resolution; create-lock serialization → reused
  by provision-on-route.
- Skip mix commands you can't run in an isolated `MIX_HOME` if you sub-dispatch a
  static codex companion; otherwise run the real gates.

## 8. Definition of done

All 14 spec tests green; every §13 checklist item resolved (test 8 green); each PR
`mix precommit` EXIT=0 + `check_invariants` green on the task branch; the no-rollback
invariant (test 1) + create-within-budget (test 2) demonstrably hold; an
integration/e2e gate proves provision-on-route brings up a hung-bridge orchestrator
without rolling back the session. Then Allen merges the task branch → `main`.

---
*Allen-confirmed 2026-06-23. Approach is closed (3 adversarial rounds). The three
wiring decisions in §3 are yours to resolve and prove — that is the implementation
work. The codex prompt is in the sibling file
`2026-06-23-session-create-orchestrator-decouple-codex-prompt.md`.*
