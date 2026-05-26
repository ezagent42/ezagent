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

You are working in the **ezagent** repo. The architectural rules below were locked across 7 phases of brainstorm with Allen, then re-shaped in PRs #140–#149 (URI SPEC v2 migration, 2026-05-19), Phase 9 (#155-#170 tenant isolation), and the 2026-05-25 caps-cleanup batch. Allen is no longer hand-walking each PR — your job is to keep the system honest without breaking the invariants he encoded as CI gates + Decision Log entries + the normative SPEC v2/v3 doc.

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
8. Cross-reference **`references/pointer-index.md`** for the durable record (Decision Log, forensic notes, SPEC, current-state snapshot).

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
    ├── slice-and-snapshot.md         ← Behavior slice + Kind snapshot model + recurring bug class
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
| "What's a slice / why is the snapshot doing weird things?" | `references/slice-and-snapshot.md` |
| "Where's the spec for X?" | `references/pointer-index.md` |

## Key invariants at a glance (full list in references/architecture-invariants.md)

1. **Dispatch is the only path** — no `PubSub.broadcast` between Kinds; everything goes through `Ezagent.Invocation.dispatch/1`.
2. **Capabilities are module references, not atoms** — `behavior: Ezagent.Behavior.Chat`, NOT `behavior: :chat`.
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

- **`uv run` not `python` / `python3`** — global hook blocks raw python invocations; always prefix with `uv run`.
- **`pnpm` not `npm`** — same project convention.
- **`agent-browser` for any UI/web debugging** — never iterate via "try it and tell me what you see"; launch headless Chrome from the agent side and screenshot. Memory `feedback_agent_browser_debug`.
- **Bilingual docs convention**: `docs/<name>.md` (English) + `docs/<name>.zh_cn.md` (Chinese) parallel files; send the `.zh_cn.md` via Feishu; sync edits both ways. Memory `feedback_bilingual_docs_convention`.
- **Decision Log new entry**: append to ARCHITECTURE.md Appendix B with next sequential number; format follows existing entries (subject line in bold + WHY + DRIFT DEFENSES). Phase 7 added #135-#144; SPEC v2 migration (PRs #140-#149) added documentation deltas to existing entries rather than new numbers.
- **Forensic notes go in `docs/notes/`** — not inline in code comments. Cross-link from Decision Log entry + (where relevant) from a moduledoc.
- **Remote browser URLs use 100.64.0.27 (Tailscale IP), not localhost** — Allen accesses remotely. Memory `feedback_remote_browser_ip`.
- **URI shape (SPEC v3)**: per-tenant schemes are `<scheme>://<type>/<workspace>/<name>` (3-segment); `workspace://` + `system://` stay 2-segment; `?action=behavior.action` for invocation; six schemes only (`entity, workspace, session, template, resource, system`). Detail in `docs/notes/uri-design.md` §5.
- **No back-compat shims** — per SPEC v2 §5.11 + memory `feedback_let_it_crash_no_workarounds`: delete legacy paths; don't keep them alongside new ones. Existing DB data is wiped + rebuilt on URI migrations.
- **Subagent dispatch**: when dispatching to a subagent that touches ezagent code, ALWAYS pass `Skill: ezagent-developer` and `Skill: elixir-phoenix-helper` in the subagent prompt. Without them, the subagent writes stale 2023 Elixir or ignores invariants. Memory `feedback_subagent_must_load_project_skills`.

## When this skill conflicts with what's in front of you

Code wins. If you find a discrepancy between this skill's description of an invariant and what the code actually does, **the code is authoritative**. Either:
- The invariant changed and the skill wasn't updated (open a PR updating the skill)
- The code drifted from the invariant (open a PR fixing the code; the skill describes intent)

Don't silently change either to match. Surface the discrepancy in the PR description so a reviewer (or future Claude with context) can adjudicate.

## See also

- Sibling skill: `elixir-phoenix-helper` — loaded together with this skill for any Elixir/Phoenix patch.
- Sibling skill: `commit-work` — for crafting commits that match Allen's Conventional Commits + Co-Authored-By style.
