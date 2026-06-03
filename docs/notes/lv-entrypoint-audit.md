# LiveView entry-point audit

Audit requested 2026-05-30 (Allen): is every ezagent feature reachable from the
LiveView UI? For unreachable ones, why — and is it justified? Are existing LV
features placed/styled sensibly? What are the principles for adding new LV
feature components?

> Scope note: this is a **code/architecture-level** pass. The placement/styling
> verdict (Q2) should be confirmed against live screenshots via agent-browser
> (`http://100.64.0.27:10042`) before any restyling — per the "open the UI first"
> rule. This doc establishes the structure; the visual pass is the follow-up.

## Q1 — Feature → LV reachability

The system enforces **LV → CLI** parity already: `LvCliParityTest` walks every
mutating `handle_event/3` and demands a `mix ezagent …` counterpart (categories
`:cli` / `:ui_only` / `:pty_stream` / `:deferred`). So every LV action is
CLI-drivable. The audit question is the **reverse**: operator features (mix
tasks / dispatch actions) with **no** LV entry.

| Operator feature (mix task) | LV entry | Verdict |
|---|---|---|
| `agent.create` | `/identities/agents/new` (AgentNewLive) | ✓ reachable |
| `user.create`, credential set | `/identities/users` (UsersLive), `/profile` (self) | ✓ reachable |
| agent api-keys | `/identities/agents/:uri/api-keys` | ✓ reachable |
| caps grant/revoke/audit | `/identities/*/caps` (EntityCapsLive), `/admin/caps`, `/admin/audit/authz` | ✓ reachable |
| `workspace.*` (create / members / templates) | `/workspaces`, `/workspaces/:name` | ✓ reachable |
| `routing.add_rule` | `/admin/routing` (RoutingLive) | ✓ reachable |
| `external_mirror.*` | `/admin/sessions/:id/external_mirror` | ✓ reachable |
| `feishu.bind/list/unbind` | `/plugins/feishu/bindings` | ✓ reachable |
| snapshots | `/admin/snapshots` (SnapshotsLive) | ✓ reachable |
| sessions / chat | `/sessions` (AdminLive), terminal | ✓ reachable |
| observability / registry | `/admin/logs`, `/admin/registry` | ✓ reachable |
| `plugin.install` | `/plugins` is **view-only** | ⚠ gap — **justified** (installing a plugin is a code-deploy action, not a runtime op) |
| `home.backup / restore / init / adopt_db` | none | ⚠ gap — **justified** (host-level migration / disaster-recovery ops; running them from the very UI they migrate is unsafe) |
| `bootstrap`, `db.reset`, `stress`, `demo.seed_*`, `check_invariants` | none | ⚠ gap — **justified** (dev/CI/bootstrap tooling, not operator features) |

**Conclusion:** every *runtime operator feature* is LV-reachable. The only gaps
are (a) plugin installation and (b) host-migration / bootstrap / dev tooling —
all of which are deliberately CLI-only because they are deploy-time or
disaster-recovery operations, not in-session operator actions. No unjustified
gap found. The strongest guarantee here is structural: `LvCliParityTest` keeps
the two surfaces from drifting apart.

## Q2 — Placement / styling of existing LV features

Placement is governed by a documented contract (`ui-contract.md`), not ad-hoc:

- **Nested shell** (2026-05-22): one `AppShell.app_shell` owns universal chrome;
  `perspective={:workspace}` (workflow surfaces: /sessions, /routing,
  /identities, /plugins) vs `perspective={:admin}` (system config: /admin/*,
  /workspaces). Every LV renders exactly one of these — consistent IA.
- **Header vs status-bar litmus** (Allen 2026-05-22): header = workspace-scoped,
  view-invariant (workspace dropdown, ⌘K, notifications, avatar); status bar =
  position-scoped, view-variant (current entity/session URI, signal lights,
  Members toggle, debug count). Litmus: *"does this control still make sense on
  every page?"* yes → header, no → status bar.

These give a clear, testable home for any control. **Open items to confirm
visually (agent-browser):**
- Admin surfaces (/admin/*) correctly inherit the outer chrome (avatar /
  notifications / search) — this was the motivating bug for the nested-shell
  refactor; worth a screenshot to confirm it stuck.
- The two perspectives' activity-bar / settings-nav groupings match the route
  taxonomy in the table above (no orphan routes, no dead links — `ui-contract`
  DON'T #93).

## Q3 — Decision procedure: where does a UI component go?

A component's home is decided by two orthogonal axes — **SCOPE** (what it acts
on) and **PROVIDER TIER** (who owns the code) — then refined by within-page
rules. The axes are independent: scope picks the *route + perspective*; tier
picks the *owning module* and whether a dedicated plugin surface is required.

### Axis 1 — SCOPE → route + perspective (dominant axis)

Ask: *"what does this feature operate on?"* (all routes below verified against
`apps/ezagent_web/lib/ezagent_web/router.ex`):

| Scope (operates on…) | Route | Perspective |
|---|---|---|
| The whole deployment / system | `/admin/<feature>` | `:admin` |
| A workspace | `/workspaces/:name` | `:admin` |
| A session — **live use** | in-session tab on `/sessions` | `:workspace` |
| A session — **config/admin** | `/admin/sessions/:id/<feature>` | `:admin` |
| An entity (agent / user) | `/identities/{agents,users}/:uri/<feature>` | `:workspace` |
| The current user (self-service) | `/profile` | `:workspace` |

Rule of thumb: **system-wide config → `:admin` perspective; anything you operate
*within* a workspace / session / entity → `:workspace` perspective.** (The
perspective is the typed `AppShell.app_shell perspective={…}` contract: `:admin`
shows the `ezagent / system` context label, `:workspace` shows the workspace
switcher.)

### Axis 2 — PROVIDER TIER → ownership + dedicated plugin surface

- **Core / domain feature** (e.g. routing = `ezagent_core`, caps = core CapBAC,
  api-keys = `ezagent_domain_identity`, templates/snapshots = core): it lives
  *directly* on the Axis-1 surface — `/admin/routing`, `/identities/*/caps`,
  `/admin/snapshots`, etc. No extra indirection.
- **Plugin feature**: the plugin owns a **global config page** at
  `/plugins/<plugin>/<feature>` (e.g. `/plugins/feishu/bindings`). Per the North
  Star (plugin isolation) plugin UI must NOT be hard-coded into core admin
  pages — it self-registers its `/plugins/<plugin>` surface.
- **Plugin feature scoped to a session / entity / workspace**: it appears in
  BOTH — the plugin's global page (`/plugins/<plugin>`, cross-instance
  management) AND the scope's Axis-1 surface (`/admin/sessions/:id/<feature>`,
  etc.) for the per-instance config.

### Canonical worked example — ExternalMirror (verified live)

ExternalMirror is a **domain primitive** (the `ExternalMirror` Domain owns every
outbound mirror — arch invariant #15); **Feishu** is a **plugin adapter**; a
binding is **session-scoped**. Applying the axes → it surfaces in four
coordinated places, exactly the *"plugin 提供配置界面 + sessions/xx 提供
per-session 配置页面"* pattern:

- `/plugins/feishu/bindings` — the **plugin's** global binding management.
- `/admin/sessions/:id/external_mirror` — **per-session** binding config (`:admin`).
- Session **"Bindings"** tab on `/sessions` — in-context, live, per-session view (`:workspace`).
- `/admin/routing?tab=bindings` — cross-session global read view.

### Axis 3 — within the chosen page, where does the control sit?

1. **Build it 3-layer**: atom (`ezagent_domain_ui`) → composition
   (`ezagent_plugin_liveview`) → LV container. Never fork atom logic into one LV.
2. **Render through `AppShell.app_shell perspective={…}`** (wires CmdK once);
   never a shell component directly.
3. **Header vs status-bar litmus**: would the control make sense on *every* page
   (workspace-invariant)? → header. Tied to the *current* position
   (this session / entity / view)? → status bar.
4. **Use the atoms** (`.page_header` / `.card` / `.button` / `.badge` /
   `.empty_state` / `.uri_picker`); never raw inputs / inline `style=` /
   hard-coded hex; always pair `bg-*`/`text-*` with `dark:`.
5. **Earn the CLI row**: a new mutating `handle_event` MUST add its `mix ezagent
   …` counterpart to `LvCliParityTest` (or be classified `:ui_only` /
   `:pty_stream`).
6. **No dead links** — remove links to deleted features, don't strand buttons.

### One-line decision flow

```
scope?  ──► route + perspective (Axis 1)
  └─ tier?  ──► core/domain: use the Axis-1 surface directly
               plugin:      also expose /plugins/<plugin>, and if scoped,
                            put the per-instance config on the scope surface (Axis 2)
        └─ within page: 3-layer + app_shell + header/status litmus (Axis 3)
              └─ add the LvCliParity row
```

Audit-derived addition: **a new *runtime* operator feature should land in BOTH a
`mix ezagent` task and an LV surface in the same change.** `LvCliParityTest`
enforces LV→CLI, but nothing forces a new CLI feature to grow a UI — so "does
this need an LV entry, and by Axis 1 where?" belongs on the checklist for every
new `mix ezagent.<x>` task.

## Q2 — visual validation (agent-browser, live :10042, 2026-05-30)

Logged in as `entity://user/system/admin` and captured both perspectives. Both
flagged items confirmed GREEN:

- **Admin chrome inheritance ✓** — `/admin` renders the full outer header
  (⌘K search · bell · help · avatar) AND the correct **`ezagent / system`**
  system-context label (not a workspace dropdown — the a11y label
  "切换工作区" is misleading, the rendered control shows `system`). The
  nested-shell refactor goal (admin pages keep avatar/notifications/search)
  is intact.
- **Taxonomy / header-vs-status separation ✓** — workspace perspective
  (`/sessions`) shows Activity Bar + main (Chat/Routing/Bindings) + right
  sidebar (Orchestrator/Members) + a position-scoped **status bar** (current
  entity + session URI, `13 代理 / 0 桥接` signal lights, Members toggle,
  version). Admin perspective shows the settings drawer (Overview / Workspaces
  / Logs&Audit / Registry / Snapshots / Templates / Routing / Settings) over
  the same chrome. No dead links, no orphan surfaces, atoms used throughout
  (stat cards, `alive`/`seeded` badges, `font-mono` URIs).

**Verdict:** placement + styling adhere to `ui-contract.md`. No issues found.
The audit is complete; no restyling work indicated.
