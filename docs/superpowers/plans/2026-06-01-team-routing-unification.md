# Team Routing Unification — Implementation Plan (PR Decomposition)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement EACH PR. This document is the **dependency-ordered PR roadmap**; per the writing-plans multi-subsystem guidance, each PR below gets its **own bite-sized task-plan** (`docs/superpowers/plans/2026-06-01-tru-prN-<name>.md`, full TDD code) authored at the start of that PR — because each PR's exact code depends on the interfaces the previous PR lands.

**Goal:** Unify the orchestrator slot mechanism into session membership, and make multi-agent flows first-class via routing rule-sets + named prompt-templates + legends — so a flow like 传话游戏 is expressed declaratively (no model-computed routing) and `@`-mention works uniformly.

**Architecture:** Spec `docs/superpowers/specs/2026-06-01-team-routing-unification.md` (rev 2, approved by Allen + codex). Build bottom-up: first the routing/delivery plumbing that everything rides on (dynamic matcher vars → matched-rule threading → rule-set schema → prompt-template delivery), then the member model (facets/provenance/spawn-state), then the user-facing layer (legend), then template persistence (materialization), then the slot clean-cutover, then the scenario-34 gate.

**Tech Stack:** Elixir umbrella (`ezagent42/ezagent`); Ecto/SQLite; `Ezagent.Routing.{Matcher,Resolver,RuleStore,RoutingRegistry}`; `Ezagent.Behavior.Chat`; `Ezagent.CapabilityRegistry` + `Ezagent.Capability`; `Ezagent.Entity.SessionTemplate`; `Ezagent.Orchestrator.{Tools,McpServer}`; ExUnit; agent-browser for live e2e.

---

## Scope check (writing-plans guidance)

The spec is multi-subsystem → decomposed into **9 dependency-ordered PRs**, each producing working, testable software on its own. This roadmap fixes the **sequence, per-PR scope, key interfaces, and test gates**. It deliberately does NOT inline full TDD code for all 9 PRs: later PRs' code is shaped by earlier PRs' landed interfaces, so per-PR bite-sized plans are authored just-in-time (see the header). Every PR runs `/codex:adversarial-review` before merge (per `feedback_codex_review_every_pr`) and admin-squash-merges.

## File-structure map (what each PR touches)

| Area | Module(s) |
|---|---|
| Matcher / dynamic vars | `apps/ezagent_core/lib/ezagent/routing/matcher.ex`, `resolver.ex` |
| Rule store / schema | `apps/ezagent_core/lib/ezagent/routing/rule_store.ex`, a migration, `behavior/routing.ex` |
| Delivery / threading | `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex`, `apps/ezagent_plugin_cc/.../bridge_adapter.ex` (+ other flavor delivery) |
| Prompt templates | new `apps/ezagent_core/lib/ezagent/routing/prompt_template.ex` (render) + session-slice `prompt_templates` map |
| Member facets / caps | `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` (members slice), `apps/ezagent_core/lib/ezagent/capability.ex` + `capability_registry.ex`, relevant Behaviors' `actions/0` |
| Legend | new legend registry (session-scoped) + `apps/ezagent_plugin_liveview/.../mention` + `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex` |
| Template persistence | `apps/ezagent_domain_instance_message/lib/ezagent/entity/session_template.ex`, `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message.ex` (`create_session/3`) |
| Slot retirement | `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/{tools.ex,mcp_server.ex}` |
| E2E | `apps/ezagent_domain_instance_message/test/e2e/scenario_34_*.exs` + docs/scenarios/34 |

---

## PR sequence

### PR-1 — DROPPED (2026-06-01, codex review)
The original PR-1 added a `$sender` RECEIVER routing token (route a message back to its own sender). codex flagged it HIGH (loop: an auto-replying agent recurses `send→receive→send` with no guard on that path) and analysis showed it's the wrong primitive — "return to the asker" needs reply-context (the in-reply-to *other party*), not own-sender. **Dynamic audience is DEFERRED** to a future `$reply_to` + reply-context feature (spec §3.2/§7). The **template variables** (`{sender}`/`{flavor}`/`{body}`/`{session}`/`{sent_at}`) bundled here are RETAINED but move into **PR-4** (the render consumer). Implementation therefore STARTS at PR-2. (Note: `{sender}` the prompt-template VARIABLE is fine + kept; only `$sender` the routing TOKEN was dropped — different layers.)

### PR-2 — Resolver returns matched-rule context + delivery threading  (spec §3.5, CRITICAL)
- **Scope:** change `Resolver.resolve/4` to return `[{recipient_uri, ctx}]` where `ctx` carries `%{rule_id, prompt_template_ref}` (nil ctx for the system-default rule); add a back-compat `resolve_uris/4` returning bare `[URI]`. Thread `ctx` through `Behavior.Chat.handle_send/2` fan-out → `dispatch_receive_call/3` to the per-recipient delivery. **No rendering yet** — ctx is carried but unused (behaviour-preserving plumbing).
- **Files:** `resolver.ex`, `chat.ex` (fan-out + dispatch_receive_call), update all `resolve/4` callers (audit: grep) to `resolve_uris/4` except the chat fan-out which takes the ctx form.
- **Key interfaces:** `Resolver.resolve/4 :: [{URI.t(), ctx :: map() | nil}]`; `Resolver.resolve_uris/4 :: [URI.t()]`.
- **Deps:** none — this is now the FIRST PR (PR-1 dropped).
- **Test gate:** ctx returned + threaded to delivery; ALL existing routing/mention/chat tests green (behaviour-preserving — this is the riskiest plumbing change, so the no-regression bar is the gate).

### PR-3 — Rule-set schema + API  (spec §3.3)
- **Scope:** Ecto migration adding `rule_set` (string, null), `position` (int), `prompt_template_ref` (string, null) to `routing_rules`; `RuleStore` reads/writes them; `Behavior.Routing.add_rule` gains those params and **enforces single-receiver when `rule_set` is set**; `RuleStore.load_into_registry/1` publishes `prompt_template_ref` + rule_id into the registry so PR-2's ctx can carry it.
- **Files:** migration, `rule_store.ex`, `behavior/routing.ex`, `routing_registry.ex`.
- **Key interfaces:** `Routing.add_rule(table, matcher_json, receivers, opts)` where `opts` accepts `:rule_set`/`:position`/`:prompt_template_ref`; single-receiver validation error `{:error, :rule_set_requires_single_receiver}`.
- **Deps:** PR-2 (registry must carry `prompt_template_ref` into ctx).
- **Test gate:** rule-set rows persist + load; single-receiver enforced; existing flat rules (nil columns) behave unchanged.

### PR-4 — Prompt-template store + path-A delivery transform  (spec §3.4)
- **Scope:** session-scoped `prompt_templates` map (name → template string); new `Ezagent.Routing.PromptTemplate.render/3` (flat `{var}` substitution over the fixed var set `{sender}/{flavor}/{body}/{session}/{sent_at}` — the extractor lives HERE, moved from the dropped PR-1; **validates `{body}` present at write time**); apply at the per-recipient delivery seam using PR-2's ctx: agent delivery renders into the payload text; **human delivery renders a display/render-time suffix** (not stored). Single function `render_for_recipient/3` (NOT a hook registry — B deferred).
- **Files:** new `prompt_template.ex`, `chat.ex` (call render at delivery for agent + human branches), flavor bridge adapters (agent payload), LiveView/Feishu render (human suffix).
- **Key interfaces:** `PromptTemplate.render(template :: String.t(), vars :: map()) :: String.t()`; `render_for_recipient(message, recipient, ctx) :: rendered`.
- **Deps:** PR-2 (ctx), PR-3 (`prompt_template_ref`). Template-var extraction lives here (moved from the dropped PR-1).
- **Test gate:** render placeholders + `{body}`-required validation; agent-payload site; human render-suffix site; two-rules-same-recipient determinism (higher `position` wins).

### PR-5 — Member facets + provenance + `:manage` cap  (spec §3.1, §8.3)
- **Scope:** member `meta` gains `provenance`, `role_name`, `in_session_template`, and spawn-source state (`source_template_uri`, `live_worker_uri`, `generation`); declare a `:manage` action on the relevant Behavior(s); routing-row edit actions cap-check `{:manages, provenance}` via the existing `CapabilityRegistry`/`holds_cap?`/`matches?` path (action axis already merged). Member lookup by `role_name → current URI`.
- **Files:** `chat.ex` (members slice shape + role_name resolution), `capability.ex`/relevant Behaviors (`actions/0` + `:manage`), routing-row edit cap-check site.
- **Key interfaces:** member meta map keys; `{:manages, provenance_uri}` cap with `action: :manage`; `role_name_to_uri(session, role_name) :: {:ok, URI} | :error`.
- **Deps:** PR-3 (routing-row cap-check ties to rule editing).
- **Test gate:** `:manage` cap authorises member + its routing rows, denies non-owners; "only reply to owner" expressed purely as a routing rule routes correctly; role_name→URI rebinding across respawn; spawn-source/generation round-trip (drives a member-level update/rollback/respawn).

### PR-6 — Legend + resolution layer  (spec §3.6)
- **Scope:** session-scoped legend registry (`name → %{member_set, bound_rule_set, fold}`); mention parsers (LiveView + Feishu) resolve a legend name to "fire its bound rule-set entry" BEFORE the URI-mention path; UI fold (collapse legend members in the member list).
- **Files:** new legend registry module + session-slice `legends`; `mention_parser.ex` (Feishu) + LiveView mention resolution; member-list UI fold.
- **Key interfaces:** `Legend.resolve(session, name) :: {:ok, entry_rule} | :error`; legend takes precedence over URI-mention in the parser.
- **Deps:** PR-3 (rule-set entry), PR-5 (member_set by role_name).
- **Test gate:** `@legend` resolves via registry → entry rule fires; a legend name does NOT mis-route through the URI-mention path; fold hides members but they stay individually `@`-able.

### PR-7 — SessionTemplate members/templates/legends + create_session materialization  (spec §3.7)
- **Scope:** extend `SessionTemplate` content with `members` (`in_session_template: true`), `prompt_templates`, `legends`; extend version-hash; remove `agent_slots` from the content; change `create_session/3` to **materialize template members** (rebuild spawned members from `source_template_uri` + register provenance/role_name, install rule-sets + prompt_templates + legends) — not just join owner+orchestrator.
- **Files:** `session_template.ex` (content + hash), `ezagent_domain_instance_message.ex` (`create_session/3`).
- **Key interfaces:** template content keys; `create_session/3` materialization step.
- **Deps:** PR-3, PR-4, PR-5, PR-6 (it persists/rehydrates all of them).
- **Test gate:** snapshot round-trip (members/templates/legends); **instantiate/fork a template → the team actually appears + routes** (the load-bearing contract codex flagged).

### PR-8 — Slot retirement / clean cutover  (spec §3.8)
- **Scope:** remove `add_agent_slot`/`remove_agent_slot`/`update_agent_template`/`write_matcher(receiver_slot_names)` + slot-name routing; rewrite the orchestrator MCP tool surface to member+rule-set tools (add managed member, define rule-set rule, etc.); drop residual `agent_slots`. Clean cutover (no shim).
- **Files:** `tools.ex`, `mcp_server.ex`, `chat.ex` (remove agent_slots from working copy).
- **Key interfaces:** new orchestrator MCP tools (member/rule-set oriented); removal of the slot tools.
- **Deps:** PR-5, PR-6, PR-7 (members/rule-sets/templates must be in place to replace slots).
- **Test gate:** orchestrator builds a team via members + rule-sets; **invariant gate** (`feedback_completion_requires_invariant_test`): a test that FAILS if a slot-style mechanism reappears OR if a rule-set flow requires model-computed routing.

### PR-9 — Scenario 34 e2e + no-regression gate  (spec §9, Allen)
- **Scope:** express 传话游戏 purely via legend + rule-set + prompt-template (no baton tokens); deterministic Resolver-level invariant test of the chain topology; LIVE tier — real cc/codex/curl through the bound Feishu group (agent-browser screenshot per `feedback_esr_e2e_standards`); docs/scenarios/34 + index.
- **Files:** `scenario_34_*.exs`, `docs/scenarios/34-sender-locked-relay/scenario.md` (+ `.zh_cn.md`), index.
- **Key interfaces:** the scenario doc + test.
- **Deps:** PR-2..PR-8.
- **Test gate (the headline):** scenario-34 e2e passes (live cc→codex→curl via legend/rule-set/template, mirrored to the Feishu group) **AND the full umbrella suite shows no functional regression** (the cutover touched Resolver/Chat/RuleStore/templates/orchestrator — existing routing/mention/chat/orchestrator e2e scenarios stay green).

## Dependency graph

```
PR-2 ─→ PR-3 ─→ PR-4 ─┐
                │      ├─→ PR-7 ─→ PR-8 ─→ PR-9
      PR-3 ─→ PR-5 ───┤
      PR-5 ─→ PR-6 ───┘
```
(PR-1 DROPPED; PR-2 is the first PR. PR-3 needs PR-2's ctx plumbing for `prompt_template_ref`. Template-var extraction folds into PR-4.)

## Per-PR discipline (every PR)
1. Author its bite-sized task-plan (full TDD code) first.
2. Branch off latest `origin/main`; implement TDD; `mix test <touched apps>` green.
3. `/codex:adversarial-review`; address findings.
4. Feishu heads-up → push → PR → admin-squash-merge.
5. NEVER run `mix test`/compile in the live-phx main tree — use a worktree (per `feedback_subagent_worktree_wrong_repo`).

## Self-review (spec coverage)
- §3.1 member facets/provenance/spawn-state → PR-5. §3.2 template vars → PR-4 (dynamic audience deferred, §7). §3.3 rule-set → PR-3. §3.4 prompt-template/path-A → PR-4. §3.5 matched-rule threading → PR-2. §3.6 legend → PR-6. §3.7 template+materialization → PR-7. §3.8 slot cutover → PR-8. §5 decisions → distributed. §8 resolved decisions → honored (existing CapabilityRegistry in PR-5; session-scoped templates PR-4; per-session role_name PR-5; meta spawn-state PR-5; Resolver shape PR-2). §9 testing + scenario-34 → PR-9 + per-PR gates. No spec section is unassigned.
- Type consistency: `ctx` shape (`%{rule_id, prompt_template_ref}`) defined PR-2, consumed PR-4; `prompt_template_ref` column PR-3 feeds PR-2's ctx feeds PR-4's render; `role_name` defined PR-5, consumed PR-6 (member_set) + PR-7 (materialize). Consistent.

## Future PRs (post-v1)

### PR-F1 — `$reply_to` receiver token + reply-context (dynamic audience)
Deferred from the dropped PR-1 (the `$sender`-as-own-sender token was loop-prone AND the wrong primitive — codex 2026-06-01). This is the correct way to do "reply to whoever addressed me / return to the asker":
- **`Message` gains an `in_reply_to` field** — the URI of the message/originator this message is responding to, set when a user/agent replies to a specific message (thread context).
- **`$reply_to` receiver magic token** — expands to the `in_reply_to` originator (the OTHER party), member-filtered via `valid_member?/2`. **Loop-safe by construction** (it is never the message's own sender).
- **Reply-context threading** — when an agent receives a message (`chat.receive`) and replies (`chat.send`), the reply's `in_reply_to` is set to the received message's sender, so `$reply_to` routes the reply back to the originator.
- **Use case (Allen 2026-06-01)**: rule `{a member's message contains "need clarify"} → $reply_to` routes that member's clarification back to the ORIGINAL broadcaster A — which `$sender` (= the member itself, B) could not do.
- **Deps**: the v1 routing refactor (PR-2..PR-9) landed; needs a `Message` schema change + a UI/flow that sets `in_reply_to` (reply/threading).
- **Why post-v1**: requires a Message schema change + reply/threading UX; the v1 core gets by with static `from(X) → [Y]` rules + `$session_members` broadcast.
