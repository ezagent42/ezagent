# CS-Team Orchestrator Playbook — build/operate service teams via conversation (no code changes)

> Produced 2026-06-02 (subagent, opus) grounded in `/private/tmp/esr-impl` as of that date.
> Goal: what an operator can do TODAY, no code changes, mostly by TALKING to the orchestrator
> (which calls the 8 `Ezagent.Orchestrator.Tools` MCP tools). Honest about gaps.

The 8 orchestrator tools (`orchestrator/mcp_server.ex` `tool_schemas/0`):
`add_managed_member`, `remove_member`, `define_rule_set_rule`, `define_prompt_template`,
`define_legend`, `update_template`, `save_template_as`, `list_templates`.

Three load-bearing constraints:
1. `add_managed_member` always SPAWNS a worker from an AgentTemplate — it cannot invite an
   existing entity (a human user, or a pre-existing agent). No "invite existing member" tool.
2. Routing is by `role_name` / member URI. A role must exist (member added) BEFORE a rule can
   target it. `{:from, X}` matchers carry the resolved member URI (returned by add_managed_member).
3. cc-agent skills come from its AgentTemplate's `claude_config_dir` (reference dir copied
   per-agent at spawn). The ONLY orchestrator-driven skill copy is the hardcoded
   `ezagent-session-orchestrator`, gated on `role:"orchestrator"`. NO tool attaches arbitrary skills.

## 1. Stand up 售前 + 售后 teams
- Prereq (operator, not orchestrator): the worker AgentTemplates must already exist. Ask the
  orchestrator to `list_templates` to confirm URIs.
- `add_managed_member` ×N (cc/codex/curl worker template, role_name per agent, `in_session_template:true`).
- Front each team with a legend: define a pos-0 entry rule `{:mention, "售前"} -> presale-1`
  (`define_rule_set_rule`), then `define_legend("售前", ["presale-1","presale-2"], "presale", true)`.
- Intra-team relay/escalation: `{:from, presale-1-uri} -> presale-2` (need presale-1's returned URI).
- GAPS: no bulk "spawn N"; no invite-existing-agent; a single rule is SINGLE-RECEIVER (no team-scoped
  multicast — only whole-session `$session_members`).

## 2. Give agents NEW capabilities (DB skill, external-API skill)
- BIGGEST GAP. Skills are template-time config in `claude_config_dir`; there is NO orchestrator tool
  to attach a skill at runtime, and member-regeneration (`update_member_template`) is explicitly
  DEFERRED/unimplemented (`tools.ex:57-66`).
- Achievable path (operator + template author, not pure conversation): author skill files under a
  reference `claude_config_dir` (e.g. `skills/db-query/SKILL.md`, `skills/external-api/SKILL.md`),
  create/fork an AgentTemplate (LV form / `mix esr.agent_template.create`) pointing at it, THEN via
  the orchestrator `add_managed_member` from that capability-bearing template.
- Weaker conversation-only approximation: a `define_prompt_template` injects standing INSTRUCTIONS
  per hop ("优先用数据库查询技能") — but only guides behavior; it cannot INSTALL a skill.

## 3. New session copying the team + add human user + human CS
- Snapshot (pure conversation): `save_template_as("service-team")` (or `update_template` for a new
  version of the parent) captures members(`in_session_template:true`) + legends + prompt_templates +
  rule-set rules.
- Materialize: GAP — orchestrator has NO create_session/fork tool (explicit design lock,
  `tools.ex:78`). `create_session(name, creator, template_name:"service-team")` is an operator/LV/API
  action. It re-spawns the team and auto-joins `[owner, orchestrator]`, so the human owner IS auto-added.
- Add another human user: LV `chat.join` with the user's `entity://user/...` URI (NOT an orchestrator
  tool; humans aren't spawned from templates).
- Human CS: if a real person → another human user who joins. GAP: supported UI/tools don't set a
  `role_name` for a human member, so rules can target a human only by concrete URI. No human-proxy
  agent flavor ships.

## 4. Human ↔ AI handoff (switching)
- Achievable AS ROUTING with legends/rules, provided both human + AI are session members:
  - `@转人工`: `define_rule_set_rule({:mention,"转人工"} -> <human user URI>, rule_set:"handoff_human", pos 0)`
    + `define_legend("转人工", [], "handoff_human", false)`. (Receiver may be a concrete URI, but the
    human must already be a joined member.)
  - `@转AI`: symmetric, routes back to `presale-1`.
  - Optional supervision: `{:from, presale-1-uri} -> <human URI>`.
- GAPS: no sticky/per-user handoff MODE — handoff is PER-MESSAGE re-routing, not a durable "in human
  mode until toggled" flag (no `applies_to_users`-style matcher; no enable/disable-rule-set toggle).
  A sticky mode needs code.

## Summary of capability gaps (need future code)
1. No runtime skill/capability attach (skills are template-time; `update_member_template` deferred). ← central.
2. No orchestrator create/fork/instantiate-session tool (operator/LV/API only).
3. No orchestrator tool to add a human user / pre-existing entity as a member.
4. No supported way to give a human member a `role_name` (target humans only by concrete URI).
5. No sticky/per-user handoff mode (no per-user rule scoping; no rule-set enable/disable toggle).
6. No team-scoped multicast (single-receiver rules; only whole-session `$session_members`).
7. No AgentTemplate-creation tool (templates pre-exist via LV/mix).

Works cleanly by conversation TODAY: spawn agent members from existing templates, group under
legends, wire single-receiver rule-sets (mention-entry + `{:from,X}` chains), attach per-hop prompt
templates, snapshot the team into a reusable SessionTemplate. Gaps cluster in: runtime skill attach,
session creation, and human-member/handoff modeling.

## Recommended path forward (for R&D)

**Spec FIRST — do not ad-hoc bolt new tools onto `Orchestrator.Tools`.** The 7 gaps are not
independent feature requests; they cluster into three design areas that touch CORE
(creation-unification + the planned `domain.agent` abstraction), so patching them piecemeal would
re-create the exact "scattered, mis-settable per-agent config" class that already bit us (the
shared-cwd → `:no_bridge` bug). Proposed grouping for a spec discussion:

1. **Runtime capability / skill management** (gaps #1, #2, #7). The biggest gap. Needs a coherent
   model for: authoring/registering skills, attaching them to an agent or template, and
   **member regeneration** (the deferred `update_member_template`). This is the natural home for the
   `domain.agent` abstraction (own per-agent identity + filesystem/skill isolation as an invariant),
   already queued in `docs/futures/todo.md`.
2. **Session lifecycle from the orchestrator** (gaps #2-create, #3). An orchestrator-driven
   create/fork/instantiate-session path + adding pre-existing entities (humans) as members. This
   belongs with the **creation-unification spec (#533)** — unify ALL Kind creation through one
   authorized chokepoint — rather than a new ad-hoc `:fork`/`create_session` tool (explicitly locked
   out today for that reason).
3. **Human-member + handoff modeling** (gaps #3-human, #4). First-class human members with
   `role_name`s, and a sticky/per-user handoff MODE (durable "in human mode until toggled"), which
   needs either per-user rule scoping or rule-set enable/disable — a small but real new primitive.

**Suggested sequence:** (a) land the E2E acceptance of the current team-routing relay (validates the
foundation); (b) **write/extend a spec** folding the three areas above into the
creation-unification (#533) + `domain.agent` direction; (c) implement against that spec. Areas 1 & 2
should reference #533 and the `domain.agent` todo so we don't fork the design.

> TL;DR for the forward: yes, let's discuss a spec before building. The CS-team requirements are a
> good forcing function for the `domain.agent` + creation-unification work already on the roadmap —
> they're the same core concerns (per-agent isolation, one authorized creation chokepoint), surfaced
> from the customer-service use case.
