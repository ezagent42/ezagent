# PLAN: PR-DR — delivery readiness + bridge lifecycle (blocker #1)

**Spec**: docs/superpowers/specs/2026-06-02-domain-agent-design.md §3.5 + §4 (PR-DR row).
**Blocker fixed**: #1 — a routed cc relay member's `AgentBridge.Registry` row vanishes (its claude/python bridge subprocess exits → `Channel.terminate/2` unbinds) and is never restored; subsequent routed delivery → `AgentBridge.deliver/2` → `:no_bridge` → silently dropped. Non-orchestrator agents have no readiness gate; delivery has no recovery.

## Root cause (verified)
- `Channel.terminate/2` (channel.ex:70-76) unbinds the Registry row when the bridge WS dies (claude/python exit).
- Nothing proactively relaunches the subprocess + rebinds. `ensure_subprocess_alive/2` exists (cc_agent.ex:1444; respawns the PtyServer) but is only invoked from `Sandbox.activate/2` (sandbox.ex:242) — i.e. on boot/cold-start, NOT on delivery.
- `Chat.handle_receive/3` Agent branch (chat.ex:686) calls `_ = AgentBridge.deliver(...)` and discards the result.
- `AgentBridge.deliver/2` (agent_bridge.ex:11-19) on `:no_bridge` → `drop/2` (log+telemetry), no recovery.
- The readiness wait (`await_orchestrator_boot_readiness`, cc_agent.ex:1508) returns `:ok` immediately for non-orchestrators.

## Design (decided)
**Make routed delivery to a bridge agent self-heal: on `:no_bridge`, ensure the agent's subprocess is (re)alive, await the rebind (bounded), retry once.** Flavor-neutral, in the AgentBridge domain, reusing two existing seams:
1. **Re-launch seam (already exists, flavor-neutral):** `Kind.Template.ensure_subprocess_alive/2` (optional callback; cc + np implement it; curl has none). Invoke it via the agent Kind's `Sandbox` behavior so the domain stays flavor-blind.
2. **Bound-signal seam (already exists):** `Registry.bind/3` broadcasts `{:agent_bridge_connected, uri, info}` on `Registry.topic()`. A general `await_bound(uri, timeout)` = subscribe to `Registry.topic()` → check `Registry.lookup/1` → `receive {:agent_bridge_connected, ^uri, _}` with timeout. (No orchestrator-specific `orch:lifecycle`.)

### Where the recovery is triggered
At the agent Kind's receive (the delivery chokepoint for every relay hop): `Chat.handle_receive/3` Agent branch. Before/around `AgentBridge.deliver/2`:
- `deliver/2` returns `{:error, :no_bridge}` → call `AgentBridge.ensure_ready(agent_uri)` then retry `deliver/2` ONCE.
- `ensure_ready/1` (new, AgentBridge domain): if `Registry.lookup` already ok → `:ok`; else ask the agent Kind to self-heal its subprocess (a Kind call that runs `Sandbox` → `template_class.ensure_subprocess_alive/2` with the slice's `respawn_template_data`), then `await_bound(uri, @ensure_timeout)`.

This keeps `chat.ex` flavor-neutral (it only calls `AgentBridge.deliver` + `AgentBridge.ensure_ready`, both domain functions). The cc-specific relaunch stays behind the existing `ensure_subprocess_alive/2` callback.

### Kind self-heal entry
`ensure_ready/1` needs to run `ensure_subprocess_alive` in the agent Kind's context (it owns `respawn_template_data` + `template_class`). Add a thin `Ezagent.Behavior.Sandbox.ensure_subprocess_alive_now(self_uri)` that resolves the Kind, reads its slice, and runs `do_ensure_subprocess_alive/3` (existing). If the Kind isn't running, `ensure_agent_kind`/SpawnRegistry spawns it (same as `Channel.ensure_agent_kind`).

### Why this is structural, not a shim
- No silent drop: a missing bridge becomes a bounded self-heal, not a lost message.
- Uniform: works for relay members, orchestrators, any bridge flavor implementing `ensure_subprocess_alive/2`. Orchestrator's existing `orch:lifecycle` gate is unchanged (additive).
- Let-it-crash preserved: if self-heal fails (subprocess won't come up), `ensure_ready` returns `{:error, _}`, deliver drops AS TODAY (logged), and the operator restarts — no degraded masking beyond one bounded retry.

## TDD tests (write first, must fail on current code)
1. **agent_bridge_test**: `deliver/2` to an agent whose row is absent, with a stub `ensure_ready` that binds a fake channel pid → assert the retry delivers (no `:no_bridge` drop). (Unit, domain-level, no claude.)
2. **await_bound test**: subscribe + a delayed `Registry.bind` in another process → `await_bound` returns `:ok` within timeout; absent bind → `{:error, :timeout}`.
3. **chat receive recovery test**: `handle_receive` Agent branch where first `deliver` is `:no_bridge` and `ensure_ready` succeeds → message delivered once. (May use a test adapter / Mox-free stub via a test flavor.)
4. **regression invariant (the blocker)**: an agent bound, then its channel pid dies (terminate→unbind), then a routed receive → message is delivered (self-heal rebinds), NOT dropped. This is the test that fails when blocker #1 is unfixed.

## Open questions for codex PR review
- Is `await_bound` racy if `ensure_subprocess_alive` rebinds BEFORE we subscribe? (Mitigation: subscribe-then-check-lookup, same pattern as `do_await_orchestrator_boot_readiness`.)
- Should the one-shot retry be in `deliver/2` itself (so ALL callers benefit, not just chat.handle_receive)? Leaning yes — put ensure+retry INSIDE `deliver/2` so the recovery is centralized and chat.ex stays untouched except for not discarding the result. Decide during impl.
- `ensure_subprocess_alive_now` resolving the Kind + reading its slice: confirm the existing API to read another Kind's slice synchronously without racing its own dispatch.

## Order: tests → impl → `mix test` green → codex review of the PR → commit on domain-agent-foundation.
