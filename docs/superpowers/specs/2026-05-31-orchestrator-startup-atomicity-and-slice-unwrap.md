# Orchestrator Startup Atomicity + Unified Session Creation + Slice Unwrap

**Date:** 2026-05-31
**Status:** rev3 — IMPLEMENTATION-READY (pending codex adversarial-review rev3)
**Author:** Claude (brainstorm with Allen, 2026-05-31)
**Reviews folded:** codex rev1 (root-cause correction → C2), codex rev2 (5 blocking
gaps on the "route-through-Generator" reframe), Allen direction (no split — one
complete refactor; make `create_session` internal; unify the two paths).

**Origin:** Allen "更完整测试飞书同步" e2e — chained dispatch from Feishu group
`oc_83a4f1ff` never fired because **no orchestrator can register** after a phx
restart.

---

## 1. Problem

Three compounding defects:
1. **Slice-unwrap regression** — can't read an orchestrator's durable config on restart.
2. **Two divergent session-creation paths** — `EzagentDomainChat.create_session/3`
   (direct) and `Session.spawn_from_template/2` (Generator). The direct path
   never instantiates the named template, so orchestrator sessions are born
   without an orchestrator (nil `orchestrator_template_uri`, no MCP registration).
3. **Half-started orchestrators** — `:pending`/`:degraded` states + process-liveness
   ("PTY running") mistaken for readiness, leaving silent non-functional zombies.

## 2. Root cause (codex rev1+rev2 corrected)

- **Unwrap (2.1):** `Kind.normalize_slice_view/1` (kind.ex:600) unwraps only
  `%{state, transients}`; persist strips `:transients` (Lifecycle migration #481)
  → on-disk `%{state}` falls through unchanged → `McpServer.load_chat_slice/1`
  can't read `template_working_copy` → `:orchestrator_not_registered`. Same class
  as Feishu bug #502, unfixed in `mcp_server.ex`.
- **Creation (2.2):** `create_session/3` requires `template_name`
  (`require_template_name!`, ezagent_domain_chat.ex:112) but uses it only for the
  URI; `do_create_session/3` spawns the Kind directly (`Kind.spawn(Session,…)`,
  :157) and **never instantiates the named SessionTemplate** — so OTU stays nil
  and Generator step 7 registration never runs. Both `main` and `orch-feishu-7429`
  are in this state. NOT #481 data-loss.
- **Half-start (2.3):** `create_session/3` keeps a session alive with
  `orchestrator_status: :failed`/`:degraded`/`:pending` (SPEC 2026-05-26 Gap A +
  codex PR #408 HIGH-3); `ensure_subprocess_alive/2` (cc_agent.ex:1389) respawns
  the PTY on boot without re-registering → silent forever-refused JOIN loop.

## 3. The divergence map (why "just call the Generator" failed codex rev2)

The two paths overlap (both create a Session) but differ. The unified path must
carry the union of correct behaviors:

| Concern | `create_session`/`do_create_session` | `spawn_from_template` (Generator) | Unified path MUST |
|---|---|---|---|
| Session naming | caller `short_name` → `session://<template_name>/<ws>/<short>` | `derive_session_uri(template, ws, owner)` | accept a caller name + template; URI = `session://<template_class>/<ws>/<name>` |
| Concurrency | per-URI `:global.set_lock` | none | keep the `:global` lock |
| Spawn outcome | `:fresh`/`:adopted` + rollback-on-finalize-failure | `:already_present` idempotent, no rollback | keep `:fresh`/`:adopted` + rollback |
| Creator membership | auto-joins creator (619) | joins orchestrator + worker slots only (NOT creator) | join creator **and** orchestrator + workers |
| Template materialization | none (OTU stays nil) | full (slots, routing, working copy, **OTU**) | full materialization |
| Orchestrator | `ensure_orchestrator_meta` only | step 2 spawn + step 7 register | atomic startup + register (§4.4) |
| Instantiate cap | none required | `owner_instantiate_preflight` requires `Template :instantiate` on the template (session.ex:2048) | reconcile — session-create authority must cover instantiating the session's own template (§4.3) |
| Cap grant | grants directly to creator | grants via delegated orchestrator ctx | both, per the unified flow |

## 4. Design (one complete refactor — Allen: no split)

### 4.1 A — `normalize_slice_view/1` (kind.ex)
Add a single-key clause; `map_size == 1` guard so it matches ONLY the
transients-stripped persisted shape, never a legacy-flat multi-key slice (codex
rev1 verified no current Kind flat is single-key `%{state}`):
```elixir
def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state), do: state
def normalize_slice_view(%{state: state} = slice) when is_map(state) and map_size(slice) == 1, do: state
def normalize_slice_view(slice), do: slice
```
Document the constraint in the moduledoc for future Kind authors.

### 4.2 C2 — chokepoint at decode consumers (kind_snapshot.ex)
Do NOT mutate raw `decode_state/1` output (preserves the snapshot-state contract
for UI / `SnapshotStore` / boot-restore / `mix snapshot.dump`). Add a normalized
accessor that maps slice values through `normalize_slice_view/1`; route only the
**persisted-slice internal-reader** — `McpServer.load_chat_slice/1` (mcp_server.ex:323)
— through it. Fold `feishu_adapter.ex` `slice_state/1` (feishu_adapter.ex:277,
incl. string-keyed `%{"state"=>…}`) into the same chokepoint, removing #502's
local copy.

### 4.3 Unified session creation — ONE path

**Make the Generator the sole implementation; `create_session/3` becomes an
internal thin resolver.** Concretely:

- **Public entry** = `Session.spawn_from_template/N`, extended to accept a
  **caller instance name** (so callers keep naming their session) in addition to
  the template + owner. `create_session/3` is demoted to an internal wrapper that
  resolves `template_name` → SessionTemplate URI and delegates; the
  `Workspace.create_session` dispatch (workspace.ex:752) re-points to it.
- **Absorb `do_create_session`'s semantics into the Generator path:**
  - wrap `reconcile_loop` body in the per-URI `:global.set_lock/3`;
  - keep `:fresh`/`:adopted` adoption + **rollback the freshly-created session on
    any finalize-step failure** (replaces the Generator's partial_report-and-leave);
  - **Step 8 auto-joins the creator/owner** in addition to orchestrator + workers
    (fixes codex rev2 Q1 silent creator-drop).
- **Template resolution (codex rev2 Q2):** the unified path resolves the
  caller-supplied name/class → a real `SessionTemplate`. **Fail loudly if the
  named template does not exist** (no name-only-for-URI). Therefore:
  - ensure a `"default"` SessionTemplate (with an orchestrator) is **robustly
    seeded** — promote the seed from best-effort (logs-then-:ok,
    application.ex:381) to a hard boot invariant (crash boot if it can't persist).
  - migrate AdminLive's workspace-local `session_templates` map keys
    (admin_live.ex:798/3097) + `Workspace.Loader`'s TemplateRegistry names
    (workspace/loader.ex:76) so every name callers pass resolves to a real
    SessionTemplate (or is explicitly rejected).
- **Instantiate-cap reconciliation (codex rev2 Q5):** a creator authorized to
  create a session must be able to instantiate that session's own template.
  `owner_instantiate_preflight` (session.ex:2048) currently demands a
  `Template :instantiate` cap on the template that a plain creator lacks on a
  shared default. Resolution (pick in implementation, flag for codex): either (a)
  grant every workspace member an `:instantiate` cap on the workspace's default
  SessionTemplate at workspace bootstrap, or (b) treat the workspace
  `:create_session` authority as sufficient and have the preflight accept it for
  the workspace's own default template (system-materialization ctx for the
  template read/instantiate, scoped to session-create). Must NOT silently bypass
  the check.

### 4.4 Atomic orchestrator startup + the step-ordering race fix

- **Race fix (codex rev2 Q5):** today the orchestrator PTY spawns at Step 2 but
  OTU is written at Step 5 and the registry context at Step 7 — a bridge JOIN
  before Step 5 fails (`rebuild_from_durable` needs durable OTU). **Reorder:
  persist the working-copy `orchestrator_template_uri` + `session_template_uri`
  (the durable fields `rebuild_from_durable` needs) BEFORE the orchestrator PTY
  can attempt a JOIN** — i.e., materialize the orchestrator-relevant working-copy
  slice before/at Step 2, not Step 5. Step 7's ETS put then becomes a cache-fill
  (the lazy `rebuild_from_durable` already reconstructs it on JOIN).
- **Async readiness signal (codex rev2 Q3 — net-new):** `McpChannel.join/3`
  (mcp_channel.ex:61), on successful registration, `Phoenix.PubSub.broadcast`es
  `{:orchestrator_ready, uri}` on a new `"orch:lifecycle"` topic (core PubSub).
- **30s fail-loud gate:** after spawning the orchestrator, the unified path
  subscribes + `receive`s the readiness signal with a 30s timeout (no busy-poll).
  `:registered` → `:ready`. Timeout → kill PTY, mark orchestrator `:failed` with
  reason, emit operator-visible error (EventLog + owner notification), **stop
  auto-respawn**. **Stagger** gates on boot (bounded concurrency) to avoid an
  N×30s boot storm.
- **Collapse states** to `:ready | :failed` (drop `:pending`/`:degraded`).
- **Preserve `{:ok, session_uri, failed_meta}`** (codex rev1 Q3) — the session is
  a valid container; only the orchestrator is `:failed`. Update AdminLive
  (admin_live.ex:846/2823) + the affected tests to the 2-state model.
- **`ensure_subprocess_alive/2`:** readiness = registered (await the same gate),
  not process-alive; fail-loud + stop respawn loop on timeout; staggered.

### 4.5 `:restart` repair (codex rev2 Q4)
`OrchestratorAdmin :restart` (orchestrator_admin.ex:95) today only re-instantiates
the orchestrator AgentTemplate + respawns the PTY; it does NOT set OTU. Extend it
to **re-materialize the session working copy from its SessionTemplate** (persist
OTU + `session_template_uri`) then run the atomic gate — so it actually repairs
nil-OTU sessions (`main`, `orch-feishu-7429`).

## 5. Files touched (anticipated)

| File | Change |
|---|---|
| `…/kind.ex` | A clause + moduledoc constraint |
| `…/ecto/kind_snapshot.ex` | C2 normalized accessor (raw decode unchanged) |
| `…/orchestrator/mcp_server.ex` | use normalized accessor in `load_chat_slice/1` |
| `…/entity/session.ex` | unified path: name param, `:global` lock, fresh/adopted+rollback, creator auto-join, reorder OTU/registry before JOIN, atomic 30s gate; instantiate-cap reconcile |
| `…/ezagent_domain_chat.ex` | `create_session` → internal resolver; collapse states; preserve `{:ok,_,failed_meta}` |
| `…/orchestrator/mcp_channel.ex` | broadcast `{:orchestrator_ready, uri}` on registration |
| `…/orchestrator/orchestrator_admin.ex` | `:restart` re-materializes OTU + atomic gate |
| `…/template/cc_agent.ex` | `ensure_subprocess_alive` = registration-gated + staggered |
| `…/plugin_liveview/admin_live.ex` | 2-state orchestrator UI; template_name → real SessionTemplate |
| `…/plugin_feishu/feishu_adapter.ex` | fold `slice_state/1` into chokepoint |
| `…/application.ex` (seed) | `"default"` SessionTemplate seed = hard boot invariant |
| `…/workspace/loader.ex`, `…/behavior/workspace.ex` | template-name resolution → real SessionTemplate |

## 6. Validation

- **Invariant gate test:** create session from orchestrator-bearing template →
  `:ready`; **drop `McpRegistry`, `from_orchestrator_uri/1` → `{:ok,_}`** (rebuilt
  from durable; FAILS on main today, PASSES with A+C2); orchestrator-less template
  → no orchestrator/no failure; un-registerable orchestrator → `:failed` (loud,
  not zombie); **creator IS a member** after create (regression-guards the Q1 drop);
  raw `decode_state` output unchanged (guards the C2 contract).
- **Unit:** `normalize_slice_view/1` table; template-resolution fail-loud on
  missing template; the `:restart` OTU repair.
- **E2E:** fresh orchestrator session + bind Feishu `oc_83a4f1ff` + chained-dispatch
  prompt → orchestrator dispatches → chained replies mirror back.

## 7. Scope / out of scope
- **In:** A+C2; unified creation path (all §3 divergences reconciled); atomic
  orchestrator startup + race fix; `:restart` OTU repair; template-resolution +
  default-seed-as-invariant; AdminLive + tests; validation.
- **Out (follow-up):** generic non-orchestrator cc-agent readiness gating.

## 8. Resolved by codex rev1+rev2
A-clause safe; C2 over C1; nil-OTU = direct-create bypass (not #481); `:pending`/
`:degraded` removal is a contract break (update AdminLive+tests, keep `{:ok,_,
failed_meta}`); async readiness signal is net-new; boot-storm → stagger;
spawn_from_template loses lock/rollback/creator-join + needs instantiate cap;
`:restart` doesn't set OTU; Generator step-ordering race.

## 9. Open for codex rev3
1. Session naming under unification — does adding a caller-name param to
   `spawn_from_template` collide with `derive_session_uri`'s template-derived
   naming, or with deterministic-URI assumptions elsewhere?
2. Instantiate-cap reconcile — option (a) grant-default-instantiate vs (b)
   create_session-authority-suffices: which is consistent with the cap model +
   doesn't open a privilege hole?
3. Reordering OTU/registry before Step 2 JOIN — does any Step 3/4/5 input depend
   on the orchestrator already being spawned (ordering inversion hazard)?
4. Rollback in the unified path — is rolling back a freshly-created Session safe
   given workspace bind + cap grants + member joins already applied? Enumerate
   teardown order.
5. Making the `"default"` SessionTemplate seed a hard boot invariant — any
   environment (test/CI/fresh) where that would prevent boot?
