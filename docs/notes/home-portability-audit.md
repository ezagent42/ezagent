# EZAGENT_HOME portability audit — absolute paths persisted in DB / Kind slices

> Drives the `mix ezagent.home.backup` / `mix ezagent.home.restore` design.
> Task: **home portability (#120)**. Date: 2026-05-30.

## Question

If you copy a whole `$EZAGENT_HOME/$EZAGENT_PROFILE/` tree to another machine
or another path, what *persisted* state still points at the OLD absolute path
and would break the restored system?

## What the home actually contains

`Ezagent.Home` (`apps/ezagent_core/lib/ezagent/home.ex`) resolves
`$EZAGENT_HOME/$EZAGENT_PROFILE/` (default `~/.ezagent/default/`). Sub-trees
observed in the code (`grep Home.path`):

| Subdir | Producer | Persistent? | In backup? |
|---|---|---|---|
| `db/ezagent_core.db` (+ `-wal`/`-shm`) | Repo (config/dev.exs, runtime.exs) | **yes** — the source of truth | ✅ |
| `cc-agents/<ws>/<name>/` | `EzagentPluginCc...CcAgent.agent_config_dir/1` | **yes** — per-agent `.claude` config + creds + history | ✅ |
| `codex/<slug>/` | `EzagentPluginCodex...CodexAgent` (app-server sock + thread-id files) | partly — thread-id files persist; `.sock` is transient | ✅ (sock recreated) |
| `credentials/*.yaml` | `ezagent.home.init` + plugins | **yes** — secrets | ✅ |
| `snapshots/` | `Ezagent.Snapshot.Writer` (file dumps, debug) | yes | ✅ |
| `plugins/<p>/*.yaml` | per-plugin tunables (e.g. feishu initial bindings) | yes | ✅ |
| `uploads/` | LV admin + uploads controller | yes (user data) | ✅ |
| `inbox/feishu/` | feishu client downloads | yes (received files) | ✅ |
| `logs/` | python server etc. | **no** — ephemeral, rebuilt | ❌ excluded |
| `pty-pids/` | `Ezagent.Runtime.PidFile` | **no** — live PID tracking, stale on a new host | ❌ excluded |
| `runtime/cookie` | `Ezagent.Runtime` | **no** — node cookie, host-local | ❌ excluded |

**Kind snapshots are stored IN the DB**, not in `snapshots/`. The
`kind_snapshots` table holds `state_binary` = `:erlang.term_to_binary/1` of
each Kind's full slice map (`Ezagent.Ecto.KindSnapshot`). So "back up the
state" = "back up `db/ezagent_core.db`" + the on-disk config dirs the snapshots
*reference*.

## Absolute paths that are PERSISTED

Searched: all `{:set, ...}` slice writes carrying a path
(`grep '{:set,' | grep -i 'path\|dir\|file\|sock'`), every migration column
(`grep 'add :.*path|dir|file'`), and every `Home.path` consumer.

### 1. `Sandbox.config_dir_path` — **ABSOLUTE, persisted, breaks on move** ⚠️

`apps/ezagent_core/lib/ezagent/behavior/sandbox.ex`:
- Slice field documented `config_dir_path: nil | String.t() # absolute path`.
- `{:set, :config_dir_path, path}` (line 402) persists the value written by
  `:write_path`, which is `CcAgent.agent_config_dir/1` =
  `Path.join([Ezagent.Home.path("cc-agents"), workspace, name])` — i.e.
  `/Users/<u>/.ezagent/default/cc-agents/<ws>/<name>` **absolute**.
- On cold-load `activate/2` reads it back and feeds the subprocess respawn.
- **If the home moves, this points at the old (now-absent) path.** The cc
  process would get a stale `CLAUDE_CONFIG_DIR`.

### 2. `Sandbox.respawn_template_data` — **embeds the same absolute path** ⚠️

Same slice. The opaque plugin tmpl map for cc agents carries
`"agent_config_dir"` (and may carry the template's `"claude_config_dir"`),
both absolute, both under `cc-agents/...`. Threaded into the PTY env at
`activate/2`. Same staleness on move.

**Both #1 and #2 are buried inside the `term_to_binary` snapshot blob in the
DB**, so a textual `sed` on the `.db` file is unsafe — they must be rewritten
by decoding the term, rewriting the path string, re-encoding.

### Everything else: NOT a problem

- **Codex `app_server_socket` / `socket_path`** — derived fresh at `activate`
  from `Ezagent.Home.path("codex")` (`codex_agent.ex:314`,
  `default_app_server_socket_path/1`); the persisted `respawn`/tmpl only keeps
  it if the *template* pinned one (rare). Recomputed on the new host. The
  `.sock` is a transient and is recreated.
- **No DB column stores a filesystem path** — every migration was checked; no
  `add :*_path / *_dir / *_file` columns. Entity/agent/session/workspace rows
  are URI-keyed (`entity://agent/<ws>/<name>`), and the agent URI is what
  `agent_config_dir/1` re-derives the path FROM. URIs are host-independent.
- **Credentials** — YAML files, no embedded host paths.
- **`pty-pids/`** — host-local PIDs; deliberately excluded from backup (would
  be stale and misleading on the new host).

## Conclusion → restore strategy

The *only* persisted absolute paths are the two Sandbox-slice fields, and both
share the prefix `<old_profile_dir>` (everything lives under
`cc-agents/...`). They are 100% **prefix-rewritable**: replacing
`<old_home>/<old_profile>` → `<new_home>/<new_profile>` inside the decoded
snapshot maps fixes both.

Two viable approaches:

1. **Rewrite-on-restore (CHOSEN for this PR).** On `restore`, after copying the
   tree, open the target DB, walk every `kind_snapshots.state_binary`, deep-
   rewrite any string starting with the source `profile_dir` to the target
   `profile_dir`, re-encode. Correct, contained, no runtime contract change.

2. **Relativize the slice (DEFERRED — structural follow-up).** Store
   `cc-agents/<ws>/<name>` (profile-relative) in the slice and resolve against
   `Ezagent.Home` at read time in `activate`. The durable fix, but it touches
   the Sandbox slice contract, the cc Template Class, `:write_path` callers,
   and `reconcile_after_load`, plus a data migration of existing rows. Out of
   scope for a single backup/restore PR; the rewrite-on-restore path makes
   migration correct *today* without it. Tracked in `docs/futures/todo.md`.

The source `profile_dir` is recorded in the backup manifest at `backup` time
so `restore` knows the prefix to rewrite without guessing.
