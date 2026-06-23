# Return — world-deploy-e2e-pg (PostgreSQL deploy + E2E support matrix)

| Field | Value |
|---|---|
| Task | `world-deploy-e2e-pg` (dev-together 2026-06-23 #2) |
| Dev | zylideveloper (Claude) |
| Branch | `world-deploy-e2e-pg` (off `main` @ `9835cfe3`) |
| Handoff | `docs/together/2026-06-23/handoffs/world-deploy-e2e-pg.md` |
| Deadline | 2026-06-23 20:00 +08:00 (18:00 checkpoint) |
| Status | **runbook refreshed + support matrix + live agent-browser walkthrough done**. Steps 1-2 ✅ (with 2 UX bugs), step 3/4 🟡 blocked by one crux bug (operator-created session lacks `:send`/routing cap), steps 5-8 hello → task 3. Evidence screenshots in `docs/together/2026-06-23/evidence/`. |

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
   NOT a hello (task 3) issue. Needs confirmation of the exact denied cap from the server log.

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

## 6. Merge request
PR into `world-deploy-e2e-pg`; lead merges to `main` after review. The matrix above
is the 18:00 coordination artifact for tasks 1/3/4.
