# Orchestrator Session-Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the v4 orchestrator Session-Config design as a P1-first target branch whose durable-binding fix is independently mergeable, followed by the domain API, authentication/admission, and HTTP/UI projections.

**Architecture:** P1 makes the session working copy the explicit source of truth for a versioned orchestrator binding and makes the cc ETS registry an epoch-coherent cache. P2 introduces `Ezagent.SessionConfig` as the only executable operation boundary, with a frozen core-plus-extension catalog, credential-only principal resolution, declarative target/admission metadata, and thin MCP/HTTP/UI projections.

**Tech Stack:** Elixir 1.19, OTP, Phoenix 1.8, Ecto/PostgreSQL, ExUnit, existing Ezagent Kind/Invocation/CapBAC primitives.

## Global Constraints

- Source of truth: `spec/orchestrator-mcp-revision-v4@eec2f82af:docs/specs/2026-07-12-orchestrator-session-config-api-and-surfaces.md`, especially I1-I8 and §8a.
- Preserve SessionTemplate definition data named `orchestrator_template_uri`; delete only the dead runtime working-copy key and writer.
- P1 is the first feature commit and remains independently mergeable; no P2 dependency may enter it.
- Every production behavior change follows RED → GREEN → REFACTOR with the failing output observed.
- Every sub-step runs touched tests, `mix ezagent.check_invariants`, the named I* regression tests, and `mix ci.local` before its commit is accepted on the target branch.
- MCP, HTTP, and UI adapters perform transport parsing/authentication only; they never derive caps or accept authority context from request input.
- No compatibility path for old bcrypt PATs or caller-supplied identity URIs.
- Do not merge `main` and do not open a PR targeting `main`.

---

### Task 1: P1 versioned durable orchestrator binding

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/session/orchestrator_binding.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/orchestrator_context_port.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_registry.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/orchestrator/context_adapter.ex`
- Test: `apps/ezagent_domain_session/test/integration/orchestrator_binding_lifecycle_test.exs`
- Test: `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_reregister_test.exs`

**Interfaces:**
- `Ezagent.Session.OrchestratorBinding.active(uri, epoch)` returns a persisted binding value with `status: :active`.
- `Ezagent.Session.OrchestratorBinding.tombstone(uri, epoch, reason)` returns a discoverable fail-loud value on the same `:orchestrator_uri` key.
- `Ezagent.Session.OrchestratorBinding.decode/1` is the single reader for the persisted shape and returns `{:ok, binding}` or `{:error, {:orchestrator_binding_tombstoned, reason}}`.
- `Materializer.prepare_orchestrator_binding(session_uri, workspace_uri, template_content)` allocates the real random URI and epoch only when the declaration contains a fresh orchestrator role, persists `:orchestrator_uri` plus `:orchestrator_materialization_epoch`, and returns before async install is started.
- `DefinitionAgents.materialize_definition_agents/4` consumes the prepared URI from the session binding for the orchestrator role instead of allocating another URI; non-orchestrator roles still allocate independently.
- Registry contexts carry `binding_epoch`; register/unregister stays behind `OrchestratorContextPort`.

- [ ] **Step 1: Write the P1 red tests**

  Add production-path tests for: (A) create returns and cold lookup succeeds before the async installer is allowed to spawn; (B1) repair skip restores the prior binding; (B2) definitive repair error writes a tombstone and cold lookup returns `{:error, {:orchestrator_binding_tombstoned, reason}}`; (C) an epoch-changing repair invalidates the old warm cache row. Add source assertions that the runtime working copy no longer reads/writes `:orchestrator_template_uri` while SessionTemplate definition files still do.

- [ ] **Step 2: Run the red tests**

  Run `mix test apps/ezagent_domain_session/test/integration/orchestrator_binding_lifecycle_test.exs apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_reregister_test.exs`; confirm failures show the async gap, drop-without-restore, warm-cache bypass, and dead runtime key.

- [ ] **Step 3: Implement the binding value and synchronous ordering**

  Persist `%OrchestratorBinding{uri:, epoch:, status:, reason:}` under `:orchestrator_uri`, persist the same epoch as the current materialization epoch, allocate/persist before `trigger_socialware_install/1`, thread the prepared binding into the async installer, and make all readers use `OrchestratorBinding.decode/1`. Remove `materialize_orchestrator_working_copy/3`, `prestore_planned_orchestrator_uri/2`, the runtime-key drop, and stale readiness/tool-count docs.

- [ ] **Step 4: Implement repair and cache coherence**

  Capture the prior binding before declaration rewrite, start a new epoch, restore an active binding on success/skip, write a same-key tombstone on definitive failure, and unregister or epoch-replace the cc cache on every epoch transition. Cold and warm reads must reject tombstones and stale epochs before serving.

- [ ] **Step 5: Run P1 green tests and invariants**

  Run the two P1 test files, `mix ezagent.check_invariants`, then `mix ci.local`. Inspect `git diff --check`, `git status --short`, and the staged diff.

- [ ] **Step 6: Commit standalone P1**

  Commit only P1 files as `fix(orchestrator): persist current binding before exposure`. Record the commit SHA as the standalone P1 merge point.

### Task 2: P2a domain-owned executable contract and extension assembly

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/session_config.ex`
- Create: `apps/ezagent_domain_session/lib/ezagent/session_config/operation.ex`
- Create: `apps/ezagent_domain_session/lib/ezagent/session_config/catalog.ex`
- Create: `apps/ezagent_domain_session/lib/ezagent/session_config/extension.ex`
- Create: `apps/ezagent_domain_session/lib/ezagent/session_config/extension_registry.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/application.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`
- Delete: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/tool_catalog.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_adapter.ex`
- Modify: `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/application.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/session_config/catalog_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/session_config/execute_test.exs`
- Test: `apps/ezagent_plugin_cc/test/integration/session_config_projection_test.exs`

**Interfaces:**
- `Ezagent.SessionConfig.execute(operation, args, authenticated_principal, addressed_target)` is the only executable boundary.
- `%Ezagent.SessionConfig.Operation{name:, description:, input_schema:, target_scope:, admission_gate:, execute:}` owns exact names, schemas, coercion/defaults, and dispatch selection.
- `Catalog.core_operations/0`, `Catalog.operation/1`, and `Catalog.schemas/0` are domain-owned.
- `ExtensionRegistry.assemble!(extensions)` sorts deterministically, rejects duplicate core/plugin or plugin/plugin names, freezes once, and rejects late registration.
- KB contributes only name/schema/generic action-route metadata through the extension contract; no KB operation is in the core catalog.

- [ ] **Step 1: Write catalog/execute/projection red tests**

  Assert the domain catalog contains the 11 core operations with exact cc schemas, `kb_*` appears only after KB extension assembly, duplicate and late registrations fail loudly, MCP and codex route through `SessionConfig.execute/4`, and owner/caller derivation is identical for equal principal/target inputs.

- [ ] **Step 2: Run the red tests**

  Run the three P2a test files and confirm missing domain schemas, plugin inversion, and `SessionManager.run_tool_op` ownership cause the failures.

- [ ] **Step 3: Move schemas and coercion into the domain**

  Define immutable operation descriptors in `Catalog`, move every `arg_*` coercion/default and `run_tool_op` branch into operation executors, and derive caller/owner/workspace/session/parent inside `SessionConfig.execute/4`.

- [ ] **Step 4: Assemble extensions and thin the LLM projections**

  Let the KB plugin expose a duck-typed `session_config_operations/0` declaration, discover loaded plugin contract modules at the late `EzagentWeb.Application` boot point, freeze the sorted registry there, make cc schemas derive from the domain catalog, and replace MCP/codex execution with calls to `execute/4` while retaining bridge token verification and structural binding as transport authN.

- [ ] **Step 5: Gate and commit P2a**

  Run P2a tests, I1 conformance/context parity tests, `mix ezagent.check_invariants`, and `mix ci.local`; commit as `feat(session-config): own executable operation contract`.

### Task 3: P2b credential-only authN and HMAC PAT migration

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/authentication.ex`
- Create: `apps/ezagent_core/priv/repo/migrations/20260712000000_hmac_entity_tokens.exs`
- Create: `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.entity_tokens.invalidate_legacy.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex`
- Modify: `apps/ezagent_cli/lib/ezagent_cli/exec.ex`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Create: `docs/operators/entity-token-hmac-cutover.md`
- Create: `docs/operators/entity-token-hmac-cutover.zh_cn.md`
- Test: `apps/ezagent_domain_identity/test/ezagent/authentication_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/entity/token_test.exs`
- Test: `apps/ezagent_web/test/api_v1_controller_test.exs`
- Test: `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`

**Interfaces:**
- `Ezagent.Authentication.authenticate({:pat, token})` returns only `{:ok, principal}` or authN error.
- `Ezagent.Authentication.authenticate({:bridge, connection_bound_uri, token})` delegates to `AgentBridge.TokenStore` and returns the connection-bound principal.
- PAT format is exactly `esr_pat_v<N>_<raw>`; parse version before DB access, select `pepper_vN`, HMAC-SHA256 the raw secret, perform one unique-index lookup, and verify row `digest_version == N`.
- `Token.mint/2` writes `token_digest` and `digest_version`; no bcrypt verify or URI-selected token verify remains.
- Pepper absence makes mint and verify fail closed.

- [ ] **Step 1: Write HMAC/authentication red tests**

  Cover token-only principal derivation, one indexed lookup, version/pepper selection, absent-pepper failure, old `esr_pat_` rejection, digest-version mismatch, expiry/revoke, bridge-store routing, and rejection of supplied principal fields/headers/CLI flags.

- [ ] **Step 2: Run the red tests**

  Confirm current bcrypt + URI-selected APIs fail every token-only and versioned-format assertion.

- [ ] **Step 3: Implement the executable schema transition**

  Rebuild `entity_tokens` so `token_hash NOT NULL` is removed, add non-null new-format columns for new rows plus unique index, leave legacy rows with null digest for cutover hygiene deletion, and implement an idempotent cleanup operation for `token_digest IS NULL`.

- [ ] **Step 4: Implement mint/verify/resolver and re-mint entrypoints**

  Add versioned pepper config, HMAC mint/lookup, an authenticated web-session self-mint endpoint that works after password or magic-link login and atomically replaces the caller's prior `web-self-mint` row before returning the new PAT once, bootstrap-admin direct mint, and agent spawn/restart mint. Preserve `AgentBridge.TokenStore` unchanged. Add an idempotent legacy-row cleanup task and bilingual runbook spelling out bootstrap-admin-first rollout, forced agent restart sweep, forward repair, snapshot restore, and old-binary/schema rollback as a full re-auth event.

- [ ] **Step 5: Gate and commit HMAC authN**

  Run migration up/down tests, identity/web/CLI tests, I6 tests, `mix ezagent.check_invariants`, and `mix ci.local`; commit as `feat(identity): derive principals from versioned PATs`.

### Task 4: P2b declarative scope/admission and full predicates

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/session_config.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session_config/operation.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session_config/catalog.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/session_config/admission_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/session_config/capability_predicate_test.exs`

**Interfaces:**
- Each operation declares exactly one `{target_scope, admission_gate}` pair.
- Session operations use owner-or-roster-member admission; `list_templates` uses workspace/template caps without a session and retains per-kind partial results; template writes are session-addressed but use template-write admission.
- A single full `Capability.matches?/2`-equivalent required predicate is evaluated before side effects and reused by the downstream runtime gate.
- Canonical errors identify `:validation`, `:readiness`, `:admission`, or the owning downstream gate.

- [ ] **Step 1: Write admission/predicate red tests**

  Cover wrong target scope, non-member session denial, member/owner parity, workspace operator without session, agent-only/session-only partial template lists, template-write-without-membership parity, narrowed-action preflight denial before spawn/terminate, and no ambient system authority.

- [ ] **Step 2: Run red tests and implement declarations**

  Observe the coarse preflight and blanket assumptions fail; then implement target typing, admission dispatch, principal-held cap loading, and shared full predicates.

- [ ] **Step 3: Gate and commit admission**

  Run I2/I3 admission and side-effect tests, touched suites, `mix ezagent.check_invariants`, and `mix ci.local`; commit as `feat(session-config): enforce declared admission gates`.

### Task 5: P2c participant trust split and HTTP/UI projections

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/session_config/catalog.ex`
- Create: `apps/ezagent_web/lib/ezagent_web/controllers/session_config_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- Create: `apps/ezagent_domain_session/lib/mix/tasks/ezagent.session.config.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/session_config/participant_test.exs`
- Test: `apps/ezagent_web/test/session_config_controller_test.exs`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`
- Test: `apps/ezagent_domain_session/test/mix/ezagent_session_config_test.exs`

**Interfaces:**
- Remote `add_participant` accepts only a canonical existing-agent `entity://<workspace>/agent/<name>` URI.
- `import_participant_manifest` is a separate local/operator operation with an explicit operator capability and confined root; it is absent from HTTP and cannot be reached through remote `add_participant` validation fallback.
- HTTP exposes only the declared safe subset and obtains the principal only from `Authentication.authenticate/1`.
- CLI accepts a PAT plus operation/JSON args/addressed target, derives the principal through the same resolver, and calls `SessionConfig.execute/4`; it never accepts `--uri`, caller, owner, workspace, or parent authority fields.
- World mutations call `SessionConfig.execute/4`; no direct `Tools.*` call remains for projected operations.

- [ ] **Step 1: Write LFI and projection red tests**

  Assert non-URI, template URI, traversal path, and request authority fields fail validation without invoking `File.read`; assert HTTP and CLI schemas are byte-for-byte the domain schema; assert UI/HTTP/CLI/MCP return the same context/admission result for equal inputs.

- [ ] **Step 2: Run red tests and split participant operations**

  Remove the parse-error-to-`File.read` fallback from remote add, add the confined local importer, and keep it out of every remote catalog subset.

- [ ] **Step 3: Add thin HTTP and UI projections**

  Add safe-subset routes/controller serialization, add the token-only CLI projection, and route world dynamic-team mutations through `execute/4`; adapters pass only operation, args, authenticated principal, and addressed target.

- [ ] **Step 4: Gate and commit P2c**

  Run I1/I2/I6/I8 projection tests, touched web/world/session suites, `mix ezagent.check_invariants`, and `mix ci.local`; commit as `feat(web): project safe session-config operations`.

### Task 6: Final target audit

**Files:**
- Modify only files required to fix failures attributable to Tasks 1-5.

**Interfaces:**
- P1 merge point remains identifiable and passes its gates when checked out independently.
- Target HEAD passes all I1-I8 tests and repository gates.

- [ ] **Step 1: Verify P1 independently**

  Create a temporary detached verification worktree at the recorded P1 SHA, migrate its test DB, and run P1 tests, `mix ezagent.check_invariants`, and `mix ci.local`; remove the verification worktree after recording output.

- [ ] **Step 2: Verify target HEAD**

  Run all SessionConfig, authN, MCP, HTTP, world, and participant tests; run `mix precommit`, `mix ezagent.check_invariants`, and `mix ci.local` with fresh output.

- [ ] **Step 3: Audit history and scope**

  Inspect `git log --oneline origin/main..HEAD`, `git diff --stat origin/main...HEAD`, `git diff --check`, staged/unstaged status, migrations, request schemas, and source greps for bcrypt verification, supplied identity URI, remote `File.read`, cc-owned core schemas, and domain `kb_*` leakage.

- [ ] **Step 4: Report target branch**

  Report branch/worktree, P1 SHA, P2 commit SHAs, exact test/gate evidence, any environment-only caveats, and confirm no main merge or main PR occurred.
