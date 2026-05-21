# Your first 30 days on Ezagent

You've just joined the **ezagent** project (Elixir Smart Routing). This doc is a calibrated path through the codebase + culture so you can land a meaningful contribution by end of month one without re-deriving everything from scratch.

Ezagent shipped v1 at Phase 7 closeout (2026-05-18, after 7 phases of brainstorm with Allen, the original architect). Allen has handed off — there's no Allen on call. The system has docs + CI gates + the `esr-developer` skill (your Claude Code agent will auto-load it) covering the architectural rules. Trust those + this doc.

## Week 1 — install + read

**Day 1: bootstrap**

```bash
git clone <repo-url> ezagent
cd ezagent
mix deps.get
mix ezagent.bootstrap          # one-command install (D7-5 / Decision #139)
```

`mix ezagent.bootstrap` runs `ezagent.home.init` + `deps.get` + `ezagent.home.adopt_db` + `ecto.create+migrate` + a health check. End state: DB at `~/.ezagent/<profile>/db/ezagent_core.db` (NOT in repo tree), CLI token minted, ready to `mix phx.server`. If anything fails, the task prints which phase choked.

Then:

```bash
mix phx.server
```

Open `http://localhost:10042/admin` (or `http://100.64.0.27:10042/admin` if remote). LV admin should load.

**Day 2-3: read the architecture in order**

1. `ARCHITECTURE.md` — start with §1-§5 (URI / Invocation / Behavior / Kind / dispatch). 
2. `ARCHITECTURE.md` §7 (CapBAC) — non-negotiable, every dispatch goes through this gate
3. `ARCHITECTURE.md` Appendix B Decision Log — read the SUBJECT lines of #1-#144 to absorb the project's vocabulary
4. `GLOSSARY.md` — bookmark this; you'll come back for unfamiliar terms
5. `docs/notes/phase-7-handoff.md` — the v1 release note explains where the system is now
6. `docs/phase-specs/phase7/SPEC.md` — Phase 7's locked design (multi-agent orchestration + handoff)

**Day 4-5: explore the repo**

Best entry points:
- `apps/ezagent_core/lib/esr/invocation.ex` — the heart. Read `dispatch/1`.
- `apps/ezagent_core/lib/esr/kind/runtime.ex` — the 9-step dispatch flow + `authz_check/4`.
- `apps/ezagent_domain_chat/lib/esr/behavior/chat.ex` — most complex Behavior; well-commented.
- `apps/ezagent_plugin_feishu/` — fullest plugin reference.
- `apps/ezagent_plugin_echo/` — smallest plugin reference.

## Week 2 — pick a small task

Try one of:

1. **Read a forensic note** (`docs/notes/phase-6-architecture-closeout.md` or `docs/notes/phase-7-handoff.md`) and ask yourself: would I have caught this issue in review? Reading these is the closest you'll get to "what did Allen pattern-match."
2. **Write a tiny plugin** following `docs/onboarding/adding-a-plugin.md`. Even an echo-style plugin. Install via `mix ezagent.plugin.install` against running phx.
3. **Add an invariant test** for an existing pattern you find under-tested. Look at `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs` for the canonical pattern.

The point of week 2 is to wrap your hands around the dispatch model. Don't try to land features yet.

## Week 3 — pick up a deferred Phase 7 item

The Phase 7 PLAN.md lists 24 PRs. ~half shipped in the Allen-driven autonomous run (PRs 30-54 with gaps). Check `docs/notes/phase-7-resume-state.md` for the live status table.

Highest-leverage deferred items (pick one):

- **PR 32: CC channel v1→v2 cutover** (LARGE, careful). The largest deferred item. Requires Python bridge HTTP/SSE → WebSocket port + 6 Elixir file migrations + delete v1 app. Will touch live cc-demo agent — pre-audit carefully via subagent, verify v2 e2e BEFORE deleting v1. Allen flagged this as "fresh session needed."
- **PR 38: SessionTemplate Kind + git-hash versioning + tag registry** (M). The production unit of multi-agent orchestration. Builds on PR 37 AgentTemplate.
- **PR 40: `Ezagent.Entity.Agent.spawn/4` + slice workspace_uri + spawned_by fields** (M). Unlocks the orchestrator lineage tracking (PR 42 ships the cap shape; PR 40 fills in the data).
- **PR 46: 7 orchestration MCP tools** (LARGE). The killer feature implementation. Composes 7-1 + 7-2.

## Week 4 — your first real contribution

Pick a deferred PR. Follow the per-PR workflow in `docs/phase-specs/phase7/PLAN.md` (subagent-review pre + post implementation; rebase + admin-merge; append IMPL-7-N to DECISIONS.md if a judgment call surfaces; update PLAN.md row status).

Run the SPEC_REVIEW 8-item checklist (see SPEC §SPEC_REVIEW walkthrough) BEFORE requesting review. Run all 8 invariant tests locally before push (CI runs them too, but local first saves a CI cycle):

```bash
mix test --include slow apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs
mix test apps/ezagent_core/test/esr/capability_test.exs
mix test apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs --include slow
mix test apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs
mix test apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs
mix test apps/ezagent_domain_identity/test/esr/entity/user_test.exs
# Plus the ones your PR adds
```

## Things you'll be tempted to do that are wrong

Each of these matches an "Anti-patterns the skill refuses" entry. They're listed here for visibility — but your Claude Code agent should auto-refuse them when you ask:

- **"I'll just PubSub.broadcast from this plugin to that one"** — bypasses dispatch + CapBAC + audit + idempotency. Decision #127: model the destination as a Receiver Kind.
- **"I'll bypass the cap check with admin_caps()"** — admin_caps is a structural bootstrap, NOT a goto. Use scope-bounded delegation (Decision #137).
- **"I'll write `behavior: :chat` (atom) in the cap struct"** — silently denies because `matches?/2` checks module equality, not atom (Decision #137 atom-shorthand trap).
- **"Structured data goes in channel `meta`"** — silently dropped by claude TUI (Decision #132). Use `content` text + optional `meta.file_path` string.
- **"Inbound transport handler uses `:cast`"** — silent drop on cap denial (Decision #134). Use `:call` + error feedback to original channel.
- **"Let's abstract a generic channel for text + media"** — hides the request-response vs streaming difference (ROADMAP §9c design call).
- **"Make orchestrator deterministic — write the logic in Elixir"** — defeats the killer feature (Decision D7-1).
- **"SessionTemplate fork should include message history"** — explicitly out of scope (Decision #141).
- **"Add `mix ezagent.plugin.uninstall`"** — Kind lifecycle management for live instances is non-trivial (Decision #142 — defer).

## When you're stuck

In order:

1. **Check the `esr-developer` skill** — your CC agent auto-loads it. It has invariants + how-to recipes + debug recipes for the most common symptoms.
2. **Check `docs/runbook/common-failures.md`** — symptom-first list of known failure modes with actionable fixes.
3. **Check forensic notes in `docs/notes/`** — past bugs and their root causes, indexed by topic.
4. **Check the Decision Log** — every architectural choice has a rationale; if your problem touches a decision, the rationale will tell you why it's that way.
5. **Read the test** — invariant tests are written to FAIL when the rule is violated. Reading the test backward tells you what the system is defending against.
6. **Ask a teammate** — even without Allen, your colleagues have collectively built up understanding by working in the system.

## What Ezagent v1 means

Ezagent v1 = "production-grade session-template generator" + "self-sustaining for dev team without Allen as fallback." Phase 7 closeout (2026-05-18) is the v1 release boundary. Your job: keep the invariants green, ship features, build whatever Phase 8+ direction makes sense for the team.

Read `docs/notes/phase-7-handoff.md` for the full v1 framing.

Welcome.
