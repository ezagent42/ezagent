# Agent Definition Contract — Implementation Plan (roadmap)

> **For the implementing agent (codex):** this is a **goal-driven roadmap**, not a line-by-line TDD script. Per the specs' `Plan-time (not spec)` markers and master §0, you resolve exact code-seam mechanics **against live code** as you implement, applying the design principles. Set a `/goal` per phase, generate your own granular TDD steps, and gate each phase on its E2E flow. Load **Skill: ezagent-developer** + **Skill: elixir-phoenix-helper** before any `.ex` edit.

**Goal:** Give ezagent a declarative, backend-swappable, forkable **agent definition contract** (a data manifest over `AgentTemplate`), wired into the live spawn path, with dispatch-backed tools, type-transparent participant invites, and immutable publish/migrate — re-expressing what `seed_autoservice` hard-codes.

**Architecture:** Data manifest (YAML + `soul.md`) = the agent-type body of an entity. `flavor.compile` (pure render) feeds the **existing** spawn/validate/materialize path. Tools = dispatch-backed MCP under CapBAC. Teams reuse existing team-routing. Versioning reuses the immutable `session_template_uri@hash` + a migration ledger. **The runtime (dispatch / CapBAC / Kind / team-routing / CR) is reused, not reinvented.**

**Specs (authoritative):**
- master `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md` (read §0 Review altitude first)
- spec-1 `…-agent-contract-spec1-manifest-compile-fallback.md`
- spec-2 `…-agent-contract-spec2-tools-participant.md`
- spec-3 `…-agent-contract-spec3-versioned-artifact.md`
- codex review records `…-agent-contract-codex-review.md`, `…-codex-rereview.md`

## Global Constraints (every task)

- **Invariants are CI landmines.** Respect P14 dispatch-only, the CapBAC chokepoint (`ctx.caps` is trusted *before* `holds_cap?` — `runtime.ex:405`), no-silent-drop (P18), workspace scoping, entity-type transparency, no live-PTY-mutation, immutable-hash versioning. Run `mix ezagent.check_invariants` + `mix format --check-formatted` + `mix test` before every commit.
- **No raw RPC / eval against a live node** — operate via `mix ezagent <verb>` (CLAUDE.md). E2E faces production through the CLI.
- **No back-compat shims** (SPEC §5.11) — delete legacy paths; don't keep them alongside.
- **`uv run` not python; `pnpm` not npm.** Format only touched files.
- **Sibling-branch check before each phase:** autoservice is a 14-branch family. Before a phase, `git log feat/autoservice-{operator,phaseB-customer-path,cs-stage1}` for any already-built piece the contract must *accommodate* (don't duplicate).

---

## File structure (where the work lands)

| Area | Module(s) | Phase |
|---|---|---|
| Manifest schema + loader + render | `apps/ezagent_core/lib/ezagent/agent_manifest.ex` (new) | 1 |
| flavor compile callback | `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`, `…_codex/…`, `…_curl_agent/…` (+ a `@callback compile/2` on the Template-Class behaviour) | 1 |
| spawn wire + fallback | `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`, `apps/ezagent_core/lib/ezagent/agent_flavor_attributes.ex` | 1 |
| Role.Materialize delete | `apps/ezagent_core/lib/ezagent/role/materialize.ex` (delete); keep `role.ex` | 1 |
| tools schema + MCP inject + participant | `agent_manifest.ex` (tool_decl), flavor compile (MCP emit), `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` (+ `tools/*`) | 2 |
| versioning + migrate ledger | `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`, `…/session_creator/*`, `…/orchestrator/tools/member_template.ex`, working-copy in `behavior/session/config_actions.ex` | 3 |
| skills | `.claude/skills/ezagent-developer/` (update), `.claude/skills/ezagent-admin/` (new) | 4 |

---

## Phase 1 — spec-1: manifest + flavor.compile + executor fallback  →  gates G1, G2, G5

**Set `/goal`:** "Implement spec-1: data AgentManifest + pure flavor.compile + executor fallback wired into the live spawn path, re-expressing seed_autoservice fast/slow; delete Role.Materialize. Done when G1/G2/G5 E2E + units green."

- **T1.1 — `Ezagent.AgentManifest` schema + loader.** Author fields (`name/soul/skills/tools/caps/lifecycle`) + `executor{flavor,params,fallback,on_exhausted}`. `load/1` validates; **rejects a flavor field inside author fields** (runtime twin of the grep-gate). Unit: valid load; reject flavor-in-author, empty `executor.flavor`.
- **T1.2 — slot render.** `AgentManifest.render(soul, slots) → resolved instructions`; flavor-agnostic; spawn-time. **Plan-time decision:** missing-slot policy (error vs passthrough) — pick + document. Unit: substitution + missing-slot.
- **T1.3 — `flavor.compile/2` (pure).** Add `@callback compile(resolved, params) :: {:ok, flavor_data} | {:error}` to the Template-Class behaviour; implement for cc + curl as the **render half** of `template_data_extra/1`, returning flavor_data (no FS/PTY). **Plan-time decision:** exact boundary — compile returns the layers `to_template_data/2` then validates, OR add an explicit derived-config materialization hook (spec-1 §3.3). **G1 golden test:** cc.compile output byte-identical to the autoservice `SoulRenderer` fixture (pull fixture from `feat/autoservice-*`).
- **T1.4 — executor fallback.** Loop candidates calling the **existing** `spawn_from_template_content/4`; fall through per `on:` conditions; `fresh?: false` = success; `on_exhausted` dispatch (fail-closed, no orphan). **Plan-time decision:** residue inventory — make `AgentFlavorAttributes` (and any pre-confirm state) **write-on-success / reset-on-fall-through** (codex round-2 P1-3). Unit: order, fall-through, exhaustion, **no cross-candidate residue**.
- **T1.5 — wire into live spawn path.** Replace the ad-hoc per-flavor branching in `spawn_from_template_content`'s caller with render→loop→record-flavor→on_exhausted. Reuse existing lineage/workspace/sandbox obligations + rollback unchanged.
- **T1.6 — delete `Role.Materialize`.** Grep/test confirm no live caller; delete. **Keep `Ezagent.Role`** (live in `orchestrator_role.ex`/`orchestrator_bootstrap.ex`). *(Tail / spec-1b, gated on cc-orchestrator still spawning: replace `OrchestratorRole.recipe` + bootstrap role-install with an AgentManifest, then retire `Role`.)*
- **Phase-1 E2E gate (VERIFICATION):** re-express `seed_autoservice` fast(curl)+slow(cc) from manifests (**G1**, byte-identical compiled config); `flavor:[cc,codex,curl]` fall-through + exhaustion + no orphan (**G2**); one-field `cc→codex` swap (**G5**). Falsifiers stay red: flavor-in-author-bucket loads; derived config persisted; orphan after exhaustion; compile writing disk; `fresh?:false` double-obligated.

## Phase 2 — spec-2: tools[] + type-transparent participant  →  gate G3

**Set `/goal`:** "Implement spec-2: dispatch-backed MCP tools (ctx.caps=[], holds_cap? auth) + :participant generalizing add_managed_member with provisioned session-scoped admit. Done when G3 E2E + units green."

- **T2.1 — tool_decl schema.** `:action` (requires `action`+`caps`) and `:participant` (requires `ref`); validate in the manifest loader.
- **T2.2 — tool → MCP inject + CapBAC.** flavor.compile (cc/codex) emits one MCP entry per tool; the endpoint dispatches with **`ctx.caps = []`** (authz falls to `holds_cap?` against the agent's Identity grants — codex P1-1). A **tool-less flavor with non-empty `tools[]` fails compile or warns degraded** (P18, G-INV-9). Unit: `:action` denied without grant; **malicious manifest cap denied**; tool-less warns.
- **T2.3 — `:participant` generalize `add_managed_member`.** Spawn-or-invite → **same provisioned admit** (session-scoped join authority + participation caps, never workspace-wide); compensation on failure. **Plan-time decision:** which `Membership` entry point admits a brand-new non-member invitee + whose authority mints the session-scoped grant (codex round-2 P1-2) — resolve per CapBAC principles.
- **Phase-2 E2E gate:** add a manifest-spawned agent + invite an existing human into one session; both indistinguishable in `slice.members` + `$session_members` fan-out (**G3**); the invited human can send/receive/leave but holds **no** workspace-wide cap; a manifest cap the agent was never granted is **denied**. Falsifiers stay red: manifest cap authorizes via ctx.caps; bare-join human can't act / over-granted; tool-less silent drop; author-code tool.

## Phase 3 — spec-3: manifest+team as versioned artifact  →  gate G4

**Set `/goal`:** "Implement spec-3: lean on immutable session_template_uri pin + ledger-tracked migrate_session over update_member_template. Done when G4 E2E + units green."

- **T3.1 — adopt-at-create.** New sessions resolve the **published version** at `create_session/3` and stamp the immutable `session_template_uri@hash`; existing sessions stay frozen. **Plan-time decision:** wire tag→hash resolution into `create_session/3` (the `TemplateTags` API is currently unused — codex round-2 P1-4).
- **T3.2 — per-edit version minting.** A soul/slot edit mints a **new** `source_template_uri` (mirroring the immutable-hash model) so migration is always changed-URI, never the rejected same-URI (`member_template.ex:426`). **Plan-time decision / dependency:** AgentTemplate is not content-hash-versioned on main today — add per-edit version minting (or consume autoservice `release/vN` immutability).
- **T3.3 — `migrate_session` (ledger).** Write a migration **ledger** to the session working-copy (per-member `:pending/:done/:failed`); per changed member call `update_member_template/3`; repoint changed routing rules via `RuleStore` (scoped `created_by == session_uri`); set the pin on full success; **resumable** on partial failure. **Plan-time decision:** partial-migration semantics (resume vs all-or-nothing) — pick + document.
- **Phase-3 E2E gate:** session A at `@h1`; edit + publish → `@h2`; session B adopts `h2`, A frozen at `h1`; `migrate_session(A, @h2)` regenerates the changed member + repoints routes + advances pin, members never lost mid-migration; injected mid-migration failure → ledger resumes (**G4**). Falsifiers stay red: publish mutating a pinned session; migration touching another session's rules; history in a forked/migrated session; live-PTY mutation; same-URI edit; non-resumable partial migration.

## Phase 4 — skills (deliverable, not gated by E2E)

- **T4.1 — update `ezagent-developer`:** add the `AgentManifest` schema, the `flavor.compile` contract + its CI grep-gate, the team-layer reuse pointers.
- **T4.2 — new `ezagent-admin` skill:** non-developer authoring workflow — soul/slot/manifest, team composition (SessionTemplate role-chains + routing rules + legends), CR publish, session migration. No Elixir.

---

## Plan-time decisions register (resolve against live code; apply principles)

| # | Decision | Where | Principle to apply |
|---|---|---|---|
| D1 | missing-slot policy (error vs passthrough) | T1.2 | fail-loud / no-silent |
| D2 | compile→validate→materialize wiring (layers vs new hook) | T1.3 | reuse existing seam; pure render |
| D3 | residue inventory + write-on-success | T1.4 | no-silent-drop / no orphan |
| D4 | Membership entry for new-member invite + grant authority | T2.3 | CapBAC granter authority, no over-grant |
| D5 | tag→hash wiring into create_session/3 | T3.1 | immutable pin; adopt-at-create |
| D6 | AgentTemplate per-edit version minting | T3.2 | immutable-hash versioning |
| D7 | partial-migration semantics | T3.3 | resumable / no half-state |

## Self-review (done)

- **Spec coverage:** every G1–G5 gate maps to a phase; tools/participant/escalation, versioning/migrate, Role split, skills all have tasks. ✓
- **Altitude:** tasks state requirements + plan-time decisions, not invented code (per master §0 + Allen's calibration). ✓
- **Sequencing:** Phase 2 + 3 depend on Phase 1 (compile + manifest); noted. ✓
