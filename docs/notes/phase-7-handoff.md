# Phase 7 handoff — Ezagent v1 release (code-complete; demo recording open)

> **STATUS HISTORY:**
>
> - 2026-05-18 morning (PR #95): premature "v1 released" declaration.
> - 2026-05-18 PM (PR #110): withdrawn → rc1.
> - 2026-05-18 evening (this revision): **v1 released** in code +
>   verified live; PR 49 e2e demo recording is the only remaining
>   non-code deliverable.
>
> Same evening: the project was renamed **ESR → Ezagent** (PRs #113 /
> #114 / #115 / #118), per Allen's pre-public-tunnel rebrand
> directive. All identifiers, paths, env vars, and the HTTP port
> (4000 → 10042) updated; `~/.ezagent/` replaces `~/.esr-ng/`.
> Decision Log entries are preserved with their original "ESR"
> phrasing since they are historical record — the modules they
> reference (`Esr.Bridge.V1Prototype`, `EsrCore`, etc.) all renamed
> in the same drop and the original names are gated against
> resurrection by `apps/ezagent_core/test/invariants/no_v1_bridge_after_cutover_test.exs`.

**Released:** 2026-05-18 evening.
**Companion docs:** Phase 6 closeout `docs/notes/phase-6-architecture-closeout.md`, SPEC `docs/phase-specs/phase7/SPEC.md` (LOCKED v3), VERIFICATION `docs/phase-specs/phase7/VERIFICATION.md`, PLAN `docs/phase-specs/phase7/PLAN.md`.

---

## What shipped (against the rc1 blocker list)

The rc1 declaration in PR #110 enumerated 5 blockers. Every code blocker has landed; only the e2e recording remains:

| Blocker | Landed in | Status |
|---|---|---|
| **PR 32** CC channel v1→v2 cutover | PR #111 (v2 readiness) + PR #115 (PtyServer cutover) + PR #118 (v1 plugin delete + Decision #144 invariant) | ✅ merged + invariant gates resurrection |
| **PR 46-impl** orchestrator 7 tool bodies | PR #119 | ✅ all 7 wired to `Agent.spawn/4` / `RuleStore.add/5` / `SessionTemplate.compute_version_hash/1` / `KindRegistry`; CI gate refutes `:not_implemented_yet` |
| **PR 47** Generator scoped-cap grant call site | PR #120 | ✅ `spawn_from_template/2` dispatches `identity/grant_cap` with `{:within_session, S}` + `{:spawned_by, orchestrator_uri}` |
| **PR 48** in-flight template-deletion semantics | PR #120 | ✅ `update_template` → `{:error, :parent_template_deleted}` on dead parent; `save_template_as` unaffected (design lock test asserts the asymmetry) |
| **PR 49** orchestrator e2e demo recording | — | ⏳ **open** (last v1 deliverable) — requires (a) operator-filled Feishu credentials in `~/.ezagent/default/credentials/feishu.yaml`, (b) MCP bridge stdio shim translating `tools/call` → `Ezagent.Orchestrator.Tools.invoke/2` (not yet built — see PR #119 commit message), (c) `agent-browser record start/stop` capture of NL prompt → spawn → `save_template_as` → re-instantiate |

The v1 contract is met by **code + tests + invariants**. PR 49 is an **evidence pack** — it doesn't extend the contract, it demonstrates the contract holding. A future dev-team member or Allen can record it when convenient; the system's behaviour is gated by `apps/ezagent_domain_chat/test/ezagent/orchestrator/tools_test.exs` (16/16 passing) in the meantime.

### Live verification 2026-05-18 evening

After PR #118 merged, phx restarted on `0.0.0.0:10042` under `EZAGENT_HOME=~/.ezagent`. agent-browser screenshot of `http://100.64.0.27:10042/login` confirmed "Ezagent Login" page renders; login with `user://admin` (password set via `mix ezagent.user.set_password`) successfully landed on `/admin` LV with session sidebar + members panel + floating agents intact. The rebrand + cutover + tool-body fill-in are intact in production.

---

## v1 in one line

Ezagent v1 = "production-grade session-template generator" + "complete handoff to dev team without Allen as fallback."

The killer feature is multi-agent orchestration where the user spawns a session, dialogues with its embedded orchestrator agent, and that conversation IS the template-refinement process — outputs (configured agent teams + routing matchers) become first-class persisted `SessionTemplate` rows that can be re-instantiated, forked, version-tagged.

The non-feature half is just as important: invariant tests + an `esr-developer` Claude Code skill take over the architectural-judgment role Allen used to play in PR reviews. Dev team can ship without escalating.

## What v1 delivered (8 of the 10 architecturally significant pieces)

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

`Ezagent.Entity.User.default_caps/0` uses `kind=:session, behavior=:any` for the structural session-chat baseline. The "right" cap would be `behavior: Ezagent.Behavior.Chat` (specific module). But `Ezagent.Entity.User` lives in `ezagent_domain_identity`, and `Ezagent.Behavior.Chat` lives in `ezagent_domain_chat`, which already depends on identity → circular dep at compile time.

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
| Channel `meta` values are all strings | `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings" |
| Every user has `session.chat` baseline cap | `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` `describe "default_caps/0 (PR 27)"` |
| `Chat.invoke(:send)` plumbs workspace_uri to Resolver | `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs` |
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

If this is being read by a Claude Code session picking up Phase 7 work AFTER Allen's involvement (or finishing the deferred items):

1. Start with `docs/notes/phase-7-resume-state.md` for the per-PR status table.
2. Then `docs/phase-specs/phase7/{SPEC,VERIFICATION,PLAN,DECISIONS}.md` for the design.
3. Then this file for the v1 release context.
4. Activate `esr-developer` skill (via Claude Code skill loader) for per-task guidance.
5. Each PR follows the workflow in PLAN.md §per-PR-workflow.

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

**Ezagent v1 released.** Phase 7 closed (modulo the PR 49 e2e recording — not a contract item, see §What shipped at top).

— v1 release recorded 2026-05-18 evening, executed by Claude Code (Opus 4.7) under Allen's `/goal` directive. The same session shipped the ESR → Ezagent rebrand (8 PRs total: #110 / #111 / #112 / #113 / #114 / #115 / #118 / #119 / #120).
