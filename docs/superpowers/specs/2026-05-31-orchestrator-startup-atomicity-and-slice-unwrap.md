# Orchestrator Startup Atomicity + Two-Container Slice Unwrap

**Date:** 2026-05-31
**Status:** rev2 — IMPLEMENTATION-READY (pending 2nd codex adversarial-review)
**Author:** Claude (brainstorm with Allen, 2026-05-31)
**Reviews folded in:** codex adversarial-review rev1 (verdict "needs rework" — false-premise + root-cause correction), Allen spec review.

**Origin:** Allen "更完整测试飞书同步" e2e — chained dispatch from the Feishu
group `oc_83a4f1ff` never fired. Root-cause investigation found that **no
orchestrator can register** after a phx restart (`from_orchestrator_uri/1` →
`:orchestrator_not_registered`), so every MCP bridge JOIN is fail-closed.

---

## 1. Problem

Two compounding defects make the orchestrator subsystem non-functional:

1. A two-container **slice-unwrap regression** prevents reading an orchestrator's
   durable config on restart.
2. The public **`create_session/3`** never actually instantiates the named
   SessionTemplate, so orchestrator sessions are born without an orchestrator
   (and with a family of "half-started" degrade paths that hide it).

## 2. Root-cause analysis (corrected by codex rev1)

### 2.1 Two-container slice unwrap regression (HIGH, confirmed)

`Ezagent.Kind.normalize_slice_view/1` (kind.ex:600):

```elixir
def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state), do: state
def normalize_slice_view(slice), do: slice
```

Unwraps only when **both** `:state` AND `:transients` are present. The snapshot
persist path **strips `:transients`** (Lifecycle migration #481), so the on-disk
slice is `%{state: persistent}` → falls through unwrapped.
`McpServer.load_chat_slice/1` (mcp_server.ex:320) routes the decoded chat slice
through `normalize_slice_view/1` *expecting it flattened*, then
`orchestrator_working_copy/1` reads `template_working_copy` at the top level →
nil → `:error` → `:orchestrator_not_registered`. **Same class as the Feishu
mirror bug (#502)**, unfixed in `mcp_server.ex`.

### 2.2 `create_session/3` never instantiates the named template (HIGH, codex rev1 correction)

The nil `orchestrator_template_uri` is **NOT** #481 data-loss. `create_session/3`
already **requires** a `template_name` (`require_template_name!`, ezagent_domain_chat.ex:112)
— but it uses the name only to build the session URI, then `do_create_session/3`
spawns the Kind directly via `Ezagent.Kind.spawn(Session, ...)`
(ezagent_domain_chat.ex:157). It **does not instantiate from the named
SessionTemplate** — it never calls the Generator
(`Session.spawn_from_template/2`), so it never materializes the template's
working copy (which is what sets `orchestrator_template_uri`) and never runs
Generator step 7 (`register_orchestrator_mcp_context/5`, session.ex:1836).

So a "default"-named session gets `orchestrator_template_uri: nil` and no MCP
registration — a session that *looks* templated but is actually bare. Both
`main` and `orch-feishu-7429` are in this state.

### 2.3 Half-started degrade paths (the "hack 启动一半" family)

`create_session/3` (ezagent_domain_chat.ex:340-370) intentionally keeps a
session alive with a non-functional orchestrator (SPEC 2026-05-26 "Gap A" +
codex PR #408 HIGH-3): spawn `:error` → `orchestrator_status: :failed` (operator
clicks Restart); skill load failure → `:degraded` "plain claude"; `{:partial}` →
`:pending`. `ensure_subprocess_alive/2` (cc_agent.ex:1389) then treats "PTY
process running" as "alive" and respawns the PTY on boot **without
re-registering** (registration is Generator-only), so the orchestrator silently
retries the bridge JOIN forever and is refused.

## 3. Design decisions (brainstorm + reviews, Allen-approved)

1. **Unwrap fix = A + C2 (defense in depth).** A: extend `normalize_slice_view/1`
   to flatten single-key `%{state: map}`. C2: enforce all `decode_state`
   consumers through the normalize chokepoint (a normalized accessor), rather
   than C1 (rehydrate in decode) — codex rev1 + Allen both chose C2, since C1
   would change raw decode output for UI / snapshot tooling / `SnapshotStore` /
   `StateRebuilder` whose contract is "snapshot state."
2. **Generator is the SOLE session-creation path; direct create is internal.**
   `do_create_session` routes through `Session.spawn_from_template/2` so the
   (already-required) `template_name` actually instantiates the template
   (materializes working copy → sets `orchestrator_template_uri` + registers).
   The bare `Kind.spawn(Session, ...)` becomes an internal primitive used only
   by the Generator. A template with `orchestrator_template_uri` set ⇒
   orchestrator session; nil ⇒ plain session (first-class, future-proof).
3. **Atomic orchestrator startup = strict fail-loud, 30s registration gate, via
   an async readiness signal.** codex rev1 showed bridge JOIN success is not
   synchronously observable. Add an async readiness signal (PubSub broadcast
   from `McpChannel.join/3` on successful registration); the Generator's
   orchestrator-ensure step waits on it ≤30s (non-blocking — uses the signal,
   does not busy-poll). On timeout: kill PTY, mark `:failed`, emit
   operator-visible error, **stop auto-respawn**. Eliminate `:pending` and
   `:degraded`. Registration = readiness proxy.
4. **Fail-loud preserves the `{:ok, session_uri, failed_meta}` shape** (codex
   rev1): the session is created (it is a valid container); only the orchestrator
   is `:failed`. `create_session` must NOT start returning `{:error, _}` —
   AdminLive, bootstrap, and tests treat orchestrator failure as non-fatal to the
   session. Collapsing the states requires updating AdminLive + the affected tests.
5. **Scope:** orchestrators only. Generic cc-agent readiness (no MCP registry
   signal) is a documented follow-up.

## 4. The fix

### 4.1 A — `normalize_slice_view/1` (kind.ex)

```elixir
def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state), do: state
def normalize_slice_view(%{state: state} = slice) when is_map(state) and map_size(slice) == 1, do: state
def normalize_slice_view(slice), do: slice
```

The `map_size == 1` guard matches ONLY the exact transients-stripped persisted
shape, never a legacy-flat slice. codex rev1 verified **no current Kind's flat
slice is a single-key `%{state: map}`** (Chat/Workspace/Identity/Template/
Publisher/Sandbox/ExternalMirror flats are all multi-key or `%{caps: …}` /
`%{content: …}` / `%{}`). **Constraint for future Kind authors (document in the
moduledoc):** a Kind's flat persistent state must never be a bare single-key
`%{state: …}`.

### 4.2 C2 — enforce the chokepoint at decode consumers (kind_snapshot.ex + 5 sites)

`decode_state/1` returns the full multi-slice Kind state; individual
Lifecycle slices are `%{state: …}`. Do NOT mutate `decode_state`'s raw output
(preserves the UI/tooling contract). Instead provide a normalized accessor
(e.g. `decode_state_normalized/1` or a per-slice `slice_view/2`) that maps slice
values through `normalize_slice_view/1`, and route the **persisted-snapshot
internal-readers** through it. codex rev1 enumerated the 5 `decode_state`
consumers — only **MCP durable rebuild** (`mcp_server.ex:323`) reads slice
internals and must use the normalized accessor; the other four (snapshot UI dump,
`SnapshotStore.latest/1`, Kind boot restore, `mix ezagent.snapshot.dump`) keep
the raw "snapshot state" contract.

**Fold-in:** refactor `feishu_adapter.ex` `slice_state/1` (feishu_adapter.ex:277)
to delegate to the same chokepoint (handle string-keyed `%{"state" => …}` too),
removing #502's duplicate local definition.

### 4.3 Generator as the sole creation path (ezagent_domain_chat.ex + session.ex)

- `do_create_session/3`: replace the bare `Ezagent.Kind.spawn(Session, …)`
  (ezagent_domain_chat.ex:157) with `Session.spawn_from_template/2` using the
  required `template_name` → materializes the template working copy (sets
  `orchestrator_template_uri` when the template defines one) + runs the Generator
  finalize incl. step 7 registration. The `:fresh`/`:adopted` freshness +
  per-URI `:global` lock semantics are preserved.
- The bare `Kind.spawn(Session, …)` is demoted to a Generator-internal primitive
  (not a public create path).
- **Named templates must exist:** ensure a `"default"` SessionTemplate (with an
  orchestrator) and any other names callers pass (`require_template_name!`
  already forces a name; now it must resolve to a real template — fail loudly if
  the named template is missing).
- Public signature unchanged → the ~96 call sites (mostly tests + a few LV /
  bootstrap) keep working; most already pass `template_name`. The behavioral
  change is internal (they now get a properly-instantiated session).

### 4.4 Atomic orchestrator startup (session.ex Generator step + cc_agent.ex)

- **Async readiness signal:** `McpChannel.join/3` (mcp_channel.ex:61), on
  successful registration, broadcasts a PubSub message keyed by orchestrator
  URI (e.g. `Phoenix.PubSub.broadcast(…, "orch:ready:" <> uri, :registered)`).
- **30s gate in the Generator's orchestrator-ensure step:** after spawning the
  orchestrator PTY, subscribe + wait on the readiness signal with a 30s timeout
  (receive/await — does not block other work; the caller process awaits its own
  child). On `:registered` → `:ready`. On timeout → kill PTY, mark orchestrator
  `:failed` with reason, emit operator-visible error event (EventLog + owner
  notification), DO NOT leave a retrying PTY. Return `{:ok, session_uri,
  %{orchestrator_status: :failed, …}}`.
- **Eliminate `:pending` and the `:degraded` "plain claude" path** — collapse to
  `:ready | :failed`. Update `create_session/3`'s typed response + callers.
- **`ensure_subprocess_alive/2` (boot reconcile):** readiness = registered, not
  process-alive. After respawning an orchestrator PTY, await the same 30s
  registration gate; on timeout, fail-loud (mark `:failed`, stop respawn loop).
  **Stagger** concurrent gates on boot (bounded concurrency) so N orchestrators
  do not pin N processes for 30s simultaneously (codex rev1 boot-storm note).

### 4.5 Existing-session repair

`main` / `orch-feishu-7429` carry nil OTU from §2.2. No risky data migration.
Repair = `Behavior.OrchestratorAdmin :restart` (orchestrator_admin.ex:101)
re-runs orchestrator setup atomically by (re)instantiating from the session's
template (deriving + persisting `orchestrator_template_uri`, then the 30s gate).
For the e2e: create a FRESH session from an orchestrator-bearing template (now
properly instantiated), verify `:ready`, bind Feishu `oc_83a4f1ff`, drive the chain.

## 5. Files touched (anticipated)

| File | Change |
|------|--------|
| `apps/ezagent_core/lib/ezagent/kind.ex` | A: `normalize_slice_view/1` single-key `%{state}` clause + Kind-author constraint moduledoc |
| `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex` | C2: normalized accessor (raw `decode_state` unchanged) |
| `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_server.ex` | use normalized accessor in `load_chat_slice/1` |
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex` | route `do_create_session` → Generator; collapse orchestrator states → ready\|failed; preserve `{:ok, _, failed_meta}` |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` | Generator orchestrator-ensure: async readiness gate (30s, fail-loud); OTU-set ⇒ atomic |
| `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_channel.ex` | broadcast readiness PubSub on registration |
| `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` | `ensure_subprocess_alive` = registration-gated readiness + staggered |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex` | handle collapsed `:ready\|:failed` (drop `:pending`/`:degraded` UI) |
| `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/feishu_adapter.ex` | fold `slice_state/1` into the chokepoint |
| (templates seed) | ensure a `"default"` SessionTemplate with an orchestrator exists |

## 6. Testing / validation

### 6.1 Invariant gate test (per feedback_completion_requires_invariant_test)
1. Create a session from an orchestrator-bearing template → orchestrator reaches
   `:ready` (registered).
2. **Drop the in-memory `McpRegistry`, call `McpServer.from_orchestrator_uri/1`,
   assert `{:ok, _}`** (rebuilt from durable). FAILS on `main` today (unwrap bug),
   PASSES with A+C2. This is the architectural gate.
3. A session from an orchestrator-LESS template → no orchestrator, no failure.
4. An orchestrator that cannot register within 30s → `:failed` (loud), NOT a
   zombie / `:pending` / `:degraded`.

### 6.2 Unit
- `normalize_slice_view/1`: single-key `%{state}` → unwrapped; `%{state,
  transients}` → unwrapped; legacy multi-key flat → unchanged; non-map → unchanged.
- C2 normalized accessor; raw `decode_state` output unchanged (regression-guard
  the UI/tooling contract).

### 6.3 E2E (original goal)
Fresh orchestrator session + bind Feishu `oc_83a4f1ff` + chained-dispatch prompt
→ orchestrator dispatches → chained replies mirror back to the group.

## 7. Scope / out of scope

- **In:** A + C2 unwrap; Generator-as-sole-creation-path; atomic 30s fail-loud
  orchestrator startup (async signal, staggered); existing-session repair;
  AdminLive + test updates; validation suite.
- **Out (follow-up):** generic non-orchestrator cc-agent readiness gating
  (no MCP registry signal — needs a separate readiness probe).

## 8. Open questions resolved by codex rev1

1. A's clause safe ✓ (no current single-key `%{state}` flat slice; documented for future authors).
2. C2 chosen over C1 ✓ (preserves raw decode contract; only MCP reads internals).
3. Removing `:pending`/`:degraded` = contract break ⇒ must update AdminLive +
   tests + preserve `{:ok, _, failed_meta}` (folded into §4.4/§5).
4. 30s gate needs an async readiness signal (PubSub from `McpChannel.join`) —
   no synchronous JOIN observability today (folded into §4.4).
5. Boot storm ⇒ staggered/bounded gates, do not block boot activation per agent
   (folded into §4.4).
6. nil OTU root cause = direct-create bypassing the Generator, NOT #481
   data-loss (folded into §2.2/§4.3).

## 9. Remaining questions for codex rev2

1. Does routing `do_create_session` → `spawn_from_template/2` preserve the
   `:fresh`/`:adopted` adoption + per-URI `:global` lock + rollback semantics
   currently in `do_create_session`? Any behavior the bare `Kind.spawn` path had
   that `spawn_from_template` lacks (or vice-versa)?
2. Are there session-create callers that pass a `template_name` for which **no
   SessionTemplate exists** (relying on the current name-only-for-URI behavior)?
   Those break under §4.3 (fail-loud on missing template) and must be enumerated.
3. PubSub readiness signal: is there an existing orchestrator-lifecycle PubSub
   topic to reuse, or a cleaner GenServer-reply path from the bridge?
4. Repair via `OrchestratorAdmin :restart` — does the restart flow already
   re-instantiate from template (set OTU) or only respawn the PTY?
