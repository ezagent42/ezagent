# AutoService v2 — live E2E findings (2026-06-12)

First end-to-end live run of the AutoService-on-socialware vertical (single-tenant
`cinnox`, real cc bot on **claude 2.1.169**, ambient `CLAUDE_CODE_OAUTH_TOKEN`).
All three role paths now work live. The 145-unit/integration suite was green, but
the live run exposed **8 bugs that only manifest in the cold-load + real-bridge +
real-UI paths** (the tests dispatch to already-alive in-BEAM kinds and stub the
browser, so they never hit these). All fixed; suite now 61 autoservice tests green.

## Demos (this directory)
- `customer.gif` / `.mp4` — customer → on-brand, soul-driven CS reply, multi-turn.
- `operator.gif` / `.mp4` — operator console: select session → type reply → 接管 → 提交.
- `admin.gif` / `.mp4` — tenant admin: edit soul → 保存 → 发布 (CR v→v+1) → preview render.
- `customer-screenshot.png` — the verified customer-reply frame.

## Bugs found & fixed (all in `ezagent_plugin_autoservice`)

**Customer path**
1. **Orchestrator flavor cache non-durable** — `AgentFlavorAttributes` is ETS; the
   server booted with an empty cache, so the dormant CS orchestrator failed to
   resolve (`:no_such_actor`) and the customer message never reached it. Fix:
   `Application.after_boot/0` rehydrates the flavor tag for every persisted
   `cs_orchestrator` snapshot (durable snapshot index, not the §11-barred
   SnapshotStore) + warm-spawns.
2. **Orchestrator dropped agent replies** — the cc/curl bridge delivers a sub-agent
   reply to its caller (the orchestrator) as `chat.send`, but the orchestrator only
   handled `chat.receive` → `{:unknown_action, :send}`, silently dropping a
   correctly-generated reply. Fix: a `:send` action delegating to the
   receive-classifier (+ behaviors/0 registration + regression test).

**Operator path**
3. **Session list never matched** — OperatorLive filtered on a `session://cs/`
   prefix, but CS URIs are `session://<ws>/cs/<name>` (ws is the host). Fix: filter
   on the `/cs/` path segment.
4. **Proactive takeover blocked** — the 接管 button + claim handler required an open
   turn, but `operator_claim` already handles the nil case (opens a fresh turn).
   Relaxed the UI gate + handler.
5. **Session rehydrated as the wrong Kind** — OperatorLive used the generic
   `SpawnRegistry.spawn` → plain chat `Session` (no Turn), so the fresh `turn.open`
   failed `{:unknown_action, :open}`. Fix: `Assembly.ensure_socialware_session/2`
   (spawns `SocialwareSession`, mirroring the customer mount path).
6. **Settle targeted the wrong turn** — `operator_claim` opens+tracks a fresh turn,
   but OperatorLive's `@open_turn_id` stayed stale, so settle bailed/targeted nil.
   Fix: the orchestrator settles its OWN tracked `open_turn_id` (arg is a fallback);
   OperatorLive dispatches unconditionally.

(The admin path worked end-to-end on the first try — it is mostly synchronous CR
operations the unit tests covered well.)

## Remaining gaps (NOT fixed — flagged)

- **Fast curl ACK (biphasic) is wired but keyless** — `Assembly.maybe_put_api_key/2`
  now provisions the fast agent's key from `$<PROVIDER>_API_KEY` (e.g.
  `DEEPSEEK_API_KEY`), but no key was available on the demo box, so the recorded
  customer demo is **single-agent (slow cc only)**. Set the env var + re-provision
  to enable the fast ACK leg.
- **SocialwareSession shares `kind_type "session"` with the plain chat Session**
  (substrate). The generic `SpawnRegistry "session"` handler spawns the plain
  Session; our paths must explicitly spawn `SocialwareSession` (bug #5 is the
  plugin-side workaround). Proper fix (distinct kind_type or a snapshot-inspecting
  session spawn handler) is substrate-level — **flag to gagameow/Allen**.
- **Generic `AgentFlavorAttributes` boot rehydration** — bug #1's fix lives in this
  plugin's `after_boot/0`; every non-core-kind agent-flavor plugin hits the same
  non-durable-cache issue, so the generic rehydration arguably belongs in core —
  **flag to Allen**.
- **Per-message authorship on the settled surface** — the operator's reply is
  composed by the orchestrator (sender = the agent URI), so the customer sees it
  under "AI 客服", and in the operator console the customer (a `/user/` URI) is
  mislabeled "人工客服". ChatUI already documents this as a settlement-layer
  follow-up — cosmetic, not functional.

## Repro
Fresh `EZAGENT_HOME` → `mix ezagent.bootstrap` → `mix ezagent.tenant.seed --tenant
cinnox --customer alice --operator bob --admin carol` → `mix phx.server` with
`CLAUDE_CODE_OAUTH_TOKEN` set. Customer `/autoservice` (alice/alice), operator
`/autoservice/operator` (bob/bob), admin `/autoservice/admin` (carol/carol). cc
JOIN needs PRs #723 + #730 (cherry-picked locally onto `demo/autoservice-live`;
they land via main, not this branch).
