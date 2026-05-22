# Nested shell refactor — one outer shell, two inner perspectives

> **Status**: DRAFT rev 1 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22. Will go through `codex adversarial-review` before
> implementation (per `feedback_spec_codex_adversarial_review`).

## 0. The problem

Allen's mental model (Feishu 2026-05-22), which this SPEC adopts:

> The whole ezagent app has ONE unified shell holding what every user
> always needs — notifications, search, avatar. Functional pages then
> split two ways: (a) **global/system config** (mounted under
> `workspace://system`, affects the whole runtime), (b)
> **workspace-specific** function (sessions, agents — what regular
> users use). So: an outer `ide_shell`, and under it two inner
> perspectives — `workspace_shell` + `admin_shell`.

**Current implementation does NOT match this.** It has TWO sibling
(not nested) shells:

| | `IdeShell.ide_shell` | `EzagentDomainUi.AdminSettingsShell` |
|--|----------------------|--------------------------------------|
| pages | ~13 workflow LVs | 7 config LVs (workspaces, workspace_detail, entities, admin_dashboard, settings, observability, snapshots) |
| header | workspace dropdown + search/⌘K + bell + help + avatar | only a folder icon + back + close |
| universal chrome | all of it | **almost none** — no avatar, no notifications, no search |

The universal chrome (avatar / notifications / search+⌘K) lives ONLY
in `ide_shell`. The 7 `AdminSettingsShell` pages have no avatar, get
no notifications, and ⌘K does nothing there. Plus `home_live` (the
first-run wizard) is in **no shell at all**.

This is the "ad-hoc multiple shells" drift Allen suspected. The CmdK
gap PR-2b "fixed" (per-LV `:command_palette` slot ×13) is a symptom:
the chrome is not owned in one place, so it has to be repeated.

## 1. Target structure

```
ide_shell  (OUTER — owns universal chrome, once)
├── universal top header: workspace dropdown · search/⌘K · notifications · help · avatar
├── CommandPalette  (rendered directly by the outer shell — see §3)
└── :body slot — exactly one inner perspective:
      ├── workspace_shell   (INNER — sessions/agents perspective)
      │     Activity Bar · Resource Panel · Main Window · Right Sidebar · Status Bar
      └── admin_shell       (INNER — workspace://system config perspective)
            left settings nav · Main
```

- **Outer `ide_shell`** owns everything every user always needs. It is
  the ONLY place the universal header + CommandPalette are defined.
- **`workspace_shell`** is today's `ide_shell` body (Activity Bar +
  Resource Panel + Main Window + Right Sidebar + Status Bar) with the
  header REMOVED (the outer shell owns it now).
- **`admin_shell`** is today's `AdminSettingsShell` body (left settings
  nav + main) with its stripped header REMOVED.

An LV renders:

```heex
<IdeShell.ide_shell current_entity_uri={...} workspaces={...}
                    cmdk_nav_routes={...} ...>
  <:body>
    <WorkspaceShell.workspace_shell current_path="/sessions" ...>
      <:main_window>...page content...</:main_window>
      <:right_sidebar>...</:right_sidebar>
    </WorkspaceShell.workspace_shell>
  </:body>
</IdeShell.ide_shell>
```

…or `<AdminShell.admin_shell active_section={:workspaces}>` in the
`:body` slot for a config page.

## 2. Why this is the right fix (vs the earlier A/B options)

The earlier A (wire CmdK into both shells) / B (delete one shell)
options were both wrong framings. A is a patch — it papers over the
divergence by duplicating chrome into the second shell. B throws away
the genuinely-useful workspace-vs-config perspective split.

The nested structure keeps the perspective split (Allen's PR-M
2026-05-20 instinct was right — config and workflow ARE different
views) AND defines the universal chrome once. CmdK, avatar,
notifications become structurally impossible to miss on a page,
because the page can't render without going through the outer shell.

## 3. CommandPalette moves to Tier-2

For the OUTER shell (a Tier-2 `ezagent_domain_ui` component) to render
the command palette **directly** — no slot, no per-LV repetition —
the palette must be at Tier-2.

- `Ezagent.UI.CommandSource` — already Tier-2 (`ezagent_domain_ui`). ✓
- `EzagentPluginLiveview.CommandPaletteComponent` — currently Tier-3
  (`ezagent_plugin_liveview`). Its dependencies are `CommandSource`
  (Tier-2), primitives (Tier-2), and injected `nav_routes` — nothing
  Tier-3-specific. **Move it to `ezagent_domain_ui`** as
  `EzagentDomainUi.CommandPalette` (a `Phoenix.LiveComponent`).

Then `ide_shell` (outer) renders `<.live_component
module={EzagentDomainUi.CommandPalette} id="cmdk"
nav_routes={@cmdk_nav_routes} .../>` itself. The `:command_palette`
slot is **deleted** from `ide_shell`, and PR-2b's 13 per-LV slot
renders are **removed** (superseded — the outer shell does it once).

`nav_routes` still flows in from the `ezagent_web` `:cmdk_nav`
on_mount assign → the LV passes `cmdk_nav_routes` to the outer
`ide_shell` → the shell hands it to the palette. Dependency direction
unchanged (web → LV → shell → component).

## 4. home_live

The first-run wizard (`home_live.ex`, the only shell-less LV) is the
pre-workspace state. Decision: it renders inside the **outer
`ide_shell`** (so the user still has avatar / notifications / the
ability to search) but with NO inner perspective — its `:body` slot
holds the wizard content directly. The wizard is "you have nothing
yet", not "you are in a workspace" nor "you are in system config".

## 5. Scope of migration

- **2 shell atoms restructured**: `ide_shell` (becomes outer + a new
  `workspace_shell`), `AdminSettingsShell` → `admin_shell`.
- **1 component moved tiers**: `CommandPaletteComponent` → Tier-2.
- **~21 LVs migrated**: 13 workspace LVs, 7 admin LVs, `home_live`.
- The per-LV `:command_palette` slot (PR-2b) is removed everywhere.

## 6. Proposed PR sequence

| # | Title | Keeps main green by… |
|---|-------|----------------------|
| 1 | Move `CommandPaletteComponent` → Tier-2 `EzagentDomainUi.CommandPalette`; build the new outer `ide_shell` + `workspace_shell` + `admin_shell` components ALONGSIDE the existing ones (new code, not yet wired) | additive only — nothing uses the new components yet |
| 2 | Migrate the 13 workspace LVs to outer `ide_shell` + `workspace_shell`; outer shell renders CmdK directly; remove their `:command_palette` slots | the new path is proven on the bigger LV set first |
| 3 | Migrate the 7 admin LVs to outer `ide_shell` + `admin_shell`; migrate `home_live`; delete the old `AdminSettingsShell` + the old monolithic `ide_shell` body + the now-dead `:command_palette` slot definition | last consumer of the old shells removed in the same PR that deletes them |

Each PR independently compiles + ships. PR-1 is additive. PR-2 and
PR-3 each fully migrate a cohort.

## 7. Open questions (for the codex adversarial review + Allen)

1. **Workspace dropdown placement** — it currently lives in the
   `ide_shell` header. On an `admin_shell` (system-config) page, is
   the "ezagent / <workspace>" dropdown meaningful, or should the
   outer header show a different left-affordance in admin perspective?
   Proposed: keep it universal (switching workspace is always
   available); revisit if it reads wrong.
2. **`home_live` inner body** — outer shell + bare wizard (proposed),
   or keep `home_live` entirely chrome-less as a true landing page?
3. **Naming** — `ide_shell` (outer) / `workspace_shell` / `admin_shell`
   per Allen's message. Is `ide_shell` still the right name for the
   OUTER shell now that it's no longer "the IDE view" specifically?
   (`app_shell` is an alternative.) Allen to decide.
4. **Status bar ownership** — the Status Bar (per the 2026-05-22
   header/statusbar principle) is position-/view-variant → it belongs
   to `workspace_shell`, NOT the outer shell. Confirm `admin_shell`
   genuinely has no status bar (today it doesn't).
5. **Phasing risk** — PR-2 and PR-3 each touch a large LV cohort. Is
   3 PRs right, or should each cohort split further?

## 8. Verification

1. avatar / notifications / search+⌘K render on ALL ~21 pages —
   workspace pages AND the 7 admin pages AND home
2. ⌘K opens the command palette on an admin page (e.g. /workspaces)
   and on a workspace page (e.g. /sessions)
3. the universal header is defined exactly ONCE (`ide_shell` outer);
   `workspace_shell` + `admin_shell` contain NO `<header>` with
   avatar/search/notifications
4. `EzagentDomainUi.CommandPalette` is Tier-2 — no
   `ezagent_plugin_liveview` dependency
5. no LV carries a `:command_palette` slot anymore — the outer shell
   renders the palette
6. `AdminSettingsShell` is deleted; nothing references it
7. workspace pages still have Activity Bar + Resource Panel + Status
   Bar; admin pages still have the left settings nav
8. a dependency-boundary test: `workspace_shell` / `admin_shell` are
   Tier-2 atoms with no LiveView/registry imports
