# Architecture Deepening Proposal v1 — Phase 1 Gate

**Status**: Proposal for review, not an implementation plan.
**Date**: 2026-06-07.
**Scope**: behavior-preserving architecture deepening for the current `main` source.
**Companion**: [2026-06-07-architecture-deepening-v1.zh_cn.md](2026-06-07-architecture-deepening-v1.zh_cn.md).

This document is the Phase-1 deliverable for `docs/futures/todo.md` #25. It applies the deep-module lens to the current ezagent umbrella without starting Phase-2 refactors. The target outcome is a codebase with higher **depth**: more behavior behind smaller, clearer **interfaces**, better **locality**, and less information leakage across RBK / Template / domain.agent seams.

## 0. Ground Rules

Non-negotiable constraints for any Phase-2 PR:

- Behavior-preserving. No feature changes, no silent defaults, no shims.
- Preserve RBK invariants: dispatch-only, CapBAC at the chokepoint, workspace isolation, no plugin-owned schemes, strict sibling-slice reads, and Template / Lifecycle authoring contracts.
- Test only under `MIX_ENV=test`; never run dev/prod migrations or touch dev/prod Docker containers.
- For Codex companion review, static-only and skip `mix` unless the reviewer explicitly relaxes that constraint.
- Treat this proposal as the review gate. Do not start Phase 2 until Allen/Claude review it.

## 1. Verdict

The architecture is directionally right. The large files are not random bloat; they are mostly places where real, cross-cutting invariants accumulated before a deeper interface existed. The right move is not broad sharding. It is to extract a small number of deeper modules around existing domain words:

- **Session materialization** behind `SessionCreator.create_session/3` remains the single lower-level writer, but its template resolution, orchestrator bootstrap, team materialization, and rollback logic should become internal modules.
- **Agent Template Classes** should stop owning every detail of config-home materialization, credential grants, sidecar params, spawn rollback, and respawn. `cc.agent` and `codex.agent` should become adapters over shared domain seams where the behavior is already flavor-generic.
- **AdminLive** should remain the `/sessions` coordinator, but session selection, compose/upload, invite, routing-form, and subscription state should move behind small state/event modules. Existing view modules should continue rendering.
- **Core RBK primitives** are sound, but `Behavior`, `Kind`, `Kind.Runtime`, and `Capability` each contain several interfaces in one module. Split only where the extracted module hides real grammar/policy complexity; avoid pass-through stage modules.

The highest-impact safe work starts in UI because it is mostly mechanical and has fewer security invariants. The highest-impact risky work is `SessionCreator` and the agent-template spawn/config seam because those files hold rollback, CapBAC, and credential safety.

## 2. Source Snapshot

The handoff's LOC report still matches current source shape, except `session_creator.ex` lives at `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex` on `main`.

| Area | Current evidence | Interface pressure |
|---|---:|---|
| `AdminLive` | 3,217 LOC / 186 `def*`; `mount/3`, many `handle_event/3`, render, session context, routing forms, mention parsing | One LiveView owns too many event-state seams |
| `SessionCreator` | 1,983 LOC / 78 `def*`; `create_session/3`, `repair_orchestrator/2`, rollback, materialization, list | Correct single writer, but internal sequence has too many concepts in one implementation |
| `Orchestrator.Tools` | 1,886 LOC / 83 `def*`; member ops, routing rules, template writes, list templates | Tool facade, team mutation, routing mutation, and template persistence share one interface |
| `Behavior.Chat` | 1,798 LOC / 78 `def*`; Lifecycle state, send/receive/join/leave, working-copy, legends, prompts, signals | A single Behavior interface is right; implementation concepts need locality |
| `Entity.Agent` | 1,363 LOC / 59 `def*`; Kind declaration, spawn APIs, template-content spawn, credential cascade, sandbox state, lineage | Kind declaration is shallow relative to spawn/materialization implementation |
| `Entity.Session` | 1,351 LOC / 59 `def*`; Kind declaration, Publisher facade, orchestrator ensure/readiness, working-copy readers | Session Kind and orchestrator support are separate concepts |
| `Orchestrator.McpServer` | 1,071 LOC / 71 `def*`; context rebuild, schemas, tool dispatch, MCP error mapping, GenServer | MCP transport adapter, context resolver, schema catalog, and result codec are separable |
| `CcAgent` | 2,222 LOC / 103 `def*`; Template Class, form, validation, config dir, command argv, PTY, credentials, respawn | A Template Class has become a full flavor runtime |
| `CodexAgent` | 1,009 LOC / 92 `def*`; same shape plus app-server/bridge/thread-id lifecycle | Parallel flavor runtime duplicates seam shape |
| Core RBK modules | `Kind.Runtime` 1,459; `Behavior` 1,422; `Kind` 1,076; `Capability` 1,023 | Mature primitives now hide multiple grammars and policies |

Primary source anchors used for this proposal:

- Handoff / task: `docs/superpowers/handoffs/2026-06-07-architecture-deepening-codex-handoff.md`, `docs/futures/todo.md`.
- Vocabulary and invariants: `GLOSSARY.md:30` (Kind), `GLOSSARY.md:31` (Behavior), `GLOSSARY.md:147`-`154` (RBK / Lifecycle / sibling-slice / capability decisions), `.claude/skills/ezagent-developer/references/design-principles.md`, `.claude/skills/ezagent-developer/references/architecture-invariants.md`.
- Hotspot modules: `admin_live.ex:1`, `session_creator.ex:1`, `tools.ex:1`, `chat.ex:1`, `agent.ex:1`, `session.ex:1`, `mcp_server.ex:1`, `cc_agent.ex:1`, `codex_agent.ex:1`, `kind/runtime.ex:1`, `behavior.ex:609`, `kind.ex:1`, `capability.ex:1`.

## 3. Deepening Candidates

### 3.1 `AdminLive`: coordinator, not god-module

**Anti-pattern**: god-module plus temporal decomposition. The LiveView currently owns mount registration, session auto-ensure, PubSub/event handling, session selection, compose/upload, invite modal, routing rule form, rendering dispatch, mention parsing, and error copy.

**Proposal**: keep `EzagentPluginLiveview.AdminLive` as the only route module, but move high-locality state/event concerns behind internal modules:

- `EzagentPluginLiveview.Admin.SessionContext`
  - Interface: `default_main_session_uri/1`, `select/2`, `assign/2`, `authorize/2`, `refresh_views_and_members/1`.
  - Hides session URI parsing, workspace authority checks, view registry refresh, member/legend reads.
- `EzagentPluginLiveview.Admin.Compose`
  - Interface: `form/0`, `send(socket, text, attachments)`, `parse_mentions(text, members, legends)`, `clear(socket)`.
  - Hides upload attachment mapping and mention/legend parsing.
- `EzagentPluginLiveview.Admin.Invites`
  - Interface: `options(socket, session_uri, current_members)`, `invite(socket, member_uri)`.
  - Hides invite workspace selection and `chat.join` dispatch.
- `EzagentPluginLiveview.Admin.SessionRoutingForm`
  - Interface: `build_matcher(params)`, `parse_receivers(params)`, `validate(socket, params)`, `add_rule(socket, params)`.
  - Hides form parsing and receiver revalidation while preserving dispatch.
- `EzagentPluginLiveview.Admin.RehydrateFlash`
  - Interface: `assign(socket, meta)`, `text(meta)`.
  - Hides orchestrator-status flash copy.

**Why deeper**: callers still use one LiveView route, but the LiveView no longer exposes every workflow's data-shape assumptions to every handler. The extracted modules hide meaningful policy and parsing, not just line ranges.

**Risk**: Low. Mostly mechanical split. Preserve template IDs, `Layouts.app`, stream usage, and existing `SessionEditor` / `MemberPanel` / `OrchestratorHealthCard` rendering.

### 3.2 `SessionCreator`: one public writer, deeper internal materializer

**Anti-pattern**: god-module with information leakage. The public interface is correct: `create_session/3` is the lower-level atomic writer and must remain the single chokepoint. The problem is that one module now holds template lookup, lock orchestration, Session Kind spawn, workspace bind, orchestrator working-copy writes, cap grants, MCP context, team materialization, prompt templates, legends, routing rows, rollback, repair, and listing.

**Proposal**: keep the public facade intact:

```elixir
EzagentDomainInstanceMessage.SessionCreator.create_session/3
EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator/1
EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator/2
EzagentDomainInstanceMessage.SessionCreator.rollback_session/3
EzagentDomainInstanceMessage.SessionCreator.materialize_template_team/4
```

Move internals into modules named for the sequence's real seams:

- `SessionCreator.TemplateResolver`
  - Interface: `resolve!(template_name, workspace_uri)`, `resolve_for_repair(session_uri, workspace_uri)`, `find_uri(template_name, workspace_name)`.
  - Hides snapshot lookup and content-addressed SessionTemplate selection.
- `SessionCreator.Materializer`
  - Interface: `create(session_uri, workspace_uri, creator_uri, template)` returning `{:ok, meta}` or `{:error, reason}`.
  - Owns the 4-8 fail-loud sequence, but delegates sub-operations.
- `SessionCreator.OrchestratorBootstrap`
  - Interface: `materialize_working_copy/3`, `ensure/4`, `grant_caps/4`, `register_mcp/4`, `ready_meta/4`.
  - Hides orchestrator-specific materialization while keeping rollback visible to the materializer.
- `SessionCreator.TemplateTeam`
  - Interface: `materialize(session_uri, workspace_uri, granted_by, content)` returning spawned members and installed rows.
  - Hides role-name to URI maps, member facets, prompt templates, legends, rule sets.
- `SessionCreator.Rollback`
  - Interface: `session(session_uri, orchestrator_uri, opts)`, `delete_rule_rows/1`, `forget_lineage/1`.
  - Hides compensation details and centralizes "what residue must be removed".
- `SessionCreator.Listing`
  - Interface: `list_sessions/0`, `list_sessions/1`.
  - Low-risk tail extraction.

**Why deeper**: the public writer remains simple and load-bearing; the implementation gains locality around invariant clusters. Reviewers can audit "template resolution" or "rollback surfaces" without reading two thousand lines.

**Risk**: High. Touches RBK invariants, rollback, workspace binding, orchestrator MCP context, and template materialization. Phase-2 PRs must be small and use source review plus test proof.

### 3.3 `cc.agent` and `codex.agent`: Template Class as adapter over flavor runtime seams

**Anti-pattern**: leaky seam and duplicated flavor runtime. `CcAgent` and `CodexAgent` implement `Ezagent.Kind.Template`, `Ezagent.UI.Form`, credential declarations, config-home allocation, cascade materialization, sidecar process parameters, rollback, respawn, and test credential refresh in one module each. The Template Class interface is too small for the amount of flavor runtime hidden behind it, so implementation details leak through long private helper chains.

**Proposal**: introduce shared domain/plugin-adjacent modules only where there are at least two real adapters (`cc` and `codex`):

- `Ezagent.Agent.TemplateData`
  - Interface: `validate_common/2`, `template_data_extra/2`, `form_to_args/2`.
  - Hides common agent URI/cwd/config_dir validation and optional flavor data.
- `Ezagent.Agent.ConfigHome`
  - Interface: `resolve(agent_uri, tmpl, adapter)`, `materialize(agent_uri, tmpl, adapter)`, `env(agent_uri, tmpl, adapter)`.
  - Adapter callbacks: `namespace/0`, `env_var/0`, `secret_relpaths/0`, `credential_relpaths/0`.
  - Preserves cascade materializer and credential safety; do not weaken `validate_and_normalize` style boundaries.
- `Ezagent.Agent.SpawnPlan`
  - Interface: `build(agent_uri, tmpl, flavor_adapter)`, `start(plan)`, `rollback(plan, reason)`.
  - Hides fresh/adopted semantics and "no sidecar on adopted worker" policy.
- `EzagentPluginCc.Runtime` and `EzagentPluginCodex.Runtime`
  - Interfaces stay flavor-specific: `pty_params/3`, `command/3`, `sidecars/3`, `ensure_alive/2`.
  - These are adapters, not new core concepts.

`CcAgent` / `CodexAgent` should shrink toward:

- `template_name/0`, `config_dir_namespace/0`, credential adapter declarations.
- `validate/1`, `instantiate/3`, `form_fields/0`, `form_to_args/1`.
- Flavor-specific command/sidecar adapter delegation.

**Why deeper**: the Template Class interface becomes leverage again. Shared config-home and spawn-plan policy is audited once; flavor modules express only what differs.

**Risk**: High. Security-sensitive code includes config-home copying, secret relpaths, grant minting, cascade resolution, sidecar rollback, and auth failure signals. Do not merge this before the proposal review and before a dedicated behavior-preservation diff review.

### 3.4 `Orchestrator.Tools` and `Orchestrator.McpServer`: split domain tools from MCP transport

**Anti-pattern**: leaky adapter seam. The MCP server knows context rebuild, schemas, argument coercion, tool dispatch, error mapping, and GenServer process form. `Tools` knows tool names, member lifecycle, routing rule mutation, template writes, and cap preflights.

**Proposal**:

- `Ezagent.Orchestrator.ToolCatalog`
  - Interface: `names/0`, `schema(tool)`, `schemas/0`, `normalize(tool)`.
  - Hides MCP JSON schema definitions and keeps schema parity with actual tools.
- `Ezagent.Orchestrator.ContextResolver`
  - Interface: `new(opts)`, `from_orchestrator_uri(uri)`, `refresh_caps(ctx)`.
  - Hides `McpRegistry` cache rebuild from durable Session snapshot.
- `Ezagent.Orchestrator.McpCodec`
  - Interface: `args(tool, raw_args)`, `result(tool, tool_result)`, `error(reason)`.
  - Hides argument coercion and MCP error mapping.
- `Ezagent.Orchestrator.TeamTools`
  - Interface: `add_member/4`, `update_member_template/3`, `remove_member/2`.
  - Hides managed-member spawn, regeneration, compensation.
- `Ezagent.Orchestrator.RoutingTools`
  - Interface: `define_rule_set_rule/4`, `define_prompt_template/3`, `define_legend/5`, `prune_for_member/2`.
- `Ezagent.Orchestrator.TemplateTools`
  - Interface: `update_template/1`, `save_template_as/2`, `list_templates/2`.

`McpServer` then becomes either a value/process wrapper around context + codec + catalog, while `Tools` can remain a compatibility facade delegating to the deeper modules.

**Why deeper**: MCP transport can change without touching team mutation, and team mutation can be audited without reading JSON schema and GenServer boilerplate.

**Risk**: Medium. It touches CapBAC-sensitive tool execution, but the split can be behavior-preserving with `Tools` as a facade.

### 3.5 `Behavior.Chat`: keep one Behavior, split implementation concepts

**Anti-pattern**: broad implementation behind a correct interface. `Chat` being one Behavior is right: `send`, `receive`, `join`, `leave`, working copy, legends, prompt templates, and signals all operate on the `:chat` slice. Splitting the Behavior interface would weaken RBK clarity. The issue is implementation locality.

**Proposal**:

- `Ezagent.Behavior.Chat.State`
  - Interface: `create(args)`, `activate(state, ctx)`, `read(ctx, key, default)`.
- `Ezagent.Behavior.Chat.Membership`
  - Interface: `join(state, member_uri, facets, ctx)`, `leave(state, member_uri, ctx)`, `handle_down(state, ref, ctx)`.
- `Ezagent.Behavior.Chat.Delivery`
  - Interface: `send_message(msg, ctx)`, `receive_message(msg, ctx)`.
  - Hides MessageStore writes, recipient fan-out, User inbox notifications, AgentBridge delivery.
- `Ezagent.Behavior.Chat.TemplateWorkingCopy`
  - Interface: `set/2`, `set_legends/2`, `set_prompt_templates/2`, `role_name_to_uri/2`.
- `Ezagent.Behavior.Chat.Ring`
  - Interface: `put_recent(state, msg, cursor)`, `message_preview/1`.

The public Behavior actions and `use Ezagent.Lifecycle, state_slice: :chat` remain in `Chat`; helpers operate on explicit state maps and return effects.

**Why deeper**: this preserves the one Behavior seam while making each state-machine concern testable without mocking full dispatch.

**Risk**: Medium. It touches lifecycle transients, sibling-slice reads, delivery fan-out, and prompt rendering. Keep the first PR to mechanical helper extraction.

### 3.6 `Entity.Agent` and `Entity.Session`: Kind declarations should be shallow; facades should be deep

**Anti-pattern**: mixed declaration and implementation. A Kind module's declaration interface (`type_name/0`, `behaviors/0`, `persistence/0`, `supervisor/0`) is intentionally shallow. The problem is when the same module also owns a deep facade.

**Agent proposal**:

- Keep `Ezagent.Entity.Agent` as the Kind declaration and public facade.
- Move spawn/materialization internals into:
  - `Ezagent.Entity.Agent.Spawner`: `spawn/4`, `spawn_fresh/4`, `spawn_from_template_content/5`.
  - `Ezagent.Entity.Agent.CredentialCascade`: `resolve/5`, `build/5`, `snapshot/1`.
  - `Ezagent.Entity.Agent.SandboxRecorder`: `record/3`, `cleanup_partial/2`.
  - `Ezagent.Entity.Agent.PostSpawn`: `bind_workspace/2`, `record_lineage/2`, `undo_fresh/1`.

**Session proposal**:

- Keep `Ezagent.Entity.Session` as the Kind declaration and Publisher facade.
- Move orchestrator internals into:
  - `Ezagent.Entity.Session.Orchestrator`: `ensure/3`, `planned_uri/2`, `read_template_working_copy/1`.
  - `Ezagent.Entity.Session.OrchestratorReadiness`: `await/3`, `kill_on_timeout/1`.
  - `Ezagent.Entity.Session.PublisherFacade`: `subscribe_from/4`, `snapshot/2`, `history/4` if the Publisher behaviour allows delegation without obscuring docs.

**Why deeper**: Kind declaration remains obvious, while spawn/orchestrator facades hide real workflows.

**Risk**: Medium-high. `Agent` touches credential lifecycle and lineage. `Session` touches orchestrator readiness and Publisher caps.

### 3.7 Core RBK primitives: split grammars and policies, not stages

**Anti-pattern**: multi-interface modules. The core files are not god-modules in the same way as UI/domain files; they are dense because they define primitive contracts. Splitting them badly would create shallow pass-through modules and make RBK harder to learn.

**Proposal**:

- `Ezagent.Behavior`
  - Keep `use Ezagent.Behavior`, `action/2`, and introspection functions as the public interface.
  - Extract `Ezagent.Behavior.ActionSpec` for action option validation and derived callbacks.
  - Extract `Ezagent.Behavior.Effects` for `apply_effects/2`, bucket grammar, and ref substitution.
  - Risk: medium; macro code is compile-time-sensitive.
- `Ezagent.Kind.Runtime`
  - Keep `handle_dispatch/4` public.
  - Extract `Ezagent.Kind.Runtime.Authz` and `Ezagent.Kind.Runtime.WorkspaceIsolation` because those are real policies with independent invariants.
  - Do not create one module per pipeline step unless the interface hides policy.
  - Risk: high; touches dispatch chokepoint.
- `Ezagent.Kind`
  - Keep behaviour callbacks and public `spawn/2`, `terminate/1`.
  - Extract `Ezagent.Kind.Lifecycle` for spawn/terminate strategies and `Ezagent.Kind.Introspection` for `behaviors_of/1` / attach metadata if line pressure remains.
  - Risk: medium-high.
- `Ezagent.Capability`
  - Extract `Ezagent.Capability.Normalize`, `Ezagent.Capability.Match`, and `Ezagent.Capability.Scope`.
  - Keep `Ezagent.Capability` as the public struct + facade.
  - Risk: high; CapBAC is security-critical.

**Why deeper**: interfaces align to grammar/policy seams: action specs, effects, authz, workspace isolation, capability normalization/matching.

## 4. Notable RBK Seams

These seams should be protected during all Phase-2 work:

- **RBK dispatch seam**: `Invocation.dispatch/1` to `Kind.Runtime.handle_dispatch/4` remains the semantic spine. No refactor may add direct actor-to-actor calls.
- **Lifecycle seam**: developer-facing Behavior code stays `use Ezagent.Lifecycle`; `use Ezagent.Behavior` and effect execution remain engine internals.
- **Template Class seam**: plugins provide Template Class adapters; core/domain define generic contracts. No plugin-specific scheme or core dependency.
- **SessionTemplate materialization seam**: `SessionCreator.create_session/3` remains the lower-level single writer; extraction must not create a second writer.
- **Agent config/credential seam**: credential relpaths, secret relpaths, config-home env vars, cascade grants, and auth failure signals are flavor adapter data over a shared materialization policy.
- **Orchestrator MCP seam**: untrusted wire input supplies tool args only; session, workspace, owner, parent template, and caps are resolved server-side.
- **Capability seam**: normalize inputs once, match on kind/behavior/action/instance/workspace, preserve scope tuple semantics.
- **ExternalMirror seam**: keep Publisher -> Worker Kind -> Adapter -> Binding; no direct PubSub subscription by bindings.

## 5. Prioritization

| Priority | Candidate | Impact | Safety | Why now |
|---|---|---|---|---|
| P0 | `AdminLive` state/event extraction | High | High | Biggest LOC file; low invariant risk; improves AI navigability immediately |
| P0 | `SessionCreator` listing / template resolver extraction | High | Medium | Starts the highest-value domain split with lower-risk edges |
| P0 | `SessionCreator` materializer / rollback / team modules | Very high | Low | Must be reviewed carefully; closes a major audit surface |
| P1 | `Orchestrator.McpServer` codec/catalog/context split | Medium-high | Medium | Separates transport from domain tools |
| P1 | `Orchestrator.Tools` team/routing/template split | High | Medium | Tool behavior becomes auditable by concern |
| P1 | `CcAgent` / `CodexAgent` shared config-home and spawn-plan seam | Very high | Low | Removes duplicated security-sensitive flavor runtime, but risky |
| P1 | `Behavior.Chat` helper extraction | High | Medium | Keeps Behavior seam intact while improving locality |
| P2 | `Agent` / `Session` facade extraction | Medium-high | Medium | Helps after SessionCreator/tool splits clarify caller needs |
| P2 | Core `Behavior` / `Capability` grammar splits | Medium | Low | Needs stronger test proof; do after domain/UI precedent |
| P3 | Core `Kind.Runtime` / `Kind` policy splits | Medium | Low | Highest blast radius; only after all callers are stable |

## 6. Recommended Phase-2 PR Sequence

1. **PR-A: AdminLive session context + rehydrate flash extraction**
   - Mechanical move. Preserve route, render, assigns, and DOM IDs.
   - Tests: touched LiveView tests only.

2. **PR-B: AdminLive compose/invite/routing form extraction**
   - Mechanical move plus helper tests for mention parsing and routing form validation.
   - Tests: LiveView + helper unit tests.

3. **PR-C: SessionCreator listing + template resolver extraction**
   - Keep facade unchanged. Move tail/listing and template lookup first.
   - Tests: existing SessionTemplate/session creation tests.

4. **PR-D: SessionCreator TemplateTeam extraction**
   - Move member materialization, role maps, prompt templates, legends, and rule sets.
   - Tests: materialization, routing rule, legend/prompt tests.

5. **PR-E: SessionCreator OrchestratorBootstrap + Rollback extraction**
   - Highest-risk session PR. Audit rollback write surfaces explicitly.
   - Tests: orchestrator startup atomicity, rollback, MCP registry rehydrate.

6. **PR-F: Orchestrator.McpServer catalog/context/codec extraction**
   - Preserve `McpServer` value/process interface.
   - Tests: MCP schema/tool-call/error mapping tests.

7. **PR-G: Orchestrator.Tools team/routing/template modules**
   - Keep `Tools` facade delegating to deeper modules.
   - Tests: tools tests plus routing/template update tests.

8. **PR-H: cc/codex shared ConfigHome and SpawnPlan foundation**
   - Introduce shared modules with both flavors as adapters; no behavior change.
   - Tests: cc + codex template tests, config-dir/cascade/credential tests.

9. **PR-I: Behavior.Chat helper modules**
   - Keep action declarations in `Chat`; move state-machine helpers.
   - Tests: chat behavior, sender/legend/prompt, AgentBridge delivery.

10. **PR-J: Agent/Session facade extraction**
    - Move spawn/orchestrator internals after SessionCreator and Tools settle.
    - Tests: agent template spawn, orchestrator readiness, publisher facade.

11. **PR-K/L: Core grammar/policy splits**
    - `Behavior.ActionSpec` + `Behavior.Effects`; then `Capability.Normalize/Match/Scope`.
    - Defer `Kind.Runtime` unless there is a concrete testability gain.

## 7. What Not To Do

- Do not split a file only to reduce line count. If the new module's interface is just "call the next step," it is shallow.
- Do not split `Behavior.Chat` into multiple Behaviors unless a real slice/interface changes. That would alter RBK semantics.
- Do not make `SessionCreator` less central. The goal is a deeper internal materializer behind the same single writer.
- Do not introduce generic "AgentRuntime" in core. Flavor runtime remains plugin/domain adapter territory.
- Do not collapse CapBAC or workspace isolation into convenience defaults for tests.

## 8. Review Checklist For Phase 2

Each refactor PR should answer:

- Which interface got smaller or deeper?
- Which implementation detail is now local?
- Which RBK invariants could this touch?
- Is the diff a pure move/split, or did behavior change?
- What test evidence proves behavior preservation?
- Did static Codex review inspect the load-bearing seams without running `mix`?

## 9. Phase-1 Conclusion

Proceed with Phase 2 only after review. Recommended first implementation target is `AdminLive`, then the low-risk edges of `SessionCreator`. The `cc/codex` shared runtime seam is architecturally important but should wait until the review confirms the exact config-home and credential boundaries, because that area is security-sensitive and easy to over-generalize.
