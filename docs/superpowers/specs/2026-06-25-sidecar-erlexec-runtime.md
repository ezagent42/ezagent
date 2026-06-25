# SPEC — Sidecar OS-process runtime unified on erlexec (subtask B)

> Status: REVISED post adversarial review (2026-06-25, two codex-style reviewers). Author: allenwoods (dev, handoff B).
> Handoff: `docs/together/2026-06-25/handoffs/allenwoods-B-sidecar-erlexec.md`.
> Master: `docs/together/2026-06-25/handoffs/allenwoods-agent-runtime-consolidation-plan.md`.
> Required project skills: `ezagent-developer`, `elixir-phoenix-helper`, `erlexec-elixir`.
> Decisions (lead, 2026-06-25): **(A) functional primitive, no `use`-behaviour** — each sidecar calls `OsProcess` directly. **Full pid-file + shared OrphanReaper** kept (not deferred).

## 1. Problem

Four OS-subprocess sidecars spawn their child via native
`Port.open({:spawn_executable, …})` and tear it down via `Port.close/1`:

| Module | File:line | Child | Subtree that orphans |
|---|---|---|---|
| `EzagentPluginCc.SdkSidecar` | `sdk_sidecar.ex:214` | `uv`/`python3` | `uv → python` |
| `EzagentPluginCodex.AppServer` | `app_server.ex:111` | `codex` | `codex → vendored bins` |
| `EzagentPluginCodex.BridgeSidecar` | `bridge_sidecar.ex:145` | `uv`/`python3` | `uv → python` |
| `EzagentPluginFeishu.WsClient` | `ws_client.ex:92` (call spans :92-93) | `node` | `node → workers` |

**Root cause.** `Port.close/1` signals only the *direct* child. The grandchild
(`python` under `uv`, vendored bins under `codex`, workers under `node`) is
reparented to PID 1 and survives — an orphan. On a brutal BEAM kill the direct
child is not signalled at all. Symptom of record: feishu accumulated 3 orphan
node sidecars in one day, all racing for inbound events
(`sidecar_orphan_reap_test.exs` moduledoc). Existing mitigations are per-sidecar
and incomplete (feishu's `node` self-exits on stdin EOF; PTY has
`Cc.OrphanReaper`). There is **no shared spawn discipline**.

## 2. The fix (verified in-tree, confirmed by review)

erlexec **2.3.0** (already the sole OS-process library) exposes the exact
mechanism (`deps/erlexec/src/exec.erl:312-318`; C impl
`deps/erlexec/c_src/exec_impl.cpp:919` SIGKILL + `:971` SIGTERM target
`-cmd_gid`; `setpgid` at `:780`):

- **`{group, 0}`** — `setpgid(0, 0)` puts the child into a **new process group**
  whose gid = the child's own OS pid. `uv` and the `python` it forks share it.
- **`kill_group`** — on `:exec.stop` / exit, signal the **whole group**
  (`kill(-cmd_gid)`), SIGTERM→`kill_timeout`→SIGKILL.

Plus, the owner-death path is closed with **`:exec.run_link`** (the erlexec skill's
default for peer-lifetime workers): the BEAM link kills the child when the owning
GenServer dies — including `Process.exit(pid, :kill)` and supervisor `:shutdown`.
Combined with exec-port's BEAM-SIGKILL reaping, every teardown path is covered:

| Teardown path | Reaped by |
|---|---|
| Graceful `terminate/2` (supervisor `:shutdown`, `{:stop,…}`) | `OsProcess.stop` → `:exec.stop` group-kill |
| Owner crash / `Process.exit(pid, :kill)` | `run_link` propagation → erlexec group-kill |
| Brutal BEAM SIGKILL | exec-port reaps every child (group-kill via `kill_group`) |

> **SAFETY INVARIANT (load-bearing).** `kill_group` MUST be paired with
> `{group, 0}`. Without `{group, 0}` the child inherits exec-port's group, so
> `kill_group` would `kill(-exec_port_group)` — killing exec-port itself and
> every sibling erlexec child (including the ungrouped `Domain.Python` children).
> The pairing lives in ONE place (`Ezagent.Runtime.OsProcess`) so no sidecar can
> set one without the other. Review confirmed: per-child gid, no interaction with
> ungrouped siblings.

## 3. Design — three runtime-tier modules (functional, no new behaviour)

All three live in `apps/ezagent_core/lib/ezagent/runtime/` (siblings of
`Ezagent.Runtime.PidFile`). **None is a Kind** (§3.5). Each sidecar keeps its own
hand-rolled GenServer (matching the `Domain.Pty.Server` / `Domain.Python.Server`
precedent) and calls these helpers directly.

```
Ezagent.Runtime.OsProcess     ← functional erlexec primitive — THE sanctioned spawn exit
Ezagent.Runtime.LineBuffer    ← newline framing (with byte cap)
Ezagent.Runtime.OrphanReaper  ← shared boot reaper (PidFile.enumerate → reap); 1 child_spec / plugin
```

> **B2 (`use Ezagent.Runtime.Sidecar` IoC behaviour) was considered and dropped**
> (lead, post-review). Two independent reviewers found it over-engineered for 4
> dissimilar sidecars: `ctx.send`/stdin/framing fully fits only cc; the codex two
> are "spawn + drain stdout to log + capture exit"; feishu is read-only +
> deferred-spawn + restart-backoff. The IoC leaked (deferred-spawn breaking the
> "callbacks return mod_state only" contract; stderr-message routing). A new
> plugin-author `use` contract is an architecture commitment better ratified
> deliberately, not under a transport-swap task. Dropping it is **net-zero** on
> every DoD property — the orphan fix + gate depend ONLY on `OsProcess`.
> Lifecycle-consistency is still honoured at the agent-Kind tier (§3.5).

### 3.1 `Ezagent.Runtime.OsProcess` (functional primitive)

The ONLY sanctioned way for non-PTY/non-Python lib code to spawn an OS process.
Pure functions; bakes in the `{group,0}`+`kill_group` pairing + `run_link`.

```elixir
@type spawn_opts :: [
        cd: String.t(),                          # required
        env: [{String.t(), String.t()}] | map(),
        stderr: :merge | :separate,              # :merge → {:stderr,:stdout}; :separate → own {:stderr,…} stream
        pid_file: nil | {plugin :: String.t(), key :: URI.t()}
      ]

@spec spawn(cmd :: [String.t()] | String.t(), spawn_opts) ::
        {:ok, %{exec_pid: pid(), os_pid: pos_integer()}} | {:error, term()}
@spec send(exec_pid :: pid(), iodata()) :: :ok | {:error, term()}
@spec stop(exec_pid :: pid() | nil) :: :ok
@spec cleanup_pid_file(plugin :: String.t(), key :: URI.t()) :: :ok
```

`spawn/2` calls **`:exec.run_link`** with `[:stdin, :stdout, {:group, 0},
:kill_group, {:cd, charlist}, {:env, charlists}]` + the stderr disposition
(`:merge` → `{:stderr, :stdout}`; `:separate` → `:stderr`). It does **NOT** pass
`:monitor` — the `run_link` BEAM link + the caller's `trap_exit` deliver child
exit as `{:EXIT, exec_pid, reason}`. `cmd` as a **list** runs via `execve` (no
shell — argv-safe, matching `Domain.Pty.Server` codex HIGH-2); a string runs via
`$SHELL -c` (legacy, trusted callers only — no sidecar uses it). On `{:ok, _,
os_pid}` it writes the pid file when `:pid_file` is given. `stop/1` →
`:exec.stop(exec_pid)` in try/catch (the **Erlang exec_pid**, matching working
`Domain.Pty`/`Domain.Python` — the documented exception to the skill's
"always os_pid" rule). `:exec.start/0` is idempotent.

> **Caller contract (every sidecar MUST honour — replaces the dropped macro).**
> 1. `init/1` calls `Process.flag(:trap_exit, true)` UNCONDITIONALLY (even in
>    codex test_mode where no child spawns) BEFORE `OsProcess.spawn`, else
>    supervisor `:shutdown` skips `terminate/2` and orphans the child.
> 2. Handle `{:EXIT, exec_pid, reason}` (child exit via the link) for **ALL**
>    reasons — `:normal` (clean status-0 — `:monitor` is dropped so the numeric
>    status collapses to `:normal`), `{:exit_status, n}`, `:port_closed`. A
>    narrow match that ignores `:normal` leaves a live GenServer with a dead
>    child and feishu's restart never fires (impl note, erlexec review). Add a
>    defensive `{:EXIT, _other, _}` clause too. Handle `{:stdout, os_pid, bytes}`
>    (+ `{:stderr, os_pid, bytes}` when `:separate`).
> 3. `terminate/2` calls `OsProcess.stop(exec_pid)` + `OsProcess.cleanup_pid_file`.
>    (Belt-and-suspenders — the link already covers most paths; `:exec.stop` on
>    an already-dead LWP is swallowed by the try/catch.)

### 3.2 Per-sidecar migration pattern (transport swap only)

Each sidecar's diff is mechanical; **the protocol logic (JSON id-correlation,
decode, dispatch, env builders) is copied verbatim** — only the transport changes:

| Before (native Port) | After (OsProcess) |
|---|---|
| `Port.open({:spawn_executable, exe}, [...])` | `OsProcess.spawn([exe \| args], cd:, env:, stderr:, pid_file:)` |
| `{port, {:data, {:eol, line}}}` | `{:stdout, os_pid, bytes}` → `LineBuffer.feed` → per-line (framing :lines) |
| `{port, {:data, data}}` (raw) | `{:stdout, os_pid, bytes}` → use chunk directly (framing :raw) |
| `{port, {:exit_status, n}}` | `{:EXIT, exec_pid, reason}` |
| `Port.command(port, bytes)` | `OsProcess.send(exec_pid, bytes)` |
| `Port.close(port)` (in terminate) | `OsProcess.stop(exec_pid)` + `cleanup_pid_file` (in terminate) |
| (no trap) | `Process.flag(:trap_exit, true)` in `init/1` |

### 3.3 `Ezagent.Runtime.LineBuffer` (newline framing, capped)

erlexec delivers arbitrary `{:stdout, os_pid, bytes}` chunks — NOT native `Port`'s
`{:line, N}` frames. JSON-line sidecars need complete lines before decoding.

```elixir
@spec feed(t(), binary()) :: {t(), [String.t()]}   # split on ~r/\r?\n/, accumulate tail
```

The cap is a **generous safety ceiling, NOT preservation of the old `{:line, N}`**
(impl note, erlexec review): `{:line, N}` is the Port's *delivery chunk size*, not
a max line length — feishu actually reassembled `{:noeol}` chunks and handled
arbitrarily-long lines with **no cap**. So size `max_line` ABOVE the realistic
max event (e.g. ≥1 MiB, or per-sidecar configurable) purely as a memory-DoS
bound; a too-small cap is a real regression for large Feishu events. On overflow
emit the capped prefix (invalid JSON → dropped-with-warning → framing resyncs at
the next `\n`; no corruption of later lines). Split on `~r/\r?\n/`.

### 3.4 `Ezagent.Runtime.OrphanReaper` (shared boot reaper) — KEPT (lead decision)

A reusable boot reaper for the **new sidecar plugins**, generalising the
`reap()`-shape of `Cc.OrphanReaper` / np `OrphanReaper` into ONE module. Each
plugin invokes it as an imperative sweep in its `Application.after_boot/0` —
`Ezagent.Runtime.OrphanReaper.reap("cc-sdk")` — exactly like the existing cc/np
reapers run (impl note, arch review — NOT a supervision-tree child_spec, which
would leave an underspecified one-shot-GenServer lifecycle + boot-ordering vs the
sidecar-spawning Kinds; `after_boot/0` runs before `Workspace.Loader.load_all/0`,
the established reap-before-load ordering). On sweep it `PidFile.enumerate(plugin)`
→ for each, recheck
`PidFile.process_start_seconds/1` (PID-recycle guard) → `:exec.stop`/signal the
stale pid + `PidFile.remove`.

- **Coexists with, does not replace, the existing `Cc.OrphanReaper` (PTY) and np
  `OrphanReaper`** — they target their own pid-file subdirs (`"cc"`, `"np"`) and
  are out of scope ("don't touch PTY"). The new reaper targets `"cc-sdk"`,
  `"codex-appserver"`, `"codex-bridge"`, `"feishu-ws"`. No cross-contamination
  (review LOW-2 verified subdir isolation).
- **Coverage note (honest):** with `run_link` (§3.1), owner-death is already
  reaped synchronously and BEAM-SIGKILL by exec-port; this boot reaper is
  belt-and-suspenders for the residual "exec-port itself also died / machine
  crash / leaked pid file" case. Kept per lead decision for defence-in-depth.

**pid-file URI-body extension** (so non-`entity://` keys round-trip): `write/3`
appends the full `URI.to_string` as line 3; `enumerate/1` reads the URI from the
body, **falling back** to the existing filename reverse-parse for legacy 2-line
files. Review LOW-2 verified this is compat-safe both directions — `PidFile.parse/1`
already destructures `[pid_str, start_str | _]` (tolerates a 3rd line), and the
existing reapers only read their own `entity://`-only subdirs. Rename `write/3`'s
`agent_uri` param to `key` (it may now be a `system://` URI).

> **Invariant (impl note, arch review):** feishu's `system://feishu/ws` key
> CANNOT be recovered from the sanitised filename (`agent_uri_from_filename/1`
> only parses `entity://ws/agent/name`), so for feishu the line-3 body is the
> ONLY source of the key. feishu pid files are therefore **always 3-line** —
> there are no legacy 2-line feishu files (feishu has no `PidFile` usage today).
> `parse/1` must NOT blind-delete a `feishu-ws`-subdir entry that is missing
> line 3 as "garbage"; treat a missing body-URI on a non-`entity` subdir as a
> recoverable skip, not a delete. `enumerate/1` always returns `%URI{}` so the
> reaper's `%{agent_uri: %URI{}}` guard holds.

### 3.5 Why the sidecars are NOT Kinds (rejected alternative)

Modelling each sidecar as a Kind mounting a Lifecycle behavior was rejected:

1. **No persistent state to snapshot** — a sidecar is 100% transient
   (`exec_pid`/`os_pid`/buffer/pending). An empty-`state` Kind is the "synthetic
   singleton" anti-pattern (architecture invariant #12).
2. **Owner-owned, not dispatch-reachable** — the agent Kind owns its sidecar 1:1;
   a sidecar Kind would force the agent to **dispatch** to its own subprocess
   (Router + authz + owner-gate). Lifecycle's `transients` exists precisely so the
   agent holds it directly — lifecycle.md's canonical case **#113 (codex bridge
   subprocess)** does exactly this in `activate/2`, no sidecar Kind.
3. **Tier collapse** — `Domain.Pty.Server` / `Domain.Python.Server` are already
   plain GenServers; `single_spawn_entry_test.exs` encodes these sidecars as
   "infrastructure, NOT Kinds" with an explicit allowlist.
4. **Double-books locality** — `LocalRuntime`/`WorkspaceOwnerGate` decide *which
   node runs the agent Kind*; the sidecar follows its agent (rebuilt by the
   agent's `activate` on the new node). A sidecar Kind records that twice.

Lifecycle-consistency is honoured at the **agent-Kind tier** (where the Lifecycle
behavior already lives + treats the sidecar as a transient). The three "runtime"
names are orthogonal tiers, no module collision: `Ezagent.Runtime` (node/cookie) ⟂
`Ezagent.LocalRuntime` (Kind-tier owner-gated spawn/liveness, subtask C) ⟂
`Ezagent.Runtime.{OsProcess,LineBuffer,OrphanReaper}` (OS-process tier). Naming
passes the NP-2/NP-3 lint (review LOW-1 verified against the word list).

## 4. Per-sidecar migration specifics

| Sidecar | framing | stderr | spawn timing | child-exit policy | pid-file key |
|---|---|---|---|---|---|
| cc `SdkSidecar` | `:lines` | **`:separate`** (NEVER merge — stderr in the JSON channel injects non-JSON lines) | init | reply pending `{:error,…}` then `{:stop,…}` | `{"cc-sdk", agent_uri}` |
| codex `AppServer` | `:raw` | `:merge` (preserve current `:stderr_to_stdout`; log-only) | init | `{:stop,…}` | `{"codex-appserver", agent_uri}` |
| codex `BridgeSidecar` | `:raw` | `:merge` (preserve current) | init | `{:stop,…}` | `{"codex-bridge", agent_uri}` |
| feishu `WsClient` | `:lines` | `:separate` | deferred (existing `send(self(), :open_sidecar)` after `load_credentials/0`) | **restart, 5 s backoff (preserve)** | `{"feishu-ws", Ezagent.URI.system("feishu","ws")}` |

- All four: `Process.flag(:trap_exit, true)` in `init/1`; `terminate/2` →
  `OsProcess.stop` + `cleanup_pid_file`.
- **`load_credentials/0` is treated as A-owned** (subtask A, config-unification —
  it reads `system://credentials/feishu.yaml`). Move it **verbatim** into the
  deferred-spawn path; do NOT refactor it. Flag in the return.
- codex `test_mode`/`@compile_env` short-circuit preserved (skip `OsProcess.spawn`
  in `:test`).
- Preserved pure helpers: `sdk_runner/1`, `bridge_runner/1`, `codex_executable/1`,
  env builders, `recent_output/1`, `EventDecoder` dispatch, the feishu node
  stdin-EOF self-exit in `main.js` (belt-and-suspenders; keep — removing it widens
  the diff + risks `sidecar_orphan_reap_test`).
- **Do NOT touch** `Domain.Pty.Server` or `Domain.Python.Server`.

## 5. Arch gate

Add fitness function `raw_port_spawn_executable` to
`Mix.Tasks.Ezagent.Arch.Scan`. **AST-based, not line-grep** (review HIGH-1: the
shared `grep/2` scans line-by-line and is structurally blind to feishu's
multi-line `Port.open(\n {:spawn_executable` form at `ws_client.ex:92-93`). Walk
each lib file's AST (`Code.string_to_quoted`) for `Port.open` calls whose **first
arg is the bare 2-tuple `{:spawn_executable, _}`** — empirically verified: a
2-element tuple quotes as a literal `{:spawn_executable, …}`, NOT `{:{}, _, […]}`
(that form is only 3+-element tuples like `{:fd, 0, 1}`, which must NOT match).
Matcher: `match?({:spawn_executable, _}, first_arg) or match?({:{}, _,
[:spawn_executable | _]}, first_arg)` (the 2nd leg defensive for a 3+-tuple).
Honour `# arch-allow:`. Manifest
baseline **`raw_port_spawn_executable: 0`** (all 4 migrate → no allowlist). New
ExUnit gate `test/architecture/raw_port_spawn_test.exs` using
`assert_zero(:raw_port_spawn_executable)`; the regression proof MUST reintroduce
the **multi-line** form to exercise the AST path. `manifest_ratchet_test`
auto-asserts the key has a scanner.

## 6. Definition of Done (four properties)

1. **Unified** — `OsProcess` exists; all 4 sidecars spawn through it; zero
   `Port.open({:spawn_executable})` in `apps/*/lib` (incl. feishu's multi-line
   form). Feishu migrated, not allowlisted.
2. **Gate live** — AST-based `raw_port_spawn_executable` capped at 0; the ExUnit
   gate fails on any reintroduction (multi-line proof).
3. **No orphans (proof, precise ownership)** — `OsProcess` `@tag :slow` unit test:
   `["/bin/sh","-c","sleep 300 & echo GRANDCHILD=$!; wait"]`, capture **that
   grandchild os_pid**, `OsProcess.stop`, poll `ps -p <grandchild>` gone (≤10 s);
   **no `pkill`**. Owner-death proof: spawn, capture os_pid, `Process.exit(pid,
   :kill)`, poll the captured pid dead (proves `run_link` reaping). Per-sidecar:
   stop/restart leaves no residual captured os_pid. **Feishu**: capture a
   node→worker **grandchild** (have `main.js`/a stub fork + print its pid), assert
   it dies (proves `kill_group`, not just the node self-exit). JSON-line proof:
   drive `SdkSidecar` end-to-end over erlexec, round-trip one `query` → JSON reply
   (stub worker acceptable; don't oversell as full-SDK e2e in the return).
4. **PTY untouched** — `Domain.Pty.Server` unchanged; **positively** assert via
   `mix test apps/ezagent_domain_pty` green (not just diff-exclusion).

Plus: full `mix test` green (the `@tag :slow` orphan proofs are NOT excluded by
this repo's config — review confirmed they run under `mix test`/`precommit`);
`mix ezagent.check_invariants` green; CI (`precommit + check_invariants`) green on
PR head; rebased on `main`. Confirm the actual CI entrypoint runs `mix test`.

## 7. Conflict management (master plan §2)

B and C share **two** files:
1. `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` — B adds
   `raw_port_spawn_executable: 0` (new key; ratchet handles new keys — `Map.fetch`
   → `:error` → `:ok` branch, review §4 verified); C lowers `spawn_registry_*`.
2. `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` — B adds the counter to
   `do_measure/0` (+ AST helpers); C removes stale entries from
   `@spawn_registry_sanctioned_files` (top-of-file). Regions differ → likely clean
   merge, but **serial**.

Protocol: whoever merges first, the other rebases onto `main`, re-runs
`mix ezagent.arch.scan`, reconciles. Recorded in the return.

## 8. Out of scope / non-goals

- No new Kinds; no Lifecycle changes; sidecars stay infrastructure GenServers.
- **No `use Ezagent.Runtime.Sidecar` behaviour** (B2 dropped — §3 note).
- `Domain.Pty.Server` / `Domain.Python.Server` not migrated (already erlexec).
- Existing `Cc.OrphanReaper` (PTY) / np `OrphanReaper` not refactored.
- `load_credentials/0` not refactored (A-owned).
- erlexec is NOT taught to talk to the web; PTY→web is a separate, untouched layer.

## 9. Resolved review items (record)

- run-vs-run_link fork → **`run_link` + `trap_exit`** (§2/§3.1); fixes the
  synchronous-reap-on-`:kill` tests (review BLOCKER 1/2).
- Sidecar IoC behaviour → **dropped** for the functional primitive (review MEDIUM).
- LineBuffer → **byte cap + `\r?\n`** (review MEDIUM/LOW).
- Gate → **AST-based** to catch feishu's multi-line `Port.open` (review HIGH-1).
- Conflict map → **second shared file named** (review MEDIUM-2).
- `load_credentials/0` → **A-owned, verbatim** (review UNVERIFIABLE/A-overlap).
- pid-file URI-body → compat-safe, kept (review LOW-2).
- `bridge_sidecar.ex` line → **:145** (review LOW-3).
