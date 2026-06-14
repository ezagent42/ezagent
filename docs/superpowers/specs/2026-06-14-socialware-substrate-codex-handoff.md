# Socialware 基座化 — Codex Development Handoff (2026-06-14)

> **You (codex) own the DEVELOPMENT to completion. The human's Claude agent owns
> E2E scenarios + validation + per-merge checks — NOT you.** Develop autonomously
> to the GOAL below: cut the remaining agent→session edges and physically split
> the umbrella into `im → session → agent` (acyclic). Per the plan, open a PR per
> step and `gh pr merge --admin --squash --delete-branch` when green. Work
> asynchronously; do not wait on the human.

## 0. Environment assumption (READ FIRST)

This handoff assumes you run in a **full working checkout of `ezagent42/ezagent`
with `mix` deps installed and `gh` authenticated** (NOT a deps-less sandbox). You
MUST be able to run `mix compile`, the full umbrella test suite, the arch/invariant
gates, and `gh pr` against the repo. If your environment cannot do this, STOP and
say so — the gates below are non-negotiable and cannot be skipped.

## 1. Goal & current state

**Goal: socialware 基座化 = the clean `im → session → agent` 3-domain split**, the
last piece of transport-line #53. The unified Session Kind (P5 collapse) is DONE
(`Entity.SocialwareSession` deleted; `Entity.Session` is the one Kind). The
transport seams are merged (`Behavior.Agent.Receive`, `AgentBridge`,
`OrchestratorReadinessPort`, `session.send`). What remains is **cutting the live
`agent → session` compile edges** so `Entity.Agent` becomes a leaf, then the
**physical app split**.

**Already done (on main):**
- **A2 (#764, MERGED):** `resolve_template_class/1` relocated from
  `SessionCreator.TemplateResolver` to `Ezagent.Entity.AgentTemplate` (agent
  domain). `agent_template.ex` + `entity/agent/template_spawn.ex` no longer
  reference that session module for flavor→Template-Class.

**Remaining agent→session edges to cut (your work):**
- **A1** — `Entity.Agent.base_behaviors/0` composes `Ezagent.Behavior.Session`.
- **A3** — `Behavior.Agent.Receive` routes through `Behavior.Session.Delivery`.

Then the physical split: **9a → 9b → 9c**.

## 2. Skills to load (mandatory)

`ezagent-developer` + `elixir-phoenix-helper`. Without them you will write stale
Elixir and miss the ezagent RBK invariants (dispatch-is-the-only-path, the CapBAC
chokepoint, Lifecycle/Behavior contracts, snapshot model). Load both before any
edit.

## 3. The plan (these specs ARE the design — read them, don't re-derive)

In `docs/superpowers/specs/`:
- `2026-06-12-im-session-agent-decomposition-design.md` — the master design (§2
  module→domain map, §3 transport, §6 migration safety, §7 O-1..O-4 decisions).
- `2026-06-14-pr9-physical-domain-split-brief.md` — the 9a/9b/9c brief +
  decisions D1–D4 (Allen-approved): **rename the app
  `ezagent_domain_instance_message → ezagent_domain_session`; feishu stays the im
  plugin (no new im app); `ezagent_domain_agent` is NEW, `ezagent_domain_agent_bridge`
  stays a separate leaf; split into 9a/9b/9c; gate-first (land the acyclic gate
  allowlisted in 9a, shrink to 0 by 9c).**
- `2026-06-14-pr9-A1-agent-session-decoupling-audit.md` — the A1+A3 audit
  (vestigial-Session finding, the shared `:session` slice, the shared-helper
  problem).

## 4. PR sequence (open a PR per step; admin-merge when ALL gates + suite green)

### PR-A (A1 + A3 together — do as ONE unit)
A1 alone is NOT runtime-true (agents still route receive through
`Session.Delivery`), so combine.

**A1 (gift — exact changes from the closed draft #763):**
1. `Entity.Agent.base_behaviors/0` (`entity/agent.ex`): remove
   `Ezagent.Behavior.Session` from the list. (It is vestigial: agents receive via
   `Behavior.Agent.Receive` registered `{Agent, :receive}` in
   `instance_message/application.ex`; NO session-host action is ever dispatched to
   an `entity://agent` — verified by grep.)
2. `test/ezagent/entity/agent_test.exs`: drop `Behavior.Session` from the expected
   `base_behaviors` list (and the stale `:chat` slice mention).
3. `arch.scan @spawn_fresh_sanctioned`: the 3 `entity/agent.ex` line anchors shift
   by your net line delta (the closed draft used +7: 230/269/271 → 237/276/278);
   recompute for your actual diff. **THIS IS A LINE-COUPLED ALLOWLIST — update it
   or `spawn_fresh_unsanctioned` goes red.**

**Shared `:session` slice caveat:** `Behavior.Session` AND `Behavior.Agent.Receive`
BOTH declare `state_slice: :session` (the chat→session rename moved `:chat`→
`:session`; the `:chat` comment in session.ex is stale). So removing
`Behavior.Session` does NOT orphan the slice — `Agent.Receive` keeps owning
`:session`. Cold-load drops only TRULY undeclared slices.

**A3 (the hard part — shared-helper extraction):** `Behavior.Agent.Receive.handle_receive/2`
calls `Behavior.Session.Delivery.deliver_agent_receive/2`. That function + its
helpers (`body_text`, `body_attachments`, `attachment_hint_text`,
`first_attachment_path`, `agent_uri_meta`, `deliver_ensuring_with_flavor`,
`resolve_delivery_flavor`) are **SHARED with the user-delivery path** in
`session/delivery.ex` (multiple call sites). You CANNOT just move them. Plan:
1. Extract the agent-delivery-relevant payload/format helpers to a shared home the
   agent domain can own without a session dep — prefer `ezagent_domain_agent_bridge`
   (already a clean core-only leaf, and this logic builds an `AgentBridge.Payload`)
   or `ezagent_core`. Keep the user-delivery path using the same extracted helpers.
2. Move `deliver_agent_receive/2` (the agent path) into the agent domain
   (e.g. onto `Behavior.Agent.Receive` or a new agent-domain delivery module),
   calling the extracted shared helpers + `AgentBridge.deliver`.
3. `Behavior.Agent.Receive` must no longer `alias`/reference `Behavior.Session.Delivery`.

**Gate for PR-A:** the agent-domain modules (`entity/agent.ex`,
`entity/agent_template.ex`, `entity/agent/*.ex`, `behavior/agent/*.ex`) have ZERO
compile reference to any `Ezagent.Behavior.Session*` / `Ezagent.Entity.Session*` /
`SessionCreator*` symbol. `grep -rn` to prove it. Full umbrella suite green
(esp. cc/codex/curl deliver-and-reply paths). All gates green.

### PR-9a — create `ezagent_domain_agent` + land the acyclic gate (allowlisted)
Per the brief: new umbrella app `ezagent_domain_agent`; move `Entity.Agent`,
`Entity.AgentTemplate`, `Behavior.Agent.Receive`, the reparented curl-state
behavior, + their supervisors (`EzagentDomainInstanceMessage.{AgentSupervisor,
AgentTemplateSupervisor}` — **freeze the module names**, just relocate the files;
see D1a below) into it. `ezagent_domain_agent` deps: `ezagent_core` +
`ezagent_domain_agent_bridge` only. Wire its `Application.start` to register the
Agent Kind + `{Agent, :receive}`. **Land the acyclic arch-fitness invariant test
NOW**, allowlisting whatever cross-edges still exist, so every later step keeps it
green while shrinking the allowlist.

### PR-9b — rename the app `ezagent_domain_instance_message → ezagent_domain_session`
Mechanical but broad. **In the SAME commit:**
- `app:` atom in its `mix.exs` + ALL `{:ezagent_domain_instance_message, ...}`
  in_umbrella refs across sibling `mix.exs` + `config/*.exs` + the release app list.
- Runtime app atoms: `Application.ensure_all_started(:ezagent_domain_instance_message)`
  (e.g. `ezagent.credential.adopt.ex`), `Application.get_env(:ezagent_domain_instance_message, …)`.
- **The hardcoded `apps/ezagent_domain_instance_message/...` PATH allowlists inside
  `ezagent.arch.scan.ex` + `ezagent.check_invariants.ex`** — these go red on rename
  if not updated (the stale-allowlist class that reddened main twice, #736/#741).
- **D1a FREEZE (snapshot/routing safety):** do NOT rename the `Ezagent.*` OR the
  `EzagentDomainInstanceMessage.*` MODULE namespaces. `routing_rules.table_name`
  persists `EzagentDomainInstanceMessage.Routing.MentionRouting` /
  `.DefaultRules` as STRINGS — renaming those modules breaks routing-rule hydration
  on restart. App-atom rename only; module names frozen. (A module-namespace rename,
  if ever wanted, is a separate routing_rules-migrating PR.)

### PR-9c — shrink the acyclic allowlist to ZERO
`im → session → agent` acyclic with empty allowlist is the COMPLETION INVARIANT
(not "tests pass + PRs merged"). The arch-fitness test asserting (a) im has no
agent-Kind/`agent.receive` symbol, (b) session has no `McpChannel`/`orchestrator_bridge`
symbol, (c) the dep graph is acyclic — at 0 allowlist — is the gate.

## 5. Non-negotiable gates EVERY PR must pass (run them, don't eyeball)

1. `mix compile --force` (ALWAYS before gates — stale `.beam` will lie).
2. `mix ezagent.arch.scan` — **if you edit `arch.scan.ex` itself (e.g. an
   allowlist), `mix compile --force` AGAIN before re-running** (it's a Mix task;
   it runs the COMPILED version — this trap cost real time tonight).
3. `mix ezagent.check_invariants` + `mix ezagent.check_invariants.lifecycle`.
4. `mix ezagent.doc.scan` (the documentation-coverage ratchet — new public
   functions need `@doc`; counters in `arch_baseline_manifest.exs`).
5. Full umbrella `mix test` (the relevant suites at minimum;
   `apps/ezagent_domain_instance_message/test` is the core one — note the SQLite
   sandbox test-isolation pollution can cause varying transient failures; confirm
   real failures by running the named test in ISOLATION before treating as a bug).

## 6. Hard-won gotchas (will save you hours)

- **Line-coupled allowlists** (`@spawn_fresh_sanctioned`, `@all_slices_sanctioned`
  in arch.scan) record `{file, line}`; ANY edit that shifts those lines breaks them
  — update the line numbers (convention: a `# PR-X shifted +N` comment).
- **`set_effect_sites` (and sibling grep counters) scan PROSE/@doc too** — a literal
  `{:set, :key, …}` written in a `@doc` string counts as a real effect site and
  reddens the gate. Don't write set-effect tuples in docstrings.
- **Shared `:session` slice** between `Behavior.Session` and `Behavior.Agent.Receive`
  (see §4 PR-A).
- **Test-DB ONLY** for any migration; NEVER run `mix ecto.migrate` against the dev/
  prod DB or touch the dev/prod docker (`:10042`/`:10043`) — it crashes the BEAM.
- **No back-compat shims / defaults / whitelists** — Allen prefers direct structural
  fixes (let-it-crash).

## 7. Division of labor (do NOT cross)

- **You (codex):** all the DEV above — PR-A, 9a, 9b, 9c — each self-implemented +
  admin-merged when green. You do NOT write/run the E2E scenarios; the human's
  Claude agent owns E2E + per-merge validation + any fix-PRs.
- **Claude (human's agent):** monitors main; on each of your merges, runs the gates
  + suite on merged main + checks against the spec; opens a fix-PR if something is
  off; marks the matching task done; builds the E2E scenarios + runs them at
  suitable milestones and reports results to Allen.
- **Collision avoidance:** Claude's only writes to `lib/` are rebased-fresh fix-PRs;
  its E2E work stays on the test/scenario-doc surface.

## 8. Definition of done
`im → session → agent` acyclic with the arch-fitness invariant at **0 allowlist**,
full umbrella suite green, all gates green, app renamed to `ezagent_domain_session`,
`ezagent_domain_agent` extracted as a leaf, module names + snapshot/routing keys
unchanged. That invariant test failing if the split regresses IS the gate.
