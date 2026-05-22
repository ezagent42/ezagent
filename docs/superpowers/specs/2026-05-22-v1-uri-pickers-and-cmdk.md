# V1 UI — URI pickers + CmdK wiring

> **Status**: DRAFT — 2026-05-22. Author: Claude, V1 acceptance phase
> per Allen Feishu 2026-05-22 (items #1 + #3). Awaiting Allen review
> before implementation.

## 0. Why

Two V1-acceptance items, both rooted in the same data source
(`KindRegistry` + `BehaviorRegistry` + Phoenix Router):

- **#1** — LiveView has ~6 places that demand a human type a raw URI
  (`entity://user/system/admin`, `session://default/default/oncall`).
  Error-prone, no discoverability. Need selector components.
- **#3** — The CmdK search bar (`command_palette/1` component exists
  but is not wired) should let the operator search + jump. Allen:
  register L1/L2 routes so search→click ≡ click-the-link.

Allen's key architectural steer (Feishu 2026-05-22): CmdK must NOT
get its own registry. It reuses the existing `@interface` /
`BehaviorRegistry` / Router mechanism — the same source CLI
(`tree_builder.ex`) derives from. CmdK is a second projection of
one tree.

### Correction — slash commands don't exist

ARCHITECTURE.md §D.3 describes LiveView slash commands (`/agent:set-default`)
as a design. **They were never implemented** — no `SlashParser`, no
slash code anywhere (`grep slash` → only `uri.ex` comments). Only the
CLI side (`tree_builder.ex`) actually auto-derives from `@interface`.
So CmdK is the SECOND real `@interface` consumer, not the third. (A
future slash implementation would be the third — and would read the
same `description:` key §0 adds.)

## 0. Part 0 (prerequisite) — unify action descriptions

Allen Feishu 2026-05-22 Q1: there is no shared description mechanism.
`BehaviorRegistry` is a bare `{Kind, action} → Behavior` map. The
`@interface` action schema is `%{args, returns, modes}` — **no
`description`**. CLI's `tree_builder.action_about/2` tries
`Code.fetch_docs/1` for a function *named* after the action — but
Behaviors implement `invoke(:action, ...)`, never `def <action>`, so
the scrape almost always falls through to generic `"<action> action
on <Behavior>"`.

**Fix**: add a `description:` key to the `@interface` action schema.

```elixir
def interface do
  %{
    send: %{
      description: "Post a message into the session",
      args: %{message: message_schema()},
      returns: %{stored: :boolean},
      modes: [:cast]
    },
    # ...
  }
end
```

- `Ezagent.InterfaceValidator` (already exists, validates `@interface`
  shape) gains an optional-`description`-is-a-string check.
- Every existing Behavior's `interface/0` gets a one-line `description:`
  per action (small, ~20 actions across ~8 behaviors).
- `tree_builder.action_about/2` is rewritten to read
  `interface[action][:description]` (falling back to generic only when
  absent). The brittle `Code.fetch_docs` scrape is deleted.
- CmdK action results (§2.2 Source 3) read the same key.

This is **PR-0** — lands before PR-1/PR-2. One source of truth for
"what does this action do," consumed by CLI today + CmdK next +
slash whenever it's built.

## 1. Part A — `uri_picker` unified component (#1)

### 1.1 The 6 sites

| Site | What it picks | Mode |
|------|---------------|------|
| `routing_live.ex` matcher arg | one entity URI | single |
| `routing/routing_view.ex` matcher arg | one entity URI | single |
| `routing_live.ex` receivers | entity + session URIs | multi |
| `routing/routing_view.ex` receivers | entity + session URIs | multi |
| `workspace_detail_live.ex` add member | one entity URI | single |
| `routing_live.ex` JSON combinator | freeform JSON (advanced) | — keep textarea |

The JSON-combinator advanced mode stays a textarea — it's a
power-user escape hatch, not a single-URI field.

### 1.2 Component: `EzagentDomainUi.Primitives.uri_picker/1`

Tier-1 atom (stateless `Phoenix.Component`) in `primitives.ex`.

```elixir
attr :name, :string, required: true          # form field name
attr :mode, :atom, default: :single          # :single | :multi
attr :options, :list, required: true         # [%{uri: String.t, label: String.t, kind: atom, flavor: String.t | nil}]
attr :value, :any, default: nil              # String.t (single) | [String.t] (multi)
attr :placeholder, :string, default: nil
attr :allow_freetext, :boolean, default: false  # advanced fallback — see 1.4
attr :label, :string, default: nil
attr :required, :boolean, default: false
```

Rendering:
- **`:single`** → a styled `<select>` (or combobox if option count is
  large; V1 ships plain `<select>` — combobox is a V2 polish). One
  hidden-or-native select bound to `name`.
- **`:multi`** → a checklist OR a tag-input. V1 ships a **checklist**
  (vertical list of checkboxes, each `name="<name>[]"`). Simple,
  accessible, no JS. Tag-input with autocomplete is V2 polish.
- Each option renders `label` (human) + the `uri` in `font-mono`
  small text + a `kind`/`flavor` badge.

The component is **pure** — it does NOT query registries. The LV
(Tier-3) computes `options` and passes them in. This keeps the atom
LV-dependency-free (3-layer architecture invariant).

### 1.3 Option source — `Ezagent.UI.UriOptions`

New Tier-2 helper module `apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex`
(OR put it in an existing domain module — implementer's call; it
needs `KindRegistry` which is `ezagent_core`, so `ezagent_domain_ui`
can host it).

```elixir
@doc "Live entity URIs (users + agents) as picker options."
@spec entities() :: [option()]
def entities do
  Ezagent.KindRegistry.list_all()
  |> Enum.filter(fn {uri, _} -> String.starts_with?(uri, "entity://") end)
  |> Enum.map(&to_option/1)
end

@doc "Live session URIs as picker options."
@spec sessions() :: [option()]

@doc "Entities + sessions both — for receiver fields."
@spec entities_and_sessions() :: [option()]
```

`option()` = `%{uri: String.t(), label: String.t(), kind: atom(), flavor: String.t() | nil}`.
`label` is the human-friendly display name (via `Ezagent.EntityPresenter.display/1`
where available, else the URI's last segment).

### 1.4 Free-text fallback

`allow_freetext: true` adds, below the select/checklist, a small
"or enter a URI manually" disclosure (a `<details>`) with a plain
text input. Used where the operator might legitimately reference a
URI that isn't live yet (e.g., a routing rule targeting an agent
that will be created later). Default `false` — most sites pick from
live options only.

### 1.5 Per-site wiring

Each of the 5 picker sites: the LV's `mount`/`handle_params` computes
`options` via `Ezagent.UI.UriOptions.*`, assigns it, and the template
swaps the raw `<input>` for `<.uri_picker .../>`. Form-submit params
are unchanged in shape (single → string, multi → list) so the
existing `handle_event` handlers need minimal-to-no change.

## 2. Part B — CmdK wiring (#3)

### 2.1 Current state

`command_palette/1` (in `ide_shell.ex`) is a complete modal component
— `@open`, `@query`, `@results`, events `command_query` /
`command_select_result`. But:
- Trigger button dispatches JS event `ezagent:open-command-palette`
  — **no JS listener**
- ⌘K keybinding — not bound
- No LV handlers for `command_query` / `command_select_result`
- No results data source

### 2.2 No new registry — three existing sources

Per Allen's steer, CmdK results union THREE existing registries:

**Source 1 — Navigation (Phoenix Router)**
`EzagentWeb.Router.__routes__/0` enumerates every route. Filter to
`live` routes without path params (the L1/L2 pages: `/sessions`,
`/identities`, `/routing`, `/plugins`, `/admin`, `/admin/logs`,
`/workspaces`, `/profile`, …). Each → a result
`%{kind: :nav, label: "Sessions", target: "/sessions", icon: ...}`.
Selecting → `push_navigate`.

**Source 2 — Entities / sessions (KindRegistry)**
`Ezagent.KindRegistry.list_all/0` → every live `entity://` / `session://`.
Each → `%{kind: :entity, label: <display>, target: "/identities/agents/<enc>", ...}`.
Selecting → `push_navigate` to that thing's detail page. Same data
`uri_picker` uses (§1.3) — **shared `UriOptions` source**.

**Source 3 — Actions (BehaviorRegistry + @interface)**
`Ezagent.BehaviorRegistry` holds `{Kind, action} → Behavior`. Each
Behavior's `interface/0` gives the action schema — including the
`description:` key added in PR-0 (§0). This is the SAME source
`tree_builder.ex` (CLI) derives from. The result `label` is
`interface[action][:description]`.
For V1, surface only the **parameter-free** actions as CmdK commands
(actions whose `@interface[:action].args` is empty — e.g. an agent
`reset_conversation`). Parameterized actions need a form → defer the
in-CmdK form to V2; for V1 a parameterized action result, when
selected, just navigates to the page where that form lives.

### 2.3 `Ezagent.UI.CommandSource` — the query function

New Tier-2 module. NOT a registry (nothing to register into) — a
pure query over the 3 sources above:

```elixir
@spec search(String.t()) :: [result()]
def search(query) do
  (nav_results() ++ entity_results() ++ action_results())
  |> Enum.filter(&fuzzy_match?(&1.label, query))
  |> Enum.sort_by(&match_rank(&1, query))
  |> Enum.take(20)
end
```

`result()` = `%{kind: :nav | :entity | :action, label, target | dispatch, icon, group}`.

### 2.4 JS wiring

- New JS hook `apps/ezagent_web/assets/js/hooks/command_palette.js`:
  - Listens for the `ezagent:open-command-palette` window event (the
    trigger button already dispatches it) → pushes a `open_command_palette`
    LV event
  - Binds **⌘K / Ctrl+K** globally → same
  - (Esc-to-close already handled by the component's `phx-window-keydown`)

### 2.5 LV handlers

Add to the LVs that wrap `ide_shell` (or — cleaner — a shared
`on_mount` / a `CommandPalette` live_component so it's not copy-pasted
into 13 LVs):

- `open_command_palette` → `assign(:cmdk_open, true)`
- `command_query` → `assign(:cmdk_results, CommandSource.search(q))`
- `command_select_result` → branch on `result.kind`:
  - `:nav` / `:entity` → `push_navigate(to: target)`
  - `:action` → `Ezagent.Invocation.dispatch(...)` then close

**Recommendation**: implement CmdK as a `Phoenix.LiveComponent`
(`EzagentPluginLiveview.CommandPaletteComponent`) so the open-state +
query + results + handlers live in ONE place, and every `ide_shell`
LV just renders `<.live_component module={CommandPalette} id="cmdk"/>`
in the `:command_palette` slot. Avoids 13× handler duplication.

### 2.6 Out of scope (V2)

- In-CmdK forms for parameterized actions (V1: navigate to the form
  page instead)
- Fuzzy-rank tuning / recency boosting
- Combobox autocomplete for `uri_picker` single mode
- Tag-input for `uri_picker` multi mode

## 3. PR sequence

| # | Title | Scope |
|---|-------|-------|
| 0 | `@interface` gains `description:` key + backfill all behaviors + CLI reads it | Part 0 (prerequisite) |
| 1 | `uri_picker` component + `UriOptions` source + wire 5 sites | Part A |
| 2 | `CommandSource` query + `CommandPalette` live_component + JS hook + ⌘K | Part B |

PR-0 lands first (CmdK action results depend on it; also fixes CLI's
brittle doc-scrape). PR-1 has no dep on PR-0 or PR-2 — can land in
parallel. PR-2 depends on PR-0 (reads `description:`) + reuses PR-1's
`UriOptions`.

## 4. Verification

1. `routing_live` matcher arg renders a `<select>` of live entities,
   not a raw text box
2. `routing_live` receivers renders a multi-checklist of entities +
   sessions
3. `workspace_detail` add-member uses the single picker
4. Clicking the header search bar OR pressing ⌘K opens the CmdK modal
5. Typing "sessions" → a `:nav` result → Enter → navigates to /sessions
6. Typing an agent name → an `:entity` result → navigates to its page
7. JSON-combinator advanced mode unchanged (still a textarea)
8. `uri_picker` is a pure Tier-1 atom (no LV/registry imports)
9. CmdK adds no new "registry" module — `CommandSource` is a query
   over Router + KindRegistry + BehaviorRegistry

## 5. Open questions for Allen

- **Q1**: `uri_picker` multi-mode — V1 ships a plain checklist. OK to
  defer tag-input-with-autocomplete to V2? (Recommended yes — checklist
  is accessible + zero-JS.)
- **Q2**: CmdK as a shared `LiveComponent` vs an `on_mount` injected
  into all 13 ide_shell LVs. Recommended: LiveComponent (one home).
- **Q3**: Should CmdK action results (Source 3) be in V1 at all, or
  V1 ships only nav + entity results and actions land in V2? Actions
  need the parameter-free filter + dispatch path. Recommended: V1
  ships nav + entity (the high-value "jump" use case Allen described);
  actions deferred to V2 to keep PR-2 tight.
