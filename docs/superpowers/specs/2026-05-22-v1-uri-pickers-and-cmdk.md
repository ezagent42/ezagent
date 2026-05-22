# V1 UI — URI pickers + CmdK wiring

> **Status**: DRAFT rev 4 — 2026-05-22. Author: Claude, V1 acceptance
> phase per Allen Feishu 2026-05-22 (items #1 + #3 + #6).
> Implementation-ready: passed a `codex:rescue` review (rev 3) AND a
> `codex adversarial-review` (rev 4).
>
> - **rev 2**: Allen's decisions on the §5 open questions + Part C
>   (member panel).
> - **rev 3**: Codex `rescue` review fixes — 3 BLOCKERs + 7 MAJORs.
>   Key structural changes: (a) dependency-cycle fix —
>   `CommandSource`/`CommandPalette` never call `EzagentWeb.Router`;
>   nav routes are assembled in `ezagent_web` via a new
>   `command_routes/0` + flow DOWN through an `on_mount` assign; (b)
>   `UriOptions` is workspace-scoped; (c) `CommandSource` is a pure
>   ranking function over injected candidates; (d) JS open-trigger is
>   global `app.js`, not a mount-point-less hook; (e) LiveComponent
>   events all carry `phx-target={@myself}` + a canonical event
>   table; (f) `uri_picker` tag-input subtree is `phx-update="ignore"`;
>   Tier-2 label; `:kinds` attr; `result()` `:key`; `allow_freetext`
>   contract; session target-URL contract.
> - **rev 4**: Codex **adversarial** review fixes — 2 HIGH + 2 MEDIUM,
>   all about tenant boundary + failure visibility: (a) §1.3 —
>   `UriOptions` enforces workspace authority ITSELF from a
>   `caller_uri` arg; the rev-3 `cross_workspace: true` caller-discipline
>   escape hatch is removed; (b) §1.6 — submitted picker URIs are
>   UNTRUSTED; every converted form revalidates server-side
>   (`UriOptions.valid_for?/4`); hook `updated()`/reconnect prunes
>   stale selections; (c) §2C.4 — the member-panel Invite uses a NEW
>   `:call` handler that surfaces `:unauthorized`/`:cross_workspace_denied`,
>   NOT the silent `:cast` `add_floating_agent` path; (d) §4 —
>   verification checklist rewritten (rev-3 left stale items asserting
>   the old Tier-1 / Router-querying architecture).

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

**Tier-2** domain-ui atom — a stateless `Phoenix.Component` in
`apps/ezagent_domain_ui/lib/ezagent_domain_ui/primitives.ex`. (Codex
review 2026-05-22: `primitives.ex` is Tier-2 domain-ui, NOT Tier-1
core — Tier-1 is `ezagent_core`, which holds no UI code.)

```elixir
attr :name, :string, required: true          # form field name
attr :mode, :atom, default: :single          # :single | :multi
attr :options, :list, required: true         # [option()] — see 1.3
attr :kinds, :list, default: [:entity, :session]  # which URI kinds the
                                              # caller's options contain;
                                              # used only for the badge +
                                              # the empty-state copy.
                                              # Callers MUST pre-filter
                                              # `options` themselves —
                                              # the component does not
                                              # filter by :kinds.
attr :value, :any, default: nil              # String.t (single) | [String.t] (multi)
attr :placeholder, :string, default: nil
attr :allow_freetext, :boolean, default: false  # advanced fallback — see 1.4
attr :label, :string, default: nil
attr :required, :boolean, default: false
```

Rendering (Allen 2026-05-22 decision — do BOTH, not V2-deferred):
- **`:single`** → a combobox: a text input with a filtered dropdown of
  matching options. Typing filters; click or Enter selects. A hidden
  `<input type="hidden" name={@name}>` carries the chosen URI.
- **`:multi`** → a **tag-input with autocomplete**: selected URIs
  render as removable chips; a text input below filters the option
  list; picking adds a chip. Each chip emits a hidden
  `<input type="hidden" name={@name <> "[]"}>` so form submit yields
  the list.
- Each option (both modes) renders the procedural `<.avatar>` (entity
  options) + `label` (human display name) + the `uri` in `font-mono`
  small text + a `kind`/`flavor` badge.

**JS hook + LiveView diff protection (Codex review 2026-05-22):**
- Autocomplete filtering + chip add/remove is a JS hook
  `uri_picker.js` (`phx-hook="UriPicker"` on the component's root
  `<div>` — the hook MUST have a mount point).
- The hook owns the mutable subtree: the filtered dropdown, the chip
  list, and the hidden form inputs. That subtree MUST be wrapped in
  `phx-update="ignore"` so a LiveView re-render does not wipe the
  hook-mutated DOM. The pre-rendered `options` list (immutable for the
  life of the form) sits OUTSIDE the ignored subtree, in a
  `data-options` JSON attribute the hook reads on mount.
- Client-side filter only — no per-keystroke server round-trip. V1
  entity/session counts are small; server-side filtering is a future
  option if sets grow.

The component is **pure** — it does NOT query registries. The LV
(Tier-3) computes `options` and passes them in. This keeps the atom
registry-dependency-free (3-layer architecture invariant).

### 1.3 Option source — `Ezagent.UI.UriOptions`

New **Tier-2** helper module
`apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex`. It
depends only on `ezagent_core` (`KindRegistry`) +
`ezagent_domain_identity` (`EntityPresenter`) — both are at-or-below
Tier-2, so `ezagent_domain_ui` may host it without a dependency-cycle
violation.

**Workspace scoping is enforced INSIDE UriOptions — no caller-discipline
escape hatch (Codex adversarial review rev 3 → rev 4, HIGH).**
`KindRegistry.list_all/0` is global; returning every URI to every user
leaks cross-workspace entities. Rev 3 made cross-workspace safety a
`cross_workspace: true` opt the caller had to "remember to authorize"
— a landmine: a single picker/CmdK call site forgetting it leaks
labels across tenants, and this read path sits OUTSIDE dispatch step
5.6 where isolation is normally enforced.

**Rev 4 fix**: every public function takes the **caller's entity URI**
and resolves authority ITSELF. There is no boolean escape hatch.

```elixir
@type option :: %{
        uri: String.t(),
        label: String.t(),
        kind: atom(),
        flavor: String.t() | nil
      }

# `caller_uri` — the acting user/entity (LV's current_entity_uri).
# `workspace_uri` — the workspace to list. UriOptions enforces:
#   - caller is a system member (cross-workspace authority, the same
#     check dispatch step 5.6 uses) → any workspace_uri allowed;
#   - else → workspace_uri MUST equal the caller's own workspace,
#     otherwise UriOptions returns [] (never leaks; never raises a
#     stack-trace at the user).
@doc "Entity URIs (users + agents) the caller may see in workspace_uri."
@spec entities(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]

@doc "Session URIs the caller may see in workspace_uri."
@spec sessions(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]

@doc "Entities + sessions both — for receiver fields."
@spec entities_and_sessions(caller_uri :: String.t(), workspace_uri :: String.t()) :: [option()]
```

Each function: resolve caller authority → if not authorized for
`workspace_uri`, return `[]` → else `KindRegistry.list_all/0` → filter
by scheme → filter by workspace (the workspace segment of the
3-segment URI, per SPEC v3 §3) → enrich each `{uri, _pid}` into an
`option()` (`label` via `Ezagent.EntityPresenter.display/1`,
`kind`/`flavor` parsed from the URI).

**PR-1 MUST add invariant tests**: a non-system user calling
`UriOptions.entities(their_uri, other_workspace_uri)` gets `[]`; a
system member gets the full list. This is the tenant-isolation gate
for the read path.

> Note (Codex review): `KindRegistry.list_all/0` returns only
> `{uri_string, pid}` — no label/kind/flavor/workspace. `UriOptions`
> is the enrichment + **authorization** layer. It is NOT a "pure
> pass-through query".

### 1.4 Free-text fallback

`allow_freetext: true` adds, below the picker, a `<details>`
disclosure ("or enter a URI manually") with a plain text input.

**Param contract (Codex review 2026-05-22 — was under-specified):**
- The free-text input uses the SAME form param `name` as the picker's
  hidden field (`@name` for single, `@name <> "[]"` for multi).
- When the disclosure is OPEN, the JS hook DISABLES the picker's
  hidden inputs (`disabled` attr → excluded from form submit) so only
  the free-text value is submitted. When CLOSED, the free-text input
  is `disabled`. Exactly one source submits — there is no merge, no
  server-side precedence rule needed.
- Default `allow_freetext: false`. Used where the operator may
  reference a URI not yet live (e.g. a routing rule targeting an agent
  to be created later).

### 1.5 Per-site wiring

Each of the 5 picker sites: the LV's `mount`/`handle_params` computes
`options` via `Ezagent.UI.UriOptions.*` (passing `current_entity_uri`
+ `current_workspace_uri`), assigns it, and the template swaps the raw
`<input>` for `<.uri_picker .../>`. Form-submit params are unchanged
in shape (single → string, multi → list).

### 1.6 Submitted URIs are UNTRUSTED — server-side revalidation is in PR-1 scope

**(Codex adversarial review rev 3 → rev 4, HIGH.)** The picker's chip
state + hidden inputs live under a JS-owned `phx-update="ignore"`
subtree. Hidden inputs are **user-controlled DOM**: a user can edit
them; and the ignored subtree can hold a **stale** option after a
workspace switch or a LiveView reconnect. Rev 3's "handlers need
minimal-to-no change" was wrong — it treated client state as trusted.

**Rev 4 — mandatory for every converted site, in PR-1 scope:**
- Client-side filtering is **UX only**. The authoritative check is on
  the server.
- Each converted form's `handle_event` MUST, on submit, revalidate
  EVERY submitted URI: (a) well-formed + correct scheme for the field,
  (b) belongs to the current workspace (or the caller has
  cross-workspace authority), (c) the target actually exists /
  membership is valid where the action needs it. A failed check →
  a flash error, not a dispatch.
- This is the SAME validation the picker's `options` were built from
  (`UriOptions` §1.3) — factor it into a shared
  `UriOptions.valid_for?(caller_uri, workspace_uri, uri, kinds)` so
  the option-build path and the submit-revalidate path cannot drift.
- **Hook `updated()` / reconnect**: the `uri_picker.js` hook MUST
  implement `updated()` — when LiveView pushes a new `data-options`
  (workspace switch, re-render), the hook drops selections no longer
  in the option set. On reconnect, LiveView re-renders the component
  from server assigns; the hook re-reads `data-options` and prunes
  stale chips. A stale selection can never silently survive into a
  submit.

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

### 2.2 V1 sources — nav + entity (no new registry)

Per Allen's steer, CmdK results union existing data. V1 uses TWO
sources (Source 3 actions = V2, §2.7).

**Source 1 — Navigation (Phoenix Router) — assembled in `ezagent_web`**

The router routes are static (compile-time known). New API in
`ezagent_web`:

```elixir
# apps/ezagent_web/lib/ezagent_web/router.ex (or a sibling module)
@doc "Palette-eligible nav routes — enriched, not raw route structs."
@spec command_routes() :: [%{label: String.t(), path: String.t(),
                             icon: String.t(), group: String.t()}]
```

It filters `__routes__/0` to `live` routes without path params (L1/L2
pages: `/sessions`, `/identities`, `/routing`, `/plugins`, `/admin`,
`/admin/logs`, `/workspaces`, `/profile`, …) and attaches a curated
`label`/`icon`/`group` per route (a small hand-maintained map keyed by
path — raw route structs carry no human label, Codex review 2026-05-22).

**Dependency-cycle fix (Codex review 2026-05-22 — BLOCKER).**
`CommandSource` and the `CommandPalette` LiveComponent live in tiers
*below* `ezagent_web` and MUST NOT call `EzagentWeb.Router`. Instead:
`ezagent_web` installs an `on_mount` hook that calls
`command_routes/0` and assigns `:cmdk_nav_routes` onto the socket.
The LV inherits the assign and passes it into the LiveComponent. The
nav data flows DOWN (web → LV → component), never up.

**Source 2 — Entities / sessions (`UriOptions`)**
`Ezagent.UI.UriOptions.entities_and_sessions(workspace_uri)` (§1.3) —
**workspace-scoped**. Each `option()` → a result
`%{kind: :entity, label: <display>, target: <detail-url>, …}`. Same
enrichment layer `uri_picker` uses.

**Target URL contract (Codex review 2026-05-22 — "navigate to detail
page" was not implementable).** The `target` per URI kind:
- `entity://agent/...` → `/identities/agents/<url-encoded-uri>` — this
  route already exists (`AgentDetailLive`).
- `entity://user/...` → `/identities/users/<url-encoded-uri>` if a user
  detail route exists; otherwise `/identities` (the list). Implementer
  checks the router.
- `session://...` → `/sessions?session=<url-encoded-uri>`. **This
  requires a small addition to `SessionsLive`/`AdminLive`**: a
  `handle_params/3` clause that reads the `session` query param and
  selects that session (today session-switching is only a
  `phx-click` event with no URL form). This `handle_params` addition
  is in PR-2's scope — without it, a CmdK session result has nowhere
  to land.

### 2.3 `Ezagent.UI.CommandSource` — a pure ranking function

New **Tier-2** module (`ezagent_domain_ui`). NOT a registry, and NOT a
query over live registries — it is a **pure function over data passed
in by the caller** (this is the dependency-cycle fix: it never reaches
for `EzagentWeb.Router` or even `KindRegistry` itself).

```elixir
@type result :: %{
        key: String.t(),        # stable id — used as phx-value-key (Codex review)
        kind: :nav | :entity,   # V1 kinds (:action = V2)
        label: String.t(),
        target: String.t(),     # URL for push_navigate
        icon: String.t(),
        group: String.t()
      }

@doc "Rank + filter pre-assembled candidates against the query."
@spec search(query :: String.t(), candidates :: [result()]) :: [result()]
def search(query, candidates) do
  candidates
  |> Enum.filter(&fuzzy_match?(&1.label, query))
  |> Enum.sort_by(&match_rank(&1, query))
  |> Enum.take(20)
end
```

The `CommandPalette` LiveComponent builds `candidates` by mapping
`@cmdk_nav_routes` (from the on_mount assign) + `UriOptions` output
into `result()` shape, then calls `search/2`. Every result carries a
stable `:key` (e.g. `"nav:/sessions"`, `"entity:" <> uri`) so the
existing `phx-value-key` markup works and selection is an O(1) lookup
in a `%{key => result}` map the component holds.

### 2.4 JS wiring (Codex review 2026-05-22 — BLOCKER fixed)

The open-trigger is **plain global JS in `app.js`**, NOT a
`phx-hook` (a hook needs a mount-point element; the open behavior is
app-global, not bound to one component instance):

```js
// apps/ezagent_web/assets/js/app.js — global, after liveSocket setup
window.addEventListener("ezagent:open-command-palette", () =>
  liveSocket.execJS(document.body, /* JS.push "cmdk_open" target the palette */))
window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "k") {
    e.preventDefault()
    window.dispatchEvent(new CustomEvent("ezagent:open-command-palette"))
  }
})
```

The existing trigger button already dispatches
`ezagent:open-command-palette`. Esc-to-close stays on the component's
`phx-window-keydown`. The push targets the LiveComponent (see §2.5).

### 2.5 LV handlers — shared LiveComponent (Allen 2026-05-22 decision)

CmdK is implemented as a **`Phoenix.LiveComponent`**
(`EzagentPluginLiveview.CommandPaletteComponent`) — Allen's decision
over the on_mount alternative. Open-state + query + results + handlers
live in ONE place; every `ide_shell` LV renders
`<.live_component module={CommandPaletteComponent} id="cmdk"
nav_routes={@cmdk_nav_routes} workspace_uri={@current_workspace_uri}/>`
in the `:command_palette` slot. No 13× handler duplication.

**Every event binding in the component markup MUST carry
`phx-target={@myself}` (Codex review 2026-05-22 — BLOCKER).** Without
it, `phx-change` / `phx-click` / `phx-window-keydown` route to the
PARENT LiveView, which has no matching `handle_event` → crash or
silent no-op. The component owns its events only if every binding is
targeted at `@myself`.

Canonical event table (Codex review 2026-05-22 — names were
inconsistent across the spec; this is the single source of truth):

| Event | Trigger | Handler effect |
|-------|---------|----------------|
| `cmdk_open` | global JS push (§2.4) | `assign(:open, true)` |
| `cmdk_close` | overlay click / Esc | `assign(:open, false)` |
| `cmdk_query` | search input `phx-change` | `assign(:results, search(q, candidates))` |
| `cmdk_select` | result row `phx-click` (`phx-value-key`) | branch on `result.kind` |

`cmdk_select` → look up `result` by `key` in the component's
`%{key => result}` map → `push_navigate(to: result.target)` for
`:nav` / `:entity` (V1). The existing `command_palette/1` markup in
`ide_shell.ex` is renamed/retargeted to these event names + gains
`phx-target={@myself}` on every binding when it becomes the
LiveComponent's `render/1`.

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
- The modal is a Tier-2 `<.modal>` atom (already in `primitives.ex`);
  the picker reuses Part A's `uri_picker`.

### 2C.4 Wiring — a NEW invite handler, NOT the silent cast path

**(Codex adversarial review rev 3 → rev 4, MEDIUM.)** Rev 3 said the
modal reuses the existing `add_floating_agent` handler. That handler
dispatches `chat.join` as **`:cast`** and discards the result — an
`:unauthorized`, `:cross_workspace_denied`, missing-session, or
invalid-target failure is **silently dropped**. That violates the
architecture's no-silent-drop posture for user-facing surfaces
(Decision #134 — inbound user surfaces dispatch `:call` + surface
errors), and after the separate floating-agent `<select>` is removed
there is no other affordance, so a silent failure is invisible.

**Rev 4 — PR-3 adds a dedicated invite handler, does NOT reuse
`add_floating_agent` unchanged:**
- New `handle_event("invite_member", %{"member_uri" => uri}, socket)`:
  1. Revalidate `uri` per §1.6 (well-formed entity URI, in the current
     workspace OR caller has cross-workspace authority).
  2. Dispatch `chat.join` as **`:call`** (not `:cast`) so the result
     comes back.
  3. Decompose the result: `:ok` → refresh members + close modal;
     `{:error, :unauthorized}` → flash "you may not add members here";
     `{:error, :cross_workspace_denied}` → flash naming the workspace
     boundary; other `{:error, reason}` → flash `inspect(reason)`.
  4. Members list refreshes ONLY on confirmed `:ok`.
- `open_invite_modal` / `close_invite_modal` for modal visibility.
- The old `add_floating_agent` handler + its `<select>` are deleted
  (nothing else uses them once the modal lands).
- The merged list is just `members` (floating agents are members).

This is **PR-3**, depends on PR-1 (`uri_picker` + the §1.6
`UriOptions.valid_for?/4` shared validator).

## 3. PR sequence

| # | Title | Scope |
|---|-------|-------|
| 0 | `@interface` gains `description:` key + backfill all behaviors + CLI reads it | Part 0 |
| 1 | `uri_picker` (combobox + tag-input) + `UriOptions` (caller-authorized) + `valid_for?/4` + server-side revalidation at all 5 sites + tenant-isolation invariant tests | Part A |
| 2 | `CommandSource` (nav + entity) + `CommandPalette` LiveComponent + JS hook + ⌘K | Part B |
| 3 | Member panel redesign — unified list + Invite modal (dedicated `:call` invite handler) | Part C |

PR-0 ships independently (fixes CLI doc-scrape; prepares V2 CmdK
actions + future slash). PR-1 independent. PR-2 independent of PR-0
(V1 CmdK = nav+entity, no action results) + reuses PR-1's
`UriOptions`. PR-3 depends on PR-1 (`uri_picker` + `valid_for?/4`).

**PR-1 is bigger than rev 3 implied** — Codex rev 4 folded the
server-side URI revalidation (§1.6) + the `UriOptions` caller-auth
model (§1.3) + the tenant-isolation invariant tests into PR-1's
definition of done. Client-side picker UX without the server gate is
NOT a shippable PR-1.

## 4. Verification

> Rewritten rev 4 — Codex adversarial review caught that the rev 3
> checklist still asserted the OLD blocked architecture (a "Tier-1
> atom", "CommandSource queries Router + KindRegistry"). Those are the
> exact mistakes rev 3's prose fixed; a stale checklist could bless
> them back in. The list below matches rev 4's design.

**Functional**
1. `routing_live` matcher arg renders a `uri_picker` `:single`
   combobox of live entities, not a raw text box
2. `routing_live` receivers renders a `uri_picker` `:multi` tag-input
   (chips + autocomplete) over entities + sessions
3. `workspace_detail` add-member uses the `:single` picker
4. Clicking the header search bar OR pressing ⌘K opens the CmdK modal
5. Typing "sessions" → a `:nav` result → Enter → navigates to /sessions
6. Typing an agent name → an `:entity` result → navigates to its page
7. JSON-combinator advanced mode unchanged (still a textarea)
8. `/sessions` right sidebar shows ONE unified member list (avatars);
   no separate "Floating Agents" section; an Invite button opens a
   modal (add-existing picker + create-new-agent link)

**Architecture / tiering (dependency-boundary tests)**
9. `uri_picker/1` is a **Tier-2** `ezagent_domain_ui` component — no
   `KindRegistry`/`Router`/LiveView imports. (`primitives.ex` is
   Tier-2; Tier-1 is `ezagent_core`, which holds no UI code.)
10. `UriOptions` is the ONLY registry-facing helper in this feature;
    it depends on `ezagent_core` + `ezagent_domain_identity` only.
11. `CommandSource.search/2` is a **pure function over injected
    candidates** — it has NO `EzagentWeb.Router` and NO `KindRegistry`
    dependency. Nav routes reach it only via the `ezagent_web`
    `on_mount` assign. (Add a test asserting `CommandSource`'s module
    deps exclude `EzagentWeb.*` and `Ezagent.KindRegistry`.)
12. No new "registry" module is added — `CommandSource` registers
    nothing; `command_routes/0` lives in `ezagent_web`.

**Tenant isolation (Codex rev 4 — the read path)**
13. `UriOptions.entities(non_system_user, other_workspace_uri)`
    returns `[]`; a system member gets the full list. (Invariant
    test — §1.3.)
14. Every converted picker form revalidates submitted URIs
    server-side (§1.6) — a hand-tampered hidden input with an
    out-of-workspace URI is rejected with a flash, never dispatched.
15. The member-panel Invite handler dispatches `chat.join` as `:call`
    and surfaces `:unauthorized` / `:cross_workspace_denied` as
    distinct flashes — no silent `:cast` drop (§2C.4).

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
