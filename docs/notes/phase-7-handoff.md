# Phase 7 handoff — the Generator + Orchestrator completion

> **⚠️ CORRECTION (2026-05-23, Phase-7-completion PR-6).** This file
> previously declared "Ezagent v1 release (code-complete)" as of
> 2026-05-18. **That claim was false** — and was caught by the
> 2026-05-22 implementation audit
> (`docs/notes/phase-7-implementation-audit-2026-05-22.md`): Phase 7
> was only ~55-60% real. The Orchestrator did NOT run
> (`Ezagent.Orchestrator.Tools` was imported by nothing, no MCP
> exposure); `update_template` / `save_template_as` persisted no row;
> the Generator (`Session.spawn_from_template/2`) was the "minimal
> PR-41" stub that spawned only the orchestrator;
> `SessionTemplate.fork/2` + `.create/2` did not exist; no
> `template:` cap was ever enforced; ~7 V1-V5 gating tests were
> missing. The 2026-05-18 "code-complete" declaration was premature
> — see the **"Premature v1 declaration — what actually happened"**
> section below for the corrected record.
>
> Phase 7's killer feature (the Generator + the live Orchestrator)
> was **completed by the 6-PR Phase-7-completion effort
> (2026-05-22 → 2026-05-23)** specified in
> `docs/superpowers/specs/2026-05-22-phase-7-completion.md` (rev 5),
> **hardened** by 10 codex adversarial-review rounds (PRs #239..#250),
> and then **simplified** by the **generator-reconciler refactor**
> (PR-A #259 + PR-C #260). The hardening rounds fixed real CapBAC +
> workspace-isolation + `fresh?`-gating bugs, but the HIGH count
> never reached 0 because the underlying `cleanup_partial` saga was
> the wrong abstraction. The reconciler refactor replaced it with
> `converge(spec, current_state)` semantics (per-Kind idempotency
> primitives, `docker-compose up`-style re-run continues from
> partial state) and removed ~800 LOC. See
> **"What the Phase-7-completion effort shipped"** below for the
> 6-PR feature build, and
> `docs/notes/2026-05-23-generator-reconciler-retrospective.md` for
> the saga → reconciler post-mortem.
>
> **Phase 7 status now: feature-complete + reconciler-validated.**
> The Generator instantiates teams idempotently; the Orchestrator
> dispatches through CapBAC; templates persist as `kind_snapshots`
> rows and re-instantiate; partial-failure re-run converges to spec.
> See SPEC `docs/superpowers/specs/2026-05-23-generator-reconciler.md`
> for the current Generator design (the SPEC the code now matches).

> **STATUS HISTORY:**
>
> - 2026-05-18 morning (PR #95): premature "v1 released" declaration.
> - 2026-05-18 PM (PR #110): withdrawn → rc1.
> - 2026-05-18 evening: a SECOND premature "v1 released" declaration
>   (the revision this file carried until 2026-05-23) — withdrawn by
>   PR-6 of the Phase-7-completion effort after the 2026-05-22 audit
>   found ~40% of Phase 7 unbuilt.
> - 2026-05-22 → 2026-05-23 (Phase-7-completion PRs #231..#237 + PR-6):
>   the Generator + Orchestrator were actually completed; THIS is when
>   Phase 7's design intent landed in code.
>
> The project was renamed **ESR → Ezagent** on 2026-05-18 (PRs #113 /
> #114 / #115 / #118), per Allen's pre-public-tunnel rebrand
> directive. All identifiers, paths, env vars, and the HTTP port
> (4000 → 10042) updated; `~/.ezagent/` replaces `~/.esr-ng/`.
> Decision Log entries are preserved with their original "ESR"
> phrasing since they are historical record — the modules they
> reference (`Esr.Bridge.V1Prototype`, `EsrCore`, etc.) all renamed
> in the same drop and the original names are gated against
> resurrection by `apps/ezagent_core/test/invariants/no_v1_bridge_after_cutover_test.exs`.

**Phase 7 completed:** 2026-05-23 (Phase-7-completion 6-PR effort).
**Premature "v1" declared:** 2026-05-18 evening — corrected here.
**Companion docs:** Phase 6 closeout `docs/notes/phase-6-architecture-closeout.md`, SPEC `docs/phase-specs/phase7/SPEC.md` (LOCKED v3), VERIFICATION `docs/phase-specs/phase7/VERIFICATION.md`, PLAN `docs/phase-specs/phase7/PLAN.md`.

---

## Premature v1 declaration — what actually happened

This file declared "Ezagent v1 released, code-complete" on 2026-05-18.
The 2026-05-22 implementation audit
(`docs/notes/phase-7-implementation-audit-2026-05-22.md`) found that
declaration premature. The honest record:

The rc1 blocker list in PR #110 named 5 blockers. PRs #111–#120 closed
the *rebrand + CC-channel-cutover* blockers (PR 32) and **wired the
orchestrator's 7 tool function bodies** (PR 46-impl) — but "wired"
meant the bodies called `Agent.spawn/4` / `RuleStore.add/5` /
`SessionTemplate.compute_version_hash/1` **directly**, bypassing
dispatch + CapBAC, and `update_template` / `save_template_as`
**computed a hash + URI and persisted no row** (`build_working_copy/4`
returned a slice; the tool returned the URI; nothing was written).
The Generator stayed the "minimal PR-41" stub. No `template:` cap was
ever enforced. So "16/16 tools_test.exs passing" gated the *tool
surface declaration*, not a running orchestrator — and PR 49's "e2e
demo recording" could never have been recorded, because the system it
would record did not run end-to-end. The audit verdict: Phase 7 was
~55-60% real.

The 2026-05-18 "code-complete" claim is therefore **withdrawn** and
replaced by the accurate account below.

## What the Phase-7-completion effort shipped

Phase 7's killer feature was **completed** by the 6-PR
Phase-7-completion effort (2026-05-22 → 2026-05-23), specified in
`docs/superpowers/specs/2026-05-22-phase-7-completion.md` (rev 5 — four
rounds of `codex adversarial-review`). The 6 PRs:

| PR | Branch / merge | What it landed |
|---|---|---|
| **PR-1** | #231 (+ #233 hardening, #235 argv fix) | `Ezagent.Behavior.Template` — the real dispatchable template-content Behavior (`:read`/`:write`/`:instantiate`) on both Template Kinds; `{:within_workspace, _}` cap shape; the `AgentTemplate→cc` adapter |
| **PR-2** | #232 | the durable `template_working_copy` Session slice + live→template normalization |
| **PR-3** | #234 | `Ezagent.TemplateTags` registry + `SessionTemplate.persist_version/2` — a SessionTemplate version IS a `kind_snapshots` row, no separate table |
| **PR-4** | #236 | the **Generator, fully** — `Session.spawn_from_template/2` instantiates workers + routing, records lineage, owner-cap preflight |
| **PR-5** | #237 | the **Orchestrator runs** — the 7 tools dispatch-routed through CapBAC; the privileged MCP surface; `update_template` / `save_template_as` now persist real rows |
| **PR-6** | this PR | the 2 remaining session-creation entry points (`SessionTemplate.fork/3` + `.create/3`) + closeout: the missing V1-V5 gating tests + this correction |

The orchestrator is dispatch-routed and CapBAC-gated; the Generator
instantiates real teams; templates persist as `kind_snapshots` rows
and re-instantiate. Phase 7's design intent — the Generator, the live
Orchestrator, the 7 tools, git-style versioning — is now **real in
code**, gated by per-PR tests (`generator_test.exs`,
`orchestrator_mcp_e2e_test.exs`, `behavior/template_test.exs`,
`session_template_fork_create_test.exs`, …).

The supplemental human agent-browser e2e demo (phase7 SPEC §"e2e
demo") remains an **evidence pack**, not a contract gate — it needs a
human to drive an orchestration chat with working `claude` credentials
(SPEC §5 user-assist). The system's behaviour is gated by the
deterministic CI e2e in the meantime.

---

## Phase 7 in one line

Phase 7 = "production-grade session-template generator" + "complete handoff to dev team without Allen as fallback."

The killer feature is multi-agent orchestration where the user spawns a session, dialogues with its embedded orchestrator agent, and that conversation IS the template-refinement process — outputs (configured agent teams + routing matchers) become first-class persisted `SessionTemplate` rows that can be re-instantiated, forked, version-tagged. This feature was DESIGNED in the original Phase 7 SPEC but only became **real in code** with the 2026-05-22→23 Phase-7-completion effort (see §"What the Phase-7-completion effort shipped" above).

The non-feature half is just as important: invariant tests + an `ezagent-developer` Claude Code skill take over the architectural-judgment role Allen used to play in PR reviews. Dev team can ship without escalating.

## What Phase 7 delivered (the 10 architecturally significant pieces)

Items 1–8 below were designed across Phase 7 and recorded in the
Decision Log; their **load-bearing implementations** (the Generator,
the orchestrator persistence + dispatch routing, the enforced template
caps) landed in the Phase-7-completion 6-PR effort, not 2026-05-18.

| | Decision Log | What it is |
|---|---|---|
| 1 | #135 | `Ezagent.WorkspaceRegistry` — 5th ETS Registry, fills the session→workspace back-edge gap that silently broke workspace-scoped routing pre-PR-31 |
| 2 | #136 | `AgentTemplate` + `SessionTemplate` are two new Template Class implementations under the existing `Ezagent.Kind.Template` umbrella in core (no rename / no new namespace needed) |
| 3 | #137 | `Ezagent.Capability.matches?/2` accepts `{:within_session, %URI{}}` and `{:spawned_by, %URI{}}` instance tuples — **this is the Ezagent v1 marker**, retiring the v0 "no delegation" baseline (ARCHITECTURE §17.6) |
| 4 | #139 | `mix ezagent.bootstrap` one-command install + EZAGENT_HOME DB migration mandatory in onboarding |
| 5 | #140 | `esr-developer` Claude Code skill (`.claude/skills/esr-developer/SKILL.md`) is the dev team's "Allen replacement" for architectural judgment, with anti-pattern refusal table |
| 6 | #141 | SessionTemplate fork unit = configuration only (no message history; D7-7) |
| 7 | #142 | Plugin runtime hot-install via `mix ezagent.plugin.install` (no unload — deferred) |
| 8 | #143 | SessionTemplate version = SHA hash (immutable) + tag overlay (mutable); git-style content addressing |

The two not in this table (#138 Federation drop, #144 cross-PR meta-decision) are framing decisions, not standalone artifacts.

## Three trade-offs the dev team should NOT cargo-cult

These are pragmatic choices made under specific constraints. If the dev team encounters similar shaped problems, **don't auto-apply the same answer** — re-derive the trade-off in the new context.

### 1. `:any` wildcard on cap behavior — *circular-dependency workaround, not idiom*

`Ezagent.Entity.User.default_caps/0` uses `kind=:session, behavior=:any` for the structural session-chat baseline. The "right" cap would be `behavior: Ezagent.Behavior.Chat` (specific module). But `Ezagent.Entity.User` lives in `ezagent_domain_identity`, and `Ezagent.Behavior.Chat` lives in `ezagent_domain_instance_message`, which already depends on identity → circular dep at compile time.

Choices considered:
- Module reference (correct): requires breaking circular dep (significant refactor)
- Runtime `BehaviorRegistry` lookup: boot-order fragile
- `:any` wildcard: what we did, scoped to a narrow `:kind` so blast radius is one Kind family

**Don't:** copy `:any` into plugin default caps thinking "default caps idiomatically use `:any`." If your plugin can name the specific module without a circular dep, do so.

**When to revisit:** if the dep graph reorganizes (e.g. `Ezagent.Behavior.Chat` moves to ezagent_core or somewhere upstream of `ezagent_domain_identity`), narrow `User.default_caps` to the specific module ref.

### 2. Dispatch mode `:cast` → `:call` override at transport edge

`Ezagent.Behavior.Chat.@interface[:send]` declares `:send` as `:cast` (fire-and-forget). PR 27 (Feishu inbound) and the orchestrator's tool dispatchers (PR 46) override to `:call` so they can return errors synchronously to the human surface. This is **legitimate** — `Ezagent.Invocation.dispatch/1` accepts any mode the caller passes.

**Don't:** "fix" a transport from `:cast` to "match the interface declaration" — silent-drop on cap denial is the bug we're avoiding.

**Do:** when adding a new transport for inbound user-driven messages (Slack, Discord, email, etc.), use the same `:call` + error-feedback pattern Feishu's `InboundDispatcher` ships.

### 3. `{:spawned_by, _}` cap shape deny-by-default placeholder

PR 42 ships the contract surface for the `{:spawned_by, principal_uri}` cap shape but returns `false` (denies all matches) until PR 40 ships the `Agent.spawned_by` slice field + lineage lookup registry. This is intentional split — the contract is observable + tested NOW; the data path lands in PR 40 without re-touching `matches?/2`.

**Don't:** assume `{:spawned_by, _}` works as documented in SPEC §D7-3 right now. Check `Ezagent.Capability.instance_match?/2` source.

**When fixed (PR 40 merged):** verify lineage tests (`cap_scope_spawned_by_test.exs`) pass; verify orchestrator's `grant_cap` tool respects lineage.

## Cross-PR invariants the dev team MUST keep green

Decision #144 names these. Each has a CI gate test:

| Invariant | CI gate |
|---|---|
| Channel `meta` values are all strings | `apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings" |
| Every user has `session.chat` baseline cap | `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` `describe "default_caps/0 (PR 27)"` |
| `Chat.invoke(:send)` plumbs workspace_uri to Resolver | `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs` |
| Scope-bounded delegation narrows, never broadens | `apps/ezagent_core/test/esr/capability_test.exs` "scope-bounded instance tuples" |
| Feishu inbound deny → text + react back, not silent drop | `apps/ezagent_plugin_feishu/test/feishu_inbound_cap_denial_feedback_test.exs` (TODO if not yet) |
| No `Ezagent.Bridge.V1Prototype` references in apps/ | `no_v1_bridge_after_cutover_test.exs` (ships with PR 32) |
| ws sidecar reaps on stdin EOF | `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs` |
| Workspace isolation cross-PR | covered by `workspace_isolation_test.exs` (above) |

If any of these fails: **stop the merge**. Do not paper over with a `@tag :skip` — the test is the architectural sensor for one of the decisions Allen would have caught in review.

## What did NOT make v1 (deferred to dev team)

These are out of v1 scope. The dev team picks them up or leaves them based on their own roadmap.

> **Note (rc1 downgrade):** the earlier revision of this doc listed
> "CC channel v1→v2 cutover (PR 32)" in this deferred bucket. That
> was wrong — it is a v1 **blocker**, not a deferral. It has been
> moved to §Blocking work for true v1 release at the top of this
> file.

- **Federation** (D7-4): Allen reopens later. Not even prep hooks in v1.
- **Plugin unload** (D7-8): hot install ships; unload requires Kind lifecycle management for live instances of the unregistered Kind — non-trivial. Defer until needed.
- **OTP release / Docker / systemd** (D7-9): `mix ezagent.bootstrap` is sufficient for "dev team installs Ezagent on prod-like host." Full release engineering when scale demands.
- **SessionTemplate three-way merge** (D7-7): message-tier conflict resolution out of scope.
- **Template synthesis** (orchestrator authoring new AgentTemplates inline): blueprint authoring stays human-only in v1.
- **Cross-session agent delegation**: orchestrator acts within its session scope only.
- **Multimedia / streaming** (Phase 8 — see `IMPLEMENTATION_ROADMAP.md §9c`): Dyte as candidate SFU; control plane stays in Ezagent (signaling, auth, session, audit); media bytes go to external SFU. Not abstracting a "generic channel" covering both message-passing and streaming.

## Resume / next-session pointers

If this is being read by a Claude Code session picking up Phase 7 work:

1. Read `docs/notes/phase-7-implementation-audit-2026-05-22.md` — the
   honest as-built audit (what was real vs. stub as of 2026-05-22).
2. Read `docs/superpowers/specs/2026-05-22-phase-7-completion.md` — the
   completion SPEC (rev 5) the 6-PR effort executed.
3. Then `docs/phase-specs/phase7/{SPEC,VERIFICATION,PLAN,DECISIONS}.md`
   for the original design intent (LOCKED v3).
4. `docs/notes/phase-7-resume-state.md` is **superseded** by (1)+(2) —
   its per-PR table reflects the pre-completion state and its header
   contradicts its own status rows; do not resume from it.
5. Activate the `ezagent-developer` skill for per-task guidance.

## What "Ezagent v1" means as a contract to the dev team

A new dev contributor in 2026-06 or later can:

- Clone repo, run `mix ezagent.bootstrap`, have a working Ezagent in under 5 minutes
- Open any `.ex` file in the repo and have their Claude Code agent automatically use `esr-developer` skill for architectural guidance
- Refer to `phase-7-handoff.md` (this file) for the v1 release framing
- Refer to ARCHITECTURE Decision Log entries #135-#144 for the design choices
- Refer to GLOSSARY for the 16 new Phase 7 terms
- Refer to CI invariant tests as the architecture sensors
- Hit a tricky bug → find an actionable answer in `docs/runbook/common-failures.md` or the linked forensic note in ≤2 minutes
- Write a new plugin → `mix ezagent.plugin.install` it into running Ezagent without phx restart

Allen 2026-05-18: "按照我完全离开 Ezagent 不管的思路进行规划" — completely-leave assumption is the design constraint behind every Phase 7 choice.

---

## Closing

Allen has driven 7 phases (0-7) plus the Phase 4.5 in-flight insertion, ~30 Decision Log entries (#114-#144 in this span), and the brainstorm history that anchors every "why X" question dev team will ask.

The dev team's job is to take v1, ship the deferred items in their own time, build Phase 8 (or whatever direction makes sense for them), and keep the cross-PR invariants green. The skill + docs + CI are designed to make that possible without Allen on call.

**Phase 7 completed 2026-05-23** by the 6-PR Phase-7-completion effort
(PRs #231–#237 + PR-6) — the Generator + the live Orchestrator are
real in code. The 2026-05-18 "v1 released, code-complete" declaration
this file originally carried was **premature** (Phase 7 was ~55-60%
real at that point — see §"Premature v1 declaration"); it is corrected
above.

Whether to *label* the result "v1" is a separate, deliberate call —
the deterministic CI e2e gates the orchestrator's behaviour; the
supplemental human agent-browser demo (SPEC §5 user-assist) is the
remaining evidence pack. A release label should follow that demo +
Allen's sign-off, not precede them.

— corrected 2026-05-23 by Phase-7-completion PR-6, executed by Claude
Code (Opus 4.7) per the Phase-7-completion SPEC
(`docs/superpowers/specs/2026-05-22-phase-7-completion.md`) + the
audit (`docs/notes/phase-7-implementation-audit-2026-05-22.md`).
The original 2026-05-18 declaration shipped alongside the ESR →
Ezagent rebrand (PRs #110–#120).
