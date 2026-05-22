# Nested shell refactor — one outer shell, two inner perspectives

> **Status**: DRAFT rev 2 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22.
>
> - **rev 1**: initial design.
> - **rev 2**: `codex adversarial-review` fixes — 3 HIGH + 1 MEDIUM.
>   (a) CmdK does NOT move to Tier-2 (that would put a stateful
>   LiveComponent in the stateless-atom layer — UI Contract violation).
>   Instead a **Tier-3 `app_shell` wrapper** renders the Tier-2 outer
>   chrome + fills its `:command_palette` slot once. (b) PR phasing is
>   genuinely additive — no existing module is moved/renamed until its
>   last consumer is gone. (c) `home_live` is OUT of scope — it has no
>   auth assigns and forcing it into the shell would crash. (d) the
>   outer shell gets an explicit `perspective` context contract so
>   admin pages don't show a tenant workspace switcher.

## 0. The problem

Allen's mental model (Feishu 2026-05-22), which this SPEC adopts:

> The whole ezagent app has ONE unified shell holding what every user
> always needs — notifications, search, avatar. Functional pages then
> split two ways: (a) **global/system config** (mounted under
> `workspace://system`, affects the whole runtime), (b)
> **workspace-specific** function (sessions, agents — what regular
> users use). So: an outer shell, and under it two inner perspectives.

**Current implementation does NOT match this.** Two sibling (not
nested) shells:

| | `IdeShell.ide_shell` | `EzagentDomainUi.AdminSettingsShell` |
|--|----------------------|--------------------------------------|
| pages | ~13 workflow LVs | 7 config LVs (workspaces, workspace_detail, entities, admin_dashboard, settings, observability, snapshots) |
| header | workspace dropdown + search/⌘K + bell + help + avatar | only a folder icon + back + close |
| universal chrome | all of it | **almost none** — no avatar, no notifications, no search |

The universal chrome (avatar / notifications / search+⌘K) lives ONLY
in `ide_shell`. The 7 `AdminSettingsShell` pages have none of it. The
CmdK gap PR-2b "fixed" via a per-LV `:command_palette` slot ×13 is a
symptom: the chrome is not owned in one place.

## 1. Target structure

The fix has THREE component layers, respecting the 3-tier rule:

```
app_shell    (Tier-3, ezagent_plugin_liveview — the single wiring point)
│  renders the Tier-2 outer chrome AND fills its :command_palette slot
│  with the Tier-3 CommandPaletteComponent, ONCE.
│
└─ ide_shell (Tier-2, ezagent_domain_ui — pure presentation, OUTER chrome)
   ├── universal top header: context affordance · search/⌘K · notifications · help · avatar
   ├── :command_palette slot   (filled by app_shell — see §3)
   └── :body slot — exactly one inner perspective:
         ├── workspace_shell  (Tier-2 — sessions/agents perspective)
         │     Activity Bar · Resource Panel · Main Window · Right Sidebar · Status Bar
         └── admin_shell      (Tier-2 — workspace://system config perspective)
               left settings nav · Main
```

- **`app_shell`** (NEW, Tier-3) is the single thing LVs render. It is
  the ONLY place CmdK is wired. It exists because the universal chrome
  must be owned once, but the command palette is a stateful
  LiveComponent (Tier-3) and the presentational shell is Tier-2 — a
  Tier-3 wrapper is the seam that lets both rules hold.
- **`ide_shell`** (Tier-2, restructured) is the OUTER presentational
  chrome: the universal header + a `:command_palette` slot + a `:body`
  slot. Stateless `Phoenix.Component`, per the UI Contract.
- **`workspace_shell`** (Tier-2, NEW) is today's `ide_shell` body
  (Activity Bar + Resource Panel + Main Window + Right Sidebar +
  Status Bar) with the header removed.
- **`admin_shell`** (Tier-2, renamed from `AdminSettingsShell`) is
  today's admin-settings body (left settings nav + main) with its
  stripped header removed.

An LV renders:

```heex
<AppShell.app_shell perspective={:workspace}
                    current_entity_uri={...} workspaces={...}
                    cmdk_nav_routes={...} current_path="/sessions" ...>
  <:body>
    <WorkspaceShell.workspace_shell current_path="/sessions" ...>
      <:main_window>...page content...</:main_window>
      <:right_sidebar>...</:right_sidebar>
    </WorkspaceShell.workspace_shell>
  </:body>
</AppShell.app_shell>
```

…or `perspective={:admin}` + `<AdminShell.admin_shell>` in `:body`
for a config page.

## 2. The `perspective` context contract (codex rev 2 — MEDIUM)

The outer shell takes a required `perspective :: :workspace | :admin`.
It is NOT cosmetic — it governs tenant context:

- **`:workspace`** — the header's left affordance is the
  `workspace_dropdown` ("ezagent / <workspace>"); switching workspace
  is meaningful. CmdK entity/session results are scoped to
  `current_workspace_uri` (per `UriOptions` §1.3 of the V1 UI SPEC).
- **`:admin`** — admin pages are `workspace://system` global config.
  The header's left affordance is a **system-context label** (e.g.
  "ezagent · System"), NOT the tenant workspace dropdown — you do not
  "switch workspace" while editing global runtime config. CmdK on an
  admin page surfaces nav results + system-scoped entities only; it
  does NOT show tenant-workspace entity/session results (those would
  be incoherent on a global page).

This makes the workspace-vs-system context an explicit, typed property
of the shell — not an emergent accident of which `current_workspace_uri`
happens to be in assigns.

## 3. CmdK — CommandPalette STAYS Tier-3 (codex rev 2 — HIGH)

rev 1 proposed moving `CommandPaletteComponent` to Tier-2 so the outer
shell could render it directly. **Rejected** — it is a stateful
`Phoenix.LiveComponent` (`mount/1`, `update/2`, open/query/result
state, targeted events, `push_navigate/2`). The UI Contract makes
`ezagent_domain_ui` the **stateless-atom** layer (zero LV deps).
Putting a LiveComponent there breaks the contract.

**rev 2**: `CommandPaletteComponent` stays exactly where it is —
`EzagentPluginLiveview.CommandPaletteComponent`, Tier-3, unchanged.
The Tier-2 `ide_shell` keeps a `:command_palette` SLOT. The NEW
Tier-3 `app_shell` fills that slot — once, in `app_shell`'s own
definition:

```elixir
# app_shell.ex (Tier-3) — renders the Tier-2 outer chrome + wires CmdK once
def app_shell(assigns) do
  ~H"""
  <IdeShell.ide_shell perspective={@perspective} ...>
    <:command_palette>
      <.live_component module={EzagentPluginLiveview.CommandPaletteComponent}
        id="cmdk" nav_routes={@cmdk_nav_routes} perspective={@perspective} ... />
    </:command_palette>
    <:body>{render_slot(@body)}</:body>
  </IdeShell.ide_shell>
  """
end
```

CmdK is wired ONE time (inside `app_shell`), not 13×. The per-LV
`:command_palette` slot from PR-2b is removed from every LV — they
render `app_shell`, which carries the palette. `CommandSource` is
already Tier-2 and stays; nothing moves tiers.

## 4. home_live is OUT of scope (codex rev 2 — HIGH)

rev 1 said `home_live` should render inside the outer shell. **Rejected
for this refactor.** `HomeLive` lives in the *public* live_session
(`on_mount: :put_locale` only), returns `layout: false`, and never
receives `:require_entity` / `:cmdk_nav` assigns (`current_entity_uri`,
`current_workspace_uri`, `workspaces`, `cmdk_nav_routes`). Wrapping it
in the outer shell would either crash on missing assigns or duplicate
the auth plumbing `LiveAuth` centralizes.

`home_live` stays as-is — a genuine pre-workspace landing page,
chrome-less. Giving it the outer shell is a SEPARATE auth/routing
change (move it to an authenticated live_session) and is explicitly
not in this SPEC. If Allen wants it, it is a follow-up.

## 5. Scope of migration

- **3 shell layers**: NEW Tier-3 `app_shell`; `ide_shell` restructured
  (Tier-2, outer chrome) + NEW Tier-2 `workspace_shell`;
  `AdminSettingsShell` → renamed `admin_shell` (Tier-2).
- **No tier moves**: `CommandPaletteComponent` + `CommandSource` stay
  put.
- **~20 LVs migrated**: 13 workflow LVs, 7 admin LVs. (`home_live`
  excluded — §4.)
- The per-LV `:command_palette` slot (PR-2b) is removed everywhere —
  `app_shell` carries it.

## 6. PR sequence — genuinely additive phasing (codex rev 2 — HIGH)

The rule that keeps main green: **no existing module is moved,
renamed, or deleted until its last consumer has migrated off it.**

| # | Title | How main stays green |
|---|-------|----------------------|
| 1 | NEW components only: `app_shell` (Tier-3), `workspace_shell` (Tier-2), `admin_shell` (Tier-2, a copy of AdminSettingsShell's body). `ide_shell` gains the `perspective` attr + keeps its current API working. Nothing is renamed or deleted. | purely additive — every existing LV still renders the OLD `ide_shell`/`AdminSettingsShell` API, untouched |
| 2 | Migrate the 13 workflow LVs → `app_shell` + `workspace_shell`. Remove their `:command_palette` slots (app_shell carries it now). | the OLD `ide_shell` monolith API stays compilable until PR-3; new LVs use the new path |
| 3 | Migrate the 7 admin LVs → `app_shell` + `admin_shell`. Then DELETE `AdminSettingsShell` + the old monolithic `ide_shell` header/body code + the dead `:command_palette` slot on consumers. | the delete happens in the SAME PR that removes the last consumer |

Every PR compiles + ships independently. A compile check after PR-1
confirms both old and new shell paths build.

## 7. Open questions (for Allen)

1. **Naming** — outer wrapper is `app_shell` (Tier-3) over `ide_shell`
   (Tier-2 chrome). Is `ide_shell` still the right name for the Tier-2
   chrome layer? (`outer_shell` / `app_chrome` are alternatives.)
   Allen to decide; this SPEC uses `ide_shell` for the Tier-2 chrome
   + `app_shell` for the Tier-3 wrapper.
2. **`:admin` system-context affordance** — §2 says the header shows
   "ezagent · System" instead of the workspace dropdown on admin
   pages. Is a plain label right, or should it be a (future)
   system-section dropdown? V1: plain label.
3. **Phasing granularity** — PR-2 migrates 13 LVs in one PR. If that
   is too large to review, it can split by LV cohort. Default: one PR.

## 8. Verification

**Functional**
1. avatar / notifications / search+⌘K render on ALL ~20 shell pages —
   workflow pages AND the 7 admin pages
2. ⌘K opens the command palette on an admin page (e.g. /workspaces)
   and on a workflow page (e.g. /sessions)
3. workflow pages still have Activity Bar + Resource Panel + Status
   Bar; admin pages still have the left settings nav
4. an admin page in `:admin` perspective shows the system-context
   label, NOT the tenant workspace dropdown
5. CmdK on an admin page shows nav + system-scoped results only — no
   tenant-workspace entity/session rows
6. `home_live` is unchanged (still chrome-less, still renders)

**Architecture / tiering**
7. `CommandPaletteComponent` is unchanged — still Tier-3
   `ezagent_plugin_liveview`, still a `Phoenix.LiveComponent`
8. `ide_shell`, `workspace_shell`, `admin_shell` are Tier-2
   stateless `Phoenix.Component`s — no LiveView/registry imports
   (dependency-boundary test)
9. `app_shell` is the ONLY place the CmdK LiveComponent is rendered —
   grep finds exactly one `module={...CommandPaletteComponent}`
10. no LV carries a `:command_palette` slot — `app_shell` does
11. `AdminSettingsShell` is deleted; nothing references it
12. PR-1's branch compiles with BOTH old and new shell paths present
    (the additive-phasing guarantee)
