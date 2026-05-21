# Domain.Pty Architecture — Promote PTY to Domain layer

> **Status**: DRAFT — 2026-05-21. Author: Claude (V1 acceptance phase
> per Allen Feishu 2026-05-21 17:16, "Domain.Pty 提供统一 terminal UI
> page 这个需要讨论"). Awaiting Allen review before implementation.

## 0. Why

Allen's V1 acceptance question (Feishu 17:16):

> 这样想起来，其实应该有一个独立的页面（类似admin setting那样）用于
> 提供Pty terminal界面，且这个界面应该是Domain.Pty提供的，目前有吗？
> 还是这是cc plugin自己实现的？其它使用了pty功能的agent（包括使用pty
> 执行或者erlexec执行的程序，echo agent等）也应该免费获得打开terminal
> 查看的能力，请audit并规划如何加入

Today PTY is 100% owned by `EzagentPluginCc`:
- `Ezagent.PluginCc.PtyServer` — the GenServer wrapping `:exec.run/2` (erlexec)
- `Ezagent.Behavior.Pty` — `:write` action Behavior on Agent Kind
- `EzagentPluginCc.Views.PtyView` — xterm.js Session View
- `EzagentPluginCc.PtyServerSupervisor` + `PtyServerRegistry`

Result: any future plugin that wants local PTY (an echo agent that
runs `bash`, a curl-runner agent for testing scripts, a generic
"shell agent") would have to either:

1. Re-implement the whole erlexec wrapper + xterm.js view +
   supervision tree, OR
2. Take a dependency on `ezagent_plugin_cc` (violating plugin
   isolation per `feedback_north_star_plugin_isolation`)

**Allen's V2 macro draft** already named the right home —
`Ezagent.Domain.Pty.PtyServer` (see
`docs/futures/v2-feedback-log.md` "V2 macro charter"). This SPEC
promotes PTY out of cc plugin into Domain layer NOW so V1 already
benefits (echo agents get terminal-viewing for free) AND V2 macro
work doesn't have to relocate code mid-stream.

## 1. Goals

1. **Promote PTY runtime** (PtyServer + Supervisor + Registry +
   Behavior) from `ezagent_plugin_cc` to a new `ezagent_domain_pty`
   app at Domain tier (Tier-2 per ezagent-developer skill).
2. **Promote PTY UI** — terminal view + xterm.js hook + dedicated
   `/terminal/:agent_uri` page — to `ezagent_domain_ui` (Tier-2) so
   any LV can embed it.
3. **Cross-flavor opt-in** — any Agent Kind whose template
   `spawns_with: [Ezagent.Domain.Pty.PtyServer]` automatically gets:
   - PTY process at agent boot
   - Terminal view in the Sessions page's view-switcher
   - Per-agent `/terminal/:agent_uri` standalone page
   - `Ezagent.Domain.Agent.lifecycle_status/1` reports PTY phase
4. **cc plugin shrinks** to ONLY its cc-specific surfaces:
   - `EzagentPluginCc.Channel` (claude TUI WS bridge)
   - `EzagentPluginCc.McpConfigWriter` (mints `.mcp.json` for spawned claude)
   - `EzagentPluginCc.TokenStore` (CC bridge auth)
   - `Ezagent.PluginCc.Template.CcAgent` (template class — uses
     Domain.Pty + cc-specific things)

## 2. Non-Goals

- **No new top-level URI scheme** for PTY (invariant 11). PTY is a
  sidecar process associated with an Agent URI; it doesn't get a
  scheme of its own. `entity://agent/<flavor>/<workspace>/<name>?action=pty.write`
  is the dispatch contract (already exists per SPEC v2 §5.7).
- **No abstraction over PTY backend** — `Ezagent.Domain.Pty.PtyServer`
  hard-codes erlexec. If we later want native `Port.open(:spawn)` or
  remote PTY proxy, that's a V2+ pluggable adapter pattern.
- **No backward-compat shim** — once moved, references to
  `Ezagent.PluginCc.PtyServer` raise compile errors. Plugins that
  imported it must update to `Ezagent.Domain.Pty.PtyServer`.
- **No new claude-specific features**. cc plugin keeps full ownership
  of MCP config, channel bridge, token store — those are CC-specific
  (claude TUI ↔ ezagent WS connection), not generic PTY.
- **No V2 macro yet** (per the v2-feedback-log charter). The macro
  consumes Domain.Pty as a step; this SPEC ships Domain.Pty so V2
  has something to wrap.

## 3. Module relocation map

### 3.1 New app: `apps/ezagent_domain_pty/`

Standard umbrella app layout. Deps: `:ezagent_core` only (per Tier-2
rules; no plugin deps, no other domain deps).

```
apps/ezagent_domain_pty/
├── lib/
│   ├── ezagent_domain_pty.ex                  # facade
│   ├── ezagent_domain_pty/
│   │   ├── application.ex                     # supervisor + registry
│   │   ├── server.ex                          # the PtyServer (moved + renamed)
│   │   ├── supervisor.ex                      # DynamicSupervisor for PTY processes
│   │   └── registry.ex                        # :via Registry by agent_uri
│   ├── ezagent/
│   │   ├── behavior/pty.ex                    # `:write` Behavior (moved verbatim)
│   │   └── domain/pty.ex                      # facade: start/2, stop/1, status/1
└── test/
    └── ... (moved tests)
```

Module renames:
- `Ezagent.PluginCc.PtyServer` → `Ezagent.Domain.Pty.Server`
- `EzagentPluginCc.PtyServerSupervisor` → `EzagentDomainPty.Supervisor`
- `EzagentPluginCc.PtyServerRegistry` → `EzagentDomainPty.Registry`
- `Ezagent.Behavior.Pty` → unchanged (already a behavior on Agent Kind; just moves apps)

### 3.2 New UI: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/`

Terminal view + xterm.js hook moved to Domain UI tier:

```
apps/ezagent_domain_ui/lib/ezagent_domain_ui/
├── pty/
│   ├── terminal_view.ex                       # SessionView (renamed from PtyView)
│   └── terminal.ex                            # the Phoenix.Component
└── ...

apps/ezagent_web/assets/js/hooks/
└── pty_terminal.js                            # xterm.js hook (moved verbatim)
```

`EzagentDomainUi.Pty.TerminalView` registers as a SessionView (any
session with an Agent member whose template declares PTY).

### 3.3 New LV: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/terminal_live.ex`

The standalone "Terminal page" Allen requested. URL:
`/identities/agents/:uri/terminal`.

**Path shape note (Allen review 2026-05-21 15:13)**: original draft
used `/terminal/:agent_uri` (verb-first). That violated the
codebase's resource-first URL convention. Phase 8b actually had
`/identities/agents/:uri/terminal` before retiring it for the
SessionView-only pattern; V1 brings the standalone page back at the
same URL shape. See **§13** for the LV-URL ↔ URI-system mapping
convention this follows.

```elixir
defmodule EzagentPluginLiveview.TerminalLive do
  @moduledoc """
  Standalone PTY terminal page for any agent whose template declares
  PTY in `spawns_with`. URL: /identities/agents/<encoded-agent-uri>/terminal.

  Renders inside IdeShell (full workspace surface) so the operator
  has navigation context. The terminal occupies the main window;
  Members + Floating Agents side panels remain.

  Per Ezagent.Domain.Agent.lifecycle_status/1:
  - phase: :alive + has PTY detail → render terminal
  - phase: :registered (no PtyServer alive) → render "Not yet started" CTA
  - phase: :not_found → 404-ish "Agent doesn't exist"
  """
  ...
end
```

Router addition (sibling to existing `/identities/agents/:uri/caps`
and `/:uri/api-keys`):
```elixir
live "/identities/agents/:uri/terminal", TerminalLive
```

### 3.4 cc plugin shrinks

`apps/ezagent_plugin_cc/` after migration keeps:
- `lib/ezagent_plugin_cc/application.ex` — boots only Channel + Bridge + TokenStore + Socket
- `lib/ezagent_plugin_cc/channel.ex` — Phoenix Channel for claude TUI WS
- `lib/ezagent_plugin_cc/bridge_registry.ex` — agent_uri → channel pid binding (CC-specific)
- `lib/ezagent_plugin_cc/mcp_config_writer.ex` — `.mcp.json` generator for spawned claude
- `lib/ezagent_plugin_cc/token_store.ex` — CC bridge auth tokens
- `lib/ezagent_plugin_cc/socket.ex` — WS endpoint
- `lib/ezagent/template/cc_agent.ex` — template class; `spawns_with: [Ezagent.Domain.Pty.Server]`
  + cc-specific env (CLAUDE_HOME, MCP config path, etc.)

Deletes: `lib/ezagent/plugin_cc/pty_server.ex`, `lib/ezagent/plugin_cc/views/pty_view.ex`,
`lib/ezagent/behavior/pty.ex` (all moved).

## 4. Cross-flavor opt-in pattern

Any template that wants its agent backed by a local PTY declares it
in `spawns_with`:

```elixir
defmodule EzagentPluginEcho.Template.EchoAgent do
  @moduledoc """
  Echo agent template — optionally backed by local PTY for shell-like
  echo testing. When `with_pty: true`, the agent template instantiate
  starts a PtyServer running `/bin/echo` or `/bin/bash`.
  """
  @behaviour Ezagent.Kind.Template

  def template_name, do: "echo.agent"

  def instantiate(_name, %{"agent_uri" => uri_str, "with_pty" => true} = tmpl, ws_uri) do
    agent_uri = URI.parse(uri_str)
    # 1. Spawn the Agent Kind (already done elsewhere)
    {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, ...})
    # 2. Spawn the PtyServer sidecar
    {:ok, _} = Ezagent.Domain.Pty.start(agent_uri, %{
      cmd: Map.get(tmpl, "cmd", "/bin/bash -i"),
      cwd: Map.fetch!(tmpl, "cwd"),
      env: Map.get(tmpl, "env", %{})
    })
    {:ok, [agent_uri]}
  end

  def instantiate(_name, %{"agent_uri" => uri_str} = _tmpl, _ws_uri) do
    # No PTY — just the agent Kind. Terminal-view doesn't apply.
    agent_uri = URI.parse(uri_str)
    {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, ...})
    {:ok, [agent_uri]}
  end
end
```

The `with_pty: true` template option is generic — any plugin sets
this and gets PTY for free.

`Ezagent.Domain.Agent.lifecycle_status/1` (Phase 9 V1) already
delegates by flavor; extended to query `Ezagent.Domain.Pty.alive?/1`
when the template has `spawns_with: [...Pty.Server]`.

## 5. UI surface

### 5.1 Terminal as Session view (existing, moved)

The view-switcher on `/sessions` shows "Terminal" tab when any
session member is an Agent backed by PTY. After migration:

- `EzagentDomainUi.Pty.TerminalView` is the SessionView impl
- Detection: query the Session's members, for each Agent URI call
  `Ezagent.Domain.Pty.alive?/1`; if any returns true, Terminal view
  is offered
- Rendering: pick the first PTY-backed agent as the default; user
  can switch between PTY-backed agents via a small dropdown above
  the terminal

### 5.2 Standalone Terminal page (new)

URL: `/identities/agents/:uri/terminal` (URL-encoded entity URI in
`:uri` path segment — same convention as the sibling
`/identities/agents/:uri/caps` and `/:uri/api-keys` routes).

Use case (Allen's #3 — agent detail page):
- Today `/identities/agents/:uri` "Open terminal" button jumps to
  /sessions and switches to PTY view — kludgy
- After this SPEC: button → `/identities/agents/:uri/terminal`
- Standalone page = full focus on terminal; no chat distraction

Rendered inside `IdeShell` (workspace surface) so nav + sidebars
still work; main window = the terminal.

### 5.3 Inline terminal on agent detail (Allen's #3)

`/identities/agents/:uri` page CURRENTLY has an "Open terminal (in
Sessions)" button. After this SPEC:

- For agents WITH PTY: detail page renders the terminal INLINE
  (collapsed by default; "Open terminal" button expands it). No jump.
- For agents WITHOUT PTY (echo without with_pty, curl, etc.):
  button absent.

The component reused is `EzagentDomainUi.Pty.Terminal` — same xterm.js
hook, just dropped in a different shell.

## 6. Lifecycle integration

`Ezagent.Domain.Agent.lifecycle_status/1` (PR #175 V1 fix) returns
`%{phase, flavor, detail}`. After this SPEC:

```elixir
def lifecycle_status(%URI{} = agent_uri) do
  kind_alive? = case Ezagent.KindRegistry.lookup(agent_uri) do
    {:ok, _pid} -> true
    :error -> false
  end

  pty_alive? = Ezagent.Domain.Pty.alive?(agent_uri)

  phase = cond do
    not kind_alive? -> :not_found
    pty_alive? -> :alive
    template_declares_pty?(agent_uri) -> :registered   # Kind alive but PtyServer didn't start
    true -> :alive                                      # No PTY needed, Kind alive is enough
  end

  %{
    phase: phase,
    flavor: flavor_of(agent_uri),
    detail: pty_alive? && Ezagent.Domain.Pty.status(agent_uri) || %{}
  }
end
```

The Q3 "unified lifecycle UI" is now COMPLETE — same status format
for cc / echo-with-pty / curl-without-pty / future flavors. `AgentDetailLive`
already uses this facade (V1 fix #175).

## 7. Capability shape

`Ezagent.Behavior.Pty` cap unchanged from current:
- `kind: :agent`
- `behavior: Ezagent.Behavior.Pty`
- `instance: entity://agent/<flavor>/<workspace>/<name>` or `:any`

Phase 9 PR-3 added `workspace_uri` dimension — also applies. Admin's
all-`:any` cap passes.

The Behavior module moves apps but the cap shape is portable —
existing grants in DB still work (modules are referenced as strings
in `caps_json` → `Elixir.Ezagent.Behavior.Pty` — same atom name post-move).

## 8. Migration plan

Per `feedback_let_it_crash_no_workarounds`: no shims.

### 8.1 PR sequence (4 PRs)

| # | Title | Files | LOC est |
|---|-------|-------|---------|
| A | `ezagent_domain_pty` app creation + Server/Supervisor/Registry move | 8 (mix.exs, new app structure) | 600 |
| B | `Ezagent.Behavior.Pty` move + caller updates + grep for `EzagentPluginCc.PtyServer` references | 12 | 400 |
| C | `EzagentDomainUi.Pty.TerminalView` move + xterm.js hook relocation | 6 | 300 |
| D | `TerminalLive` standalone page + AgentDetailLive inline terminal + /terminal/:agent_uri route + cc plugin shrink | 10 | 500 |

After D: cc plugin is ~40% smaller (PtyServer + supervisor + registry + view + behavior gone). `ezagent_domain_pty` is the canonical home.

### 8.2 Per-PR checks

- **Compile gate**: each PR must compile cleanly + tests pass
- **No backward-compat aliases** (`alias Ezagent.PluginCc.PtyServer, as: ...`) — fix call sites
- **Invariant test**: `apps/ezagent_core/test/invariants/no_pty_in_plugin_cc_test.exs` — grep gate post-PR-D asserts `Ezagent.PluginCc.PtyServer` references gone from lib code

### 8.3 DB / runtime compat

- Existing `kind_snapshots` rows with `kind_type: "agent"` unchanged
- `cc.agent` template's stored `session_templates` JSON unchanged
  (still has `agent_uri` + `cwd`); cc.agent template's instantiate
  now calls `Ezagent.Domain.Pty.start/2` instead of inline
- No DB migration
- No restart-data-loss

## 9. Audit — current PTY/erlexec users

Per Allen's audit ask:

| Module | Uses PTY? | Status | After SPEC |
|---|---|---|---|
| `Ezagent.PluginCc.PtyServer` | YES (the canonical impl) | moves to `Ezagent.Domain.Pty.Server` | gone from plugin_cc |
| `EzagentPluginCc.Channel` | NO (handles WS only) | stays | unchanged |
| `EzagentPluginEcho` | NO today | could opt-in via `with_pty: true` in echo.agent template | option exists; not enabled by default |
| `EzagentPluginCurlAgent` | NO today | could opt-in for testing scripts | option exists |
| Future plugins | — | use `spawns_with: [Ezagent.Domain.Pty.Server]` | uniform pattern |

erlexec is the ONLY PTY backend in scope (no native `Port.open(:spawn)`
because claude TUI specifically needs a real PTY).

## 10. Decisions (Allen 2026-05-21 review)

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | App name | **`ezagent_domain_pty`** | Matches `Ezagent.Domain.Pty` module namespace; "terminal" is UI, PTY is the runtime |
| 2 | TerminalLive route | **`/identities/agents/:uri/terminal`** | Original draft `/terminal/:agent_uri` was verb-first — violates the codebase's resource-first URL convention. The chosen path is the same shape Phase 8b had before retiring it, and matches sibling `/identities/agents/:uri/caps` + `/:uri/api-keys`. See §13 for the LV-URL ↔ URI mapping convention |
| 3 | Echo PTY enablement | **AgentNewLive "with PTY" checkbox** for echo flavor (consistent with cc which requires a cwd field) — operator self-service, not admin-only template config |
| 4 | Activity Bar inclusion | **NO** — terminal is a sub-view of an agent, not a top-level activity. Reaching via `/identities/agents/:uri/terminal` (or the inline expander on agent detail page) is structurally correct; Activity Bar stays 4 items (Sessions / Identities / Routing / Plugins) |

## 11. Verification checklist

After all 4 PRs land:
1. ✅ `grep -r "EzagentPluginCc.PtyServer" apps/` returns empty
   (modules moved, no aliases left behind)
2. ✅ `Ezagent.Domain.Pty.start(agent_uri, params)` starts a
   PtyServer; `Ezagent.Domain.Pty.alive?(agent_uri)` returns true
3. ✅ cc.agent template's `instantiate/3` calls
   `Ezagent.Domain.Pty.start/2`
4. ✅ `/terminal/<encoded-cc-agent-uri>` renders xterm.js terminal
5. ✅ `/identities/agents/<cc-agent-uri>` shows inline terminal
   button (expandable)
6. ✅ AgentNewLive for echo flavor offers "with PTY" checkbox; when
   checked, echo agent gets a `/bin/bash` PtyServer
7. ✅ `Ezagent.Domain.Agent.lifecycle_status/1` reports
   `phase: :alive` for cc agents AND echo-with-pty agents uniformly
8. ✅ Invariant test `no_pty_in_plugin_cc_test.exs` passes

## 13. LV URL ↔ URI system mapping convention

Allen Feishu 2026-05-21 15:17: "`/identities/agents/:uri/terminal`
这里是 LiveView 的 URL，还是我们的 URI 系统？现在 LiveView URL 和
URI 的关系是什么？"

**Three layers** with a clear mapping:

| Layer | Example | Purpose |
|---|---|---|
| Browser URL | `/identities/agents/entity%3A%2F%2Fagent%2Fdefault%2Fcc_demo/terminal` | Bookmark / nav / share |
| LV `:uri` param | `entity://agent/default/cc_demo` | Bridge (URL-decoded automatically by Phoenix Router) |
| Internal URI system | `%URI{scheme: "entity", host: "agent", path: "/default/cc_demo"}` | dispatch / cap matching / KindRegistry lookup |

**Mount-time bridge** (the pattern used by `AgentDetailLive`,
`EntityCapsLive`, future `TerminalLive`):

```elixir
def mount(%{"uri" => encoded_uri}, _session, socket) do
  decoded = URI.decode_www_form(encoded_uri)

  case URI.new(decoded) do
    {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> _name} = agent_uri} ->
      # use agent_uri throughout the LV: dispatch, status, etc.
      {:ok, assign(socket, :agent_uri, agent_uri)}

    _ ->
      {:ok, socket |> put_flash(:error, "Invalid agent URI") |> push_navigate(to: ~p"/identities")}
  end
end
```

**The bridge IS the architectural seam.** Above the seam (browser /
URL), everything is HTTP-layer addressing — strings, URL-encoding,
bookmarkable paths. Below the seam (LV / dispatch), everything is
`%URI{}` structs flowing through Ezagent's internal addressing
contracts (caps, KindRegistry, Behavior dispatch, persistence).

**Conventions ezagent enforces**:

1. **LV routes ALWAYS use `:uri` as the path segment name** for
   entity URIs (consistent across all `/identities/agents/:uri/*`
   and `/identities/users/:uri/*` routes)
2. **`:uri` value is the URL-encoded canonical entity URI string**
   — NOT a database ID, NOT a slug, NOT a short identifier
3. **LV mount/3 ALWAYS URL-decodes + URI.new() + pattern-matches**
   on the expected scheme/host shape; invalid → flash + redirect
4. **Once inside the LV, only the `%URI{}` struct is used** — the
   encoded string never leaks past mount
5. **Hyperlinks construct the URL via URI.encode_www_form(URI.to_string(uri))**
   — never hand-construct path strings

**Trade-off acknowledged** (won't fix in V1):
- Browser URLs are ugly (`entity%3A%2F%2Fagent...`) due to URL-encoding
- Any future URI scheme change (like Phase 9's 2→3 segment migration)
  breaks bookmarks
- Alternative "flat path" mapping (`/identities/agents/default/cc_demo`
  → reconstructed `entity://agent/default/cc_demo`) would be cleaner
  but requires every existing link-builder to change. Defer to V2
  consideration.

**Why surface this convention now**: V1 Domain.Pty adds the third
`/identities/agents/:uri/*` sub-view route. Without writing this
section, future contributors might reinvent the bridge inconsistently
(e.g., use a different param name, or decode in a helper, or
hand-construct paths). Documenting the seam makes the pattern
copyable.

**Reference implementations** in main:
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex` — `parse_agent_uri/1` pattern
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex` — same pattern for `/identities/agents/:uri/caps`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/user_api_keys_live.ex` — same pattern for users

## 12. Out of scope (V2+)

- Native `Port.open(:spawn)` backend (alternative to erlexec)
- Remote PTY proxy (PTY runs on a different machine; xterm.js
  connects via tunnel)
- PTY recording / playback (asciinema-style replay)
- Per-PTY resource limits (CPU / mem quotas)
- PTY transcript persistence (today everything is in-memory; if
  PtyServer dies, transcript is lost)
- V2 macro `spawn_pipeline` integration — this SPEC ships the
  primitive; macro work is V2 separately

---

## Implementation pointer

After this SPEC is approved, dispatch 4 PRs via
`superpowers:subagent-driven-development`. Each subagent loads
`Skill: ezagent-developer` (especially Tier-2 rules + UI Contract)
+ `Skill: elixir-phoenix-helper`.

Branch pattern: `feat/domain-pty-pr-<N>-<topic>`. Admin-merge per
the standard ezagent42/esr pattern.

Bilingual `.zh_cn.md` parallel doc to be written before subagent
dispatch (per `feedback_bilingual_docs_convention`).
