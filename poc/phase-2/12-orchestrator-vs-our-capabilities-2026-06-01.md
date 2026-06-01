# Task 4 — Can the (rebased) orchestrator replace our capabilities? (soul-edit / takeover)

> 2026-06-01. Investigation against the post-merge `poc/phase-2-customer-service`
> (HEAD b3c95bf0, ezagent main merged). Question from PR #446 planning: does the
> latest orchestrator code already provide what we built/are-building, so that
> **admin-edit-soul scope #1 should refactor onto orchestrator primitives**
> instead of our file-based `SoulStore`?
>
> **Verdict: NO.** Keep scope #1's `SoulStore` design as-is. The orchestrator
> neither edits soul text nor handles takeover; it is a different (LLM-driven,
> session-composition) abstraction, and it is not even on our soul/message path.
> Details + the one genuine convergence point (deferred) below.

## The two capabilities under question
1. **Editable soul** (scope #1, `11-admin-edit-soul-design.md`): a human admin
   edits a tenant's customer soul markdown in a UI → Save → new conversations use
   it. Built as: `SoulStore` (file `edited→fixture→nil`, write/revert/reset) +
   `ConfigLive` + `ConfigAuth` (workspace-admin cap). Take-effect: cc reads
   `soul_path` at spawn → `--append-system-prompt-file`.
2. **Takeover** (`Ezagent.Behavior.Mode`, this-session-migrated to Lifecycle):
   operator replaces the AI; `:set`/`:get` on a session `:mode` slice; `Chat`
   suppresses agent-sender fan-out when `:takeover`.

## What the orchestrator actually is
A **subsystem** (`apps/ezagent_domain_chat/lib/ezagent/orchestrator/*`), not a
single behavior. It is an **LLM-driven** engine: a per-session cc-orchestrator
claude instance invokes **7 MCP tools** to compose + route *worker* agents:

| Tool | What it does |
|---|---|
| `add_agent_slot(slot, template_uri, prompt_override?)` | spawn a worker at a slot from an AgentTemplate (reconciler, idempotent) |
| `remove_agent_slot(slot)` | terminate worker + prune routing |
| `update_agent_template(slot, new_template_uri)` | **swap** a slot to a *different existing* template |
| `write_matcher(ast, receivers)` | add a session routing rule |
| `update_template()` / `save_template_as(name)` | snapshot the **session composition** as a new/forked SessionTemplate version |
| `list_templates(filter?)` | discover templates (CapBAC-filtered) |

Plus `Behavior.OrchestratorAdmin` = a **cap-only** gate (`:restart`) on session-owner
authority. The orchestrator tools are **MCP-only / invisible to human operators**
(see `docs/notes/agent-orchestrator-ui-audit-2026-05-23.md`).

## Soul editing — orchestrator CANNOT (evidence)
- `add_agent_slot`'s `prompt_override` is an **explicit no-op**: *"accepted for API
  parity with the SPEC but is not consumed — the worker's prompt comes from its
  AgentTemplate's `claude_config_dir/settings.json` (Decision #136)"*
  (`orchestrator/tools.ex:155-163`).
- **No orchestrator tool edits prompt TEXT.** `update_agent_template` only *points a
  slot at a different existing template URI*; `update_template`/`save_template_as`
  snapshot **session composition** (which slots + routing), not an agent's
  system-prompt content.
- The only thing that mutates an agent's behavior-text at all is **AgentTemplate
  content** (`Behavior.Template :write`, whole-template replace) — a *separate*
  behavior, coarse-grained, with none of scope #1's per-`(tenant,role)`
  `edited/fixture/prev/reset` semantics or workspace-admin cap gate.
- Our soul model is fundamentally different in *kind*: soul = a per-`(tenant,role)`
  **markdown file** resolved `edited→fixture` at spawn and injected via
  `--append-system-prompt-file` (`cc_agent.ex:1146`); the admin edits markdown in a
  textarea. The orchestrator has no analog and no human-edit surface.

**⇒ The orchestrator cannot do scope #1. Refactoring onto it would first require
building the missing "edit prompt text" primitive anyway.**

## Takeover — orchestrator does NOT do it (orthogonal)
Mode is a **session-level** behavior (`:mode` slice); the orchestrator is unaware
of it and is not a "taken-over" participant. They already coexist correctly.
No change; do **not** route takeover through the orchestrator.

## Decisive architectural fact: the orchestrator isn't even on our path
`bootstrap.ex:74-86`: our customer conversations call `EzagentDomainChat.create_session/3`,
which **unconditionally spawns a per-session cc-orchestrator** (Phase-7
"session-create-orchestrator-unified") — **but our code never drives it; the
orchestrator sits idle (an extra claude PTY per session).** The actual customer
cc agent is spawned by **our** `ensure_cc_for_conv → Workspace.create_agent(...,
soul_path)` (`bootstrap.ex:114-167`), *not* by `add_agent_slot`. So the
orchestrator is neither in our soul path nor our message path — it is idle
dead-weight today (already tracked: REVISIT asking Allen for a
`create_session(orchestrator: false)` opt-out).

## Verdict & implications for PR #446 / scope #1
1. **Keep `SoulStore` (file-based) for scope #1.** The orchestrator provides no
   soul-text edit, is LLM-/MCP-driven (not a human admin surface), and adopting it
   would pull in the whole AgentTemplate/SessionTemplate **versioning** surface
   that scope #1 §11 *explicitly defers* — i.e. exactly the cargo-culting the
   design's incremental red line forbids. Wrong scope axis too (session-composition
   vs tenant-level config).
2. **Keep `Mode` for takeover.** Already migrated + correct; orthogonal to the
   orchestrator.
3. **The one genuine convergence point — deferred, not now.** *If/when* scope #2+
   wants **versioned souls + A/B variants + swap-in-place**, ezagent's native
   "change agent behavior by versioning" primitive is **AgentTemplate +
   `update_agent_template`** — converge there rather than building a parallel
   version store. Scope #1's `.prev` single-undo deliberately stays file-based; the
   template path is the future home for full version history.
4. **Independent cleanup worth filing (not soul-related):** the idle
   per-CS-session orchestrator PTY waste — ask Allen for the `orchestrator: false`
   opt-out. Matters extra given the boot-storm / bind pressure.

## How this informs Task 3 (PR split)
The soul-edit slice (`SoulStore`/`ConfigLive`/`ConfigAuth`) stands on its **own**
ezagent primitives (cc `soul_path`, the capability model) and has **zero**
dependency on the orchestrator. It can be split into its own reviewable PR without
any orchestrator-coupling caveat. The takeover slice (`Mode` + `Chat` gating +
operator dashboard) is likewise orchestrator-independent and splits cleanly on its
own.
