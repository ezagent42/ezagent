# Phase 7 completion — the Generator + the live Orchestrator

> **Status**: DRAFT rev 2 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22 ("和 codex 配合完成 Phase 7 的工作 … v1 要求是
> 完整的生产可用性，不要留尾巴").
>
> - **rev 1**: initial 6-PR scope from the audit.
> - **rev 2**: `codex adversarial-review` — 1 CRITICAL + 4 HIGH + 2
>   MEDIUM, all addressed. (a) CRITICAL — rev 1 copied the LOCKED
>   phase7 SPEC's URI shapes (`template://session/<name>@<hash>`)
>   verbatim, but the repo's Phase-9 URI migration moved to 3-segment
>   per-workspace URIs — rev 2 uses the CURRENT model everywhere.
>   (b) the working-copy must be normalized live→template BEFORE
>   persistence. (c) CapBAC lands per-path in the PR that introduces
>   the path, not batched. (d) PR-5 is a real privileged MCP surface,
>   specified concretely. (e) AgentTemplate is persistent CONFIG;
>   instantiation is delegated to plugin Template Classes by flavor.
>   (f) transactional persistence schema. (g) tests per-PR.

This SPEC **completes** the LOCKED `docs/phase-specs/phase7/SPEC.md`
(v3). The phase7 SPEC's *design intent* (the Generator, the live
Orchestrator, the 7 tools, git-style versioning) is the design of
record; its concrete **URI shapes are superseded** by the Phase-9
3-segment-per-workspace URI migration (see §2). rev 2 scopes the
unbuilt ~40% the audit
(`docs/notes/phase-7-implementation-audit-2026-05-22.md`) found.

## 0. What this completes

Audit verdict: Phase 7 is ~55-60% real. **Solid — do not re-do**:
WorkspaceRegistry, AgentLineage, `Agent.spawn/4`, the scope-bounded
delegation caps, `mix ezagent.bootstrap`. **Unbuilt — this SPEC**:

1. The Orchestrator does not run — `Ezagent.Orchestrator.Tools` (444
   lines) is imported by nothing; no MCP exposure.
2. `update_template` / `save_template_as` compute a hash + URI and
   **persist no row** — `build_working_copy/4` returns a slice, the
   tool calls `compute_version_hash` + `build_uri`, returns the URI,
   inserts nothing.
3. The Generator is the "minimal PR-41" stub — spawns only the
   orchestrator.
4. `SessionTemplate.fork/2`, `.create/2`, the `template_tags`
   registry — absent.
5. AgentTemplate / SessionTemplate are bare Kinds — no
   `Ezagent.Kind.Template` impl, slice schemas moduledoc-only.
6. No `template:` cap is ever enforced.
7. ~7 V1-V5 gating tests missing.

## 1. Architectural decisions rev 2 locks (codex fixes)

### 1.1 AgentTemplate is persistent CONFIG — it does NOT spawn (codex HIGH-e)

`Ezagent.Entity.AgentTemplate` is a registry-stored **config record**:
a pointer to a sandbox + a cap policy. It does NOT itself launch a
`claude` PTY. **Instantiation is delegated** — the Generator (and the
orchestrator's `add_agent_slot`) resolves an AgentTemplate, reads its
`flavor`, and routes the actual spawn through the **plugin Template
Class** for that flavor (`Ezagent.PluginCc.Template.CcAgent` for cc,
etc.) via `TemplateRegistry`. The plugin owns the launch — including
cc's tokenized MCP-config generation and the **non-bypassable
`--settings` safety override** (`remoteControlAtStartup: false`). An
AgentTemplate slice's `settings_path` / `mcp_config_path` are
operator overrides the cc Template Class APPLIES — they are layered
UNDER the mandatory safety settings (last-wins / validated; the
cc-agent-config SPEC's HIGH-2 fix governs), and an operator
`mcp_config_path` may NOT replace the trusted bridge config.

AgentTemplate gains a `flavor` slice field (`"cc"` etc.) so the
delegation target is explicit. Non-cc flavors are supported the day
their plugin Template Class accepts the AgentTemplate slice.

### 1.2 URIs — the CURRENT 3-segment per-workspace model (codex CRITICAL)

The phase7 SPEC predates Phase 9. The model in force NOW (verified:
`SessionTemplate.build_uri/3`):

- AgentTemplate — `template://agent/<workspace>/<name>`
- SessionTemplate — `template://session/<workspace>/<name>@<hash>`
- Tag-addressed — `template://session/<workspace>/<name>:<tag>`

`Ezagent.TemplateTags` is keyed by **`(workspace, name, tag)`** — a
`stable` tag in workspace A and in workspace B are distinct rows and
must never resolve to each other. Every cap `instance` and every
URI parse/build in this SPEC uses the 3-segment model. Re-instate
the cross-workspace non-collision as an invariant test.

### 1.3 The canonical `template_working_copy` schema (codex HIGH-b)

The current `Tools.build_working_copy/4` derives a slice from LIVE
runtime — `agent_slots` as `{slot_name, entity://agent/...}` (a live
instance URI), routing receivers as live agent URIs, and it would
hash `session_uri` in. That slice is **not a reusable template** and
two identical teams in two sessions hash differently.

rev 2 defines `template_working_copy` as a **template-shaped** Session
slice, and a **normalization** function `live → template`:

- `agent_slots :: [{slot_name, template://agent/<ws>/<name>}]` — each
  live worker carries (from the Generator) the AgentTemplate URI it
  was spawned from; the working copy stores THAT, never the live
  `entity://agent` URI.
- `routing_rules :: [{matcher_ast, [slot_name]}]` — receivers are
  slot NAMES, not live URIs (resolved to URIs on instantiate).
- The version hash is computed over `{agent_slots, routing_rules,
  orchestrator_template_uri, default_workspace_uri, description}`
  ONLY — `session_uri`, timestamps, `created_by`, live pids
  EXCLUDED, so identical configs hash identically.

The working copy is initialized by the Generator (PR-4) and mutated
by the orchestrator tools (PR-5); it is the ONLY thing
`update_template` / `save_template_as` persist.

## 2. PR sequence (contracts → persistence+auth → generator → orchestrator)

Every PR carries its own tests (codex HIGH-f / MEDIUM-g) — no test
batching to a closeout PR.

### PR-1 — Template Classes + the 3-segment contract + `template:read`

- AgentTemplate + SessionTemplate implement `Ezagent.Kind.Template`
  (`template_name/0`, `validate/1`, `instantiate/3`) with real slice
  fields (phase7 SPEC schemas, adjusted: AgentTemplate gains
  `flavor`; both use 3-segment URIs).
- `AgentTemplate.instantiate/3` — does NOT spawn; resolves `flavor` →
  the plugin Template Class via `TemplateRegistry` and delegates
  (§1.1).
- `SessionTemplate.instantiate/3` — delegates to the Generator (PR-4).
- `Ezagent.TemplateTags` registry — `(workspace, name, tag) → hash`
  (schema only here; population in PR-2).
- `template:read` cap enforced on `list_templates` / any template
  enumeration introduced here.
- Tests: `validate/1` accept/reject; the 3-segment URI round-trip;
  cross-workspace name non-collision; `template:read` denial.

### PR-2 — working-copy normalization + transactional persistence + write caps

- The `template_working_copy` Session slice schema (§1.3) + the
  `live → template` normalization function.
- Rewrite `Orchestrator.Tools.build_working_copy/4` to emit the
  template-shaped slice (AgentTemplate URIs + slot-name routing,
  `session_uri` excluded from hash input).
- `update_template` / `save_template_as` **persist** — a
  DB-backed SessionTemplate row + `template_tags`. **Transactional**
  (codex MEDIUM-f): `Repo.transaction` around row-insert + owner-cap
  grant; unique constraints `(workspace, name, version_hash)` and
  `(workspace, name, tag)`; idempotent duplicate-hash insert (same
  content → same hash → no-op, not error); tag moves are CAS
  (compare-and-swap on the prior hash).
- CapBAC IN THIS PR (codex HIGH-c): `update_template` requires
  `template:write` on the parent name; `save_template_as` requires
  the template-create cap. `list_templates` already gated in PR-1.
- Tests: persisted row is re-instantiable; identical config hashes
  identically across sessions; immutable-hash (no in-place rewrite);
  concurrent `save_template_as` race → one wins deterministically;
  `template:write`-less caller denied.

### PR-3 — the 3 session-creation entry points (+ their caps)

- `SessionTemplate.fork/2` — new row, `parent_template_uri` set,
  requires the template-create cap.
- `SessionTemplate.create/2` — new root template, requires the
  template-create cap.
- Both, and `spawn_from_template`, require `template:instantiate`
  before they instantiate (the cap lands here, not PR-4 — codex
  HIGH-c). Row-creation and instantiation are each cap-gated.
- Tests: fork lineage (`parent_template_uri` correct, parent row
  unchanged); create produces a root; cap denial on each path.

### PR-4 — the Generator, fully

`Session.spawn_from_template/2` performs all 8 phase7-SPEC steps
(currently 4). Adds: resolve `agent_slots` → spawn each worker via
the flavor-delegated plugin Template Class (§1.1), each worker
tagged with its source AgentTemplate URI; resolve `routing_rules`
slot-names → per-instance URIs → install rules; initialize the
`template_working_copy` slice (§1.3). `template:instantiate` is
already enforced (PR-3). The orchestrator's two scope-bounded caps
already work (audit §8).
- Tests: a multi-slot template instantiates all workers + routing;
  re-instantiation produces an identical team; the working-copy slice
  is populated + survives restart (`{:snapshot, :on_change}`).

### PR-5 — the Orchestrator runs: the privileged MCP surface

The decisive PR — specified as a concrete component, not "wiring"
(codex HIGH-d).

- **Dispatch-routing the tools first.** `Orchestrator.Tools` today
  calls `Agent.spawn/4` / `RuleStore.add/5` / `terminate_child`
  DIRECTLY — bypassing dispatch + CapBAC. Each of the 7 tools is
  refactored to go through `Ezagent.Invocation.dispatch/1` so the
  orchestrator's scope-bounded caps are actually enforced on every
  tool action. A tool that cannot be expressed as a dispatch target
  gets one (a behavior on the appropriate Kind).
- **The orchestrator MCP server** — a new component (in
  `ezagent_domain_chat`). Concrete contract:
  - **Tool JSON schemas** — one per the 7 tools, declared
    explicitly.
  - **Caller context** — the MCP server runs per-orchestrator-agent;
    the calling orchestrator's URI + its scope-bounded caps form the
    `ctx` for every dispatched action. No tool runs with ambient
    `admin_caps`.
  - **Session context** — the orchestrator's session URI is bound at
    MCP-server start; tools that need it (working-copy mutation) read
    it from there, never from tool args.
  - **Error propagation** — a dispatch `{:error, :unauthorized}` /
    `{:error, _}` becomes a structured MCP tool error the
    orchestrator LLM sees + can surface in chat.
  - This is a NEW privileged surface — it gets its own auth test
    matrix (PR-5 tests).
- **The `cc-orchestrator` AgentTemplate config** — the boot seed
  populates a real slice: a `claude_config_dir`, a `settings.json`
  enabling the orchestrator pattern, an `mcp_config_path` pointing at
  the orchestrator MCP server, a system prompt. `flavor: "cc"`.
- **The chat path** — mentioning the orchestrator routes (via
  mention-gated routing #226) `chat.receive` to it; the live
  `claude` processes it and may call the 7 MCP tools.
- Tests IN THIS PR: a **deterministic fake-LLM / fake-MCP e2e** that
  drives the 7 tools through the MCP server + asserts CapBAC holds
  (an out-of-scope tool call → `:unauthorized`); per-tool effect
  tests. The human agent-browser demo is **supplemental release
  evidence, not the CI gate** (codex MEDIUM-g).

### PR-6 — closeout

- Any V1-V5 gating test not already landed by PR-1..5
  (`bootstrap_to_serving`, `plugin_hot_install` if still missing).
- Correct `docs/notes/phase-7-handoff.md` (it falsely declares
  "v1 release, code-complete") + the stale `phase-7-resume-state.md`.
- The supplemental human agent-browser e2e (phase7 SPEC §"e2e demo").

## 3. cc-agent-config reconciliation (audit §"Overlap")

The drafted `2026-05-22-cc-agent-config.md` (branch
`docs/cc-agent-config-spec`, unmerged) and Phase-7 AgentTemplate
design the same `CLAUDE_CONFIG_DIR` sandbox. **AgentTemplate is the
design of record** (§1.1 — it owns `claude_config_dir`,
`settings_path`, `mcp_config_path`, `api_key_helper`). After PR-1,
cc-agent-config shrinks to ~nothing.

**Decision flagged for Allen**: recommend **retiring the standalone
cc-agent-config SPEC** and folding cc agent configurability into
AgentTemplate (Phase 7). Allen confirms when back. Until then, the
cc-config branch stays unmerged and is NOT implemented.

## 4. macOS Keychain caveat (carry-forward)

`CLAUDE_CONFIG_DIR` isolates everything except macOS Keychain
credentials. The cc-config rev 2 spike confirmed file-based
credentials DO isolate. The `api_key_helper` AgentTemplate field
exists for the macOS multi-agent case; PR-1's cc Template Class
delegation + the runbook document it.

## 5. Scale, risk, user-assist

- PR-1..4 are bounded — fixing broken/incomplete shipped code against
  now-correct contracts.
- **PR-5 is highest-risk** — a new privileged command surface. It
  gets the most codex scrutiny + a deterministic CI e2e.
- **User-assist (flag per memory `feedback_flag_user_assist_steps`)**:
  PR-5/PR-6's live demo needs a human to drive an orchestration chat;
  the orchestrator's `claude` needs working credentials in its
  `claude_config_dir` — the same credential-seeding question as
  cc-config Q4. Allen needed for the live demo.

## 6. Verification

Each phase7 `VERIFICATION.md` row the audit marked NOT MET / PARTIAL
ends MET, with the gating test in the PR that delivers the behavior
(not batched): V2.1 (PR-5), V2.3/V2.5 (PR-2), V2.4 (PR-4), V2.6
(PR-4), V5.1's 7 tests distributed PR-1..6. The Generator instantiates
workers+routing (PR-4); a `template:instantiate`-less caller is denied
(PR-3); `phase-7-handoff.md` no longer claims a false "code-complete"
(PR-6).
