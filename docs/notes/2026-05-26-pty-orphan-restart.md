# PTY/Python subprocess orphan-on-restart fix — 2026-05-26

## Problem

cc and np agents have a two-layer process model:

1. **Agent Kind** (Elixir GenServer) — OTP-supervised; recovers from
   `kind_snapshots` on phx restart via `Ezagent.Kind.Snapshot.load_or_init/3`.
2. **OS subprocess** (cc: claude TUI under `Ezagent.Domain.Pty.Server`;
   np: Python interpreter under `Ezagent.Domain.Python.Server`) — owned
   by `:exec.run/2` (erlexec). NOT OTP-supervised across BEAM restarts.

When the BEAM dies, erlexec's port-death cleanup normally reaps the OS
child via SIGTERM. But a **brutal BEAM kill** (`SIGKILL`, panic, SEGV)
skips that cleanup — the OS-level claude / Python process survives
attached to its dead PTY.

After phx restart, two failure modes:

### Mode A — orphan reconnects, demand-spawns Kind, ESR can't manage it

1. Orphan claude reconnects to ESR via the cc bridge Phoenix.Channel.
2. The Channel join calls `Ezagent.SpawnRegistry.spawn(agent_uri)` —
   demand-spawning the Agent Kind via the chat plugin's entity://
   spawn fn → `Ezagent.Kind.spawn(Agent, %{uri: uri})`.
3. Later, `Workspace.Loader.load_all/0` walks each workspace's
   `session_templates` and fires `cc.agent.instantiate/3`.
4. `instantiate/3` sees `agent_kind_alive?(uri) == true` and returns
   immediately (codex round-8 — "refuse to adopt foreign Kind").
5. **PtyServer never spawned**. Agent Kind alive but no PTY → operator's
   LV terminal page is dead (can't write input, no output stream).
   Meanwhile the OS orphan claude keeps talking to its old bridge
   channel.

### Mode B — orphan stays running silently, blocks fresh spawn

1. Orphan claude is alive but hasn't reconnected (e.g. its agent token
   no longer matches a known bridge).
2. `Workspace.Loader` fires `cc.agent.instantiate/3` cleanly, starts a
   new PtyServer + claude.
3. Now TWO OS claudes are running for the same agent URI. Resource
   contention; per-instance MCP config (`.mcp.json`) gets clobbered.

## Fix (Option A per Allen 2026-05-26)

Two independent layers:

### Layer 1 — post_init respawn hook (catches Mode A)

`Ezagent.Behavior.Sandbox` (the plugin-agnostic Behavior on every cc
Agent Kind) now exports `post_init/2` + `handle_continue/3`. On boot:

1. Sandbox slice (rehydrated from snapshot) carries `template_class`
   + `respawn_template_data`.
2. `post_init/2` queues a `{:continue, :ensure_subprocess}` if both
   are populated.
3. `handle_continue/3` calls the plugin's
   `Kind.Template.ensure_subprocess_alive(agent_uri, respawn_data)`
   optional callback (new in this PR).
4. The cc Template Class implements the callback: checks
   `Ezagent.Domain.Pty.alive?/1`; if absent, re-runs
   `ensure_pty_server/3` with the persisted template data.

For np: `Ezagent.Behavior.NpAgent` (the plugin-specific Behavior on
`Ezagent.Entity.NpAgent`) gets the same post_init hook directly —
NpAgent Kind doesn't use Sandbox (`:ephemeral` persistence, no
config_dir). The callback dispatch is symmetric: NpAgent's slice
carries `cwd`; on boot, `handle_continue/3` calls
`Ezagent.PluginNp.Template.NpAgent.ensure_subprocess_alive/2`.

### Layer 2 — orphan reaper (catches Mode B + makes Mode A unreachable)

Each plugin gets its own `OrphanReaper` module called from `after_boot/0`
BEFORE `Workspace.Loader.load_all/0` (cc) / template instantiation (np).

The reapers identify cc/np-managed OS subprocesses by:

1. **Argv signature** — cc: `--dangerously-load-development-channels
   server:esr-bridge`; np: `np_compute_server.py`.
2. **Env var** — `EZAGENT_AGENT_URI=<uri>` (cc PtyServer already set
   this; the np Template Class now also sets it via Domain.Python.Spec
   `env` field).
3. **URI shape gate** — cc: `entity://agent/<ws>/cc_*`; np:
   `entity://agent/<ws>/np_*`.
4. **Registry check** — `Ezagent.Domain.Pty.alive?/1` (cc) /
   `Ezagent.Domain.Python.alive?/1` (np). If the URI has no live in-BEAM
   server, it's an orphan.

Each orphan gets a single `kill -TERM`. We NEVER `pkill -9` broadly
(memory `feedback_no_pkill_tmux_default_socket`).

In `:test` env the reaper is OFF by default (every test starts a
fresh BEAM with empty Pty/Python registries, so every leftover OS
process looks reapable — would kill orphans an e2e wants to inspect).
Opt-in via `config :ezagent_plugin_cc, reap_orphans_on_boot: true`.

## Files changed

### Core
- `apps/ezagent_core/lib/ezagent/kind/template.ex` — added
  `ensure_subprocess_alive/2` optional callback to the
  `Ezagent.Kind.Template` behaviour.
- `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex` — extended slice
  to carry `respawn_template_data`; added `post_init/2` +
  `handle_continue/3`.
- `apps/ezagent_core/test/ezagent/behavior/sandbox_test.exs` — updated
  slice-shape assertions; added post_init / handle_continue tests.

### Chat domain
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` — threaded
  `respawn_template_data` from `instantiate_meta` through
  `record_sandbox_state/3` into the `sandbox.write_path` dispatch.

### cc plugin
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — added
  `respawn_template_data: tmpl_with_dir` to instantiate's meta
  return; implemented `ensure_subprocess_alive/2`.
- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/orphan_reaper.ex` —
  NEW: parses `ps` output, identifies orphans, SIGTERMs.
- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex` — calls
  the reaper from `after_boot/0` (gated on `Mix.env() != :test`).
- `apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_test.exs` —
  added `ensure_subprocess_alive/2` unit tests.
- `apps/ezagent_plugin_cc/test/orphan_reaper_test.exs` — NEW: reaper
  unit tests.

### np plugin
- `apps/ezagent_plugin_np/lib/ezagent/behavior/np_agent.ex` — extended
  slice to carry `cwd`; added `post_init/2` + `handle_continue/3`.
- `apps/ezagent_plugin_np/lib/ezagent/template/np_agent.ex` — threaded
  `cwd` into init_args; added `EZAGENT_AGENT_URI` to the Python
  subprocess env; implemented `ensure_subprocess_alive/2`.
- `apps/ezagent_plugin_np/lib/ezagent_plugin_np/orphan_reaper.ex` —
  NEW: sibling of cc's reaper.
- `apps/ezagent_plugin_np/lib/ezagent_plugin_np/application.ex` —
  added `after_boot/0` calling the reaper.

## Three-tier rules preserved

- Tier 1 (core): `Ezagent.Behavior.Sandbox` + the new
  `Ezagent.Kind.Template.ensure_subprocess_alive/2` callback. Core
  knows NOTHING about PTY / Python — it only routes through the
  optional callback.
- Tier 2 (domain): `Ezagent.Domain.Pty.alive?/1` and
  `Ezagent.Domain.Python.alive?/1` are the registry-check primitives.
  Plugin reapers consume them.
- Tier 3 (plugin): cc + np implement the callback + own their orphan
  reapers. Each reaper knows its plugin's argv signature.

No new cross-tier coupling. No new plugin-to-plugin coupling. The
Sandbox behaviour-extension is plugin-agnostic (only opts in via the
optional `function_exported?/3` probe).

## Let-it-crash discipline

Per `feedback_let_it_crash_no_workarounds`:
- The reaper itself is best-effort: a `ps` failure or `kill` failure
  is logged but does NOT crash the plugin Application start. A missed
  orphan re-surfaces on next phx restart.
- Round-2 (codex finding #3): the post_init failure path uses
  log + telemetry + `:ignore` (DEGRADED state) instead of raise. See
  "Round-2 fixes" below.

## Round-2 fixes (codex adversarial-review)

Codex reviewed PR #385 (round 1) and produced 4 findings (3 HIGH + 1
MEDIUM). All addressed:

### Finding #1 (HIGH) — cc demand-spawn race window

**Problem**: When the chat router demand-spawns the cc Agent Kind via
`SpawnRegistry.spawn`, the Sandbox slice has no `template_class` /
`respawn_template_data`, so `post_init/2` returns `:ok` (no respawn
queued). When `Workspace.Loader.load_all/0` later runs
`cc.agent.instantiate/3`, codex round-8's "refuse to adopt foreign
Kind" short-circuit fires and the fresh PtyServer is never spawned.

**Fix**: `instantiate/3`'s `:already_started` branch now checks a
**workspace-segment ownership gate** (`owns_this_agent?/2`): if the
agent URI's workspace segment matches `workspace_uri`, this IS our
template's agent (Workspace.Loader path) → bring up the PTY via the
new `ensure_subprocess_alive/2` callback. If the segments don't match,
the codex round-8 invariant holds — refuse the PTY spawn (cross-
workspace adoption is rejected as before).

### Finding #2 (HIGH) — multi-BEAM safety (friendly-fire)

**Problem**: The orphan reaper identified orphans by "URI absent from
this BEAM's `Pty.alive?/1` registry". A parallel BEAM under the same
OS user can have a legitimate live claude whose URI is naturally
absent from THIS BEAM's registry → reaper would SIGTERM B's live
process.

**Fix**: Each spawned subprocess now also carries
`EZAGENT_DEPLOYMENT_ID` env var = `Ezagent.DeploymentId.deployment_id/0`
(composed of `node()|cwd_at_load`). The reaper refuses to kill any
process whose deployment_id differs from `Ezagent.DeploymentId.deployment_id/0`
of the current BEAM. Two `iex -S mix phx.server` invocations from
the SAME source tree get the same deployment_id (legitimate same-
deployment reaping). Two parallel worktrees get different deployment_ids
(cross-deployment friendly-fire prevented).

### Finding #3 (HIGH) — tight restart loop on persistent failure

**Problem**: My round-1 used `raise` in `Sandbox.handle_continue/3`
on `{:error, _}` from the callback. This triggers `Kind.Server`
GenServer crash → `EzagentDomainChat.AgentSupervisor` restart with
default DynamicSupervisor intensity (`max_restarts: 3, max_seconds:
5`). A persistent failure (claude removed from PATH after a successful
spawn) burns through 3 restarts in milliseconds → AgentSupervisor
itself crashes → cascade kills SIBLING agents.

**Fix**: Replace `raise` with `Logger.error + :telemetry.execute(
[:ezagent, :sandbox, :subprocess_unhealthy], ...) + :ignore`. The
Kind comes up `:ready` in DEGRADED state — alive but no subprocess.
This is NOT a silent fallback: the telemetry event surfaces in the
admin LV health panel + logs scream the failure. Operator clicks
Restart manually via existing UI.

The correct structural fix (per-agent supervisor with isolated
intensity) is OUT OF SCOPE for this PR — tracked as follow-up.

### Finding #4 (MEDIUM) — np `ensure_python_alive` swallowed errors

**Problem**: `ensure_python_alive/2` discarded the result of
`start_python/2` via `_ = start_python(...)` and returned `:ok`
unconditionally. A failed Python spawn on the adopted-Kind branch
left the agent looking alive but with no working subprocess
(failures only surfaced on first user-traffic dispatch).

**Fix**: `ensure_python_alive/2` now propagates the `start_python/2`
result. The caller (`instantiate/3` adopted-Kind branch) logs the
error + returns it to the chat domain (which surfaces it).

### Round-2 file additions

- `apps/ezagent_core/lib/ezagent/deployment_id.ex` — NEW: deployment
  identity helper.

## Known limitations + follow-ups

- **Persistent post_init failure → degraded state** (codex finding
  #3): the Kind stays alive without its subprocess until operator
  manual Restart. A future PR should introduce per-agent supervision
  with isolated intensity so a transient failure auto-retries with
  backoff without cascading.
- **EZAGENT_DEPLOYMENT_ID rollout window** (codex finding #2): a
  process spawned by a pre-this-PR BEAM has NO deployment_id env
  var — the reaper refuses to kill those (fail closed). Operators
  upgrading from a pre-this-PR release MUST manually `pkill claude`
  before the first post-PR boot, OR ride out one cycle of "the
  reaper does nothing on first boot; orphans handled by manual
  cleanup".
