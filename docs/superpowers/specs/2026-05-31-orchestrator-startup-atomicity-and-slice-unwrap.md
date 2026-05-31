# Orchestrator Startup Atomicity + Two-Container Slice Unwrap

**Date:** 2026-05-31
**Status:** IMPLEMENTATION-READY (pending codex adversarial-review)
**Author:** Claude (brainstorm with Allen, 2026-05-31)
**Origin:** Allen "更完整测试飞书同步" e2e — chained dispatch from the feishu
group `oc_83a4f1ff` never fired; root-cause investigation uncovered a
HIGH-severity regression in orchestrator MCP registration plus a family of
"half-started" anti-patterns in session/orchestrator creation.

---

## 1. Problem

Driving a chained agent dispatch from a Feishu-bound session (`orch-feishu-7429`)
produced no orchestrator activity. Investigation (live `iex` on the running node)
found that **no orchestrator can register on this boot** — both
`cc_orchestrator-main` and `cc_orchestrator-orch-feishu-7429` return
`{:error, :orchestrator_not_registered}` from
`Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1`, so every MCP bridge
JOIN is fail-closed and no orchestrator can dispatch.

This is broader than Feishu — the orchestrator subsystem is non-functional after
a phx restart.

## 2. Root-cause analysis

### 2.1 Two-container slice unwrap regression (HIGH)

`Ezagent.Kind.normalize_slice_view/1` (apps/ezagent_core/lib/ezagent/kind.ex:600):

```elixir
def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state), do: state
def normalize_slice_view(slice), do: slice
```

It only unwraps when **both** `:state` AND `:transients` are present. But the
snapshot persist path **strips `:transients`** (per the Lifecycle migration
#481 — `feat(lifecycle): Phase B foundation tweaks T1-T4`), so the on-disk chat
slice is `%{state: persistent}` — which falls through the second clause
**unchanged**.

`Ezagent.Orchestrator.McpServer.load_chat_slice/1`
(apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_server.ex:320) routes the
decoded snapshot chat slice through `normalize_slice_view/1` *expecting it to
flatten* (its own comment says so), then `orchestrator_working_copy/1` reads
`Map.get(chat_slice, :template_working_copy)` at the **top level**. Because the
slice was never unwrapped, `template_working_copy` is nil (it lives under
`:state`), so `orchestrator_working_copy/1` returns `:error` →
`rebuild_from_durable/1` → `:orchestrator_not_registered`.

**This is the same root-cause class as the Feishu mirror bug (#502)** — a
two-container slice not unwrapped. #502 patched the Feishu adapter locally
(`feishu_adapter.ex` `slice_state/1`); `mcp_server.ex` has the same bug,
unfixed. Verified live: `normalize_slice_view(%{state: ...})` returns
`%{state: ...}` unchanged (`Map.keys == [:state]`).

### 2.2 Half-started orchestrator/session creation (the "hack 启动一半" family)

`EzagentDomainChat.create_session/3`
(apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:340-370) intentionally
keeps the session alive when orchestrator setup is incomplete (SPEC
2026-05-26-session-create-orchestrator-unified "Gap A" + codex PR #408 HIGH-3):

- orchestrator spawn `{:error, reason}` → session **alive**, `orchestrator_status: :failed`, "operator may click Restart in LV".
- skill / CLAUDE.md load failure → **degraded to "plain claude session"** (alive but does not orchestrate; owner gets a notification).
- `{:partial, orchestrator_pending}` → `:pending` middle state.

These leave an orchestrator agent **alive-but-non-functional** (a zombie):
`ensure_subprocess_alive/2` (apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:1389)
defines "alive" as **PtyServer process running**, not "registered/ready", so on
boot it respawns the PTY but never re-registers the MCP context (registration
happens only in the session Generator's step 7,
`Session.register_orchestrator_mcp_context/5`, session.ex:1836). The PTY then
silently retries the bridge join forever and gets refused.

**Consequence (data):** both existing sessions have
`template_working_copy.orchestrator_template_uri == nil` (key present, value
nil) — the orchestrator bootstrap degraded at create-time, so OTU was never set.
A session with nil OTU is correctly treated as "no orchestrator" by
`orchestrator_working_copy/1`.

## 3. Design decisions (brainstorm outcomes, Allen-approved 2026-05-31)

1. **Unwrap fix = A+C (defense in depth).** Fix at BOTH the read chokepoint (A)
   and the decode boundary (C) so no consumer ever sees a raw two-container
   shape regardless of read path.
2. **Atomic orchestrator startup = strict fail-loud, 30s registration gate.**
   Registration is the readiness proxy (a registered orchestrator must be
   PTY-alive + Anthropic-connected + onboarded). On timeout → kill PTY, mark
   `:failed`, emit operator-visible error, **stop auto-respawn**. Transient
   network blips are absorbed by claude's in-PTY connection retry inside the 30s
   window. Eliminate the `:pending` and `:degraded`/"plain claude" middle states.
3. **Orchestrator is an optional Session Template setting (B).** Whether a
   session has an orchestrator is determined by its SessionTemplate's
   `orchestrator_template_uri` (set ⇒ orchestrator required; nil ⇒ plain session,
   a first-class legitimate case — future templates may omit it). The **session
   is always a valid container**; the **orchestrator** is the thing that is
   binary `ready | failed-loud`. On orchestrator failure the session is NOT
   rolled back; the orchestrator agent is marked `:failed` + quarantined (no
   silent retry) and requires explicit restart.
4. **Scope:** orchestrators only this round. Regular cc-agent readiness (no MCP
   registry signal) is a documented follow-up.

## 4. The fix

### 4.1 Component A+C — slice unwrap

**A (read chokepoint).** Extend `Ezagent.Kind.normalize_slice_view/1` to also
flatten the transients-stripped persisted shape:

```elixir
def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state), do: state
def normalize_slice_view(%{state: state} = slice) when is_map(state) and map_size(slice) == 1, do: state
def normalize_slice_view(slice), do: slice
```

The new clause matches ONLY a single-key `%{state: map}` (the exact persisted
shape) — it does NOT match a legacy-flat slice that merely happens to contain a
`:state` field among others (`map_size == 1` guard). **codex must verify** no
legacy-flat slice is a single-key `%{state: ...}`.

**C (decode boundary).** `Ezagent.Ecto.KindSnapshot.decode_state/1`
(kind_snapshot.ex:236/250) returns the full multi-slice Kind state
(`%{chat: ..., external_mirror: ..., publisher: ...}`), where individual
Lifecycle-based slices are in `%{state: ...}` form. Add a normalization that
routes each slice value through the same single chokepoint so decode output is
shape-consistent with live reads.

**Precise C mechanism — DECISION FOR CODEX:** two candidate placements, pick the
one codex judges lower-risk:
- **C1 (rehydrate):** in `decode_state`, re-wrap each transients-stripped slice
  back to `%{state, transients: <default>}` so it is indistinguishable from a
  live slice and the *existing* `normalize_slice_view` first clause handles it.
  No new `normalize_slice_view` clause needed (A becomes a no-op safeguard).
- **C2 (enforce chokepoint):** keep A's new clause; make `decode_state` (or a
  thin `decode_state_normalized/1` consumers use) map slice values through
  `normalize_slice_view/1`, and audit that every persisted-snapshot consumer
  uses the normalized accessor rather than reading raw `decode_state` output.

Either way the invariant is: **a persisted two-container slice never reaches a
consumer un-normalized.**

**Fold-in:** once A handles `%{state: ...}` (and `%{"state" => ...}` if
string-keyed snapshots exist), refactor `feishu_adapter.ex` `slice_state/1`
(feishu_adapter.ex:277) to delegate to the chokepoint, removing the duplicate
local definition (so #502's local patch becomes the canonical path).

### 4.2 Component — atomic orchestrator startup

**Readiness gate (the 30s rule).** Define orchestrator readiness as: the
orchestrator's MCP context is registered (`McpRegistry.lookup/1` returns `{:ok,
_}` AND/OR a successful bridge JOIN) within **30 seconds** of PTY spawn.

Apply at BOTH startup paths:

- **`create_session/3`** (ezagent_domain_chat.ex): collapse the orchestrator
  outcome to binary. Remove the `:pending` branch and the
  `notify_orchestrator_role_degraded` "plain claude" degrade path. Outcomes:
  - `:ready` — orchestrator registered within 30s.
  - `:failed` — not registered within 30s OR spawn/role-bootstrap error. Kill
    the PTY, set `orchestrator_status: :failed` with the reason, emit an
    operator-visible error event (EventLog + owner notification), and DO NOT
    leave a retrying PTY. The session is created (B); the orchestrator is
    quarantined until explicit restart.
- **`ensure_subprocess_alive/2`** (cc_agent.ex:1389) / boot reconcile: after
  respawning the PTY for an orchestrator agent, the orchestrator must
  re-register within 30s (the registry is in-memory and empty after restart, so
  respawn alone is insufficient). If not registered in 30s → kill PTY, mark
  `:failed`, emit error, stop the respawn loop. "Alive" must mean "registered",
  not "process running".

**Registration on boot.** Because `McpRegistry` is in-memory and rebuilt lazily
via `rebuild_from_durable/1` on bridge JOIN, the A+C unwrap fix is what makes
boot-time re-registration actually succeed for an OTU-bearing session. The
atomic gate then guarantees we either reach that registered state or fail loudly.

**Explicit restart path.** Reuse the existing `Behavior.OrchestratorAdmin
:restart` (orchestrator_admin.ex:101; flow at ezagent_domain_chat.ex:276/529) as
the operator/system action to bring a `:failed` orchestrator back. Restart must
itself be atomic (subject to the same 30s gate).

### 4.3 Component — orchestrator as Session Template setting

No behavioral change to the data model (already
`SessionTemplate.orchestrator_template_uri`). Make the contract explicit:
- Generator: if the template's `orchestrator_template_uri` is set, the session's
  working copy MUST persist a non-nil OTU and the orchestrator MUST be brought
  to `:ready` atomically (or the orchestrator is `:failed`, per §4.2).
- If the template's `orchestrator_template_uri` is nil, the session is a plain
  session — no orchestrator, no startup gate, OTU stays nil legitimately.

### 4.4 Component — existing-session repair

`main` and `orch-feishu-7429` carry nil OTU from the historical degrade. Do NOT
run a risky data migration. Instead:
- Provide/confirm an explicit **repair** = `OrchestratorAdmin :restart` that
  re-runs orchestrator setup atomically against the session's template
  (re-deriving and persisting OTU from the template, then the 30s gate).
- For the default session `main` (whose default template carries an
  orchestrator), repair brings it to `:ready`.
- For the e2e: create a FRESH session from an orchestrator-bearing template,
  verify `:ready`, bind Feishu `oc_83a4f1ff` to it, drive the chain.

## 5. Files touched (anticipated)

| File | Change |
|------|--------|
| `apps/ezagent_core/lib/ezagent/kind.ex` | A: `normalize_slice_view/1` new single-key `%{state}` clause |
| `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex` | C: decode-boundary normalization (C1 or C2 per codex) |
| `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_server.ex` | consumes the fixed unwrap (verify `load_chat_slice`/`orchestrator_working_copy`) |
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex` | atomic `create_session` orchestrator outcome (remove `:pending`/`:degraded`; 30s gate; fail-loud) |
| `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` | `ensure_subprocess_alive` = registration-gated readiness, not process-liveness |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` | Generator: enforce OTU-set ⇒ atomic orchestrator |
| `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/feishu_adapter.ex` | fold `slice_state/1` into the chokepoint |

## 6. Testing / validation

### 6.1 Invariant / regression test (the gate — per feedback_completion_requires_invariant_test)

A test that:
1. Creates a session from an orchestrator-bearing template; asserts orchestrator
   reaches `:ready` (registered).
2. Simulates a restart: drops the in-memory `McpRegistry`, then calls
   `McpServer.from_orchestrator_uri/1` and asserts `{:ok, _}` (registration
   rebuilt from the durable snapshot). **This test FAILS on `main` today** (the
   unwrap bug makes `rebuild_from_durable` return `:orchestrator_not_registered`)
   and PASSES with A+C. This is the architectural gate.
3. Asserts a session from an orchestrator-LESS template has no orchestrator and
   does not fail.
4. Asserts orchestrator startup that cannot register within the gate ends in
   `:failed` (loud), NOT a zombie or `:pending`/`:degraded`.

### 6.2 Unit tests
- `normalize_slice_view/1`: single-key `%{state}` → unwrapped; `%{state,
  transients}` → unwrapped; legacy-flat (multi-key) → unchanged; non-map → unchanged.
- `decode_state` normalization (C): persisted slice → normalized shape.

### 6.3 E2E (the original goal)
Fresh orchestrator session + bind Feishu `oc_83a4f1ff` + send a chained-dispatch
prompt → orchestrator dispatches → chained replies mirror back to the group.

## 7. Scope / out of scope

- **In:** orchestrator startup atomicity + the A+C unwrap + existing-session
  repair + the validation suite.
- **Out (follow-up):** generic (non-orchestrator) cc-agent readiness gating —
  regular agents have no MCP registry signal; a separate readiness probe is
  needed and is tracked separately.

## 8. Risks / open questions for codex adversarial-review

1. **A's new clause safety:** is any legacy-flat slice a single-key `%{state:
   map}` that would be wrongly unwrapped? (The `map_size == 1` guard is meant to
   prevent this.)
2. **C placement (C1 rehydrate vs C2 enforce-chokepoint):** which is lower-risk
   given ALL `decode_state` consumers across every Kind, not just chat?
3. **Removing the degrade paths:** does any current caller DEPEND on the
   `:pending`/`:degraded`/"session-alive-on-orchestrator-failure" behavior such
   that fail-loud breaks it? (Reverses SPEC 2026-05-26 Gap A + codex PR #408
   HIGH-3 — confirm those rationales no longer hold.)
4. **30s gate mechanics:** is bridge-JOIN/registration observable to
   `create_session` and `ensure_subprocess_alive` synchronously within 30s, or
   does it need an async readiness callback? Avoid blocking the caller for 30s.
5. **Boot storm:** with N orchestrators respawning on boot, do N concurrent 30s
   gates create load/timeout cascades? Consider staggering.
