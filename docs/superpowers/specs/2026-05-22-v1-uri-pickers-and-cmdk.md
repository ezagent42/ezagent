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

Rendering (Allen 2026-05-22 decision — do BOTH, not V2-deferred):
- **`:single`** → a combobox: a text input with a filtered dropdown of
  matching options. Typing filters; click or Enter selects. A hidden
  field bound to `name` carries the chosen URI.
- **`:multi`** → a **tag-input with autocomplete**: selected URIs
  render as removable chips; a text input below filters the option
  list; picking adds a chip. Each chip emits a hidden `name="<name>[]"`
  field so form submit yields the list.
- Each option (both modes) renders the procedural `<.avatar>` (entity
  options) + `label` (human display name) + the `uri` in `font-mono`
  small text + a `kind`/`flavor` badge.
- Autocomplete filtering is a small JS hook (`uri_picker.js`) —
  client-side filter over the pre-rendered `options` (no per-keystroke
  server round-trip). Entity/session counts are small in V1; a
  server-side filter is a future option if sets grow.

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

### 2.5 LV handlers — shared LiveComponent (Allen 2026-05-22 decision)

CmdK is implemented as a **`Phoenix.LiveComponent`**
(`EzagentPluginLiveview.CommandPaletteComponent`) — Allen's decision
over the on_mount alternative. Open-state + query + results + handlers
live in ONE place; every `ide_shell` LV renders
`<.live_component module={CommandPaletteComponent} id="cmdk"/>` in the
`:command_palette` slot. No 13× handler duplication.

The component's internal events:
- `open` → `assign(:open, true)`
- `query` → `assign(:results, CommandSource.search(q))`
- `select_result` → branch on `result.kind`:
  - `:nav` / `:entity` → `push_navigate(to: target)` (V1 scope)
  - `:action` → V2 (see §2.6)

### 2.6 CmdK V1 scope = nav + entity only (Allen 2026-05-22 decision)

V1 CmdK ships **Source 1 (nav) + Source 2 (entity/session)** only.
**Source 3 (actions) is deferred to V2** — Allen's decision. The
high-value use case Allen described ("search → click ≡ click the
link") is fully served by nav + entity. Actions need the
parameter-free filter + dispatch path + (for parameterized actions)
in-CmdK forms — all V2.

PR-2 therefore does NOT depend on PR-0 (`description:` key) — that
dependency was only for action results. PR-0 still ships (it fixes
CLI's brittle doc-scrape + prepares for V2 CmdK actions + future
slash) but is no longer a hard prerequisite for PR-2.

### 2.7 Out of scope (V2)

- CmdK Source 3 — action results (parameter-free dispatch + forms)
- LiveView slash commands (`/agent:set-default`) — Allen 2026-05-22:
  slash is V2. (Never implemented; ARCHITECTURE.md §D.3 design only.)
- Fuzzy-rank tuning / recency boosting
- `uri_picker` server-side option filtering for large sets

## 2C. Part C — member panel redesign (#6, Allen 2026-05-22)

### 2C.1 The problem

The `/sessions` right sidebar has TWO sections — "MEMBERS" + a
separate "FLOATING AGENTS" dropdown. Allen: this split is confusing;
they should be ONE unified member list. Floating agents stop being a
section; instead an **Invite** button opens a modal.

### 2C.2 Entity avatars — already solved

Allen asked whether entity Kinds have an avatar attribute / an "infos"
field. **Answer: avatars are procedural, not stored.** The `<.avatar
uri={...}>` atom (Phase 8c PR-C) derives a unique 2-color conic
gradient + monogram from a hash of the entity URI. Any entity URI
gets a deterministic avatar — nothing to store. `entity_profiles`
holds `display_name` + `email`; there is no generic "infos"/metadata
JSON column. If V2 wants richer per-entity metadata, adding a
`metadata` JSON column to `entity_profiles` is the place — but the
member panel needs nothing new: `<.avatar>` + `display_name` cover it.

### 2C.3 Redesign

`EzagentPluginLiveview.Admin.MemberPanel` (`member_panel.ex`):

- **One unified member list.** Each row: `<.avatar>` + display name +
  URI (`font-mono` small) + online `<.status_dot>` + per-row actions
  (the existing cc-agent PTY button stays). `members` + `floating_agents`
  are merged into one rendered list — floating agents are simply
  members that were added ad-hoc; they render identically.
- **Remove the "FLOATING AGENTS" dropdown section** entirely.
- **Add an "Invite" button** at the top/bottom of the member list →
  opens a modal:
  - Tab/section 1 — **Add existing**: a `uri_picker` (`:single`,
    `kinds: [:entity]`) listing entities not already in the session →
    pick → adds as a member.
  - Tab/section 2 — **Create new agent**: a link/button that navigates
    to the existing `/identities/agents/new` page (AgentNewLive). Don't
    rebuild the create form in the modal — just route to it.
- The modal is a Tier-1 `<.modal>` atom (already exists in
  `primitives.ex`); the picker reuses Part A's `uri_picker`.

### 2C.4 Wiring

`AdminLive` already has the member data + the `add_floating_agent`
handler. The redesign:
- Drop the separate floating-agents `<select>`; the `add_floating_agent`
  handler is reused by the modal's "Add existing" picker.
- New handler `open_invite_modal` / `close_invite_modal`.
- The merged list is just `members` (floating agents are members).

This is **PR-3**, depends on PR-1 (`uri_picker`).

## 3. PR sequence

| # | Title | Scope |
|---|-------|-------|
| 0 | `@interface` gains `description:` key + backfill all behaviors + CLI reads it | Part 0 |
| 1 | `uri_picker` component (combobox + tag-input) + `UriOptions` + wire 5 sites | Part A |
| 2 | `CommandSource` (nav + entity) + `CommandPalette` LiveComponent + JS hook + ⌘K | Part B |
| 3 | Member panel redesign — unified list + Invite modal | Part C |

PR-0 ships independently (fixes CLI doc-scrape; prepares V2 CmdK
actions + future slash). PR-1 independent. PR-2 independent of PR-0
now (V1 CmdK = nav+entity, no action results) + reuses PR-1's
`UriOptions`.

## 4. Verification

1. `routing_live` matcher arg renders a `uri_picker` `:single`
   combobox of live entities, not a raw text box
2. `routing_live` receivers renders a `uri_picker` `:multi` tag-input
   (chips + autocomplete) over entities + sessions
3. `workspace_detail` add-member uses the `:single` picker
4. Clicking the header search bar OR pressing ⌘K opens the CmdK modal
5. Typing "sessions" → a `:nav` result → Enter → navigates to /sessions
6. Typing an agent name → an `:entity` result → navigates to its page
7. JSON-combinator advanced mode unchanged (still a textarea)
8. `uri_picker` is a pure Tier-1 atom (no LV/registry imports)
9. CmdK adds no new "registry" module — `CommandSource` is a query
   over Router + KindRegistry (V1); BehaviorRegistry actions are V2
10. `/sessions` right sidebar shows ONE unified member list (avatars);
    no separate "Floating Agents" section; an Invite button opens a
    modal (add-existing picker + create-new-agent link)

## 5. Decisions (Allen 2026-05-22 — all open questions resolved)

- **uri_picker modes**: ship BOTH — `:single` combobox + `:multi`
  tag-input-with-autocomplete. (Not V2-deferred.)
- **CmdK structure**: shared `Phoenix.LiveComponent` (one home, no
  13× duplication).
- **CmdK V1 scope**: nav + entity results only. Action results
  (Source 3) → V2.
- **slash commands**: V2. (Never implemented; CmdK is the V1 search
  surface.)
- **Member panel** (new Part C): unified member list + Invite modal;
  avatars are procedural (`<.avatar>`), nothing to store.
