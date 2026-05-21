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

The standalone "Terminal page" Allen requested. URL: `/terminal/:agent_uri`.

```elixir
defmodule EzagentPluginLiveview.TerminalLive do
  @moduledoc """
  Standalone PTY terminal page for any agent whose template declares
  PTY in `spawns_with`. URL: /terminal/<encoded-agent-uri>.

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

Router addition:
```elixir
live "/terminal/:agent_uri", TerminalLive
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

URL: `/terminal/:agent_uri` (URL-encoded agent URI).

Use case (Allen's #3 — agent detail page):
- Today `/identities/agents/:uri` "Open terminal" button jumps to
  /sessions and switches to PTY view — kludgy
- After this SPEC: button → `/terminal/:agent_uri` directly
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

## 10. Open questions for Allen

1. **App name**: `ezagent_domain_pty` or `ezagent_domain_terminal`?
   I prefer **`ezagent_domain_pty`** (matches `Ezagent.Domain.Pty`
   module namespace; "terminal" is UI; PTY is the runtime).
2. **TerminalLive route shape**: `/terminal/:agent_uri` OR
   `/agents/:agent_uri/terminal`? I prefer the former for brevity
   AND because "terminal" is a top-level activity (next to /sessions,
   /workspaces, /identities). Could add to Activity Bar if you want.
3. **Auto-enable PTY for echo agent?** Today echo agents have no
   PTY. With this SPEC, echo template gets `with_pty: false` default
   but operator can flip. Should the AgentNewLive form expose a
   "with PTY" checkbox for echo flavor? Or admin-only template
   config? I lean operator-checkbox (consistent with cc which
   requires a cwd).
4. **Should /terminal/:agent_uri appear in Activity Bar?** Current
   bar: Sessions / Identities / Routing / Plugins. Adding Terminal
   makes 5 items. Could be useful as a quick-access surface for
   power users. Or leave it out of activity bar and only reach via
   /identities/agents/:uri detail page.

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
