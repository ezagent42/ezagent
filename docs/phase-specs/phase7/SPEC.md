# Phase 7 — Session-template generator + complete handoff (Ezagent v1)

**Status:** **LOCKED v3** 2026-05-18 (Allen brainstorm rounds 1-3
+ subagent reviews 2.5; "spec 设计 OK" + AFK execution authorized).
**Theme:** Phase 7 is the **final phase Allen personally drives** and
the **official Ezagent v1 release**. After sign-off:

- Ezagent moves to a dev team Allen will not actively review.
- Phase 7 closes the v0 → v1 evolution: cap delegation becomes
  first-class (v0 baseline retires); session templates with
  fork/merge become the production unit of "a team you can spin up."
- The killer feature is a **production-grade session-template
  generator**: human enters a session, dialogues with that session's
  embedded orchestrator agent, the conversation IS the template-
  refinement process; the session can be forked, the owner can merge
  refinements back to the parent template or keep a new branch.

## North star

After Phase 7, a small dev team can:

- Take over `main` and ship features without architectural escalation.
  Decision Log, GLOSSARY, forensic notes + the `esr-developer` skill
  cover everything they need to make good choices.
- Run the system in a **quasi-production environment** with long-term
  data continuity — `~/.ezagent/<profile>/db/` is canonical; the dev
  DB no longer lives in the repo tree. `mix ezagent.bootstrap` spins up
  a fresh install in one command.
- Author session templates by dialoguing with an in-session
  orchestrator; templates are versioned, forkable, and reusable
  across teams and sessions.
- Install a new plugin into a running Ezagent via
  `mix ezagent.plugin.install`, without restarting Phoenix.
- Catch architectural drift in CI before merge — invariant tests
  cover workspace isolation, scope-bounded cap delegation,
  template fork lineage, channel meta schema, dispatch-only message
  flow, Receiver Kind contract.

## Handoff posture (LOCKED)

Allen 2026-05-18: "按照我完全离开 Ezagent 不管的思路进行规划" (plan as if
I completely leave Ezagent after this).

Practical implication:

- **No oral knowledge survives.** Every architectural choice must be
  in a Decision Log row, a forensic note, or the skill — not "ask
  Allen."
- **CI is the architecture police.** Invariant tests must fail when
  the dev team accidentally violates a principle Allen would have
  caught in review.
- **The skill is mandatory, not optional.** Dev team's Claude Code
  agents invoke `esr-developer` skill at the start of every
  Ezagent-touching task. The skill carries the anti-patterns Allen has
  corrected over the project's history.

## Core design — the three-layer composition

```
                        instantiate
SessionTemplate ──────────────────────→ Session (running)
(named, versioned, forkable)            (concrete chat room)
       │                                       │
       │ composes                              │ contains
       ▼                                       ▼
  - agent_slots: [{slot_name, template_uri}]   - orchestrator agent (live)
  - orchestrator_template_uri                  - N worker agents (live)
  - routing_rules: [matcher, receivers]        - routing_rules (workspace-scoped)
  - default_workspace_uri                      - working copy of template
  - parent_template_uri  (nil = root, else     - working copy diverges as the
    points to template this was forked from)     orchestrator/owner edit it
  - version, created_at, created_by

           │                                              │
           │ slots reference                              │ each agent is
           ▼                                              ▼
        AgentTemplate                                  Agent (running)
   - working_directory                              - bound to settings_path
   - settings_path                                  - has scope-bounded caps
   - name / description                             - granted_by = orchestrator
   - default_caps
```

### AgentTemplate — what an agent looks like (minimal)

Allen 2026-05-18: "AgentTemplate 不需要过于复杂，类似 Claude
AgentSDK 那样,指定工作目录,加载指定 setting 目录等等".

A `Ezagent.Entity.AgentTemplate` Kind instance with URI
`template://agent/<name>`. Slice schema (final v3 — based on
research into Claude Code 2.1.143 supported isolation flags):

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Stable id (`template://agent/<name>`) |
| `description` | string | Human-readable purpose |
| `working_directory` | string | OS CWD for the spawned agent's process |
| `claude_config_dir` | string | Becomes `CLAUDE_CONFIG_DIR` env var → relocates `.claude/` entirely (credentials, OAuth, MCP state, plugin/skill cache, session history). On Linux/Windows this isolates everything; on macOS the credentials live in Keychain regardless (see runbook caveat) |
| `settings_path` | string \| nil | Optional `--settings <path>` override (single JSON file). nil = use `claude_config_dir/settings.json` |
| `mcp_config_path` | string \| nil | Optional `--mcp-config <path>` override. nil = use `claude_config_dir/.mcp.json` |
| `api_key_helper` | string \| nil | Optional path to an `apiKeyHelper` script — required for multi-agent on macOS (Keychain workaround); ignored on Linux/Windows |
| `default_caps` | `[Ezagent.Capability.t()]` | Caps the orchestrator may grant to instances spawned from this template |
| `created_by` | URI | Provenance |

**Not in the slice** (deliberately): prompt, model, effort, tools
whitelist, MCP servers. All of those live in the pointed-at
`claude_config_dir` (or the explicit `settings_path` / `mcp_config_path`
override). Ezagent doesn't re-model what CC already encodes. AgentTemplate
is a pointer to a sandbox + a cap policy, not a full agent spec.

**macOS Keychain caveat** (per CC PTY isolation research):
`CLAUDE_CONFIG_DIR` relocates everything EXCEPT credentials on macOS
(those live in Keychain). For multi-agent isolation on a single
macOS user, either run agents in separate OS users OR populate
`api_key_helper` with a per-template helper script. Documented in
the plugin authoring guide (D7-6 deliverable) and the failure
runbook.

### SessionTemplate — what a team looks like (Template Class)

A `Ezagent.Entity.SessionTemplate` Kind instance with URI
`template://session/<name>@<hash>` (git-style SHA hash versioning
— see D7-10). Implements the existing `Ezagent.Kind.Template`
behaviour (which lives in `ezagent_core`, not workspace; cf. answer to
Allen's "为什么在 workspace 里" — see Decisions section). Slice
schema:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Stable id (versioned via `@<hash>` URI suffix; tags map names → hashes — see D7-10) |
| `description` | string | Human-readable purpose |
| `agent_slots` | `[{slot_name, template_uri}]` | Named positions in the team; each cites an AgentTemplate URI |
| `orchestrator_template_uri` | URI | Which AgentTemplate the bundled orchestrator uses (defaults to `template://agent/cc-orchestrator`) |
| `routing_rules` | `[{matcher_ast, [receiver_slot_names]}]` | Routing wiring expressed against slot names (resolved to URIs on instantiate) |
| `default_workspace_uri` | URI | Workspace new sessions land in |
| `parent_template_uri` | URI \| nil | nil = root template; else the template this was forked from (lineage). References the parent's specific `@<hash>`. |
| `version_hash` | string | SHA-256 over the slice content (deterministic); the URI suffix. Immutable per row. |
| `version_tag` | string \| nil | Optional human-readable tag (e.g. `"v1.2"`, `"stable"`) — a SEPARATE registry row maps `tag → version_hash` (mutable; tags can move) |
| `created_at` | DateTime | |
| `created_by` | URI | Owner who saved this version |

The Template Class implementation (`Ezagent.Template.SessionTemplate`,
in `ezagent_domain_instance_message` or new `esr_domain_template`) provides:

- `template_name/0 → "session.standard"` (or per-class id)
- `validate/1` — schema-check before persist
- `instantiate/3` — the **Generator** (see below)

### Generator — `Ezagent.Entity.Session.spawn_from_template/2`

Not an agent. The mix of code (`Generator` is the role,
`Ezagent.Entity.Session.spawn_from_template/2` is the entry point) that:

1. Reads SessionTemplate by URI
2. Creates fresh `session://<owner>-<timestamp>` URI
3. Resolves routing-rule slot names to fresh per-instance agent URIs
4. Spawns the orchestrator agent from `orchestrator_template_uri`
   with **scope-bounded delegation caps** (D7-3) for this session
5. Spawns each agent in `agent_slots` (worker agents)
6. Inserts routing rules with `workspace_uri = template.default_workspace_uri`
7. Initializes the session's **working-copy template state** —
   a slice on the Session Kind that tracks "current shape of this
   session, divergent from parent template since instantiation"
8. Returns new session URI + new orchestrator URI to caller

This is **what Allen called the "generator"** — the program that
turns a SessionTemplate into a live Session with embedded
orchestrator. Each fresh session gets its own orchestrator
instance.

### Orchestrator — session-internal template-refinement manager

Allen 2026-05-18: "我理解的 orchestrator 应该是每一个 session 的
manager", "进去和 orchestrator 对话的过程是 session template 完善
的过程".

The orchestrator is an **LLM-driven agent that lives in the session
for the session's lifetime**. It has six tools (all going through
dispatch + CapBAC). **Note**: the orchestrator does NOT have a
`fork` tool — fork is a SessionTemplate registry operation, not a
verb the orchestrator owns. The orchestrator can refine
(`update_template`) or save-as-new (`save_template_as`); to fork
an unrelated template, the human uses the session-creation entry
point.

| Tool | Args | Effect |
|---|---|---|
| `add_agent_slot` | `slot_name`, `agent_template_uri`, optional `prompt_override` | Spawns a new worker agent from template; adds to working-copy `agent_slots` |
| `remove_agent_slot` | `slot_name` | Despawns the worker, drops from working-copy |
| `update_agent_template` | `slot_name`, `new_agent_template_uri` | Replaces an agent slot's template (re-spawn) |
| `write_matcher` | `matcher_ast`, `receiver_slot_names` | Inserts routing rule into runtime + working-copy `routing_rules` |
| `update_template` | (no args) | Commit working copy as a NEW VERSION of the **current parent template** (new `version_hash`, parent_template_uri stays nil if parent was root, else points at parent's hash). Requires `template:write` cap on current parent's name. Older sessions continue on their snapshotted hashes. |
| `save_template_as` | `new_name` | Commit working copy as the FIRST version of a NEW template named `new_name` (parent_template_uri = current parent). Requires template-creation cap (granted to most users by default). Equivalent to "save as." |
| `list_templates` | optional `name_filter` | Returns available AgentTemplate and SessionTemplate URIs the caller can see per CapBAC |

(7 tools total — the previous "save_template" was ambiguous; split
into the two distinct operations Allen described.)

The session's **working-copy template state** is just a Session
slice field — every orchestrator tool that modifies team
composition updates it. The persisted parent SessionTemplate is
only touched by `update_template` or `save_template_as`.

### Session-creation entry points (LOCKED — Allen 2026-05-18)

Three ways to start a new session:

| Entry | Behavior |
|---|---|
| **Instantiate from existing template** | `Ezagent.Entity.Session.spawn_from_template(template_uri@hash, owner)` — uses the specified template version verbatim; creates new session URI |
| **Fork existing template + instantiate** | `Ezagent.Entity.SessionTemplate.fork(parent_uri@hash, new_name)` — creates a new template row with `parent_template_uri = parent_uri@hash` and a fresh `version_hash` from the (initially identical) slice content; immediately calls `spawn_from_template` on the new template |
| **Create blank template + instantiate** | `Ezagent.Entity.SessionTemplate.create(new_name, %{empty_config})` — creates a brand new root template (parent_template_uri = nil); immediately instantiates. Orchestrator then helps fill it in |

### Template version semantics (D7-10) — git-style immutable hash + mutable tag

- Every SessionTemplate row has an **immutable** `version_hash`:
  SHA-256 over the slice content (canonical encoding). The URI is
  `template://session/<name>@<version_hash>`.
- `orchestrator.update_template()` produces a **new row** with a new
  `version_hash` (because slice content changed). The previous row
  remains in the registry — older sessions instantiated from it
  continue to reference it.
- A separate `template_tags` registry maps `(<name>, <tag>) →
  version_hash`. Tags are **mutable** (a tag can be re-pointed),
  but each row is immutable. Like git: branches/tags move, commits
  don't.
- **Running sessions snapshot the hash at instantiate time** and
  continue to use it even after `update_template` produces new
  hashes. New instantiations get the latest hash if asked by name,
  or any specific hash if asked by URI.

### Fork vs update semantics — what the orchestrator can do

The orchestrator does **NOT** fork. Fork is a SessionTemplate
registry operation (`Ezagent.Entity.SessionTemplate.fork/2`). The
orchestrator's tools (D7-3) are about template REFINEMENT inside
the running session:

- `update_template()` — commit working copy as a new version of the
  **current session's parent template**. Requires `template:write`
  cap. Produces a new `version_hash` row; older sessions on prior
  hashes continue unaffected.
- `save_template_as(new_name)` — commit working copy as the FIRST
  version of a NEW SessionTemplate (parent_template_uri = current
  session's parent at instantiate time). Requires only the ability
  to create new templates (template-creation cap, granted to most
  users by default).

**Fork unit = configuration only.** Messages do not fork. Forked /
saved-as sessions start with empty chat history.

**Per-session working copy is local.** Two sessions instantiated
from the same `template://session/code-review@<hash>` diverge
independently. Neither sees the other's changes until one
`update_template`s, and even then the other doesn't auto-rebase
(the dev team has more important things to do than session-level
three-way merge).

## Sub-step model

Phase 7 = one monolithic phase delivered in **4 sub-steps**.

| Sub | Theme | Why this order |
|---|---|---|
| **7-1** | Infra closeout | Foundation for everything else. Closes deferred Phase 6 items + adds bootstrap + plugin install. |
| **7-2** | AgentTemplate + SessionTemplate registries | Orchestrator's vocabulary. Built atop the existing `Ezagent.Kind.Template` umbrella in core. |
| **7-3** | Orchestrator + scope-bounded delegation + fork/merge | The killer feature. Composes 7-1 (workspace scope) + 7-2 (template Kinds). |
| **7-4** | Handoff readiness | Locks Allen-quality judgment into CI + docs + LLM skill. |

Dependency: 7-1 → 7-2 → 7-3 → 7-4 (mostly serial; 7-4 doc work can
ramp up in parallel with 7-3).

## Decisions (LOCKED — Allen confirmed in brainstorm rounds 1-2)

These become numbered Decision Log entries at implementation time.

### D7-1: Orchestrator is LLM-driven, not deterministic (round 1)

Allen 2026-05-18: "如果没办法完成任务，这个编排者也没什么意义". The
permission-control safety of a deterministic dispatcher is real but
useless if the orchestrator can't reason about team composition.

`cc-orchestrator` is a CC agent with a system prompt + Ezagent-MCP
tools, not an Elixir state machine. It receives `chat/receive`
notifications via channel, reasons about template refinement, calls
the six tools.

**Counter-defense against the rejected option's risk** (LLM grants
unintended caps): scope-bounded delegation (D7-3) — CapBAC honors
the orchestrator's scope hints and refuses out-of-scope writes.

### D7-2: AgentTemplate + SessionTemplate are Template Classes under the existing umbrella (round 2)

Allen 2026-05-18: "Ezagent.Kind.Template 为什么会在 workspace 里面?"
followed by "Session Template 不是 template 的一种吗?".

**Verified by reading code**: `Ezagent.Kind.Template` is **already in
`ezagent_core`** (not workspace — that was my error in round 1). It's a
behaviour with callbacks `template_name/0`, `validate/1`,
`instantiate/3`. Workspace happens to be its biggest current user
(stores Template Class references in its `session_templates` map),
but the umbrella concept already exists in core.

**Therefore**: AgentTemplate and SessionTemplate are **new Template
Class implementations** under the existing umbrella, parallel to
`Ezagent.Template.CcChannelInstance` and `Ezagent.Template.GenericSession`.
No name collision, no rename needed. The "AgentBlueprint" rename
from round 1 is **reverted** — AgentTemplate is the right name.

`Ezagent.TemplateRegistry.register/1` (single-arg, reads
`template_name/0` itself) gains entries for both. Plugin authors
can register their own Template Classes the same way.

### D7-3: Scope-bounded cap delegation — Phase 7 closes v0 → v1 (round 1 confirmed round 2)

Allen 2026-05-18: "delegation v0 不做,但 phase 7 结束后我们实际上
进入了 v1,该加上了".

**Phase 7 closeout = official Ezagent v1 release.** D7-3 retires the
ARCHITECTURE §17.6 baseline ("v0 不支持 delegation"). v1 introduces
**bounded delegation as a first-class cap shape**, two new
`instance` tuple shapes:

- `{:within_session, session_uri}` — cap valid only when needed cap
  targets a URI within `session_uri`
- `{:spawned_by, principal_uri}` — cap valid only when needed cap
  targets an agent in `principal_uri`'s spawn lineage

The orchestrator agent does NOT carry `admin_caps()`. Instead, the
Generator (during session instantiation) grants the orchestrator a
scope-bounded delegation cap, allowing it to act as a delegate
within session scope without becoming a full admin.

**Implementation gap surfaced during SPEC review** (round 1):
`Ezagent.Capability.matches?/2` currently only handles `:any` or exact
equality on `instance`. Phase 7-3 MUST extend `matches?/2` (or add
`matches_scoped?/2` wrapper called from CapBAC step 5.5) to honor
the two new tuple shapes. Treating this as an explicit deliverable,
not a hidden assumption.

ARCHITECTURE §7.2 / §7.3 / §17.6 all get updates to reflect v1
delegation model.

### D7-4: Federation explicitly dropped from Phase 7 (round 1)

Allen 2026-05-18: "Federation 可以完全不做,我后续再开". Not in scope,
not in plan, not even prep-work. Dev team should not try to build
federation hooks "in case."

### D7-5: EZAGENT_HOME DB migration is mandatory + `mix ezagent.bootstrap` (round 1 expanded round 2)

`mix ezagent.home.adopt_db` already exists (Phase 6 PR 1) with
`repo_root_clean_test.exs` invariant. Phase 7-1 makes it **mandatory
in dev onboarding** AND ships a higher-level `mix ezagent.bootstrap`
that wraps init + adopt_db + migrate + health-check in one command
for the dev team's "quasi-production" deployments.

Allen 2026-05-18: "Ezagent 的安装应该是 release 形态,不过因为没有
federation,暂时只需要简单的 run 脚本(或者 mix task)方便启动就可以了".
Full OTP release / Docker / systemd left to future iterations the
dev team can scope themselves.

### D7-6: The `esr-developer` skill is the dev team's "Allen replacement" (round 1)

Allen 2026-05-18: "制作一个 esr skill,用于后续开发团队基于现有 esr
进行开发时辅助 LLM". The skill is the single most important Phase 7-4
deliverable: docs decay, but a skill the dev team's Claude Code
agents invoke on every task survives as canonical guidance.

### D7-7: Fork unit = configuration only (round 2)

Allen 2026-05-18: "A，只 fork 配置就可以".

- Forked sessions start with empty chat history
- SessionTemplate stores only configuration (agent slots, routing,
  orchestrator template, etc.), not message snapshots
- Two sessions instantiated from the same template can diverge
  independently — no auto-rebase between them
- Three-way merge of working copies is **not** a Phase 7 feature
  (would require message-tier conflict resolution, way out of
  scope). Owner picks: save to fork (new name) or merge back to
  parent (requires `template:write` cap).

### D7-8: Plugin runtime hot-install (load+start), no unload (round 2)

Allen 2026-05-18: "plugin 我希望 runtime hot-reload,现在设计可以做
到吗?".

Phase 7-1 ships `mix ezagent.plugin.install <path>`:

- `:application.load/1` the new OTP app from the path
- `:application.start/1` to kick off its supervision tree
- Plugin's `Application.start/2` runs its existing registry-register
  hooks (BehaviorRegistry, KindRegistry, RoutingRegistry,
  TemplateRegistry as needed) — no change to plugin contract
- Returns the list of newly registered Kinds + Behaviors for
  observability

**What Phase 7 does NOT do**:
- Plugin **unload** / **swap** (requires Kind lifecycle management
  for live instances of the unregistered Kind; non-trivial)
- Production hot-deploy / OTP `relup` machinery
- Both are dev team's call when they need them

Single-module reload (`:code.purge` + `:code.load_file`) is already
supported by Phoenix dev-mode reloader; Phase 7-4 documents this in
the plugin authoring guide as the day-to-day flow.

### D7-9: Ezagent packaging = `mix ezagent.bootstrap`; no OTP release in Phase 7

See D7-5. Bootstrap is sufficient for "dev team installs Ezagent on a
prod-like host." Full release engineering is future work.

### D7-10: SessionTemplate versioning = git-style immutable SHA hash + mutable tag (round 3)

Allen 2026-05-18 (round 3): "修改后的 session template 版本号更新
(更新为一个新的 hash,类似 git 的方式,也可以打 version tag),不影响
已经在运行的 session(用的还是之前版本的 session template)".

**Versioning model:**

- Every SessionTemplate row's URI is `template://session/<name>@<version_hash>`
  where `version_hash` is **SHA-256 over the slice content** (canonical
  encoding excluding timestamps + `created_by`). Two rows with identical
  config produce identical hashes — content-addressable.
- `version_hash` is **immutable** per row. Updates produce new rows.
- Tags (`v1.0`, `stable`, etc.) live in a separate `template_tags`
  registry mapping `(name, tag) → version_hash`. Tags are **mutable**
  — they can be re-pointed at any existing hash for the same name.
- Sessions snapshot the resolved hash at instantiate time and continue
  using it forever, regardless of subsequent updates or tag moves.

**Orchestrator's `update_template` produces a new hash, never overwrites
a hash row.** That preserves the "running sessions unaffected" guarantee
without requiring snapshot machinery at the session level (the session's
working copy diverges from any persisted hash anyway).

**Why git-style not monotonic integer:** content-addressing makes
"these two templates are effectively identical" cheaply detectable
(same hash); makes branching semantics natural (parent_template_uri
points at a specific commit, not a moving version number); aligns
with dev team's existing mental model. The mutable tag overlay
gives the ergonomics of human-readable versions where wanted.

**Implementation note:** hash canonical encoding must be
deterministic across BEAM runs — use `:erlang.term_to_binary(slice,
[:deterministic])` or equivalent. Document in the plugin authoring
guide so plugin authors implementing new Template Classes can
follow the same pattern.

## 7-1 Infra closeout — detailed deliverables

| Item | Detail | Acceptance |
|---|---|---|
| **Workspace-scoped routing enforcement audit** | `routing_rules.workspace_uri` exists (Phase 6 PR 8 migration); `applies_to_workspace?` exists in Resolver. Audit all matcher invocation paths honor it. Orchestrator-spawned worker agents inherit orchestrator's workspace via `Ezagent.Entity.Agent.spawn/4` (new in 7-2). | Invariant test: rule scoped to `workspace://A` never fires for a message in `workspace://B`. |
| **CC channel v1→v2 cutover** | `ezagent_plugin_cc_bridge_v1_prototype` app deleted. **Full blast radius** (verified by SPEC review v2 grep, larger than v1 stated): production code — `apps/ezagent_plugin_cc/lib/esr/plugin_cc_pty/pty_server.ex:261`, `apps/esr_plugin_ezagent/lib/esr_plugin_ezagent/admin_live.ex:495-504`, `apps/ezagent_domain_instance_message/lib/esr/behavior/chat.ex:29,197,199`, `apps/ezagent_domain_instance_message/lib/esr/entity/agent.ex:10` (moduledoc reference), `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex:9,34`. Tests — `apps/ezagent_web/test/cc_bridge_announce_controller_test.exs:8`, `apps/ezagent_web/test/cc_bridge_announce_controller_phase2_test.exs:22`, `apps/ezagent_domain_instance_message/test/integration/real_claude_hotfixes_test.exs:33,45,48,74`. **All migrate to v2 `EzagentPluginCc.BridgeRegistry`** in the same PR (or stacked PRs in a single sub-step). **Python bridge fate**: keep the process, switch its wire from HTTP/SSE to WebSocket via Phoenix.Channel client. Decision #131 (PtyServer `agent_uri` via mcp.json) preserved. | Invariant test: `no_v1_bridge_after_cutover_test.exs` greps `apps/` (excluding deleted plugin) for `Ezagent.Bridge.V1Prototype` and fails on match. |
| **EZAGENT_HOME DB migration mandatory** | Existing `mix ezagent.home.adopt_db` (Phase 6 PR 1) becomes part of the canonical bootstrap flow. CI gate already exists (`repo_root_clean_test.exs`); enforce in main branch protection. | Acceptance: fresh-clone bootstrap path (clone → `mix ezagent.bootstrap` → `mix phx.server`) succeeds with no repo-root DB. |
| **`mix ezagent.bootstrap`** | New mix task wrapping: `ezagent.home.init` (if needed) + `ezagent.home.adopt_db` (no-op if already done) + `ecto.migrate` + health check (HTTP GET on phx /). One-command setup. | Acceptance: vanilla machine + clone + run → ready-to-serve in one step. |
| **CLI token-based auth** | Per-user bearer token (issued at user creation via LV / mix task); CLI reads `~/.ezagent/<profile>/credentials/cli-token` to derive caller URI + caps; admin-all-cap shortcut for `user://admin` only when token principal is admin. | Invariant test (`cli_lv_cap_parity_test.exs`): `mix ezagent <cmd>` as a non-admin token-bound user hits CapBAC like LV would; identical authz decisions in both. |
| **ws sidecar orphan reaping** | `apps/ezagent_plugin_feishu/priv/ws_sidecar/main.js` adds `process.stdin.on('end', () => process.exit())`. Document in plugin authoring guide as the required pattern for any subprocess sidecar. | Integration test (`sidecar_orphan_reap_test.exs`): kill phx, assert no leftover node processes after 5s. |
| **`mix ezagent.plugin.install <path>`** | New mix task: `:application.load/1` + `:application.start/1` on a plugin OTP app from a local path. Returns registered Kinds + Behaviors. Errors if the plugin doesn't have a valid `Application.start/2`. **Concurrency note** (SPEC review v2): task takes an in-memory lock (named GenServer or `:global` lock) to serialize installs; two concurrent installs of the same plugin path → second waits or fails fast. Two installs of different plugins that register the same `template_name` / Kind URI scheme → second surfaces `{:error, :duplicate}` to the caller (the registry already returns this). **Mix.env() pitfall**: a plugin's `Application.start/2` that uses compile-time `Mix.env()` checks (e.g. `EzagentPluginFeishu.Application` lines 60, 96 today) will run with the plugin's *build-time* env, not the host's runtime env. Document this in the plugin authoring guide as an anti-pattern; recommend `System.get_env("MIX_ENV")` for env-dependent boot logic. | Acceptance: write a toy `esr_plugin_hello`, install via mix task on running phx, observe new behaviour registered without restart. Lock test: spawn two concurrent installs of the same path; one succeeds, the other gets a clean error. |

## 7-2 AgentTemplate + SessionTemplate registries — detailed deliverables

| Item | Detail | Acceptance |
|---|---|---|
| **`Ezagent.Entity.AgentTemplate` Kind** | New Kind in `ezagent_domain_instance_message`; URI scheme `template://agent/<name>`; slice = the 5 fields above (no prompt/model/etc — those live in `settings_path`); persistence `{:snapshot, :on_change}`. Implements `Ezagent.Kind.Template` behaviour so plugin authors can also register their own AgentTemplate-flavored Template Classes. | Test: create AgentTemplate via Identity-style dispatch; snapshot survives restart; `instantiate/3` produces a working Agent. |
| **`Ezagent.Entity.SessionTemplate` Kind** | New Kind in `ezagent_domain_instance_message`; URI scheme `template://session/<name>@<version>`; slice = the 10 fields above; `instantiate/3` is the **Generator** described in §Core design. | Test: round-trip — define SessionTemplate via mix task → `Ezagent.Entity.Session.spawn_from_template/2` → fresh session with orchestrator + workers alive. |
| **Template caps** | Two new cap kinds: `template:read` (orchestrator's `list_templates` requires read on each candidate template) and `template:write` (orchestrator's `save_template` requires write on the parent SessionTemplate). Granted via standard `identity/grant_cap` dispatch. Owner of a template gets `template:write` on it by default at create. | Invariant test: orchestrator without `template:write` on parent template gets `:unauthorized` on `save_template()` (merge-back); orchestrator can always fork (creates a new template owned by caller, no parent-write needed). |
| **`Ezagent.Entity.Agent.spawn/4`** | **New function**, not existing today. Closest existing primitive is `Ezagent.SpawnRegistry.spawn/1` (single-arg URI). Signature: `Ezagent.Entity.Agent.spawn(agent_template_uri, instance_name, workspace_uri, granted_by)`. Builds instance agent URI, calls `SpawnRegistry.spawn/1`, then installs the AgentTemplate's `default_caps` via `identity/grant_cap` dispatch with `granted_by` as caller. **Workspace injection** (SPEC review v2 caught ambiguity): AgentTemplate slice has no `workspace_uri` field intentionally — workspace is a *runtime* attribute, set by the spawn caller. `Ezagent.Entity.Agent.spawn/4`'s `workspace_uri` arg sets the spawned Agent's slice `workspace_uri` directly (does NOT come from template). Generator passes orchestrator's session-template's `default_workspace_uri`; orchestrator's `add_agent_slot` tool passes orchestrator's own workspace. | Test: spawn from AgentTemplate with explicit `workspace_uri: workspace://A` produces Agent with `slice.workspace_uri == workspace://A`, regardless of template. |
| **`workspace_uri` + `spawned_by` fields on Agent slice** | Agent Kind currently has no `workspace_uri` and no `spawned_by`. Add both as slice fields (default `nil` for both = unscoped, pre-Phase-7 behavior). `workspace_uri` enables D7-1 workspace-isolation enforcement; `spawned_by` enables D7-3 `{:spawned_by, _}` cap shape lineage. Migration: existing snapshots load with both `nil`. | Migration test: pre-Phase-7 agent snapshots load and dispatch correctly. New-spawn test: `Ezagent.Entity.Agent.spawn/4` populates both fields correctly. |
| **LV creation forms** | `/admin/agent-templates` + `/admin/session-templates`: list / create / edit / delete; auto-derived from Template Class behaviour callbacks (`form_fields/0`). | agent-browser flow: create both template types via LV, query via CLI returns same struct. |
| **Mix tasks** | `mix ezagent.agent_template.{create,list,show,delete}` and `mix ezagent.session_template.{create,list,show,delete,fork}` — auto-derived from BehaviorRegistry (existing pattern). | CLI + LV produce identical templates. |

## 7-3 Orchestrator + scope-bounded delegation + fork/merge — detailed deliverables

The scope-bounded delegation (D7-3) is the trickiest part of Phase 7
because the SPEC-v1 "extend `Capability.matches?/2`" was a hidden
4-deliverable bundle. SPEC-v2 splits them out so the implementer
sees the real shape:

| Item | Detail | Acceptance |
|---|---|---|
| **(a) `Ezagent.Capability.matches?/2` tuple-shape extension** | Add clauses (or wrap with `matches_scoped?/2` called from CapBAC step 5.5) honoring `{:within_session, session_uri}` and `{:spawned_by, principal_uri}` tuple shapes on the `instance` field. Pure function: matches? takes the new ctx fields (from (c)) and decides match/no-match. | Unit tests: cap with `instance: {:within_session, A}` + ctx with session A matches; with ctx in session B does not. |
| **(b) Agent slice `spawned_by` field + migration** | Current Agent Kind has **NO** `spawned_by` field in its slice (SPEC review v2 caught this — earlier draft claimed "already there", that was wrong). Add `spawned_by :: URI \| nil` to Agent slice; populated by `Ezagent.Entity.Agent.spawn/4` (from 7-2) using the `granted_by` arg as both the lineage anchor and the cap-grant attribution. Migration: existing Agent snapshots load with `spawned_by: nil` and behave as today (no `{:spawned_by, _}` cap targets them). | Migration test: pre-Phase-7 Agent snapshots load successfully. Lineage test: `Ezagent.Entity.Agent.spawn(_, _, _, granted_by: O)` produces agent slice with `spawned_by: O`. |
| **(c) Dispatch ctx `:session_uri` enrichment** | Current `ctx` (invocation.ex) carries `caller`, `caps`, `reply`, plus runtime-injected `kind_module` + `self_uri`. **No session_uri today**. CapBAC step 5.5 needs it to resolve `{:within_session, _}`. Derive from `target` URI's session segment (e.g. `session://main/behavior/chat/send` → `session://main`), OR add an explicit enrichment step before authz_check. Implementer's call which approach; document. | Test: cap with `{:within_session, A}` dispatched against target whose URI lives in session A is granted; against target outside A is denied. |
| **(d) Generator's scoped-cap grant call site** | `Ezagent.Entity.Session.spawn_from_template/2` (Generator) — step where orchestrator gets its delegation caps. After spawning the orchestrator agent, dispatch `identity/grant_cap` to grant the orchestrator: (i) `{kind: :session, behavior: :any, instance: {:within_session, new_session_uri}}` and (ii) `{kind: :agent, behavior: :any, instance: {:spawned_by, orchestrator_uri}}`. Both granted_by the human owner who triggered Generator. | Test: orchestrator spawned in `session://X` can dispatch on URIs within X; same orchestrator dispatching against `session://Y` URI returns `:unauthorized`. |
| **`Ezagent.Capability.matches?/2` scope-extension fallout** | Each existing call to `matches?/2` in the codebase must be audited to confirm it passes the new ctx fields (or accepts a default of `nil` session_uri = no-scope = matches anything that isn't a scope-tuple). | Audit list documented in PR description; no existing call site silently breaks. |
| **`cc-orchestrator` shipped AgentTemplate** | Installed at boot in dev profile (`template://agent/cc-orchestrator`): prompt teaches orchestrator pattern; `settings_path` points to a curated `.claude/settings.json` enabling the six orchestration tools + their MCP bridge. | Acceptance: instantiating cc-orchestrator via `Ezagent.Entity.Agent.spawn/4` produces a working agent that responds to chat. |
| **7 orchestration tools** | `add_agent_slot` / `remove_agent_slot` / `update_agent_template` / `write_matcher` / `update_template` / `save_template_as` / `list_templates`. Each implemented as an MCP tool the orchestrator agent invokes; tool handler dispatches the corresponding Ezagent action via standard `Ezagent.Invocation.dispatch/1`. | Per-tool tests: each tool with valid args produces the documented effect; with out-of-scope args returns `:unauthorized`. |
| **Working-copy session slice + persistence flip** | Add `template_working_copy` to Session slice. **Persistence flip required**: `Ezagent.Entity.Session.persistence/0` currently returns `:ephemeral`; flip to `{:snapshot, :on_change}` so working copy survives phx restart. Migration: existing in-flight sessions get snapshot on next state change; idle sessions are not retroactively snapshotted (no historical data to recover). | Test: orchestrator's `add_agent_slot` updates `template_working_copy.agent_slots`; restart phx; same session post-restart still has the slot. |
| **`update_template` mechanics** | Tool computes new `version_hash` (SHA-256 over working-copy slice content); validates current caller has `template:write` cap on current parent template's NAME (not specific hash — write cap is name-scoped); inserts new SessionTemplate row with `(name = parent.name, version_hash = new, parent_template_uri = parent_hash_uri)`. Returns new URI. Older sessions on prior hashes unaffected. | Test: from `session://X` instantiated from `template://session/A@<h1>`, orchestrator with `template:write on template://session/A` runs `update_template()` → new row `template://session/A@<h2>` exists; original `@<h1>` row unchanged; session://X continues on its working copy. |
| **`save_template_as` mechanics** | Tool validates `new_name` is unique in registry; computes `version_hash`; inserts SessionTemplate row with `(name = new_name, version_hash = new, parent_template_uri = current_parent_hash_uri)`. Caller becomes owner (granted `template:write on template://session/<new_name>`). | Test: from session instantiated from `template://session/A@<h1>`, orchestrator-caller runs `save_template_as("B")` → `template://session/B@<some_hash>` exists with `parent_template_uri = template://session/A@<h1>`; caller has template:write on B. |
| **Template tag operations** | `mix ezagent.session_template.tag <name> <tag> <version_hash>` + LV equivalent: insert/update row in `template_tags` registry (name + tag → hash). Tag move is mutable; tag delete just removes the row. Hash itself is immutable. | Test: tag `template://session/A:stable → @<h1>`; later re-tag to `@<h2>`; lookup of `template://session/A:stable` returns `@<h2>`; `@<h1>` row still exists and is instantiable by URI. |
| **`Ezagent.Entity.Session.spawn_from_template/2` CapBAC gate** | Generator entry point needs a cap: new `template:instantiate` cap kind, granted by default to any user who has `template:read` on the SessionTemplate. Admin always has it. The cap is checked at step 5.5 like any other action. Accepts either `template://session/<name>@<hash>` (specific version) or `template://session/<name>:<tag>` (resolved to hash via tag registry at call time). | Test: non-admin caller without `template:instantiate` on `template://session/X` gets `:unauthorized` when invoking spawn_from_template; with the cap, instantiate-by-tag resolves to the current tag target hash. |
| **In-flight template-deletion semantics** | If the parent SessionTemplate row (specific hash) referenced by a running session is deleted, the running session continues on its working copy. `update_template()` on a deleted parent hash returns `{:error, :parent_template_deleted}` (orchestrator surfaces via chat); `save_template_as` still works (becomes new root effectively). Deleting the LAST hash of a name also deletes the name's tags. | Test: instantiate from A@h1, delete A@h1 row, run `update_template()` → error; run `save_template_as("recovered")` → succeeds. |
| **e2e demo** | Human → LV chat in `session://team-alpha` (instantiated from `template://session/blank-team@1`) → @cc-orchestrator "build me a code review team" → orchestrator iteratively `add_agent_slot`s for backend-dev / frontend-dev / reviewer, `write_matcher`s for mention routing, reports back. Human reviews, types "save as code-review-team". orchestrator forks → `template://session/code-review-team@1`. Human in a fresh terminal: `mix ezagent.session_template.show code-review-team` shows the saved config. Human instantiates a 2nd session from it → same team appears. | Acceptance: agent-browser screenshots of (1) live orchestration session, (2) saved template via CLI, (3) re-instantiated session with identical team. |

## 7-4 Handoff readiness — detailed deliverables

### Ezagent developer skill — `.claude/skills/esr-developer/SKILL.md` + bundle

Activates when: dev's Claude Code agent opens any file in the Ezagent
repo, types `/esr-help`, or the prompt mentions Ezagent-specific terms
(Kind, Behavior, Capability, dispatch, AgentTemplate,
SessionTemplate, orchestrator, etc.).

| Section | Content |
|---|---|
| **Architecture invariants** | Dispatch is the only path; Behavior contract; Capability struct; meta schema `Record<string, string>`; Receiver Kind pattern; Plugin isolation; Workspace scoping; **v1 scope-bounded delegation cap shapes**; **Template Class umbrella in core, not workspace** |
| **Anti-patterns the skill refuses** | Naked `PubSub.broadcast` bypassing dispatch; `admin_caps()` as goto; cap behavior written as atom shorthand instead of module reference; list/map values in meta; `:cast` on inbound transports needing error feedback; new pseudo-channel covering text+media; **trying to make orchestrator a deterministic dispatcher (D7-1)**; **trying to make SessionTemplate include message history (D7-7)**; **trying to support plugin unload in Phase 7 (D7-8)** |
| **How-to recipes** | Add a plugin (mix.exs + application.ex + registry register calls); add a Kind (Kind behaviour callbacks + snapshot + persistence); add a Behavior (interface schema + invoke/4 + slice); add a Template Class (implements `Ezagent.Kind.Template` behaviour); add a routing rule; write an invariant test; install a new plugin into running Ezagent (`mix ezagent.plugin.install`) |
| **Debug recipes** | Silent drop → check CapBAC + meta schema + cap shape; orphan sidecar → check Port lifecycle + sidecar stdin EOF handler; `:unauthorized` despite cap granted → check cap struct shape (atom vs module reference) and User Kind aliveness; fork didn't preserve lineage → check `parent_template_uri` field |
| **Project conventions** | uv not python3; pnpm not npm; agent-browser for UI debugging; bilingual docs/<name>.md + docs/<name>.zh_cn.md; Decision Log new entry rules; forensic notes in `docs/notes/` |
| **Pointer index** | Each major Decision Log entry; each forensic note in `docs/notes/`; ARCHITECTURE.md key sections (§5 dispatch, §7 CapBAC, §12.8 channel); docs/phase-specs/phase7/ for v1 design |

### 4 onboarding docs

| Doc | Audience | Length |
|---|---|---|
| `docs/onboarding/first-30-days.md` | New dev contributor | 800-1500 words; week-by-week milestones, recommended reading order, "things you'll be tempted to do that are wrong" |
| `docs/onboarding/adding-a-plugin.md` | Plugin author | 600-1000 words; concrete example (adding a Slack adapter); includes `mix ezagent.plugin.install` workflow + hot-install caveats |
| `docs/onboarding/adding-kind-behavior-template.md` | Same | 800-1200 words; concrete examples for each — adding a Kind family with two actions; adding a Template Class for a new agent flavor |
| `docs/runbook/common-failures.md` | On-call / debugger | 800-1200 words; cross-references forensic notes; symptom-first organization |

### Invariant tests (≥6 new, gating Phase 7 principles)

| Test | What it locks |
|---|---|
| `workspace_isolation_test.exs` | Rule in workspace A doesn't fire for message in workspace B |
| `orchestrator_cap_scope_test.exs` | Orchestrator's `grant_cap` / `add_agent_slot` outside its `:within_session` scope returns `:unauthorized` |
| `template_fork_lineage_test.exs` | Forked template has `parent_template_uri` pointing at the source version; original template unmodified; both instantiate independently |
| `template_merge_requires_cap_test.exs` | Orchestrator without `template:write` on parent gets `:unauthorized` on `save_template()` (merge-back); fork remains available |
| `cli_lv_cap_parity_test.exs` | Same action via CLI (token-bound non-admin) and LV (cookie-bound same user) produces identical authz decisions |
| `no_v1_bridge_after_cutover_test.exs` | After 7-1, no module references `Ezagent.Bridge.V1Prototype`; live system has no agents bound to v1 |
| `sidecar_orphan_reap_test.exs` | Killing phx leaves no leftover node sidecar processes after 5s |
| `plugin_hot_install_test.exs` | `mix ezagent.plugin.install` on a toy plugin against a running phx adds the plugin's Kinds + Behaviors to the registries; messages can dispatch to the new Kind |

### Decision Log + GLOSSARY + ROADMAP final state

By Phase 7 close:

- Every D7-* decision becomes a numbered Decision Log row (#135+)
- GLOSSARY adds: **AgentTemplate**, **SessionTemplate**, **Generator** (program — `Ezagent.Entity.Session.spawn_from_template/2`), **Orchestrator** (session-internal manager agent — capitalized to distinguish from generic noun), **Scoped Delegation** (v1), **Working-copy template state**, **Template fork lineage**, **Template version hash (D7-10, git-style SHA + mutable tags)**, **Template tags registry**, **`template:read` / `template:write` / `template:instantiate` caps**, **`Capability.matches?/2` tuple-shape extension**, **`Agent.spawned_by` lineage field**, **`mix ezagent.bootstrap`**, **`mix ezagent.plugin.install`**, **`CLAUDE_CONFIG_DIR` per-agent isolation pattern**
- ROADMAP §9b (Phase 7) replaced with delivery accounting (same format as §9 Phase 6 closeout)
- Forensic note `docs/notes/phase-7-handoff.md` recording: what was on the table; what we cut; what survived intact; future-dev orientation summary; **declaration of Ezagent v1 release**
- ARCHITECTURE.md §17.6 (delegation) updated to reflect v1 model retiring the "v0 不支持 delegation" baseline

## SPEC_REVIEW walkthrough (Layer 4 of drift defense)

For each PR in Phase 7, the contributor MUST run through this
checklist BEFORE requesting review:

1. **Decision impact**: which Decision Log entries does this PR
   create / change / invalidate? Add a row or document the change.
2. **Cap surface**: does this PR add a code path that grants /
   checks / requires caps? If yes, the cap shape MUST use module
   reference (not atom shorthand) and MUST scope as narrowly as
   possible. If using a scope tuple (`{:within_session, _}` etc.),
   confirm `Capability.matches?/2` handles it.
3. **Dispatch path**: does this PR introduce a new way to deliver a
   message to a Kind? If yes, it MUST go through
   `Ezagent.Invocation.dispatch/1` — no exception. If you think you need
   an exception, write a Decision Log entry first and get review.
4. **Meta schema**: if this PR touches code that constructs the
   payload for `notifications/claude/channel` or any future channel
   adapter, every meta value MUST be a string.
5. **Workspace scope**: if this PR touches routing rules or Kind
   instances, verify they respect their declared workspace scope.
6. **Template lineage**: if this PR touches SessionTemplate, verify
   fork creates a child row; merge writes a new version of parent;
   neither retroactively affects already-running sessions.
7. **Skill update**: did this PR introduce a pattern future devs
   should follow, or an anti-pattern they should avoid? Update
   `.claude/skills/esr-developer/SKILL.md`.
8. **Forensic note**: if this PR is solving a tricky bug or making
   a non-obvious trade-off, write a forensic note in `docs/notes/`
   capturing the WHY.

## Non-goals (deferred to dev-team v1.x+)

- **Federation** (Allen reopens later) — D7-4
- **Plugin unload / swap** — D7-8; requires Kind lifecycle management
- **Production OTP release / Docker / systemd** — D7-9; dev team scopes
- **SessionTemplate three-way merge** — D7-7; needs message-tier conflict resolution
- **Template synthesis** (orchestrator generating new AgentTemplates on the fly) — Phase 7 keeps templates human-authored or LLM-authored-but-saved-as-named; orchestrator can compose existing templates into SessionTemplates but cannot mint new AgentTemplates inline
- **Cross-session agent delegation** — orchestrator acts within its session scope only
- **Multimedia / streaming** — see ROADMAP §9c (Dyte direction)

## Brainstorm provenance

**Round 1** (2026-05-18 morning):

1. Phase 6 closeout merged (PR 28); Allen asks about Phase 7 direction
2. Pre-SPEC questions narrowed to:
   - Orchestrator A (LLM) vs B (deterministic) → A
   - Phase 7 monolithic vs split → monolithic with 4 sub-steps
   - Handoff depth → complete (Allen leaves)
   - Federation scope → drop
   - EZAGENT_HOME DB migration → mandatory
   - Ezagent developer skill → new explicit deliverable
3. SPEC v1 drafted, subagent-reviewed, shipped as PR 30 DRAFT.

**Round 2** (2026-05-18 afternoon — fundamental reframe):

1. Allen pushed back on v1: "orchestrator 不是 MVP,而是一个生产可用的
   session template generator"
2. Working back through the model:
   - Generator (creates session) ≠ Orchestrator (manages session)
   - SessionTemplate is the production unit, instantiable + forkable
   - Orchestrator is session-internal manager (not ephemeral
     authoring tool from v1)
   - Conversation with orchestrator IS template-refinement
   - Sessions are forkable; owner picks merge-back vs branch
3. Allen also clarified:
   - AgentTemplate keeps original name (no Blueprint rename)
   - Template umbrella is in `Ezagent.Kind.Template` (core, not workspace)
   - AgentTemplate is minimal: working_directory + settings_path
   - Ezagent install = `mix ezagent.bootstrap` only
   - Plugin hot-install yes; hot-unload deferred
   - Phase 7 closeout = Ezagent v1 release; delegation v0 retires
4. Fork unit = configuration only (option A; no message history)
5. SPEC v2 (this document) re-written from scratch.

**Round 3** (2026-05-18 — after v2 ship + Allen review):

1. Allen pushback: "orchestrator fork" 表述误导。Fork 是 SessionTemplate
   registry 操作,不是 orchestrator verb。
2. 锁定 session-creation 3 entry points: instantiate / fork+instantiate /
   create-blank+instantiate.
3. 锁定 git-style versioning: immutable SHA hash + mutable tag overlay
   (D7-10).
4. CC PTY isolation research: `CLAUDE_CONFIG_DIR` env var enables full
   per-agent isolation on Linux/Windows; macOS Keychain caveat needs
   `apiKeyHelper` or separate OS users for credential isolation.
5. AgentTemplate slice final: adds `claude_config_dir` (mandatory),
   `settings_path`/`mcp_config_path` (optional overrides), `api_key_helper`
   (macOS multi-agent workaround).
6. Allen AFK; SPEC v3 lock + VERIFICATION/PLAN/DECISIONS authoring +
   full Phase 7 execution authorized.

**Round 2.5** (immediately after v2 draft, 2026-05-18) — subagent
review against codebase caught 6 wrong claims + 8 risks before
Allen review:

- `EzagentDomainInstanceMessage.Template.GenericSession` → `Ezagent.Template.GenericSession`
  (correct module path)
- CC v1→v2 blast radius understated — added 4 more reference sites
  (chat.ex, agent.ex, controller, additional test file)
- D7-3 deliverable was 1 row hiding 4 implementation tasks; split
  into 4 explicit rows ((a) matches?/2, (b) Agent.spawned_by field
  + migration, (c) ctx :session_uri enrichment, (d) Generator
  scoped-cap grant call site)
- Agent slice did NOT have `granted_by` (SPEC v2 draft falsely
  claimed "already there"); promoted to explicit 7-2 deliverable
- Session is `:ephemeral` today; working-copy needs persistence flip
- `spawn_from_template/2` CapBAC gate was unnamed; added
  `template:instantiate` cap kind
- In-flight template-deletion semantics undefined; added explicit row
- Workspace inheritance ambiguity (AgentTemplate has no
  workspace_uri but workers should inherit orchestrator's);
  clarified: workspace is runtime arg to `Agent.spawn/4`, not a
  template field
- `TemplateRegistry.register/2`/`/3` → `register/1` (correct arity)
- Plugin hot-install: concurrency lock + Mix.env() compile-time
  pitfall noted

## Sign-off

- [x] Allen reviews SPEC v3 — "spec 设计 OK" + AFK execution authorized 2026-05-18
- [ ] `docs/phase-specs/phase7/VERIFICATION.md` written (acceptance
      criteria + e2e gate definitions per sub-step)
- [ ] `docs/phase-specs/phase7/PLAN.md` written (PR ordering + estimate)
- [ ] `docs/phase-specs/phase7/DECISIONS.md` initialized (capture
      implementation-time judgment calls as they happen)
- [ ] Phase 7-1 sub-step PRs begin
