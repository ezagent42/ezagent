# Codex prompt — de-orchestrator-ize the session (fix #902)

> Paste the block below to codex. It is self-contained: it points at the spec +
> handoff, fixes the branch/base, names the wiring decisions codex owns, and the
> green-at-each-step gate. Codex implements; Allen merges the task branch → `main`.

---

You are implementing a landed, Allen-confirmed design. **Do not re-open the
approach** — three adversarial-review rounds already converged it. Your job is to
implement it across the sequenced PRs and resolve the three wiring decisions the
spec explicitly delegates to you.

**Load the `ezagent-developer` skill first** (3-tier core/domain/plugin invariants,
GLOSSARY, ARCHITECTURE). You are in the `ezagent` Elixir/Phoenix umbrella.

**Repo / branch:**
- Worktree: `.worktrees/fix-session-create-decouple`
- Branch: `fix/session-create-orchestrator-decouple` (off `origin/main` @ `3cd5a5a4`)
- All PRs merge into this **task branch**, never `main`; keep rebased on `main`.
  Allen merges the task branch → `main`.

**Read in full before writing any code:**
1. `docs/superpowers/specs/2026-06-23-session-create-orchestrator-decouple-design.md` (rev6) — the design.
2. `docs/superpowers/handoffs/2026-06-23-session-create-orchestrator-decouple-codex-handoff.md` — the operational constraints, file:line landmines, PR sequencing, gates.

**Mission:** `create_session` must always succeed and return a usable session
**regardless of whether the orchestrator ever comes up.** Remove the orchestrator's
specialness: make it an ordinary `role: orchestrator` member, brought up lazily by
routing (provision-on-route), and **delete** the 90s wait→kill→rollback gate. Fixes
PR #902. The cc onboarding/MCP-trust hang is OUT OF SCOPE (other devs); make the
session robust regardless of bring-up.

**The three wiring decisions you OWN (handoff §3 has the landmines + gate tests):**
1. **Transport-readiness = a generic domain-agent contract, migrated in-work,
   test-first (an agent-layer change — the session never waits):** a bridge-backed
   agent's `ReadyGate` does not flip `:ready` until its transport durably joins;
   bounded wait → `:failed` on timeout; the generic `PendingDelivery` then covers it
   — **no session-special buffer**. The 90s wait in `ezagent_domain_session` is
   DELETED; the bounded wait is ADDED in `ezagent_domain_agent`. **Method:** write
   the `ezagent_domain_agent` test FIRST (full contract), watch it fail, then
   **migrate** the generic join-state/readiness up from `plugin_cc`
   (`LiveJoinRegistry`/`OrchestratorRole`) and **build** the missing
   bounded-wait→`:failed`. The migration **generalizes** the join registry from
   `orchestrator_uri`-keyed → **`agent_uri`-keyed** (not a verbatim copy); the
   cc-specific MCP socket/channel stays in `plugin_cc`; acyclic stays clean
   (`plugin_cc → domain_agent` is the existing direction). **Add the anti-recurrence
   arch gate (test 15):** fail if any join-state/readiness primitive is defined under
   `apps/ezagent_plugin_*/`. Verify the widened not-ready window strands no
   non-message dispatch. Prove with **test 12** (held → delivered on join, or visible
   `:failed`; never silently lost) **+ test 15**. (The #902 fix itself is independent
   of and not blocked by this migration.)
2. **Tagged routing receivers (two layers, neither changes meaning):** template
   `routing_rules` bare role-names already resolve as roles (`template_team.ex`
   ~:360-383) — keep that, only move resolution to route-time. Add the tagged form
   `{:role|:uri|:magic,_}` to the **persisted `RuleStore`** layer + migration +
   dual-read of legacy untagged strings. Prove with **test 13**.
3. **Cap policy (fail-closed, not a genesis carve-out):** route role-member caps
   through an INJECTED fail-closed policy on `Role.CapMint` (`role/cap_mint.ex`
   ~:42-48); populate `OrchestratorRole.requested_caps`; **replace** the `caps.ex`
   genesis carve-out (`tag_for/2`, ~:63-73/140-148/163-181) with the policy path.
   Tenant roles must NOT be able to mint genesis-backed `behavior: :any` /
   `{:spawned_by}` via `requested_caps`. Prove with **test 14** (negative).

**PR sequence (green at each step — spec §12 / handoff §4):** A (role-member
alongside field) → B (role-targeted rules, dual-read) → C (provision-on-route +
transport-readiness, create still ensures in parallel) → D (**atomic flip**: pure
create + delete gate + retarget create-meta/Workspace/CLI/HomeLive/Scenario-32 G1 in
the SAME PR) → E (drop the field + `[owner,orchestrator]` arm + OTU readers + cap
policy) → F (de-orchestrator-ize naming + arch baselines + the §13 completion-gate
test 8 + `OrchestratorReadinessPort` cleanup) → G (UI: status badge + send-error
surfacing + restart-member + agent-browser E2E).

**Gates (every PR):** `mix precommit` EXIT=0 (the EXIT= line is authoritative) **+**
`check_invariants` green. The readiness path is compile-bypassed in `:test` — add an
explicit integration/e2e gate for provision-on-route + no-rollback. Expect and
retarget the red arch invariants/baselines in spec §11 (acyclic allowlists stay
empty — introduce NO agent→session dependency).

**Completeness gate:** walk the spec §13 de-orchestrator-ization checklist item by
item; **test 8** mechanizes "no orchestrator-specialness left in the session
domain." Done = all 15 spec tests green (incl. test 12 transport-readiness + test 15
anti-recurrence gate) + §13 fully resolved + the no-rollback (test 1) and
create-within-budget (test 2) invariants demonstrably hold.

If you hit a genuine approach-level contradiction (not a wiring question), stop and
report it rather than improvising — but the wiring questions in §3 are yours to
decide and prove with their tests.
