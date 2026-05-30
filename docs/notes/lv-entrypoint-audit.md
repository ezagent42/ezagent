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

## Q3 — Principles for adding a new LV feature component

Codified in `ui-contract.md`; the load-bearing rules:

1. **3 layers, never skip.** Layer 1 stateless atoms (`ezagent_domain_ui`) →
   Layer 2 plugin compositions → Layer 3 LV containers. Don't fork atom logic
   into an LV "just for this page" — that breaks the style-replacement boundary.
2. **Render through `AppShell.app_shell`** with the right `perspective`; never a
   shell component directly (it wires CmdK exactly once).
3. **Place controls by the header/status-bar litmus**, not by convenience.
4. **Use the atoms** (`.page_header`, `.breadcrumb`, `.card`, `.button`,
   `.badge`, `.empty_state`, `.uri_picker`) — never raw inputs / inline `style=`
   / hard-coded hex; always pair `bg-*`/`text-*` with `dark:`.
5. **Earn the CLI counterpart.** A new mutating `handle_event` MUST add its row
   to `LvCliParityTest`'s mapping (or be classified `:ui_only`/`:pty_stream`) —
   keeps the LV from becoming the only way to do something headless ops needs.
6. **No dead links.** If a feature is removed, remove the link, don't strand a
   button (`feedback_ui_no_misleading_buttons`).

The first principle worth adding from this audit: **a new operator feature
should land in BOTH a mix task and an LV surface in the same change** — the
parity test enforces LV→CLI, but nothing forces a new CLI feature to grow a UI.
The "justified gaps" above are fine; the risk is a *runtime* feature shipping
CLI-only by omission. Make "does this need an LV entry?" a checklist item when
adding a `mix ezagent.<x>` task.

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
