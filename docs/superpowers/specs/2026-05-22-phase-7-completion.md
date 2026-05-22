# Phase 7 completion — the Generator + the live Orchestrator

> **Status**: DRAFT rev 1 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22 ("和 codex 配合完成 Phase 7 的工作 … v1 要求是
> 完整的生产可用性，不要留尾巴"). Goes through `codex adversarial-review`
> before implementation.
>
> This SPEC **completes** the LOCKED `docs/phase-specs/phase7/SPEC.md`
> (v3). It invents no new design — the Phase-7 SPEC's §"Core design",
> §7-3 deliverables table, and §"Session-creation entry points" are
> the design of record. This SPEC scopes only the **unbuilt ~40%**
> the audit (`docs/notes/phase-7-implementation-audit-2026-05-22.md`)
> found, into an implementable PR sequence.

## 0. What this completes

The Phase-7 audit established: Phase 7 is ~55-60% real. The
infrastructure (WorkspaceRegistry, AgentLineage, `Agent.spawn/4`,
`mix ezagent.bootstrap`) and the scope-bounded delegation caps
(`{:within_session}` / `{:spawned_by}`) are **done and solid — do not
re-do them**. The **killer feature is unbuilt**: the SessionTemplate
Generator and the live in-session Orchestrator do not work end to end.

Concrete gaps this SPEC closes (audit §"Concrete unfinished items"):

1. The Orchestrator does not run — `Ezagent.Orchestrator.Tools` (444
   lines) is imported by nothing; no MCP exposure, no live agent.
2. `update_template` / `save_template_as` compute a hash + URI and
   **persist no SessionTemplate row** — template refinement is inert.
3. The Generator (`Session.spawn_from_template/2`) is the "minimal
   PR-41" stub — spawns only the orchestrator, no workers / routing /
   working-copy.
4. `SessionTemplate.fork/2` and `.create/2` do not exist; no
   `template_tags` registry exists.
5. AgentTemplate / SessionTemplate are bare Kinds — neither
   implements `Ezagent.Kind.Template` (`validate/1` + `instantiate/3`);
   slice schemas live only in moduledoc.
6. No `template:` cap is ever enforced.
7. ~7 V1-V5 gating tests missing.

## 1. Design (from the LOCKED phase7/SPEC.md — recap, not redesign)

- **AgentTemplate** — `Ezagent.Entity.AgentTemplate`, URI
  `template://agent/<name>`. Slice (phase7 SPEC §"AgentTemplate"):
  `name`, `description`, `working_directory`, `claude_config_dir`
  (→ `CLAUDE_CONFIG_DIR`), `settings_path`, `mcp_config_path`,
  `api_key_helper`, `default_caps`, `created_by`. A pointer to a
  sandbox + a cap policy — NOT a full agent spec.
- **SessionTemplate** — `Ezagent.Entity.SessionTemplate`, URI
  `template://session/<name>@<hash>`. Slice (phase7 SPEC
  §"SessionTemplate"): `name`, `description`, `agent_slots`,
  `orchestrator_template_uri`, `routing_rules`, `default_workspace_uri`,
  `parent_template_uri`, `version_hash`, `version_tag`, `created_at`,
  `created_by`.
- **Generator** — `Session.spawn_from_template/2` — the 8 steps in
  phase7 SPEC §"Generator".
- **Orchestrator** — an LLM-driven agent that lives in the session,
  holding the 7 tools (phase7 SPEC §"Orchestrator" table).
- **3 session-creation entry points**, **git-style hash + mutable
  tag versioning** (D7-10).

## 2. PR sequence

### PR-1 — AgentTemplate + SessionTemplate become real Template Classes

Both Kinds implement the `Ezagent.Kind.Template` behaviour
(`template_name/0`, `validate/1`, `instantiate/3`) and gain real
slice-field code (the schemas above — today moduledoc-only).

- **AgentTemplate**: the slice fields; `validate/1` schema-checks;
  `instantiate/3` spawns a configured agent — constructs the
  `CLAUDE_CONFIG_DIR` env from `claude_config_dir`, applies
  `settings_path` / `mcp_config_path` / `api_key_helper`. The agent
  spawned is a cc-flavor agent (a `claude` PTY) — `instantiate/3`
  hands the config to the cc plugin's spawn path.
- **SessionTemplate**: the slice fields; `validate/1`; `instantiate/3`
  delegates to the Generator (PR-4).
- **`Ezagent.Entity.AgentTemplate` registers via the plugin contract**
  — it ships in a plugin (`ezagent_domain_chat` hosts it today).

### PR-2 — Template persistence: rows, hashes, tags

- Fix `Orchestrator.Tools.update_template/_` and `save_template_as/_`
  to ACTUALLY persist — insert a `SessionTemplate` registry row
  `(name, version_hash, parent_template_uri, slice…)`. `update_template`
  writes a new hash row under the SAME name; `save_template_as` writes
  the first row of a NEW name. (phase7 SPEC §"update_template
  mechanics" / §"save_template_as mechanics".)
- **`Ezagent.TemplateTags`** — a new registry (`(name, tag) → hash`),
  mutable tags over immutable hash rows. `mix ezagent.session_template.tag`
  CLI + the lookup path (`template://session/<name>:<tag>` resolves to
  a hash).
- `version_hash` immutability — a row is never rewritten in place.

### PR-3 — the 3 session-creation entry points

- `SessionTemplate.fork/2` — `fork(parent_uri@hash, new_name)`:
  new row, `parent_template_uri = parent_uri@hash`, fresh hash,
  then `spawn_from_template`.
- `SessionTemplate.create/2` — `create(new_name, config)`: new root
  template (`parent_template_uri = nil`), then instantiate.
- (Entry point 1, `spawn_from_template`, is completed in PR-4.)

### PR-4 — the Generator, fully (+ `template:instantiate` cap)

`Session.spawn_from_template/2` performs all 8 phase7-SPEC steps —
currently only 4. Add: resolve `agent_slots` worker AgentTemplate
URIs → spawn each worker (via PR-1 `AgentTemplate.instantiate/3`);
resolve `routing_rules` slot-names → per-instance agent URIs → install
the rules; initialize the **`template_working_copy`** Session slice
(the live, divergent-from-parent team shape). Add the
`template:instantiate` cap kind + enforce it at the Generator entry
(phase7 SPEC §"spawn_from_template CapBAC gate"). The orchestrator
still gets its two scope-bounded caps (already working — audit §8).

### PR-5 — the Orchestrator runs end to end

The decisive PR. `Ezagent.Orchestrator.Tools`' 7 functions become
LLM-invocable.

- **MCP exposure** — an MCP server (in `ezagent_domain_chat`, reusing
  the cc plugin's existing MCP bridge infrastructure —
  `apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py` + the
  `--mcp-config` mechanism) exposes the 7 tools. Each tool handler
  dispatches the corresponding Ezagent action via
  `Ezagent.Invocation.dispatch/1` (the tool bodies already do this —
  audit §7 — they just need an MCP front door).
- **The `cc-orchestrator` AgentTemplate gets a real config** — a
  `claude_config_dir` with a curated `settings.json` + a
  `mcp_config_path` pointing at the orchestrator MCP server + a
  system prompt teaching the orchestrator pattern. The boot seed
  (`seed_cc_orchestrator_template`) populates a real slice, not an
  empty Kind.
- **The chat path** — mentioning the orchestrator agent in its
  session routes (via the now-mention-gated routing, #226) a
  `chat.receive` to the orchestrator; the orchestrator (a live
  `claude`) processes it and may call the 7 MCP tools.
- Working-copy semantics — every team-mutating tool updates the
  `template_working_copy` Session slice (PR-4); persistence is
  `{:snapshot, :on_change}` (already flipped — audit §9) so it
  survives restart.

### PR-6 — the missing tests + closeout

- The ~7 missing invariant/gating tests (audit V5.1):
  `orchestrator_cap_scope`, `template_immutable_hash`,
  `template_fork_lineage`, `template_tag_resolution`,
  `plugin_hot_install`, `bootstrap_to_serving`, and an
  `orchestrator_e2e` test.
- VERIFICATION V1-V5 — close every row the audit marked NOT MET /
  PARTIAL with a real passing test.
- Downgrade / correct `docs/notes/phase-7-handoff.md` (it falsely
  declares "v1 release, code-complete") and update the stale
  `phase-7-resume-state.md`.
- e2e per phase7 SPEC §"e2e demo" — agent-browser screenshots of a
  live orchestration session, a saved template, a re-instantiated
  session.

## 3. cc-agent-config reconciliation (audit §"Overlap")

The drafted `docs/superpowers/specs/2026-05-22-cc-agent-config.md`
(branch `docs/cc-agent-config-spec`, NOT merged) and Phase-7's
AgentTemplate **both design the same `CLAUDE_CONFIG_DIR` sandbox
mechanism**. The locked phase7 SPEC already places it on the
AgentTemplate slice (`claude_config_dir`, `settings_path`,
`mcp_config_path`, `api_key_helper`). **AgentTemplate is the design
of record** — PR-1 implements it there.

Therefore: **cc-agent-config does not also build a sandbox.** After
PR-1, the cc-agent-config SPEC must be revised (rev 3) to:
- DROP its Layer-2 `sandbox_mode` + the `:form`-surface plumbing for
  it — the sandbox lives on the AgentTemplate slice.
- Keep (if still wanted) a thin cc-plugin default: "new cc
  AgentTemplates get an isolated `claude_config_dir` by default."
- Its Layer-1 `settings_path` IS AgentTemplate's `settings_path`
  field — same thing.
- Its non-bypassable PTY safety `--settings` override
  (`remoteControlAtStartup: false`) MUST be honored by
  `AgentTemplate.instantiate/3`'s PTY-launch path — carry that
  finding forward into PR-1.

**Decision flagged for Allen**: this means cc-agent-config shrinks
to almost nothing once Phase 7 lands. Recommendation — fold the cc
agent configurability into AgentTemplate (Phase 7) and retire the
separate cc-config SPEC. Allen confirms when back.

## 4. The macOS Keychain caveat (carry-forward, phase7 SPEC §"AgentTemplate")

`CLAUDE_CONFIG_DIR` relocates everything EXCEPT credentials on
macOS (Keychain). The capability spike (cc-config rev 2 §4) confirmed
file-based credentials DO isolate. PR-1's `instantiate/3` + the
runbook must document: on macOS, multi-agent isolation needs either
separate OS users or a per-template `api_key_helper`. This is the
`api_key_helper` slice field's reason to exist.

## 5. Sequencing, risk, scale

- PR-1 → PR-2 → PR-3 → PR-4 are bounded, lower-risk — they fix
  broken/incomplete shipped code and add clearly-specified pieces.
- **PR-5 is the design-heavy, highest-risk PR** — the live LLM
  orchestrator wiring. It builds on the cc plugin's existing MCP
  bridge; it is "wire an existing tool module to an MCP front door +
  give the orchestrator agent a real config", not a from-scratch
  design. Still, it gets the most codex scrutiny.
- **User-assist steps** (flag per memory): PR-5's e2e + PR-6's
  agent-browser demo need a human to drive a live orchestration
  chat; the orchestrator's `claude` needs working credentials in its
  `claude_config_dir` (the cc-config Q4 credential-seeding question
  applies here too).

## 6. Verification

Every phase7 `VERIFICATION.md` row the audit marked NOT MET / PARTIAL
must end MET with a real test:
- V2.1 — the Orchestrator stands up a team from an NL prompt (PR-5).
- V2.3 / V2.5 — `save_template_as` / `update_template` create
  persisted, re-instantiable rows (PR-2).
- V2.4 — re-instantiation produces an identical team (PR-4).
- V2.6 — `template_working_copy` survives restart (PR-4).
- V5.1 — the 7 missing gating tests exist + pass (PR-6).
- The Generator instantiates workers + routing, not just the
  orchestrator (PR-4).
- A `template:instantiate`-less caller is denied the Generator (PR-4).
- `phase-7-handoff.md` no longer claims a false "code-complete".
