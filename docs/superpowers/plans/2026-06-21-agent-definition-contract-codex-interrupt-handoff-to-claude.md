# Agent Definition Contract — Codex Interrupt Handoff to Claude

**Date:** 2026-06-21  
**Author:** codex  
**Audience:** claude  
**Status:** interrupted implementation handoff, not final handback  
**Worktree:** `/Users/h2oslabs/Workspace/esr-ng/.worktrees/agent-contract-phase3`  
**Current branch:** `codex/agent-contract-phase3`  
**Integration branch:** `agent-schema`  
**Current base:** `b4375ec5` (`Merge branch 'codex/agent-contract-phase2' into agent-schema`)  

This document hands the work back to claude mid-Phase 3. It includes the original reason for the task, the spec decisions, what landed in Phase 1 and Phase 2, what is currently implemented in Phase 3, what was verified, and exactly what remains before Phase 3 can be committed/merged.

This is **not** `docs/superpowers/plans/2026-06-21-agent-contract-handback-from-codex.md`. That final handback should only be written after all phases are green on `agent-schema`.

## 1. Original Task / Why This Exists

The agent-definition contract work started because ezagent had a strong runtime spine but no canonical, declarative way to define an agent or a team of agents.

Current ezagent already owns:

- dispatch and CapBAC;
- Kind / Behavior / Lifecycle runtime;
- AgentTemplate and SessionTemplate;
- cc/codex/curl/echo flavors;
- team routing, legends, prompt templates, and members;
- session membership and type-transparent entity routing.

But an "agent definition" was fragmented across:

- `AgentTemplate` content;
- plugin-specific flavor config;
- the mostly-dead `Role.Materialize` prototype;
- autoservice branch artifacts (`soul`, slots, `SoulRenderer`, CR/release/Refresh);
- hand-written seed/bootstrap code.

The driving scenario was the autoservice customer-service vertical: 导购 / internal process / OA bots. That branch proved the needed authoring contract for one vertical, but hard-coded it. The goal of this work is to extract the contract so future verticals can be declared as data instead of re-implemented.

Core product decision from the master design:

> Build a framework/contract layer over ezagent's existing runtime. Do not invent a new runtime. ezagent's moat is "few well-integrated backends + thick runtime".

Important consequence:

- Agent manifest is the **agent-type body** of an entity, not a parallel system.
- Team composition remains a **SessionTemplate**.
- Tools are **dispatch-backed**.
- Participants are **type-transparent entities**.
- Versioning leans on immutable `@hash` URIs and moving tags.

## 2. Authoritative Docs

The implementation was started under the process contract in:

- `docs/superpowers/plans/2026-06-21-agent-definition-contract-handoff.md`
- `docs/superpowers/plans/2026-06-21-agent-definition-contract-plan.md`

Specs:

- `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`
- `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`
- `docs/superpowers/specs/2026-06-21-agent-contract-spec2-tools-participant.md`
- `docs/superpowers/specs/2026-06-21-agent-contract-spec3-versioned-artifact.md`

The handoff process is authoritative:

- load `ezagent-developer` and `elixir-phoenix-helper` before `.ex` edits;
- use a git worktree off `agent-schema`;
- set one goal per phase;
- a phase is complete only after its E2E gate passes via sanctioned `mix ezagent` flow, no raw RPC/eval;
- run `mix ezagent.check_invariants`, `mix format --check-formatted`, and `mix test` before each commit;
- merge phase branches into `agent-schema`, never `main`;
- when all phases are green, write final `agent-contract-handback-from-codex.md`, then stop for claude review/merge.

## 3. Spec Summary / Design Decisions

### Master design

The contract has two layers:

1. **Agent manifest**: per-agent body. Data manifest plus `soul.md` and slots. Holds backend-agnostic author fields plus an `executor`.
2. **Team / SessionTemplate**: members, routing rules, legends, prompt templates. Existing team-routing is reused.

Entity-type transparency is load-bearing:

- user / program / agent are all entity URIs;
- dispatch, routing, membership, and CapBAC do not branch on entity type;
- "operator escalation" is just routing to an existing human participant.

### spec-1

Spec-1 defines:

- `Ezagent.AgentManifest`;
- slot rendering;
- `flavor.compile/2` as pure render;
- executor fallback over the existing spawn path;
- deletion of `Role.Materialize`;
- keeping `Ezagent.Role` until the live orchestrator bootstrap path is replaced.

Gates:

- **G1**: re-express autoservice fast/slow manifests, golden output byte-identical to autoservice rendering.
- **G2**: backend fallback cc -> codex -> curl, all-fail notification, no orphan.
- **G5**: one-field backend swap, e.g. cc -> codex.

Key decision taken in implementation:

- `flavor.compile/2` is pure and feeds the existing validate/materialize seam.
- fallback reuses `spawn_from_template_content/4`;
- per-candidate residue is write-on-success / reset-on-fall-through.

### spec-2

Spec-2 defines:

- manifest `tools[]` with `:action` and `:participant`;
- tool -> MCP injection;
- tool calls dispatch with `ctx.caps = []`;
- actual authority comes from the agent Identity slice via `holds_cap?`;
- `:participant` generalizes `add_managed_member` so existing humans/programs and spawned agents end in the same type-blind session member shape.

Gate:

- **G3**: add a manifest-spawned agent and invite an existing human into one session. Both appear in `slice.members`, `$session_members` reaches both, human can send/receive/leave only within that session, and a manifest-declared but ungranted action cap is denied.

Key decision taken in implementation:

- participant invite provisions session-scoped admit/participation, not workspace-wide authority;
- fake orchestrator infrastructure was used for E2E rather than requiring real Claude.

### spec-3

Spec-3 defines:

- no new pin field;
- the pin is already `template_working_copy.session_template_uri`, an immutable `template://...@hash`;
- publish creates/moves a mutable tag, not a live-session mutation;
- new sessions adopt current only at create time;
- existing sessions stay frozen until explicit `migrate_session`;
- `migrate_session` is session-level orchestration over existing `update_member_template/3`;
- migration writes a ledger to working copy and is resumable.

Gate:

- **G4**: session A pins `@h1`; publish `@h2`; session B adopts `@h2`; A stays `@h1`; `migrate_session(A, @h2)` regenerates changed members, repoints routes, advances pin, does not lose members; injected mid-migration failure persists ledger and rerun converges.

Key decisions currently taken in implementation:

- D5: `TemplateTags current` is wired into create-time template resolution.
- D6: AgentTemplate per-edit hash URI minting was added.
- D7: partial migration semantics are resumable ledger, not all-or-nothing rollback.

## 4. Process / Branch History So Far

Phase 1 and Phase 2 are already merged into `agent-schema`.

Current commit chain:

```text
b4375ec5 (agent-schema, codex/agent-contract-phase3) Merge branch 'codex/agent-contract-phase2' into agent-schema
0d5d57f7 (codex/agent-contract-phase2) Implement agent manifest tools contract phase 2
a15ca637 (codex/agent-contract-phase1) Implement agent manifest contract phase 1
a5cda483 docs(agent-contract): design specs + plan + handoff (DESIGN-READY)
```

Current worktree:

```bash
cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/agent-contract-phase3
git status --short --branch
```

Expected branch:

```text
## codex/agent-contract-phase3
```

## 5. Phase 1: What Landed

Commit:

```text
a15ca637 Implement agent manifest contract phase 1
```

Observed commit stat:

```text
41 files changed, 1335 insertions(+), 418 deletions(-)
```

Major landed areas:

- `apps/ezagent_core/lib/ezagent/agent_manifest.ex`
- `apps/ezagent_core/lib/ezagent/agent_flavor_resolver.ex`
- `apps/ezagent_core/lib/ezagent/kind/template.ex`
- `apps/ezagent_core/lib/ezagent/role/materialize.ex` deleted
- `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`
- `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex`
- cc/codex/curl template classes gained compile-related behavior
- CLI facade for manifest-driven E2E
- tests for manifest schema, render, fallback, Role.Materialize deletion, flavor compile behavior, spawn integration

What Phase 1 accomplished:

- Introduced data manifest schema and loader.
- Rejected flavor leakage into author fields.
- Added slot rendering / resolved instructions path.
- Added flavor compile callback contract.
- Wired manifest spawn into the live agent spawn path.
- Implemented backend fallback semantics without inventing a parallel spawn path.
- Deleted `Role.Materialize` while keeping the live `Ezagent.Role` path.

Phase 1 gate status before merge:

- Phase 1 was committed and merged to `agent-schema` before Phase 2 started.
- Its E2E evidence should be preserved in earlier codex context; if claude needs final audit, re-run G1/G2/G5 from `agent-schema` or inspect the final handback once all phases are done.

## 6. Phase 2: What Landed

Commit:

```text
0d5d57f7 Implement agent manifest tools contract phase 2
```

Observed commit stat:

```text
22 files changed, 1044 insertions(+), 22 deletions(-)
```

Major landed areas:

- `apps/ezagent_core/lib/ezagent/agent_manifest.ex`
- `apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex`
- `apps/ezagent_core/lib/ezagent/kind/template.ex`
- `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex`
- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`
- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex`
- `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`
- cc/codex/curl compile tests
- fake orchestrator Claude fixture:
  - `apps/ezagent_plugin_cc/test/fixtures/fake_orchestrator_claude.py`

What Phase 2 accomplished:

- Added manifest tool declaration validation.
- Added manifest-to-tool/MCP-related compile behavior.
- Added participant tool support.
- Generalized participant handling to existing entity URI and manifest-spawned agent.
- Preserved CapBAC rule that manifest caps do not flow into dispatch `ctx.caps`.
- Added SessionManager operation surface for participant/tool calls.
- Added test support and fake orchestrator path for E2E.

Phase 2 final state:

- Branch `codex/agent-contract-phase2` was committed as `0d5d57f7`.
- It was merged into `agent-schema` by merge commit `b4375ec5`.
- Root checkout was left clean after resolving temporary identical dirty files.
- Nothing was merged to `main`.

## 7. Phase 3: Current Implementation State

Active goal:

> Implement spec-3: lean on immutable session_template_uri pin + ledger-tracked migrate_session over update_member_template. Done when G4 E2E + units green.

Current branch:

```text
codex/agent-contract-phase3
```

No Phase 3 commit has been made yet.

Current local changes include these tracked files:

- `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex`
- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`
- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex`
- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/tool_catalog.ex`
- `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex`
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex`
- `apps/ezagent_domain_session/test/integration/orchestrator_tools_ops_test.exs`
- `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`

Untracked new files:

- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex`
- `apps/ezagent_domain_session/test/ezagent/entity/agent_template_versioning_test.exs`
- `apps/ezagent_domain_session/test/integration/session_template_version_pin_test.exs`
- this handoff doc

Last observed Phase 3 diff stat for tracked code paths:

```text
9 files changed, 297 insertions(+), 13 deletions(-)
```

### 7.1 T3.1 Adopt-at-create / immutable pin

File:

- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex`

Current behavior:

- `resolve_session_template!/2` first tries `TemplateTags.resolve(workspace_uri, template_name, "current")`.
- If a current tag exists, it builds the immutable URI:
  - `template://<workspace>/session/<template_name>@<hash>`
- It falls back to the prior live/snapshot scan only when no tag exists.

Test:

- `apps/ezagent_domain_session/test/integration/session_template_version_pin_test.exs`

Assertions:

- session A created while current points at `@h1` pins `@h1`;
- after current moves to `@h2`, session B pins `@h2`;
- session A remains pinned to `@h1`.

### 7.2 `update_template` / `save_template_as` publish current

File:

- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex`

Current behavior:

- `update_template/1` publishes/moves current after persisting a new SessionTemplate version.
- `save_template_as/2` publishes current for the new template family.

Helper:

- `template_hash!/1`

Test added in:

- `apps/ezagent_domain_session/test/integration/orchestrator_tools_ops_test.exs`

Assertion:

- `update_template` moves `current` to the newly persisted hash.

Potential cleanup before final:

- `save_template_as/2` currently uses `:ok = publish_current(...)`; converting to a `with :ok <- publish_current(...)` would give cleaner error propagation.

### 7.3 T3.2 AgentTemplate per-edit version minting

File:

- `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex`

Added functions:

- `compute_version_hash/1`
- `build_versioned_uri/3`
- `persist_version_as_system/2`

Current design:

- hash is deterministic SHA-256 over content after dropping address/provenance-ish fields:
  - `:created_at`
  - `:created_by`
  - `:version_hash`
  - `:version_tag`
  - `:name`
- URI form:
  - `template://<workspace>/agent/<name>@<hash>`
- persistence writes through existing AgentTemplate Kind and `template.write`.
- system caller is the literal URI `entity://system/user/admin` to avoid cross-app alias warnings.

Test:

- `apps/ezagent_domain_session/test/ezagent/entity/agent_template_versioning_test.exs`

Assertions:

- same logical name but changed content mints a distinct hash URI;
- persisted content can be read back.

### 7.4 T3.3 `migrate_session`

New file:

- `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex`

Public surface added:

- `Ezagent.Orchestrator.Tools.migrate_session/2`
- `SessionManager.run_tool_op(:migrate_session, args, opts)`
- domain tool catalog entry
- cc MCP tool schema entry

Current migration behavior:

- requires opts:
  - `:session_uri`
  - `:workspace_uri`
  - `:caller`
  - `:caps`
- preflights:
  - within-session cap;
  - session-template cap;
- reads target SessionTemplate content;
- computes changed member plan by comparing current member `source_template_uri` with target template members by role;
- writes working-copy ledger:
  - `%{target_session_template_uri: target_uri, members: %{role => :pending | :done | :failed}}`
- calls existing `Tools.update_member_template/3` per changed role;
- checkpoints after each role;
- supports fault injection:
  - `Application.put_env(:ezagent_domain_session, :migrate_session_fault, {:after_role_done, role})`
- replaces this session's rule-set rows only where:
  - `created_by == URI.to_string(session_uri)`
  - `rule_set != nil`
- installs target prompt templates and legends;
- finalizes by:
  - writing `session_template_uri: target_uri`;
  - deleting `:migration_ledger`.

Implementation note:

- `write_working_copy/2` drains one `{:ezagent_reply, _}` from the current mailbox after `Session.system_set_working_copy/2`. This removed noisy `SessionManager unexpected message` logs in targeted tests.

Test added:

- `orchestrator_tools_ops_test.exs`
- test name:
  - `migrate_session persists a ledger on injected failure and resumes to advance the pin`

Assertions:

- first run with injected fault returns `{:error, {:injected_migration_failure, "worker"}}`;
- working copy still points at the old template;
- ledger persists and marks worker as `:done`;
- rerun after clearing fault succeeds;
- final working copy pins target template and ledger is removed;
- old member is gone and new member source is target source.

### 7.5 Member URI change required by migration

File:

- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex`

Change:

- spawned member instance names now include a 12-character hash of `source_template_uri` when `role_name` is present.

Reason:

- `update_member_template/3` intentionally uses spawn-new -> repoint -> retire-old.
- If member URI is derived only from role name, then changing the source template for the same role yields the same member URI and triggers `:same_member_uri_use_reconfigure`.
- Including the source-template hash makes content/version edits produce a distinct replacement member URI.

## 8. Verification Already Run for Phase 3

Formatting was run once:

```bash
env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix format
```

Targeted tests were run and passed:

```bash
env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix test \
    apps/ezagent_domain_session/test/ezagent/entity/agent_template_versioning_test.exs \
    apps/ezagent_domain_session/test/integration/session_template_version_pin_test.exs \
    apps/ezagent_domain_session/test/integration/orchestrator_tools_ops_test.exs
```

Observed result:

```text
Running ExUnit with seed: 32374, max_cases: 56
38 tests, 0 failures
```

Known acceptable warnings/noise at that point:

- Feishu missing credentials warning from existing boot paths.
- One expected create-session rollback warning from existing tests.

The targeted run after the mailbox-drain patch no longer showed the earlier `SessionManager unexpected message` noise.

Do not treat this as Phase 3 green. G4 E2E has not passed, and full gates have not run.

## 9. Current Interruption Point

Codex was preparing to implement the G4 E2E scenario when interrupted. No E2E scenario patch has been written.

The immediate next implementation plan was:

1. Add a focused test for dynamic scenario resolution if changing `Ezagent.E2E.Run`.
2. Extend `Ezagent.E2E.Run.resolve/1`:
   - keep registered scenarios like `"scenario_0"`;
   - if missing, resolve by convention:
     - ref `"agent_contract_g4"`
     - module `Ezagent.E2E.Scenarios.AgentContractG4`.
3. Add:
   - `apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex`
4. Drive it through:
   - `mix ezagent.e2e.run agent_contract_g4`

Important nuance:

- The handoff says E2E gates must be driven via `mix ezagent`, no raw RPC.
- Existing `mix ezagent.e2e.run` is an official in-node E2E harness. It connects with `Ezagent.Runtime.connect_as_cli()` like the CLI and performs the RPC internally.
- If claude requires literal `mix ezagent ...` syntax for this gate, add a thin sanctioned CLI wrapper rather than using raw RPC/eval.

## 10. Suggested G4 E2E Scenario

Use an isolated runtime and preferably echo-flavor templates to avoid real Claude subprocess dependency.

Scenario outline:

1. Create a unique template family name.
2. Create two AgentTemplate versions for the same logical worker:
   - `source_v1`
   - `source_v2`
3. Create SessionTemplate `h1`:
   - member role `"worker"` uses `source_v1`;
   - optional routing rule to prove rule-set replacement.
4. Publish:
   - `TemplateTags.put(workspace_uri, team_name, "current", hash(h1_uri), admin_uri)`
5. Create session A through production create path:
   - `SessionCreator.create_session("a-...", admin_uri, workspace_uri: ..., template_name: team_name)`
6. Assert A working copy pins `h1`.
7. Create SessionTemplate `h2`:
   - same team name;
   - same role uses `source_v2`;
   - changed routing rule if testing route replacement.
8. Move current:
   - `TemplateTags.move(workspace_uri, team_name, "current", h1_hash, h2_hash)`
9. Create session B.
10. Assert:
    - B pins `h2`;
    - A remains pinned to `h1`.
11. Inject migration failure:
    - `Application.put_env(:ezagent_domain_session, :migrate_session_fault, {:after_role_done, "worker"})`
12. Run `migrate_session(A, h2)` through production tool path.
13. Assert:
    - returns `{:error, {:injected_migration_failure, "worker"}}`;
    - A still pins `h1`;
    - A working copy has ledger targeting `h2`;
    - ledger marks `"worker"` as `:done`;
    - A still has at least one worker member after the failure.
14. Clear env and rerun `migrate_session(A, h2)`.
15. Assert:
    - success;
    - A pin advances to `h2`;
    - ledger removed;
    - final worker source is `source_v2`;
    - B remains pinned to `h2`;
    - another session's rules are not touched.

Cap shape should be explicit orchestrator-style caps, not admin caps as a workaround:

- within-session cap:
  - `kind: :session`
  - `behavior: :any`
  - `action: :any`
  - `instance: {:within_session, session_uri}`
  - `workspace_uri: workspace_uri`
- spawned-by cap:
  - `kind: :agent`
  - `behavior: :any`
  - `action: :any`
  - `instance: {:spawned_by, caller_uri}`
  - `workspace_uri: workspace_uri`
- session-template cap:
  - `kind: :session_template`
  - `behavior: Ezagent.Behavior.Template`
  - `action: :any`
  - `instance: {:within_workspace, workspace_uri}`
  - `workspace_uri: workspace_uri`
- agent-template cap:
  - `kind: :agent_template`
  - `behavior: Ezagent.Behavior.Template`
  - `action: :any`
  - `instance: {:within_workspace, workspace_uri}`
  - `workspace_uri: workspace_uri`

If `update_member_template/3` requires concrete chat join/leave authority in the runtime scenario, add explicit session `join` and `leave` caps matching the shape already used in `orchestrator_tools_ops_test.exs`.

## 11. Commands to Resume

```bash
cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/agent-contract-phase3
git status --short --branch
git diff --stat
git ls-files --others --exclude-standard
```

Recommended env for local commands:

```bash
export MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps
export MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build
```

Focused tests already known to be relevant:

```bash
env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix test \
    apps/ezagent_domain_session/test/ezagent/entity/agent_template_versioning_test.exs \
    apps/ezagent_domain_session/test/integration/session_template_version_pin_test.exs \
    apps/ezagent_domain_session/test/integration/orchestrator_tools_ops_test.exs
```

Final Phase 3 gates before commit:

```bash
env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix ezagent.check_invariants

env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix format --check-formatted

env MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
  MIX_BUILD_PATH=/private/tmp/esr-agent-contract-phase3-build \
  mix test
```

After fresh G4 E2E and all gates are green:

1. commit Phase 3 on `codex/agent-contract-phase3`;
2. merge into `agent-schema`;
3. do **not** merge to `main`.

## 12. Open Risks / Things Claude Should Re-check

1. **G4 exact CLI shape.** If `mix ezagent.e2e.run` is considered insufficiently literal, add a `mix ezagent` subcommand/wrapper rather than raw RPC.
2. **`save_template_as/2` tag publication error propagation.** Current implementation may need a cleaner `with` path.
3. **Migration route replacement coverage.** Unit implementation replaces scoped rule-sets; G4 should explicitly prove another session's rules are untouched.
4. **AgentTemplate hash canonicalization.** Current hash drops common volatile fields. Confirm this matches desired immutability semantics.
5. **Member URI hash change.** This is necessary for changed-source swaps. Re-check any tests expecting role-only deterministic member names.
6. **Tool catalog/MCP schema parity.** `migrate_session` was added to domain and cc surfaces; verify no other tool catalog needs updating.

## 13. Hard Boundaries

- Do not modify `ARCHITECTURE.md` or `GLOSSARY.md`.
- Do not implement deferred items:
  - NL-decomposition skill;
  - SLA/filler;
  - code-builder;
  - omnigent;
  - ephemeral gating beyond cheap field handling.
- Do not use raw RPC/eval to force the runtime state.
- Do not merge to `main`.
- Do not call Phase 3 complete until G4 E2E, invariants, format check, and full tests are green.

## 14. Final Handback Still Required Later

After all phases are green on `agent-schema`, write:

```text
docs/superpowers/plans/2026-06-21-agent-contract-handback-from-codex.md
```

That final doc must include:

- what landed per phase;
- D1-D7 decisions actually taken;
- E2E evidence for G1-G5 with commands and pass output;
- deviations/open items;
- git log range for claude review.

Then stop for claude review and merge from `agent-schema` to `main`.
