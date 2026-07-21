---
name: ezagent-developer
description: >-
  Use whenever working on the ezagent codebase — touching any .ex file under
  apps/, modifying ARCHITECTURE.md/GLOSSARY.md/IMPLEMENTATION_ROADMAP.md/
  docs/notes/uri-design.md, reviewing PRs, or answering questions about
  Ezagent patterns. Ezagent is a multi-agent platform with three-tier
  architecture (core / domain / plugin), strict dispatch model, capability-
  based access control (CapBAC), Behavior+Kind+URI primitives following
  SPEC v2/v3 (6 schemes, 3-segment authority for per-tenant schemes,
  query-string actions), and ~17 cross-PR architectural invariants captured
  in CI gates. This skill loads the invariants the dev team must respect,
  the anti-patterns to refuse, the how-to recipes for common contributor
  tasks, and pointer index to forensic notes. Trigger on any Ezagent
  contribution because the invariants are silent landmines.
---

# ezagent-developer

You are working in the **ezagent** repo. The architectural rules below were locked across 7 phases of brainstorm with Allen, then re-shaped in PRs #140–#149 (URI SPEC v2 migration, 2026-05-19), Phase 9 (#155-#170 tenant isolation), the 2026-05-25 caps-cleanup batch, and most recently the **Router/Behavior/Kind self-built architecture (SPEC PR #445, 2026-05-28; Phase 1-4 migration PRs #451-#469)**. Allen is no longer hand-walking each PR — your job is to keep the system honest without breaking the invariants he encoded as CI gates + Decision Log entries + the normative SPEC v2/v3 + 2026-05-28 SPEC doc.

> **2026-05-29 contract change — read this BEFORE writing any Behavior or Kind code.** `use Ezagent.Lifecycle` is now the **SOLE developer-facing way to author a Behavior**. The `use Ezagent.ActionSet` + `action/3` + hand-rolled `state_slice`/`init_slice`/`invoke/4` surface is the **INTERNAL ENGINE** the Lifecycle macro compiles down to (R10-3) — developer/plugin/domain code NEVER writes it. A Lifecycle module holds two state containers — `state` (PERSISTENT, auto-snapshotted) and `transients` (NEVER persisted; PIDs/refs/ETS/ports/subprocesses/monitors, rebuilt every start in `activate/2`) — and exposes hooks `create` / `activate` / `handle_<action>` / `handle_signal` / `activated` / `pre_handle` / `post_handle` / `deactivate` / `destroy`. This kills the cold-restart bug class (#110/#113/#114) by construction. The effect grammar is UNCHANGED plus `{:set_transient, k, v}`. **Always read `references/lifecycle.md` first if writing Behavior code.** The Phase C gate `mix ezagent.check_invariants.lifecycle` HARD-fails CI on any developer-tier `use Ezagent.ActionSet` / `init_slice` / `def state_slice` / `invoke/4` / boot-hook re-introduction, plus the §11 NP-1/2/3 naming lints. Reference: `ARCHITECTURE.md §6.0.7`, SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`, Decision Log #153. (The underlying engine: `references/new-contract.md`, SPEC `2026-05-28-router-behavior-kind-architecture.md`, Decision #147-#152.)

Read the relevant references before writing code. **The most expensive bugs in this codebase are invariant violations that pass type-check + tests-pass and only surface as silent drops in production.**

## How to use this skill

For every task:

1. Read **`references/design-principles.md`** — the authoritative consolidated set (P1-P27). Skim in ~10 min and have them in mind.
2. Read **`references/architecture-invariants.md`** for the CI-gate detail behind dispatch / cap / workspace / persistence principles.
3. Read **`references/three-tier-structure.md`** — every contribution lives in one of `core / domain / plugin`. Pick the right one before writing a line of code.
4. Check **`references/anti-patterns.md`** — if the task description matches one, push back BEFORE writing code.
5. Use **`references/how-to-recipes.md`** for common contributor tasks (add plugin, Kind, Behavior, Template Class, routing rule, invariant test, ExternalMirror adapter).
6. When debugging, jump to **`references/debug-recipes.md`** — symptom-first.
7. For UI/frontend work, load **`references/ui-contract.md`** — 3-layer architecture + nested shell + DO/DON'T lists.
8. **Before ANY code that grants / revokes / checks / declares a capability, read `references/capbac.md`.** CapBAC is the most pitfall-prone area in the repo (granter≠caller, `ctx.caps` is the authorizer, the `Ezagent.Identity.Grant` chokepoint + tag decision tree, `rule_cap_bounded?`, the system-principal Catalog, Decision #154). The §9 pitfalls list is the set of mistakes that have actually shipped. **Cap-signing status (do NOT re-hallucinate):** cap-signing **Path A is DONE + merged** (PR #1457, 2026-07-18) — caps are **born-signed and strictly crypto-verified** with per-Kind ed25519 keys (`Ezagent.Cap.Authority` + `Ezagent.Cap.Verifier`). There is **no permissive verify, no dual-read, no `require_signature:false`, no pending "cap-signing strict"**, and `Ezagent.Cap.verify/1` is retired. **Path B** (isolated external signer, for in-VM-malicious defense) is **deferred**. See `references/capbac.md` §4.6 + GLOSSARY Decision #164 + ARCHITECTURE §7.8.
9. Cross-reference **`references/pointer-index.md`** for the durable record (Decision Log, forensic notes, SPEC, current-state snapshot).
10. **Adding a new agent type, or a render/feed/transport capability? Run the §"Extending agents without violating the architecture" pre-flight checklist below** (depth in `references/extending-agents.md`) — it catches the two violations that pass tests but break the architecture.

For larger changes, also load `docs/phase-specs/phase7/SPEC.md` and `docs/phase-specs/phase7/VERIFICATION.md` directly — they have the V1-V5 acceptance criteria the system was built against, and `docs/notes/uri-design.md` §5 — the URI SPEC v2/v3 normative spec.

## File layout

```
ezagent-developer/
├── SKILL.md                          ← you are here (navigation + project conventions)
└── references/
    ├── design-principles.md          ← P1-P27 (Groups A-E)
    ├── architecture-invariants.md    ← 20 numbered invariants + CI gates
    ├── three-tier-structure.md       ← core / domain / plugin boundary rules
    ├── anti-patterns.md              ← what the skill refuses
    ├── how-to-recipes.md             ← contributor recipes (add plugin / Kind / Behavior / …)
    ├── debug-recipes.md              ← symptom-first debug
    ├── ui-contract.md                ← 3-layer UI + nested shell + DO/DON'T
    ├── slice-and-snapshot.md         ← Behavior slice + Kind snapshot model + recurring bug class (ENGINE-internal now)
    ├── lifecycle.md                  ← post-2026-05-29 Lifecycle API: the SOLE developer surface (use Ezagent.Lifecycle + two-container state + hooks + §11 naming)
    ├── new-contract.md               ← the INTERNAL engine (R/B/K) the Lifecycle macro compiles down to (use Ezagent.ActionSet + action/3 + effects)
    ├── extending-agents.md           ← new agent type = role × flavor (never own Kind); mechanism ≠ business — worked examples + levers (checklist inline in SKILL.md)
    └── pointer-index.md              ← durable record + current state
```

The references are organized so you only load the file relevant to your current task — keeping the active context lean. The summary table below tells you which file is authoritative for which question.

## Quick-reference summary

| If your question is about… | Authoritative file |
|---|---|
| "Why is X the rule?" | `references/design-principles.md` (P1-P27) |
| "What CI gate enforces it?" | `references/architecture-invariants.md` |
| "Where does my code live?" | `references/three-tier-structure.md` |
| "Is this pattern OK?" | `references/anti-patterns.md` |
| "How do I add X?" | `references/how-to-recipes.md` |
| "Why isn't my thing working?" | `references/debug-recipes.md` |
| "How do I render this LV/component?" | `references/ui-contract.md` |
| "What's a slice / why is the snapshot doing weird things?" | `references/slice-and-snapshot.md` (engine-internal) — for developer state, see `references/lifecycle.md` two-container model |
| "Where's the spec for X?" | `references/pointer-index.md` |
| "How do I write a Behavior?" | `references/lifecycle.md` (developer surface — `use Ezagent.Lifecycle`) |
| "How does the engine the macro compiles to work?" | `references/new-contract.md` (R/B/K internals) |
| "What's the effects vocabulary?" | `references/lifecycle.md` + `references/new-contract.md` §"Effect vocabulary" |
| "state vs transients / cold-restart bug class / activate?" | `references/lifecycle.md` two-container model |
| "§11 naming (NP-1/2/3) / why was it renamed?" | `references/lifecycle.md` §"naming principles" |
| "How do I grant/revoke/check a capability? Which authority do I use?" | **`references/capbac.md`** (READ before any grant/cap code — the 3 roles, the `Ezagent.Identity.Grant` chokepoint + tag decision tree, `rule_cap_bounded?`, default_caps, the gates, the pitfalls) |
| "What's a system principal / why is this `granted_by` wrong / Decision #154?" | `references/capbac.md` §1/§7 |
| "I'm adding a new agent type / coupling a mechanism to a business persona — is this OK?" | §"Extending agents…" below (checklist) + `references/extending-agents.md` (worked examples) |

## Extending agents without violating the architecture

Two recent PRs were complete, working, and well-tested — yet had to be re-shaped
because they crossed two architectural lines that "tests pass" never catches (P6).
Run this **pre-flight checklist BEFORE writing code** for any agent / feed /
render task; any "yes" in the STOP column means re-align with the lead (台账 P0)
first. Worked examples + the concrete levers (which docs/skills, the SPEC→codex-
review→implement gate) are in `references/extending-agents.md`.

| Check | If yes → |
|---|---|
| **1. Adding a new `Ezagent.Entity.*` Kind** (e.g. `Entity.Salesperson`) for an agent type? | **STOP.** An agent type is a **role × flavor** on the unified `Entity.Agent`, not a new Kind (see Principle 1). |
| **2. Bundling business logic into a platform path** — a generic mechanism (render/feed/transport/dispatch) gated by, or routed through, a specific business persona/producer/cap (`:salesperson`)? | **STOP.** Separate the generic **mechanism** from the **producer** that consumes it (see Principle 2). |
| **3. Does a generic mechanism for this already exist?** `git grep -n "render\|json-render\|feed_encoding\|RoleRegistry\|agent_flavors" -- apps/` | If yes → consume it, don't fork a parallel one (台账 P2). |
| **4. Does this make a plugin author learn one MORE concept, or one FEWER?** (P8) | One more → reject. New Kind = one more; role-on-existing-flavor = one fewer. |

**Principle 1 — a new agent type is a role × flavor, never its own Kind.** `agent
= role (what it does) × flavor (how it executes — cc/codex/py/curl/native, all
hosted by the unified `Ezagent.Entity.Agent`)`. Register a **role recipe** via the
`roles/0` plugin callback (behaviors loaded per-instance, role-foundation #54); do
NOT write an `Entity.<Type>` module. Own-Kind-per-type was retired in P4b
(`Entity.PyAgent` → unified `Entity.Agent`); it breaks P1/P24/P9 and grants
unwanted chat-principal semantics. Canonical fix: kanban-as-role (`kanban-manager`
recipe on the `native` flavor). A new Kind is justified ONLY for a genuinely new
**non-agent primitive** (P9/P10 + lead sign-off), never for an agent type.

**Principle 2 — platform mechanism must be separable from business logic.** A
generic capability (render transport, feed encoder, dispatch path) is
producer-agnostic — any agent produces into it, it names no persona and is NOT
gated by a business-specific cap. The business agent is a fixture/role that
*consumes* it. Coupling forces the next producer to re-implement or impersonate
(P1/P3) and makes the mechanism untestable in isolation (P12). The render-card
path shipped transport-only in #1035 (`feed_encoding.ex` reads `body["render"]` for
every message — no `:salesperson` cap).

## Key invariants at a glance (full list in references/architecture-invariants.md)

1. **Dispatch is the only path** — no `PubSub.broadcast` between Kinds; everything goes through `Ezagent.Invocation.dispatch/1`.
2. **Capabilities are module references, not atoms** — `behavior: Ezagent.ActionSet.Chat`, NOT `behavior: :chat`.
3. **Channel notification `meta` is `Record<string, string>`** — non-string values cause silent drop.
4. **Workspace scoping enforced via `Ezagent.WorkspaceRegistry`** — bind every spawned session.
5. **Scope-bounded delegation caps narrow, never broaden.**
6. **User Kind structural baseline cap** — `default_caps/0` is non-negotiable.
7. **Dispatch mode is a transport choice** — `:cast` vs `:call` decided by inbound surface.
8. **Plugin authoring contract** — declare don't call; no top-level plugin schemes.
9. **No silent drops at user-facing surfaces** — inbound transports surface errors with reactions.
10. **SessionTemplate fork = config only** — no message history.
11. **URI shape — 3-segment authority for per-tenant schemes + 6-scheme allowlist + query-string action.**
12. **Synthetic singletons dissolved** — Behaviors live on the actual scope-owning Kind.
13. **Cross-workspace dispatch requires structural authority** — distinct `:cross_workspace_denied` error.
14. **Per-tenant DB tables MUST carry `workspace_uri NOT NULL`.**
15. **ExternalMirror Domain owns every outbound mirror** — no plugin-owned one-offs.
16. **No `Phoenix.PubSub.subscribe` in Bindings** — use `Publisher.subscribe_from/3`.
17. **No re-entry to dispatch from `target_ownership_check/2` or `event_to_payload/1`.**
18. **Sibling slice reads are opt-in via `reads_sibling_slices/0`** (2026-05-26) — declare keys; default `[]`; no `:all_slices` escape hatch.
19. **Capability inputs flow through `Ezagent.Capability.normalize!/2`** (2026-05-26) — single chokepoint converting struct/atom-keyed/string-keyed → canonical `%Capability{}`. Revoke matches by 4-tuple identity_key, NOT full struct.
20. **Behaviors with DB projections implement `reconcile_after_load/2`** (2026-05-26) — snapshot merge would otherwise overwrite fresh DB reads; reconcile runs AFTER merge to union/dedupe DB rows added between snapshot and restore.

Plus the 2026-05-25 caps-cleanup additions (see references/pointer-index.md §"Current state"): `lv_cli_parity`, `workspace_sot`, `no_admin_caps_fallback`, `cap_check_only_at_chokepoint`, `no_wildcard_system_principals`, `dispatch_uses_required_caps`.

## Project conventions

- **Local dev boot / `mix run` / e2e: keep the dev DB migrated; `EZAGENT_SIGNING_SEED_V1` is NO LONGER needed (superseded by cap-signing Path A, PR #1457, 2026-07-18).** The #1399 "Phase-4 master-seed" scheme (`export EZAGENT_SIGNING_SEED_V1=<≥32 bytes>`, `:missing_seed` boot crash, dual-read / `require_signature:false` / "verify-fail soft") is **retired** — Path A generates a **per-Kind ed25519 key on genesis** and persists it DB-backed in `kind_cap_authorities` (`Ezagent.Ecto.KindCapAuthority`), so there is **zero** `EZAGENT_SIGNING_SEED_V1` reference left in `apps/` prod code or `config/`. Any wrapper script that still exports it is a harmless no-op for cap-signing; don't rely on it and don't reintroduce a "signing seed" env requirement. **Still true:** (a) run `mix ecto.migrate` so the cap-signing + recipe tables exist (`kind_cap_authorities`, `recipe_cap_bindings`) — a stale DB crash-loops boot on missing tables; (b) **`EZAGENT_PAT_PEPPER_V1`** is a SEPARATE secret (PAT-token pepper, `entity/token.ex`), still required where CLI/PAT token verification runs — do not conflate it with cap-signing. Current cap-signing reference: `references/capbac.md` §4.6.
- **`uv run` not `python` / `python3`** — global hook blocks raw python invocations; always prefix with `uv run`.
- **`pnpm` not `npm`** — same project convention.
- **Formatter noise policy** — day-to-day patches should format only touched files (`mix format path/to/file.ex ...`) so a small behavior fix does not absorb existing formatter debt. Keep `mix precommit` / CI as the final gate, but prefer a check-only formatter gate (`mix format --check-formatted`) over an auto-rewriting gate when maintaining automation. If full-project `mix format` would rewrite unrelated files, do not include that mechanical churn in the feature/fix PR; open a separate "format baseline" PR to normalize the repo first, then future commits can stay clean.
- **Running gates locally — run the fast subset ALWAYS, and a killed run is NEVER a pass.** Before you push, ALWAYS run the fast deterministic gate `mix ci.fast` — it runs the EXACT set the CI `gate` job runs (`check_invariants` + `socialware.check` + the arch/invariant ExUnit subset, ~1–2 min), the never-flaky gates that catch the class of failure that slips to review when the full suite dies early (a red arch/invariant test). There is no excuse to skip it. Because even `ci.fast` can approach the ~120s default bash-tool timeout under machine load, run it with an EXPLICIT timeout (`timeout: 300000`), never the bare default. The SLOW full gate — `mix precommit` / `mix ci.local` / the full test suite — is 500s+ and WILL blow past the default 120s: run it EITHER with an explicit long timeout (`timeout: 600000`) OR in the background (`run_in_background`) and poll to completion. **A timeout / killed command is NOT a pass.** Never claim "precommit passed" or "tests green" from a run that was cut off at the timeout — a timeout tells you NOTHING about the result. If it didn't finish, say so plainly and re-run it correctly.
- **`agent-browser` for any UI/web debugging** — never iterate via "try it and tell me what you see"; launch headless Chrome from the agent side and screenshot. Memory `feedback_agent_browser_debug`.
- **Bilingual docs convention**: `docs/<name>.md` (English) + `docs/<name>.zh_cn.md` (Chinese) parallel files; send the `.zh_cn.md` via Feishu; sync edits both ways. Memory `feedback_bilingual_docs_convention`.
- **Decision Log new entry**: append to ARCHITECTURE.md Appendix B with next sequential number; format follows existing entries (subject line in bold + WHY + DRIFT DEFENSES). Phase 7 added #135-#144; SPEC v2 migration (PRs #140-#149) added documentation deltas to existing entries rather than new numbers.
- **Forensic notes go in `docs/notes/`** — not inline in code comments. Cross-link from Decision Log entry + (where relevant) from a moduledoc.
- **Remote browser URLs use 100.64.0.27 (Tailscale IP), not localhost** — Allen accesses remotely. Memory `feedback_remote_browser_ip`.
- **URI shape (SPEC v3, Amendment 2 — Allen 2026-05-21)**: per-tenant schemes carry the **workspace as the FIRST authority segment**: `<scheme>://<workspace>/<type>/<name>` (3-segment), so workspace identity is O(1)-extractable — `entity://<ws>/<type>/<name>`, `session://<ws>/<template>/<name>`, `template://<ws>/<type>/<name>`, `resource://<ws>/<type>/<name>`. `workspace://` + `system://` stay 2-segment; `?action=behavior.action` for invocation; six schemes only (`entity, workspace, session, template, resource, system`). **Authoritative = `apps/ezagent_core/lib/ezagent/uri.ex` moduledoc** (builder arg order `URI.template(workspace, type, name)`; `workspace_name!/1` reads segment 1). (Was documented type-first here and in `uri-design.md` §5.15 — that draft order was flipped by Amendment 2; **corrected 2026-06-22**, out-of-scope of task #84.)
- **No back-compat shims** — per SPEC v2 §5.11 + memory `feedback_let_it_crash_no_workarounds`: delete legacy paths; don't keep them alongside new ones. Existing DB data is wiped + rebuilt on URI migrations.
- **Subagent dispatch**: when dispatching to a subagent that touches ezagent code, ALWAYS pass `Skill: ezagent-developer` and `Skill: elixir-phoenix-helper` in the subagent prompt. Without them, the subagent writes stale 2023 Elixir or ignores invariants. Memory `feedback_subagent_must_load_project_skills`.
- **No hacks against the live node — operate through the CLI / sanctioned dispatch (Allen 2026-06-03).** Do NOT drive the running node with raw `:rpc.call` + `:erlang.binary_to_term` / `SpawnRegistry.spawn` / arbitrary eval to "make it work" (e.g. force-rehydrating a session). That bypasses authorization (the create entry + CapBAC) and has side effects (an unsafe `binary_to_term` mutates the node's atom table, masking the real bug). RPC is for READ-ONLY forensics only. Operator actions go through `mix ezagent <verb>` (dispatch → authz). If a sanctioned CLI path is missing, that's the bug to fix — don't route around it. If you find a defect this way, fix the production flow + add a regression test (`feedback_e2e_faces_production`, `feedback_e2e_failure_earns_unit_test`), then re-verify through the sanctioned path. Raw distribution/RPC access being open at all is itself a hardening gap (see the RPC-console hardening task).

## When this skill conflicts with what's in front of you

Code wins. If you find a discrepancy between this skill's description of an invariant and what the code actually does, **the code is authoritative**. Either:
- The invariant changed and the skill wasn't updated (open a PR updating the skill)
- The code drifted from the invariant (open a PR fixing the code; the skill describes intent)

Don't silently change either to match. Surface the discrepancy in the PR description so a reviewer (or future Claude with context) can adjudicate.

## See also

- Sibling skill: `elixir-phoenix-helper` — loaded together with this skill for any Elixir/Phoenix patch.
- Sibling skill: `commit-work` — for crafting commits that match Allen's Conventional Commits + Co-Authored-By style.
