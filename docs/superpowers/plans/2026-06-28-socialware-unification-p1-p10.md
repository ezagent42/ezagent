# Socialware Unification P1-P10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the socialware unification P0-P10 on `implement/socialware-unification-p1-p10`, with phase commits and a green P10 automated E2E gate.

**Architecture:** Keep `Ezagent.Entity.Session` as the host, represent socialware as config-as-data in `apps/ezagent_domain_socialware`, install socialware through existing per-instance mount and `ConfigObject` mechanisms, and keep plugin/domain/core dependency boundaries acyclic. P10 adds a codex-flavored orchestrator by mirroring the cc recipe/seed while reusing the shared tool execution and bridge-token substrate.

**Tech Stack:** Elixir/Phoenix umbrella, Ecto, ExUnit, Ezagent Kind/Behavior/Invocation, ConfigStore/ConfigObject, CapBAC, Phoenix world plugin, codex and cc plugins.

## Global Constraints

- Base branch: `origin/main`; target branch: `implement/socialware-unification-p1-p10`.
- Do not self-merge and do not open/merge a PR; hand branch back to coordinator.
- Use local project skills: `ezagent-developer`, `ezagent-socialware`, `elixir-phoenix-helper`; AGENTS.md rules override generic guidance.
- No `socialware://` scheme; socialware definitions use `config://<ws>/socialware/<name>` ConfigStore subjects.
- P1-P8 introduce no named `operator` or `supervisor` responsibility; `supervisor` becomes named only in P9.
- P8a security gate lands before P7.
- P10 assertions must exercise public author/install/dispatch entrypoints; no hand-inserted install records, direct `:kind_base` writes, or hand-written orchestrator replies.
- Cap grants/revokes must use `Ezagent.Identity.Grant`; no scattered `Capability.matches?/2` authority gates outside sanctioned chokepoints.
- Developer-authored Behaviors use current project conventions and must satisfy `mix ezagent.check_invariants.lifecycle`.
- Final verification includes `mix precommit`; phase gates also include `mix compile --warnings-as-errors`, `mix ezagent.arch.scan`, `mix ezagent.check_invariants`, `mix ezagent.check_invariants.lifecycle`, `mix ezagent.uri_query.scan`, `mix ezagent.doc.scan`, and touched-app tests unless the phase is docs-only.

---

### Task 0: Baseline And SPEC Tracking

**Files:**
- Read: `docs/together/2026-06-26/handoffs/socialware-p1-p10-codex-handoff.md` from `origin/docs/socialware-app-unification`
- Read: `docs/together/2026-06-26/specs/socialware-unification.md` from `origin/docs/socialware-app-unification`
- Track: this plan file

**Interfaces:**
- Consumes: handoff and SPEC phase table.
- Produces: working branch baseline and gate log.

- [ ] Run `git status --short --branch` and confirm clean target worktree on `implement/socialware-unification-p1-p10`.
- [ ] Run baseline compile/invariant commands before code changes; record pre-existing failures separately from phase failures.
- [ ] Use known-flake list from handoff only for test names explicitly listed there.

### Task P0: Concepts Documentation

**Files:**
- Create: `docs/socialware-concepts.md`
- Create: `docs/socialware-concepts.zh_cn.md`

**Interfaces:**
- Consumes: SPEC §0 concepts.
- Produces: standalone authoring guide describing base/socialware/fixture, shape, install model, and anti-patterns.

- [ ] Write English concepts doc lifted from SPEC §0, with code-verified taxonomy: five bases, chat as world Conversation, kanban as recipe-only today, Turn as shape, Surface as base, autoservice as fixture.
- [ ] Write Chinese parallel doc with the same substance.
- [ ] Gate: `test -f docs/socialware-concepts.md && test -f docs/socialware-concepts.zh_cn.md`.
- [ ] Gate: `rg -n "base|socialware|fixture|Turn|Surface|kanban|autoservice" docs/socialware-concepts*.md`.
- [ ] Commit as `[P0] docs: add socialware concepts guide`.

### Task P1: Rename Message Visibility `operator_only` To `internal`

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/message.ex`
- Modify: `apps/ezagent_core/lib/ezagent/message_store.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/settlement_message.ex`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/*.ex`
- Modify: migrations creating or backfilling `messages.visibility`
- Modify: tests referring to `operator_only`
- Modify: `apps/ezagent_core/test/invariants/no_customer_concept_test.exs`

**Interfaces:**
- Consumes: current `Ezagent.Message.visibility :: :external_visible | :operator_only`.
- Produces: `Ezagent.Message.visibility :: :external_visible | :internal`, with a data migration updating existing string values.

- [ ] Write failing tests asserting `Ezagent.Message.new(..., visibility: :internal)` persists and `:operator_only` is forbidden by invariant.
- [ ] Run focused tests and confirm expected failure on missing enum/invariant.
- [ ] Update schema enum, docs/specs in module comments, query filters, settlement and external feed logic from `operator_only` to `internal`.
- [ ] Add one-shot migration `UPDATE messages SET visibility = 'internal' WHERE visibility = 'operator_only'`; verify no DB enum constraint exists.
- [ ] Replace test fixtures and assertions.
- [ ] Gate: `rg -n "operator_only" apps test docs | cat` should show only explicitly historical docs if any; invariant must forbid code/test usage.
- [ ] Gate: `mix test apps/ezagent_core/test/invariants/no_customer_concept_test.exs`.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P1] refactor: rename internal message visibility`.

### Task P2: AnonIngress Primitive

**Files:**
- Create/modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_admission.ex`
- Create: `apps/ezagent_web/lib/ezagent_web/socialware/anon_ingress.ex`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex`
- Modify: public socialware controllers using anon admission
- Add tests under `apps/ezagent_domain_socialware/test` and/or `apps/ezagent_web/test`

**Interfaces:**
- Produces: `Ezagent.Socialware.AnonAdmission.admit_anonymous_participant(session_uri, opts) :: {:ok, result} | {:error, reason}`.
- Produces: thin web shim handling cookie/HTTP concerns only.

- [ ] Write failing INV-1/INV-2/INV-2a tests: no `system://` granter, mint/spawn/join fail-closed, reuse-path spawn failure falls through to mint-fresh.
- [ ] Run focused tests and confirm failures show duplicated lifecycle is still scattered.
- [ ] Move domain lifecycle into `AnonAdmission`; keep cookie/session HTTP in web shim.
- [ ] Repoint chat/customer controllers to the shim.
- [ ] Gate: duplicate anon lifecycle groups collapse to one primitive and one shim.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P2] feat: centralize anonymous socialware ingress`.

### Task P3: SessionTemplate `installs` And Temporary Catalog

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`
- Modify: `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex`
- Create: temporary catalog module in the domain owning session composition
- Add tests for template-based session creation

**Interfaces:**
- Produces: `SessionTemplate` content key `installs: [%{ref: "chat" | "socialware", seed: map()}]` or equivalent normalized representation.
- Produces: temporary resolver mapping `"chat"` to `Session.chat_behaviors()` and `"socialware"` to `Session.socialware_behaviors()`.

- [ ] Write failing tests creating a session from a template with `"socialware"` install and asserting Turn/Surface appear through data.
- [ ] Write failing test for `"chat"` install asserting Turn/Surface are absent.
- [ ] Add `installs` normalization to SessionTemplate.
- [ ] Add temporary built-in catalog and thread resolved behavior set into `SessionCreator`.
- [ ] Rewire hello creation to author/install through data rather than hardcoded `Session.socialware_behaviors()` at the call site.
- [ ] Gate: focused session creation tests.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P3] feat: drive session socialware installs from template data`.

### Task P4: Socialware Definition And Install Relation

**Files:**
- Create/modify: modules under `apps/ezagent_domain_socialware/lib/ezagent/socialware/definition*`
- Create/modify: install relation resolver/installer under `apps/ezagent_domain_socialware`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`
- Modify: public controllers and world read-model/actions using `public_view`
- Modify: `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`
- Remove P3 temporary catalog.

**Interfaces:**
- Produces: socialware definition resolver using ConfigStore key `"socialware"`.
- Produces: install record `ConfigObject` with `subject = session_uri`, `key = "install:" <> socialware_ref`.
- Produces: anon gate from definition `visibility_policy.web_anon_access`.

- [ ] Write failing tests for definition write/read by `config://<ws>/socialware/<name>`.
- [ ] Write failing install test asserting install record exists and `effective_set` includes mounted extra behavior set.
- [ ] Write failing parity test that production code no longer reads `public_view` as a boolean.
- [ ] Implement definition struct/resolver and install relation.
- [ ] Replace temporary catalog with ConfigStore-backed resolver.
- [ ] Split identity display reads to install relation and anon-access reads to definition visibility policy.
- [ ] Rewire hello and world paths.
- [ ] Gate: `rg -n "public_view" apps scripts docs | cat` and enforce only allowed historical/non-production exclusions.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P4] feat: introduce socialware definitions and installs`.

### Task P5: Move Socialware Config Out Of SessionTemplate

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`
- Modify: orchestrator tool modules under `apps/ezagent_plugin_cc/lib/ezagent/orchestrator`
- Modify: migration tooling and session template materialization paths
- Modify: socialware definition modules from P4
- Add round-trip tests for orchestrator tools

**Interfaces:**
- Moves `members`, `routing_rules`, `prompt_templates`, `legends`, `orchestrator_template_uri` to the socialware definition.
- Orchestrator tools mutate the socialware definition, not SessionTemplate content.

- [ ] Write failing tests for `add_managed_member`, `define_rule_set_rule`, template update/save, and `migrate_session` targeting socialware definition content.
- [ ] Implement extraction and compatibility migration for existing orchestrated sessions.
- [ ] Keep SessionTemplate focused on name/description/lineage/default workspace/installs.
- [ ] Gate: tool round-trip tests and non-socialware orchestrated session composition test.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P5] feat: move socialware team config into definitions`.

### Task P6: `publish_policy`

**Files:**
- Modify: socialware definition visibility policy modules
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`
- Add tests for auto vs supervised publishing

**Interfaces:**
- Produces: `visibility_policy.publish_policy :: :auto | :supervised`.
- `Turn.handle_open` reads policy and sets initial output visibility accordingly.

- [ ] Write failing tests for `:supervised` holding output as `:internal` until `:settle`.
- [ ] Write failing test preserving `:auto` immediate external visibility.
- [ ] Implement policy lookup with fail-closed/default behavior specified by current code and SPEC.
- [ ] Gate: focused Turn tests.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P6] feat: add socialware publish policy`.

### Task P8a: Cap-Gate Unfiltered Management Read

**Files:**
- Modify: `/sessions` management read path in world/web modules
- Modify: `apps/ezagent_core/lib/ezagent/message_store.ex` or add authorized read facade
- Add tests for non-holder exclusion and holder visibility

**Interfaces:**
- Produces: `read_unfiltered` cap gate for management read; fail-closed and rechecked per read.

- [ ] Write failing test proving non-holder authenticated workspace user cannot read `:internal` via `/sessions`/`recent_in_session`.
- [ ] Write passing-control test for holder with `read_unfiltered` cap seeing `:internal`.
- [ ] Implement gate at the sanctioned dispatch/read boundary without scattering raw `Capability.matches?/2`.
- [ ] Gate: security tests.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P8a] fix: cap-gate unfiltered session reads`.

### Task P7: Dual-Path Socialware Editor

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex`
- Modify: `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`
- Modify: socialware definition validation module
- Modify: orchestrator tool save/update paths from P5
- Add world/action tests and UI-facing tests where available

**Interfaces:**
- Produces: one domain validation function used by form and orchestrator path.
- Produces: form payload for full socialware definition plus `installs`.
- Publishes `"current"` tag on author save.

- [ ] Write failing form-action tests proving non-empty members/routing/prompts/legends/adapters/visibility plus installs are saved into one definition.
- [ ] Write failing orchestrator-path test proving it mutates the same definition object.
- [ ] Implement validation and world action convergence.
- [ ] Update React payload away from `public_view` toggle toward install + adapter + visibility data.
- [ ] Gate: form authors complete runnable socialware and `"current"` tag is published.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P7] feat: converge socialware editor paths`.

### Task P8b: Relabel Operator Surfaces To Internal

**Files:**
- Modify: files mentioning `operator_tree`, `Operator SessionView`, or user-facing operator labels.
- Add/modify grep invariant if present.

**Interfaces:**
- Produces: relabel-only change; no new responsibilities or auth semantics.

- [ ] Write/extend grep test that user-facing operator labels are absent where SPEC requires internal.
- [ ] Rename labels and identifiers where safe, preserving persisted compatibility only if code requires it.
- [ ] Gate: `rg -n "operator|Operator|operator_tree" apps docs | cat` reviewed for allowed historical/code-only references.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P8b] refactor: relabel operator surfaces as internal`.

### Task P9: Supervisor Responsibility And B2 Pool

**Files:**
- Create/modify: `apps/ezagent_domain_workspace` assignment modules and tests
- Create/modify: `apps/ezagent_domain_session` approval/quorum behavior and tests
- Modify: core routing seam only through injected resolver
- Modify: world UI/CLI takeover surfaces
- Add P9-a through P9-d tests

**Interfaces:**
- Produces: workspace durable assignment with `:assign_role` cap.
- Produces: session approval/quorum/arbiter workflow.
- Produces: injected multi-holder resolver for `{:role, name}` with same-workspace/current-assignment validation.

- [ ] P9-a: write failing assignment tests for assign/unassign durability and cap gate; implement in `domain_workspace`.
- [ ] P9-b: write failing quorum/arbiter and stale-holder verdict tests; implement session workflow.
- [ ] P9-c: write failing tenant-isolation fan-out test proving no `:receive` cap is minted for unassigned/out-of-scope principals; implement injected resolver seam.
- [ ] P9-d: write failing UI/CLI tests driving `:claim`/`:settle`/`:approve`; implement takeover surface.
- [ ] Gate: all P9 sub-step tests.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P9] feat: add supervisor responsibility pool`.

### Task P10.0: Codex Orchestrator

**Files:**
- Create: `apps/ezagent_plugin_codex/lib/ezagent/orchestrator/orchestrator_role.ex` or codex-appropriate sibling
- Create: `apps/ezagent_plugin_codex/lib/ezagent/orchestrator/codex_orchestrator_seed.ex`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent_plugin_codex/application.ex`
- Modify: codex sidecar/tool-loop modules as needed to forward `{:run_tool, bridge_token}`
- Add tests mirroring cc orchestrator recipe/seed behavior

**Interfaces:**
- Produces: codex plugin role recipe named `"orchestrator"` with `@skill_ref "ezagent-session-orchestrator"`.
- Produces: `codex-orchestrator` AgentTemplate seed with `flavor: "codex"` and isolated `CODEX_HOME`.
- Reuses: `SessionManager.run_tool_op(:kb_query, ...)` and `AgentBridge.TokenStore.verify_token/2`.

- [ ] Write failing tests proving codex plugin exposes an orchestrator role and seed analogous to cc.
- [ ] Write failing deterministic bridge/tool-loop test using a fake codex sidecar that exercises recipe + seed + bridge token + `kb_query` forwarding.
- [ ] Implement role and seed without new Behavior or duplicated tool catalog/executor.
- [ ] Wire codex sidecar tool-loop to shared run-tool seam.
- [ ] Gate: codex plugin tests.
- [ ] Gate: phase structural suite and touched app tests.
- [ ] Commit as `[P10.0] feat: add codex orchestrator recipe and seed`.

### Task P10: Automated Lifecycle E2E Gate

**Files:**
- Create: `scripts/socialware_lifecycle_seed.exs`
- Create: `apps/ezagent_plugin_kb/test/e2e/socialware_lifecycle_e2e_test.exs`
- Create: deterministic codex test fixture if needed
- Modify: test support as needed

**Interfaces:**
- Consumes: public author/install/dispatch entrypoints from P4-P10.0.
- Produces: automated E2E suite green iff lifecycle holds.

- [ ] Write failing E2E assertions for author, install, customer codex-orchestrator reply, supervisor/takeover, security, and publish_policy.
- [ ] Ensure seed does not hand-insert install records, direct `:kind_base`, or hand-write replies.
- [ ] Implement deterministic test-mode codex fixture for final token generation only.
- [ ] Run focused E2E: `mix test apps/ezagent_plugin_kb/test/e2e/socialware_lifecycle_e2e_test.exs`.
- [ ] Run full required gate suite and `mix precommit`.
- [ ] Push `implement/socialware-unification-p1-p10`.
- [ ] Commit as `[P10] test: add socialware lifecycle e2e gate`.

