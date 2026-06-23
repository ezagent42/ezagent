# Return — world-deploy-e2e-pg (PostgreSQL deploy + E2E support matrix)

> **Task:** `world-deploy-e2e-pg` (dev-together 2026-06-23 #2)
> **Branch:** `world-deploy-e2e-pg` (pushed; `d7d4543a..e3d6254d`)
> **PR:** [#902](https://github.com/ezagent42/ezagent/pull/902) — OPEN → `main`
> **Dev:** zylideveloper (Claude)
> **returned_at:** 2026-06-23 16:05 +0800
> **deadline:** 2026-06-23 20:00 +0800 (18:00 checkpoint)
> **deadline_status:** `on_time` — early-return path (refreshed runbook + support matrix + root-caused crux + full step-by-step blocker routing), delivered before the 18:00 checkpoint.

| Field | Value |
|---|---|
| Task | `world-deploy-e2e-pg` (dev-together 2026-06-23 #2) |
| Dev | zylideveloper (Claude) |
| Branch | `world-deploy-e2e-pg` (off `main` @ `9835cfe3`) |
| Handoff | `docs/together/2026-06-23/handoffs/world-deploy-e2e-pg.md` |
| Deadline | 2026-06-23 20:00 +08:00 (18:00 checkpoint) |
| returned_at | 2026-06-23 14:45 +08:00 |
| deadline_status | `on_time` — refreshed runbook + support matrix + **root-caused crux** delivered well before the 18:00 checkpoint (the early-return path the handoff prescribes when the full operator E2E is blocked). |
| Status | **runbook refreshed + support matrix + live walkthrough + crux root-caused (§7), independently reviewed**. Steps 1-2 ✅ (2 UX bugs), steps 3/4/8 ⛔ — **NOT a cap issue** (admin holds a wildcard cap). ONE root cause, two surfaces, proven by an in-node `:erpc` positive control: `create_session` times out at the 5 s framework dispatch limit AND snapshot-on-create **races** that budget (reviewer: 2 identical timed-out creates → 1 snapshotted, 1 didn't), so a session can reach the UI without a respawnable snapshot → `:session :send` returns `:no_such_actor`, swallowed by the `:cast` path. **Send itself works on a snapshotted session (`{:ok, stored: true}`)** — fix is bounded. Steps 5-8 hello → task 3. Evidence in `docs/together/2026-06-23/evidence/`. |

## 1. Phase 0 — runbook refreshed for PostgreSQL ✅ (DONE)

`docs/guide/world-e2e-seed.md` rewritten for the PG substrate. Corrections vs the
SQLite-era version:
- Removed the **two-BEAM SQLite trap** language; on PG seeding-while-running is safe
  (the `mix run` seed node does not bind the HTTP port; PG has no single-file lock).
  Kept *seed-then-start* as the recommended pattern (clean cold-load).
- **PG bring-up** documented both ways: canonical `docker-compose.pg.yml` (:55432,
  `ezagent_pg_compat`) and the **host/existing-PG via `POSTGRES_*` env** path
  (e.g. mirrored-networking WSL → Windows-host PG at `127.0.0.1:5432`).
- **First-time DB setup**: `deps.get` (postgrex is new) → `ecto.create` →
  `ecto.migrate` (migrations in `priv/repo_pg`) → core seeds → world E2E seed.
- **Ports corrected** 4020/5175 → **10042 (phx) / 5173 (vite)**.
- **Host routing + HSTS lesson**: world UI is `host: "world."` → use
  **`http://world.localhost:10042`** (NOT `world.ezagent.chat`, which HSTS-upgrades
  to a blank HTTPS page). Login/register/customer are host-agnostic.
- Clean-restart / orphaned-vite section (`pkill -f "vite --host 0.0.0.0 --port 5173"`).

**Runbook-bug found while verifying the seed (fresh DB):** `scripts/world_e2e_seed.exs`
logs `join … {:error, :no_such_actor}` for alice/bob because
`session://system/default/main` does not exist on a fresh PG DB (the seed assumes
it pre-exists). Admin login + user rows still seed correctly. Documented as a known
limitation; the full E2E creates its own session via the UI so this is non-blocking.
A proper fix (seed creates the session first) is a small follow-up owned by this branch.

## 2. Environment stood up (verified live)

- Host PG reachable (mirrored WSL) at `127.0.0.1:5432`, db `ezagent_pg_compat_dev`
  created + migrated + core-seeded + world-seeded.
- `mix phx.server` live: phx `0.0.0.0:10042`, vite `5173`.
- Probes: `/_health`→200 · `/login`→200 · `world.localhost` `/`→**302 /login** (host
  route + RequireEntity OK) · `/register`→200 · `/socialware/customer`(no param)→400 ·
  `/api/v1`→**106 backend actions**.
- Admin login: `admin@ezagent.chat` / `worlddev`.

## 2b. Live E2E walkthrough (agent-browser, on the running server)

agent-browser 0.27.0 **is** available in this env (earlier session assumption was
wrong). Drove the real browser flow against `world.localhost:10042`. Screenshots in
`/tmp/world-e2e/` (to be attached to the PR / copied into `docs/together/2026-06-23/evidence/`).

| Step | Live result | Screenshot |
|---|---|---|
| 1 login | ✅ logged in as admin → world dashboard renders | `01a-login.png`, `01b-sessions-loggedin.png` |
| 2 create cc agent | ✅ created `entity://system/agent/claude-bot` (flavor cc). It **spawned a real `claude` OS process** (`os_pid` live, `running: true`, credential-cascade `auto_prompts` wired). **2 bugs found** (below). | `02a-agent-new-form.png`, `02b-agent-created.png`, `02c-agent-apikeys.png` |
| 3 session + converse | 🟡 session create ✅ + **invite agent member ✅** (members 1→2, claude-bot AGENT live). **Send is BLOCKED**: typing + Send registers NO message/turn (debug panel `messages: 0`; transcript "No turns"), via both plain send and `@mention`. | `03a-session-open.png`, `03b-member-added.png`, `03c-debug.png` |
| 4 routing | 🟡 **correction to static matrix: an in-session routing-rule builder DOES exist** in the conversation panel (Matcher `Always`/`Mention`/`From`/`Text contains` + Receivers + Add). But **Add silently no-ops** (no rule persisted) — same failure class as send. | `03b-member-added.png` (routing builder visible) |
| 5-8 hello | not reached (blocked upstream by step-3 send + hello product gaps owned by task 3) | — |

### Bugs found live (precise, for the owning branches)
1. **cc agent create — empty-CWD silent failure (UX).** cc/codex flavors require an
   existing CWD dir (`validate_cwd_for_flavor` → `{:error, :cwd_required_for_cc}`,
   `agent_create.ex:144`). With CWD blank the world form sets
   `last_dispatch_status: "error:cwd_required_for_cc"` but **shows nothing to the user**
   — the form just sits there. → **FatNine `socialware-creator-agent-config`** (surface the error / mark CWD required for cc).
2. **agent detail shows `Phase: unknown / Flavor: unknown / Bridge: not connected`**
   while the raw status is `%{phase: :alive, flavor: "cc", detail: %{running: true, …}}`
   — the detail page doesn't parse the live status. → **FatNine** (agent detail surface).
3. **🚩 the crux — `session/send` and session `add_rule` silently no-op for the
   operator who CREATED the session.** Inviting a member works (workspace/identity cap),
   but sending a message or adding a routing rule registers nothing (no turn, no rule, no
   visible error). **Hypothesis (precise):** creating a session through the world UI does
   **not** grant the creator a per-session `:send` / routing cap, so those dispatches are
   cap-denied at the chokepoint and swallowed by the UI. The seed's alice/bob get explicit
   `:send` caps and are the intended senders; an operator-created session has no such grant.
   This blocks E2E steps 3,4,8 for an operator. → **owner: lead / world-session owner**
   (decide: auto-grant the creator session caps, or document the intended sender path) —
   NOT a hello (task 3) issue.
   **Code pointer:** all four route through `conversation_actions.ex` `@conversation_actions`
   (`chat.send` / `session.create` / `session.invite` / `session.routing.add`,
   `world_live.ex:228`). `session.invite` succeeds; `chat.send` + `session.routing.add`
   no-op → inspect the authz/cap path for `chat.send` + whether `session.create` grants
   the creator a session `:send`/routing cap. Confirm the exact denied cap in the server log.

## 3. Support matrix — full E2E on current `main`

Legend: ✅ supported · 🟡 partial / needs live operator confirmation · ⛔ blocked / needs product work.
"Owner" = branch that owns closing the gap.

| # | E2E step | Backend / route evidence | Status | Gap & owner |
|---|---|---|---|---|
| 1 | register / log in | `/login` 200 (email+pw, #87); `/register` 200; `workspace/create_user`; admin seeded | ✅ | login fully supported. (register page serves; confirm self-register is enabled vs closed-by-default during evidence) |
| 2 | create a `cc` agent + credential/login path | `workspace/create_agent`; world `/identities/agents/new` (AgentNewForm: flavor/name/cwd/caps/with_pty); `/identities/agents/:uri/api-keys`; `agent/grant_cap` | 🟡 | create + api-key UI present. The **cc credential/login completion** (Claude creds → agent actually authenticated) needs live confirm → **FatNine `socialware-creator-agent-config`** (config surface) + **gagameow `agent-flavor-headless-protocol-api`** (flavor/credential path) |
| 3 | open a session + converse with the agent | `workspace/create_session`, `session/open` (Turn), `session/send` (Session); world Conversation surface | 🟡 | session + send supported. A **real agent reply** depends on a working cc flavor + credentials → **gagameow** (flavor/headless). Confirm live once step 2's credential path is proven |
| 4 | create routing table / session routing rule + team routing | rich `Routing` behavior in `/api/v1` (`add_rule`/`enable_rule`/`disable_rule`/`delete_rule` on session/workspace/system; `workspace/set_routing_rules`, `list_routing_rules`); world `/admin/routing` route | 🟡 | backend + API fully support rule CRUD. **world_live.ex has NO routing-rule *create* handler** — `/admin/routing` is display (+ enable/disable). Creating a rule today is via `/api/v1` or CLI, not a world form. Operator-UI create gap → flag to lead / a world-routing-UI follow-up (not owned by tasks 1/3). Team routing verifiable via API now |
| 5 | create a hello page/app | no `create_hello`/`create_app` dispatch in catalog; hello app = `EzagentPluginHello.App.ensure_app/2` (function); world can set `public_view` on session/template create (`workspace_plugin_actions.ex:334`, `WorkspacePlugin.tsx:196`) | ⛔ | no clear **world UI path to create a hello app** specifically. Generic public_view session create exists but the hello-app flow is "hidden/awkward" → **zhaomaota97 `world-hello-convergence`** (its handoff Phase 1 owns exposing this) |
| 6 | open external hello/customer link, no login when public | `/socialware/customer` route is public; 400 without `session_uri`; resolves anon read-only User for `public_view` sessions | ✅ | infra supported. Needs a `public_view` hello session (blocked upstream by step 5) to demo end-to-end |
| 7 | see hello conversation/page state in world session | `Conversation.tsx:121-124` TEMPORARY `HelloPagePreview` iframe (`isHelloSession = uri.includes("/hello/")`); `conversation_actions.ex:268` "page (TEMPORARY)"; `Surface` behavior (`session/put_version`, `commit_settlement`) | 🟡 | works only via the **temporary iframe**, not the native `HelloRenderer`/PageView → **zhaomaota97 `world-hello-convergence`** (its handoff Decision #2 + open question own replacing/accepting the iframe) |
| 8 | cross-surface messages (session ↔ external hello) sync both sides | `session/send`, `session/deliver` (Turn), Surface behavior | 🟡 | one-directional likely works; full two-way sync "may need a deeper socialware change" (per task-3 handoff §4 Phase 2) → **zhaomaota97 `world-hello-convergence`** |

### Routing of gaps (the coordination output)
- **FatNine `socialware-creator-agent-config`** → step 2 agent config/credential surface.
- **gagameow `agent-flavor-headless-protocol-api`** → step 2/3 cc flavor + credential/login path (agent that actually authenticates + replies).
- **zhaomaota97 `world-hello-convergence`** → steps 5, 7, 8 (hello app create path, native operator page render, cross-surface sync).
- **lead / world-routing-UI follow-up** → step 4 operator-UI rule-create form (backend already supports it).

## 4. Screenshots (human-driven — no agent-browser in this env)

This WSL env has no agent-browser, so supported-step evidence is captured by the
operator driving the browser against the live server. Capture list (URLs in the
refreshed runbook §5):

- [ ] step 1 — login page + post-login world dashboard (`world.localhost:10042`)
- [ ] step 2 — `/identities/agents/new` create form + created agent detail/api-keys
- [ ] step 3 — session conversation (operator ↔ agent) — pending step-2 credential path
- [ ] step 4 — `/admin/routing` rules view (create via `/api/v1` if no UI form)
- [ ] step 6 — public `/socialware/customer?session_uri=…` opens without login — pending a public_view hello session (step 5)
- [ ] steps 5/7/8 — blocked/partial → evidence owned by `world-hello-convergence`

## 5. Gates

- Docs-only + runbook on this branch so far; no product code touched (scope held per
  handoff §7). `world` mount/slot gates unaffected (no route/renderer change).
- One non-blocking seed follow-up identified (§1, owned here).

## 7. Addendum — crux ROOT-CAUSED live: NOT a cap issue (one root cause, two surfaces) — independently reviewed

The original §2b bug 3 hypothesis ("operator-created session lacks a `:send`/routing
cap → cap-denied at the chokepoint") is **WRONG**. Established by driving the live
server with agent-browser, querying the live PostgreSQL audit/snapshot tables, AND a
**positive-control dispatch run inside the running BEAM node** (`:erpc` into
`ezagent_runtime@127.0.0.1`).

> **Self-correction (15:10):** the first cut of this addendum (commit `612aae77`)
> over-claimed *"the Session Kind never writes a snapshot (P22 not firing for
> sessions)."* The positive control below **disproves** that — `create_session`
> DOES persist a respawnable session snapshot, and send to a snapshotted session
> works end-to-end. The real blockers are sharper (and there are two). Kept the
> wrong-then-right trail deliberately.

### Hard evidence (all reproduced live; DB + in-node dispatch)
| # | Probe | Result |
|---|---|---|
| 1 | `data-last-dispatch` after a real operator Send on `e2e-chat` | **`error:no_such_actor`** (captured ×2 + screenshot `03d-send-no-such-actor.png`). NOT a cap error. |
| 2 | `Users.confirmed?(admin)` + row | `confirmed: true`, `email_verified: true`. |
| 3 | `Identity.list_caps_for(admin)` | admin holds a **wildcard cap** `{:any,:any,:any,:any,:any}`. So `:session :send` IS authorized; cap is NOT the blocker. |
| 4 ✅ **positive control** | In-node `:session :send` to **`livesend…` (which HAS a snapshot but was `:unknown`/not alive)** | **`{:ok, %{stored: true}}`** — lazy-spawn rehydrated it (`ReadyGate :unknown→:ready`) and the **message persisted (`messages` 0→1)**. The send/cap/lazy-spawn machinery is CORRECT. |
| 5 ⛔ | In-node `:session :send` / earlier UI send to **`e2e-chat` / `main` (NO snapshot)** | `:no_such_actor` — `snapshot_exists?=false` ⇒ `attempt_lazy_spawn_and_redispatch` returns `:no_such_actor` (`invocation.ex:190-194`). |
| 6 ⛔ | In-node `Workspace.create_session/3` (`:call`) ×5 across two sessions (dev + reviewer) | **times out at the framework 5 s dispatch `:call` limit** every time (`{:timeout, {GenServer,:call,[…workspace.create_session…],5000}}`; the 5000 ms is `invocation.ex:259-260` `ctx[:deadline_ms] \|\| 5_000`). Whether a respawnable snapshot lands afterward is **RACY**: of the reviewer's two identical timed-out creates, **one snapshotted, one did not**. |
| 7 | `kind_snapshots` `session://` rows (point-in-time, race-dependent) | started at `0`; some timed-out `create_session` runs left a snapshot (`livesend…`), others left none (`revprobe2`), and one earlier survivor (`fresh…`) was later gone. **So sessions CAN snapshot, but snapshot-on-create is not guaranteed** — `e2e-chat`/`main` simply lost that race. |

### The failure (ONE root cause, two surfaces)

Bug X and Bug Y are **the same underlying failure**, not two independent bugs:
`create_session` is too slow for the dispatch budget, and snapshot-on-create
races that budget — so a session can be handed to the operator without a
respawnable snapshot, after which every send to it silently fails.

- **Surface X — `create_session` exceeds the 5 s framework dispatch timeout.**
  Every `:call` to `workspace://system?action=workspace.create_session` times out
  at 5000 ms (orchestrator/template instantiation is slow). The operator's "New
  session" → `create_session` returns a timeout/exit to the caller (and in the
  world modal it silently fails to advance). Whether the session ends up with a
  respawnable snapshot is **RACY** — the reviewer's two identical timed-out
  creates diverged (one snapshotted, one didn't), so snapshot-on-create is **not
  guaranteed**. This is why `e2e-chat` (created in the walkthrough, accepted joins)
  carries no `kind_snapshots` row: nothing special about it — it lost the race.
- **Surface Y — the send error is swallowed.** `ConversationActions.send_message`
  dispatches `mode: :cast` + `reply: :ignore` (`conversation_actions.ex:144-149`),
  so when a session has no live process AND no snapshot, the resulting
  `:no_such_actor` surfaces ONLY in the hidden `data-last-dispatch` DOM attribute
  — empty composer, "No turns", zero error. (`session.routing.add` is `:call`,
  surfaces the same error to `last_dispatch_status` — `conversation_actions.ex:354`.)

### Mechanism CONFIRMED live (16:30) — the "race" is an orchestrator-readiness gate; the cc AGENT works, the orchestrator LINKAGE is what hangs

The earlier "snapshot-on-create races the 5 s budget" framing was the *symptom*. The
actual mechanism, nailed by in-node `:erpc` (direct `SessionCreator.create_session/3`,
bypassing the 5 s dispatch timeout) + per-agent lifecycle inspection:

1. **`create_session` synchronously spawns a `cc_orchestrator` AGENT** (a real cc
   flavor — saw `entity://system/agent/cc_orchestrator-<short>` spawn live, with
   `WorkspaceSharedSource.resolve` credential + `agent_lineage` writes). Direct call
   **did not return in 60 s**.
2. **`Session.Orchestrator.ensure_orchestrator/3` then GATES on the orchestrator
   joining the live MCP bridge** — it polls `LiveJoinRegistry.joined?/1` (marked by
   `McpChannel.join/3`) on a **90 s deadline** (`orchestrator.ex:242-331`,
   `@orchestrator_readiness_poll_ms 2_000`), with `{:orchestrator_ready, uri}` as an
   instant-wake. On the 90 s deadline → kill the orchestrator PTY + Kind →
   `{:error, {:orchestrator_not_ready_within, 90_000}}` → caller **fail-loud ROLLS
   BACK the whole session (deletes the snapshot row)**.
3. **The cc agent is alive but never joins the bridge** because it is **stuck at the
   interactive onboarding dialog**. Verified on the two live standalone cc agents
   (`claude-bot` `os_pid 81785`, `e2e-test` `os_pid 82138`): both `phase: :alive,
   pty_alive: true`, real `claude` running — but their `recent_output` is parked at
   *"New MCP server found: esr-bridge … 1. Use this MCP server … Enter to confirm"*
   and `auto_prompts.mcp_trust_dialog: fired?: false`. The onboarding auto-prompts
   are NOT dismissing the MCP-trust / login dialogs, so the agent never finishes
   startup → never `McpChannel.join`s → `joined?` stays false.
4. **So:** the 5 s dispatch `:call` times out first (caller gives up); server-side
   the readiness gate waits up to 90 s; the orchestrator never joins → rollback →
   the session has **no snapshot** → later `:send` → `:no_such_actor`.

**This discriminates the two suspects cleanly (the question that triggered this):**
- **cc AGENT functionality = OK.** Standalone cc agents spawn a live `claude` process
  + PTY (`claude-bot`, `e2e-test` both `:alive` / `pty_alive: true`). EVERY
  `cc_orchestrator-*` from a session create, by contrast, is `phase: :not_found`.
- **The broken link = the agent↔session bridge join**, gated by the cc **onboarding
  automation** (`auto_prompts` not firing `mcp_trust_dialog`/login). Fix that and the
  orchestrator can `McpChannel.join` → `ensure_orchestrator` returns → `create_session`
  completes → the session is snapshotted → send/join/routing work.

**Coupling (important for routing):** the lead's "session-create crux" and gagameow's
"cc credential/login completion" are **the same root** — the session orchestrator IS a
cc agent, so the onboarding/credential gap that blocks step 2 is exactly what hangs the
90 s readiness gate that blocks steps 3/4. Fix paths: (a) **gagameow** — make the cc
onboarding auto-prompts fire (dismiss MCP-trust/login → agent joins the bridge); and/or
(b) **lead** — don't block `create_session` on a synchronous 90 s live-join (spawn the
orchestrator async + ack, or surface a "session pending" state) so a slow/stuck
orchestrator doesn't roll back the session.

### Step-2 confirmed from a live crash log (16:50) — `create_agent` ALSO 5 s-times-out, and the world handler CRASHES the LiveView on it

An operator agent-create from the world UI (`agents.create` → cc `tesy-pty`, cwd `/tmp`,
`with_pty:false`, workspace `li-zhenyu-709522`) produced a **LiveView crash** in the
server log:

```
** (stop) exited in: GenServer.call(#PID, {:ezagent_dispatch, %Invocation{
     target: workspace://…?action=workspace.create_agent, mode: :call, …}}, 5000)
   ** (EXIT) time out
   world_live.ex:380: EzagentPluginWorld.WorldLive.dispatch_agent_create/2
```

Mechanism (same 5 s budget as `create_session`, plus a missing guard):
1. cc `create_agent` **synchronously spawns the claude process** via the
   credential-cascade chokepoint (`agent_create.ex:274` `do_create_agent("cc", …)`
   → `Agent.spawn_from_template_content/5`) → takes **>5 s**.
2. `Ezagent.Workspace.create_agent/3` dispatches `mode: :call`, so it hits the **5 s
   framework dispatch timeout** → raises `{:exit, {:timeout, …}}`.
3. `dispatch_agent_create/2` (`world_live.ex:366-398`) calls it inside a `with`
   chain whose `else` only matches `{:error, _}` / `_` — it **does NOT catch the
   `:exit`** → the whole `WorldLive` LiveView process **crashes and remounts**.

This is **strictly worse than `create_session`**, which is guarded
(`conversation_actions.ex:248-263` `create_session_result` has `rescue` + `catch :exit`
→ degrades to an error status). The agent-create path has no such guard, so the
operator's entire world UI dies. **This — not a credential gap — is the first thing an
operator hits at step 2** (the credential/login layer is only reachable *after* a
successful create). It resolves this return's earlier open question (step-2 symptom =
create-timeout crash, NOT primarily credential).

**Routing:**
- **FatNine** (`world_live.ex` agent-create handler is task-1's owned surface): wrap
  the `create_agent` call in `try/rescue` + `catch :exit` (mirror `create_session_result`)
  so a slow create degrades to an `error:*` status instead of crashing the LiveView.
- **lead / core**: the underlying *synchronous cc spawn exceeds the 5 s dispatch
  budget* — the SAME root as the `create_session` orchestrator gate. Fix once (spawn
  async + ack, or raise the budget for these spawn actions).

### Corrected matrix impact (supersedes §2b bug 3 + §3 rows 3/4)
- **Steps 3 / 4 / 8 ⛔ for the operator** today: create is racy/timeout-prone
  (surface X) and the resulting snapshot-less session is un-dispatchable
  (`:no_such_actor`, surface Y hides it). When a session DOES have a snapshot, send
  works (probe 4) — so the fix is bounded.
- Step 4's in-session routing-rule **builder DOES exist** in the UI — the §3-row-4
  "no create handler" note was wrong; handler is `session.routing.add` →
  `add_routing_rule`, it just fails with the same `:no_such_actor`.
- **Not** a cap/authz gap, **not** a hello (task 3) gap, **not** a FatNine
  agent-config gap.

### Owner + fix direction (for the lead)
**Owner: core/domain workspace + Session-Kind lifecycle (lead / a dedicated
session branch).** One root cause, so the fixes interlock: **(1)** make
`create_session` fit the dispatch budget (async/await the orchestrator spawn, or
raise the timeout for this action, or return a fast ack + settle); **(2)**
guarantee a respawnable snapshot before a session is handed to the UI — snapshot
synchronously on create (closing the race), or surface an explicit "session not
ready" state — so send/join/routing never silently hit `:no_such_actor`; **(3)**
stop swallowing the `:cast` send error — surface it instead of hiding it in
`data-last-dispatch`. The send + lazy-spawn machinery itself is sound (probe 4).

**The defining open question for the lead** (sharpened by the review): NOT "what
was special about `e2e-chat`" (answer: nothing — it lost the snapshot race). It is
**"is snapshot-on-create supposed to be guaranteed, and why does it race the 5 s
`create_session` budget?"** — i.e. is there an unbounded/slow step in orchestrator/
template instantiation that must be made async-with-ack, and should the session be
withheld from the UI until its snapshot is durably persisted?

### Reproduction (for whoever picks this up)
```bash
# A. swallowed send error on a snapshot-less session (UI):
agent-browser --session s eval "document.querySelector('[data-last-dispatch]').getAttribute('data-last-dispatch')"  # => error:no_such_actor

# B. POSITIVE CONTROL — drive the RUNNING node via :erpc (no second BEAM, no contention):
COOKIE=$(cat "$HOME/.ezagent/default/runtime/cookie")
elixir --name "probe@127.0.0.1" --cookie "$COOKIE" -e '
  t=:"ezagent_runtime@127.0.0.1"; Node.connect(t)
  code="""
  alias EzagentCore.Repo
  u=Ezagent.URI.new!(\"session://system/default/<a-snapshotted-session>\")
  admin=Ezagent.Entity.User.admin_uri()
  msg=Ezagent.World.ConversationData.build_message(admin,\"probe\",u,[])
  Ezagent.Invocation.dispatch(%Ezagent.Invocation{target: Ezagent.URI.with_action(u,:session,:send), mode: :call, args: %{message: msg}, ctx: %{caller: admin, caps: Ezagent.Identity.list_caps_for(admin), reply: :ignore}})
  """
  IO.inspect(:erpc.call(t, Code, :eval_string, [code,[],[]], 30000))'
# => {:ok, %{stored: true}}   on a snapshotted session;  {:error, :no_such_actor} on one without.

# C. confirm which sessions have a respawnable snapshot:
#    :erpc … Repo.query!("SELECT uri FROM kind_snapshots WHERE uri LIKE 'session://%'")
```

## 8. Deliverables + merge request

**Deliverables (all on the branch / PR #902):**
- Refreshed PG runbook `docs/guide/world-e2e-seed.md` (+ ⛔ known-blocker note, §3).
- Support matrix (§3) + root-caused crux (§7, **independently reviewed** by a subagent).
- **Full step-by-step blocker analysis + owner routing** for steps 2–8:
  `docs/together/2026-06-23/e2e-blocker-analysis.md`, **posted as a PR comment**:
  [#902 comment](https://github.com/ezagent42/ezagent/pull/902#issuecomment-4776984856).
- Evidence: `docs/together/2026-06-23/evidence/*.png` (incl. `03d-send-no-such-actor.png`).

**Gate status:** docs + evidence only — **no product code touched** (scope held per
handoff §7). No `mix` gates apply; world mount/slot gates unaffected (no route/renderer
change). One non-blocking seed follow-up noted (§1).

**Routing to other branches (the coordination output):**
- **lead / core+domain session lifecycle** → steps 3/4 (+ 8 world side): `create_session`
  5 s dispatch timeout + snapshot-on-create race → `:no_such_actor` swallowed by `:cast`.
- **gagameow `agent-flavor-headless-protocol-api`** → step 2/3 cc credential/login completion.
- **FatNine `socialware-creator-agent-config`** → step 2 UX (empty-CWD silent fail; detail status).
- **zhaomaota97 `world-hello-convergence`** → steps 5/6/7/8 (hello-app create flow, native page render, cross-surface sync).

**Merge request:** lead merges `world-deploy-e2e-pg` → `main` after review (PR #902).
Docs/evidence only; rebased on `main`; no ordering constraints with other returns.

**Open item for the lead:** step 2's exact operator symptom is unconfirmed (agent-browser
can't drive the React form reliably — my `error:name_required` was a tooling artifact). If
the operator's create fails *after* a valid name+CWD, its `data-last-dispatch` may show a
create-timeout (→ lead) rather than a credential gap (→ gagameow); flagged in the PR comment.
