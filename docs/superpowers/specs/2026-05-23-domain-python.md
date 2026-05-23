# Domain.Python — Tier-2 runtime for ezagent-launched Python subprocesses

> **Status**: DRAFT — 2026-05-23. Author: Claude (per Allen Feishu
> 2026-05-22, redesigning the Phase-6 placeholder). Awaiting Allen +
> codex adversarial review before implementation.

## 0. Scope and non-scope

### 0.1 Domain.Python **is**

A unified Tier-2 domain runtime for **Python subprocesses that ezagent
itself launches**. The runtime owns one OS process per Python child,
manages its lifecycle inside OTP, talks to it over a documented
LSP-style JSON-RPC stdio protocol, and exposes a small Elixir API
(`start_subprocess / call / notify / stop`) plus a small Python-side
library so plugin authors do not reinvent the wire.

Future consumers:

- A Python-implemented Agent Kind (e.g. a Python LLM agent whose chat
  loop does not go through claude-PTY) — its `Behavior.Chat.invoke`
  calls into Domain.Python.
- A Python-implemented Behavior `:invoke` or Template `:instantiate`
  exposed by a future plugin.
- Future Python plugins that ship a `.py` script + a `pyproject.toml`
  (or PEP-723 inline-script metadata) and let ezagent run it.

This is the **foundation for the Python ecosystem** in ezagent. The
Phase-6 contract called it the "Python plugin host"; the redesigned
runtime is broader (host for any ezagent-launched Python subprocess)
but keeps the JSON-RPC stdio wire.

### 0.2 Domain.Python **is not**

- **Not the cc / MCP-bridge path**. Allen (2026-05-22):
  > MCP 的实现受限于 agent 的限制，例如 Claude Code 的 channel 就要
  > 求以子进程的形式启动，这些应该通过 pty 去支持，有必要的时候再考
  > 虑使用 Domain.Python.

  `ezagent_mcp_bridge.py` and `orchestrator_bridge.py` stay where they
  are: Domain.Pty launches `claude --mcp-config <path>`, claude spawns
  those bridges as MCP servers in its own subprocess tree, and they
  speak WebSocket back to ezagent. Domain.Python does **not** refactor
  those, does **not** wrap them, does **not** become their parent.
- **Not a PTY**. Domain.Python is for stdio-protocol Python processes
  (line-buffered, no terminal control sequences). Domain.Pty is for
  TUI / terminal-style child processes that need a real `tty`.
- **Not a generic "run any command" primitive**. Domain.Pty already
  fills that role for arbitrary commands; Domain.Python is
  specifically the Python + uv runtime. (If a non-PTY non-Python
  runtime is later needed — e.g. Node.js plugins — that gets its own
  Tier-2 app, modelled on Domain.Python.)
- **Not a sandbox / capability boundary**. The Python subprocess
  inherits the BEAM process's file / network privileges; CapBAC
  applies at the dispatch boundary, not at the OS-process boundary.
- **Not a hot-reload runtime**. A Python script change requires
  restarting the subprocess via the supervisor; live-reload is a
  future concern.

## 1. Architecture

### 1.1 Tier and app layout

`Domain.Python` is a **Tier-2 domain app** (`apps/ezagent_domain_python/`).
It already exists as a Phase-6 placeholder; this SPEC turns it into a
real runtime. Deps: `:ezagent_core` + `:jason` only (consistent with
the principle that a Tier-2 domain app depends on `core` and nothing
else — see ezagent-developer SKILL §Three-tier project structure).

```
apps/ezagent_domain_python/
├── lib/
│   ├── ezagent_domain_python.ex                       # facade (4 public fns)
│   ├── ezagent_domain_python/
│   │   ├── application.ex                             # Registry + DynamicSupervisor
│   │   ├── server.ex                                  # GenServer wrapping :exec.run/2
│   │   ├── supervisor.ex                              # (constant inlined into application.ex)
│   │   ├── json_rpc.ex                                # KEPT — LSP framing encoder/decoder
│   │   ├── frame_buffer.ex                            # NEW — incremental LSP frame parser (stream → frames)
│   │   └── spec.ex                                    # NEW — typed Spec struct for start_subprocess
│   └── ezagent/
│       └── domain/python.ex                           # facade alias (Ezagent.Domain.Python)
├── priv/
│   └── python/
│       └── ezagent_python.py                          # NEW — Python lib (loop + @method decorator + log helper)
└── test/
    ├── json_rpc_test.exs                              # existing — kept
    ├── frame_buffer_test.exs                          # NEW — incremental decode unit tests
    ├── spec_test.exs                                  # NEW — Spec validation
    ├── server_test.exs                                # NEW — Server fake-port unit test
    ├── integration_test.exs                           # NEW — real `uv run` end-to-end (tagged @uv)
    └── support/
        └── echo_server.py                             # NEW — fixture using the Python lib
```

### 1.2 Process structure

One `Ezagent.Domain.Python.Server` GenServer per managed Python
subprocess (parallel to `Ezagent.Domain.Pty.Server`). All servers run
under a `DynamicSupervisor` (`EzagentDomainPython.Supervisor`) and
register under a `:via` Registry (`EzagentDomainPython.Registry`)
keyed by the **canonical handle key** derived from the caller's
handle (see §1.2.1 for the canonicalization rules — codex round-1
HIGH-4).

#### 1.2.1 Handle identity — canonicalization at the boundary (codex round-1 HIGH-4)

The caller-facing `handle` accepts EXACTLY two shapes:

- **`URI.t()`** — the production case. P5 UUID-canonical-identifier
  applies; every per-tenant URI in ezagent already canonicalizes
  through `Ezagent.URI.parse!/1`, so callers are already passing
  parsed structs.
- **binary** — restricted to a SINGLE production use (a static
  service handle like `"system://python-sidecar/default"` that the
  caller has already serialized) PLUS test fixtures. Any other
  binary form raises at the boundary.

`Ezagent.Domain.Python.handle_key/1` is the SOLE canonicalization
point:

```elixir
@spec handle_key(URI.t() | binary()) :: binary()
def handle_key(%URI{} = uri), do: URI.to_string(uri)
def handle_key(bin) when is_binary(bin) do
  # Defensive: roundtrip through URI.parse + back so an accidentally
  # different-but-equivalent string (e.g. trailing slash, lowercased
  # scheme) normalizes to one Registry key. URI.parse is lenient;
  # for production URIs the caller should have used %URI{} directly.
  case URI.new(bin) do
    {:ok, %URI{} = uri} -> URI.to_string(uri)
    {:error, _} -> bin  # test fixture or static handle — used as-is
  end
end
def handle_key(other), do:
  raise ArgumentError,
        "Ezagent.Domain.Python: handle must be %URI{} or binary, got: #{inspect(other)}"
```

Both `start_subprocess/1` (via `Spec.validate/1`) AND `call / notify /
stop / alive?` invoke `handle_key/1`. So passing a `%URI{}` for spawn
and the URI's `to_string/1` for `call` resolve to the SAME Registry
entry. **No tuples, no maps, no atoms.** The Registry key is always a
binary; the type is enforced at the boundary so a typo
(`call(:my_atom, ...)`) fails loudly, not silently as `:not_alive`.

Invariant test (§9.3): start with `URI.parse("system://python/default")`,
then call with the literal binary `"system://python/default"` — must
hit the same Server pid.

The Python subprocess is launched via `:exec.run/2` — the same
primitive Domain.Pty uses — but **without** the `:pty` option. Pipes:

- `:stdin` — BEAM writes LSP-framed JSON-RPC requests
- `:stdout` — Python writes LSP-framed JSON-RPC responses + notifications; BEAM reads
- `:stderr` — captured to a log file (per P22, never silent)

### 1.3 Relation to Domain.Pty

Domain.Python is the **stdio sibling** of Domain.Pty:

| Concern | Domain.Pty | Domain.Python |
|---|---|---|
| Wire | raw bytes through `tty` | LSP-framed JSON-RPC over pipes |
| Use case | TUI / terminal apps (`claude`, `bash`) | Python business-logic processes |
| Primitive | `:exec.run/2` with `:pty` | `:exec.run/2` without `:pty` |
| Key by | `URI.to_string(agent_uri)` | caller-supplied handle (`URI.t()` typical) |
| Failure mode | child dies → DynSup restarts | child dies → pending RPC calls get `{:error, :subprocess_died}`, DynSup restarts |
| Tier | Tier-2 (`ezagent_domain_pty`) | Tier-2 (`ezagent_domain_python`) |

Both are pure Tier-2 process primitives — neither knows about the cc /
echo / curl / future plugins that use them. Plugin authors compose
them in their Template Class's `instantiate/3`.

## 2. Wire protocol

### 2.1 Decision: keep LSP `Content-Length` framing

The Phase-6 placeholder picked LSP framing (`Content-Length: N\r\n\r\n<body>`)
over newline-delimited JSON. **This SPEC keeps that choice.** Honest
evaluation:

| Concern | LSP framing | Newline-delimited |
|---|---|---|
| Embedded `\n` in JSON strings | safe (binary-clean) | unsafe unless escaped — escaping is a per-encoder hazard |
| Binary attachment (future: image base64, file bytes inline) | safe — length is bytes | breaks on any `\n` in payload |
| Parser cost | one read-N-bytes loop | one `String.split("\n")` |
| Encoder cost | one `byte_size/1` call | zero |
| Existing code | `JsonRpc.encode_frame/1` + `decode_body/1` already implemented + tested | would require rewrite |
| Ecosystem precedent | LSP, DAP, JDWP (battle-tested) | many ad-hoc protocols |
| Python-side cost | one `read_exact(n)` helper (~10 lines) | same as Elixir-side |

Keeping LSP framing costs almost nothing (the encoder/decoder is
already there; we only need to **stream-parse** incoming bytes into
frames — `FrameBuffer.feed/2 :: (state, binary) → {state, [frames]}`)
and buys correctness for the Behavior `:invoke` return value, which is
"arbitrary user-defined map" — including strings with embedded
newlines (chat replies, code blocks, log lines).

The trade-off this SPEC accepts: a future polyglot debugging tool
must speak the same framing. That tool would be written by us, so
this is internal cost.

### 2.2 Envelopes (JSON-RPC 2.0 — unchanged from Phase-6)

Four envelope shapes carry between BEAM and Python:

```
Request:       {"jsonrpc":"2.0", "id": N, "method": "...", "params": {...}}
Response (ok): {"jsonrpc":"2.0", "id": N, "result": ...}
Response (err):{"jsonrpc":"2.0", "id": N, "error": {"code": N, "message": "...", "data": ...?}}
Notification:  {"jsonrpc":"2.0", "method": "...", "params": {...}}
```

These shapes are already enforced by `EzagentDomainPython.JsonRpc`;
this SPEC keeps that module untouched (one PR adds incremental
parsing; the envelope contract does not change).

### 2.3 Method namespacing

#### BEAM → Python (request / notification)

- `python.ping` — no-op health check; returns `{"pong": true}`. Used
  by Server post-spawn to confirm Python is alive.
- `python.shutdown` — notification (no id); Python event loop exits
  cleanly within `shutdown_grace_ms` (default 2000ms) — Server then
  reaps via `:exec.stop/1`.
- `<plugin>.<method>` — application methods registered by the Python
  side via `@method` decorator. Examples in the future Python Agent
  plugin: `chat.send`, `chat.cancel`, `agent.status`.

The `python.*` namespace is **reserved** for Domain.Python lifecycle
methods. Plugins must register methods outside that namespace.

#### Python → BEAM (notification only in V1)

V1 supports **notifications only** for the Python → BEAM direction:

- `log` notification — `params = {"level": "info|warn|error|debug", "message": "...", "meta": {...}}`. Server translates to `Logger.<level>/1` with `domain: :python_subprocess` + the handle prefix.
- `progress` notification — `params = {"id": "<call_id>", "fraction": 0.0..1.0, "message": "..."}`. Used for long-running RPC calls; Server emits telemetry `[:ezagent, :python, :progress]`.

V1 deliberately does **not** support Python → BEAM **requests** (full
bidi RPC). Rationale:

1. The known use cases (Python Agent invoke; Template instantiate;
   logging) do not need it. The Python side performs work and
   responds; if it needs ezagent data, the caller passes it in
   `params`.
2. Bidi RPC creates the question "what can Python call into?" — the
   answer would have to be a small Elixir-side dispatch surface
   (mirror of `kind.lookup`, `dispatch`, `audit.log` from the
   Phase-6 placeholder). That surface is a CapBAC bypass (Python
   would speak directly to ezagent's core; CapBAC is enforced at
   dispatch). Better to thread requests through the caller.
3. **Reservation for V2**: if bidi becomes necessary, the method
   shape is already JSON-RPC requests, just travelling in the other
   direction. The Server already correlates by id (it does so for
   BEAM → Python responses); adding a Python → BEAM correlator is a
   strict extension, no breaking change.

### 2.4 Error codes (JSON-RPC standard)

- `-32700` — parse error (Python received malformed framing)
- `-32600` — invalid request (well-formed JSON, wrong shape)
- `-32601` — method not found (no `@method` handler registered)
- `-32602` — invalid params (handler raised TypeError on params unpack)
- `-32603` — internal error (handler raised any other exception)
- application-specific: codes ≥ `-32000` (per spec); plugin authors
  pick their own. The Python lib ships a `RpcError(code, message,
  data=None)` exception that handlers raise to send a structured
  error response.

## 3. Lifecycle

### 3.1 `start_link(opts)` accepted shape (`Spec` struct)

`Ezagent.Domain.Python.Spec` carries the parameters Server's `init/1`
consumes. A struct (not a free map) so `Spec.validate/1` raises early
on missing required fields:

```elixir
%Ezagent.Domain.Python.Spec{
  handle:             URI.t() | binary(),   # required; Registry :via key (canonicalized via handle_key/1)
  command:            [String.t()] | :uv_script | :uv_project,  # required
  script_path:        String.t() | nil,     # required when command == :uv_script (path to .py with PEP-723 header)
  project_dir:        String.t() | nil,     # required when command == :uv_project (dir with pyproject.toml)
  entry_module:       String.t() | nil,     # required when command == :uv_project (module to `uv run -- python -m`)
  env:                %{String.t() => String.t()},   # optional extra env
  cwd:                String.t(),           # required
  shutdown_grace_ms:  pos_integer(),        # default 2000
  ping_timeout_ms:    pos_integer(),        # default 5000
  test_mode:          boolean()             # default Mix.env() == :test; short-circuits :exec.run/2
}
```

`Spec.validate/1 :: (%Spec{}) -> :ok | {:error, reason}` runs in the
CALLER process before `start_subprocess` touches the supervisor.
Required-field check (`handle`, `command`, `cwd`); command-discriminator
check (e.g. `command: :uv_script` requires non-nil `script_path`);
`File.dir?(cwd)` returns `{:error, :bad_cwd}`. Each per-field error is
a distinct atom so callers can map to operator-facing messages.

The Spec's `command` field accepts THREE shapes (mirroring the
three uv invocation patterns in §7):

1. **`[String.t()]` argv list** — caller has already resolved the
   executable and assembled argv. Server uses it verbatim. Element 0
   must be an absolute path (per Domain.Pty's "argv element 0 = absolute
   path" lesson from cc round-6 — `execve(3)` performs no `$PATH`
   search; bare `"uv"` would fail).
2. **`:uv_script`** — Server resolves `uv` via `System.find_executable/1`
   and builds `[<uv_path>, "run", "--script", script_path]`. Used for
   PEP-723 inline-deps single-file scripts.
3. **`:uv_project`** — Server resolves `uv` and builds
   `[<uv_path>, "run", "--directory", project_dir, "--", "python", "-m", entry_module]`.
   Used for multi-file packages with a `pyproject.toml`.

`Spec.to_argv/1` returns `{:ok, [String.t()]}` or `{:error, :uv_not_found}`.
The latter is a clear, propagated error — Server's `handle_continue`
returns `{:stop, {:spawn_failed, :uv_not_found}, state}` and the
caller (Python Agent's Template Class) reports it through the
Generator / instantiate failure path. (P2 let-it-crash; no silent
shell fallback; mirrors the `:claude_not_found` precedent in
`Ezagent.PluginCc.Template.CcAgent.resolve_claude_executable/1`.)

### 3.2 Spawn sequence — startup is a synchronous readiness gate (codex round-1 HIGH-1)

The naive pattern (`init/1 → {:ok, state, {:continue, :spawn}}` +
`handle_continue` does spawn + ping) is REJECTED. With that pattern,
`DynamicSupervisor.start_child/2` returns `{:ok, pid}` BEFORE spawn
finishes — so `:uv_not_found`, bad cwd, script import errors, or a
ping timeout produce a `{:ok, pid}` immediately followed by silent
process death + restart. The Template Class's `instantiate/3` would
report success while the runtime never became usable. Mirrors
P4 production-usability and P6 completion-claim-requires-invariant-test.

The CORRECT pattern: `start_subprocess/1` does preflight + spawn +
ping SYNCHRONOUSLY before returning, and only returns `{:ok, pid}`
once Python is **ready**.

```
Ezagent.Domain.Python.start_subprocess(%Spec{} = spec) ::
  {:ok, pid} | {:error, reason}

reason ::
  :uv_not_found        # Spec.to_argv preflight
  :bad_cwd             # cwd does not exist
  {:spawn_failed, _}   # :exec.run/2 returned :error
  :ping_timeout        # subprocess started but never answered python.ping
  {:already_started, pid}  # Registry hit — caller can adopt
  ...
```

Step-by-step:

1. **Preflight in the calling process (NOT inside the GenServer):**
   `Spec.validate/1` raises on missing required fields;
   `Spec.to_argv/1` returns `{:error, :uv_not_found}` if uv missing;
   `File.dir?(spec.cwd)` check returns `{:error, :bad_cwd}` if cwd
   absent. Preflight failures are returned to the caller WITHOUT
   touching the supervisor — no half-started child, no restart loop.
2. **Atomic Registry dedup:** the Server's `start_link` uses
   `name: via(handle_key(spec.handle))`. Concurrent starts for the
   same handle collapse to `{:error, {:already_started, pid}}` which
   `start_subprocess/1` returns AS-IS (caller decides whether to
   adopt — mirrors the cc plugin's `:already_started` handling).
3. **`init/1` performs the spawn synchronously:**
   `Process.flag(:trap_exit, true)`, then `:exec.run/2` (no `:pty`;
   `[:stdin, :stdout, :stderr, :monitor, {:env, env}, {:cd, cwd}]`).
   On `{:error, reason}` → `{:stop, {:spawn_failed, reason}}`, which
   `start_link` propagates as `{:error, {:spawn_failed, reason}}`.
4. **`init/1` then issues `python.ping` and AWAITS it synchronously:**
   write the ping frame, then `receive` `{:stdout, _, bytes}` chunks
   feeding `FrameBuffer` until either the ping response arrives
   (success, transition to `ready? := true`, return `{:ok, state}`)
   or `ping_timeout_ms` elapses (`{:stop, :ping_timeout}` →
   `start_link` returns `{:error, :ping_timeout}`). The Server stops
   the subprocess (`:exec.stop/1`) before exiting on ping failure so
   no orphan remains.
   Edge case: if `{:DOWN, _, :process, _, reason}` arrives before
   the ping response (subprocess crashed at import time), the Server
   stops with `{:spawn_died_at_init, reason}`.
5. **After `init/1` returns**, the GenServer is in normal message
   loop. `handle_info({:stdout, os_pid, bytes}, state)` feeds bytes
   into `FrameBuffer`. Each completed frame is decoded via
   `JsonRpc.decode_body/1` and dispatched:
   - `{:result, id, _}` / `{:error, id, _, _, _}` → reply to the
     caller in `pending_requests` (drop the entry on match).
   - `{:notification, "log", params}` / `{:notification, "progress", params}` →
     Server emits Logger / telemetry.
   - `{:notification, other, _}` → log warning + drop (V1 has no
     other registered notifications).
   - `{:request, _, _, _}` → log warning + reply with
     `error: -32601 method not found` (V1 disallows Python → BEAM
     requests; an unsolicited request indicates a buggy plugin).
6. **`handle_info({:stderr, _, bytes}, state)`** → append to a per-handle
   stderr log file under `~/.ezagent/<profile>/logs/python-<slug>.log`
   (slug = handle key with `://` → `-` and `/` → `_`, mirroring the
   `ezagent_mcp_bridge.py` log naming).

**Why synchronous init/1 (vs `{:continue, :spawn}` async startup):**
the contract `start_subprocess/1 returns {:ok, pid} only when ready`
is the only way for Template Class `instantiate/3` to know whether
to proceed. Async startup gives an `{:ok, pid}` whose pid may die in
the next message — a TOCTOU window. Synchronous init removes the
window by making the readiness check part of `start_link`'s
return value. Init may take up to `ping_timeout_ms` (default 5s),
which is acceptable for a Template Class spawn (cc's claude PTY
spawn is comparable).

**Invariant test** (§9.3): `start_subprocess` with `command:
["false"]` (resolves to a process that exits immediately, no ping)
MUST return `{:error, _}`, not `{:ok, pid}`. Test fails the moment
someone refactors init/1 to async startup.

### 3.3 RPC: `call(server, method, params, timeout)` and `notify(server, method, params)`

`call/4` (synchronous; default timeout 5000ms):

1. Allocate next monotonic `id` (incrementing integer per Server).
2. Insert `{id, from, deadline_mref}` into `pending_requests`.
3. Encode + write frame to subprocess stdin.
4. Set a `Process.send_after(self(), {:rpc_timeout, id}, timeout)` ref;
   on timeout the Server treats the subprocess as **unhealthy** and
   tears it down — see §3.3.1.
5. When `{:result | :error}` for `id` arrives in `handle_info`,
   `GenServer.reply/2` to the original caller.

`notify/3` (fire-and-forget):

1. Encode + write notification frame.
2. Return `:ok` immediately.

Notifications do not allocate ids. There is no error path back from a
notification — Python-side handler failures inside a notification
handler are logged on the Python side + relayed via the `log`
notification.

#### 3.3.1 RPC timeout = subprocess is unhealthy → terminate + restart (codex round-1 HIGH-2)

The Python lib is single-threaded by design (§6.2): it reads ONE frame,
dispatches, writes ONE response, loops. So a handler that blocks (hung
HTTP call without timeout, infinite loop, deadlock) STOPS the entire
subprocess from servicing any further call — including future
`python.shutdown` notifications. `alive?/1` would still return `true`
(the OS process is up), but every `call/4` would time out.

The recovery contract is: **an RPC timeout means the subprocess can
no longer be trusted; tear it down so the supervisor gives the next
caller a fresh one.**

On `{:rpc_timeout, id}`:

1. Reply `{:error, :rpc_timeout}` to the caller pinned at `id`.
2. Reply `{:error, :subprocess_unhealthy}` to every OTHER entry in
   `pending_requests` (they are stuck behind the hung handler — no
   point waiting).
3. Force-stop the subprocess (`:exec.stop/1` → SIGTERM → 1s →
   SIGKILL, per erlexec default).
4. `{:stop, :subprocess_unhealthy, state}` → DynamicSupervisor
   restarts the Server, which respawns Python via `init/1` (§3.2)
   into a fresh ready state.

Trade-off accepted: a single slow handler that happens to exceed its
caller's `timeout` argument kills the subprocess. This is the right
default because (a) the Python lib has no way to interrupt the
running handler from outside, and (b) leaving the subprocess running
with one stuck handler poisons all future callers. Callers who
expect long-running work pass a larger `timeout` (the parameter
exists for exactly this); the truly-long-running case (>30s LLM
calls etc.) is the plugin's responsibility to declare a generous
timeout for. If V2 grows an asyncio Python lib (§6.2 future-V2), per-
handler cancellation becomes possible and this policy can soften.

**Invariant test** (§9.3): start a subprocess; call a `block_forever`
handler with `timeout: 100ms`; expected `{:error, :rpc_timeout}`;
THEN call `ping` on the same handle — must either succeed against a
fresh subprocess (DynSup restarted in test_mode it's a no-op so the
invariant test is structured around `:subprocess_unhealthy` being
returned to in-flight callers and the Server stopping). The "next
call works" gate is the test that fails the moment someone reverts
to "just drop the pending entry and keep going."

### 3.4 Crash + restart

- **Python process exits unexpectedly** (any reason, including OOM
  kill, SIGSEGV, `sys.exit(1)`): the erlexec `:monitor` sends a
  `{:DOWN, ref, :process, _, reason}` message. Server replies
  `{:error, {:subprocess_died, reason}}` to every entry in
  `pending_requests`, then `{:stop, {:subprocess_died, reason}, state}`.
  DynamicSupervisor restarts per its strategy (default
  `:one_for_one`, `max_restarts: 3, max_seconds: 60` — mirrors PtyServer
  default).
- **Subprocess unhealthy after RPC timeout**: covered in §3.3.1.
  Same restart path as unexpected exit.
- **Server process crashes**: `terminate/2` calls `:exec.stop/1` on
  the os_pid (best-effort). DynamicSupervisor restarts the Server,
  which respawns Python.
- **Hung Python during graceful shutdown (no response to
  `python.shutdown` within `shutdown_grace_ms`)**: `terminate/2`
  calls `:exec.stop/1` which sends SIGTERM, waits 1s, then SIGKILL
  (erlexec's default behavior).

### 3.5 Graceful shutdown via `stop(server)`

`Ezagent.Domain.Python.stop(handle)`:

1. Look up pid in Registry. If absent, return `:ok` (idempotent;
   mirrors `Ezagent.Domain.Pty.stop/1`).
2. `GenServer.call(pid, :graceful_stop, shutdown_grace_ms + 1000)`.
3. Server sends `python.shutdown` notification, waits up to
   `shutdown_grace_ms` for the subprocess to exit on its own
   (`:exec.stop_and_wait/2` if available, else send-and-monitor).
4. If still alive, force-stop via `:exec.stop/1`.
5. `DynamicSupervisor.terminate_child(EzagentDomainPython.Supervisor, pid)`.
6. Return `:ok`.

### 3.6 Per-process state (`%Server{}`)

```elixir
defstruct [
  :handle,                  # URI.t() | binary()
  :spec,                    # %Spec{}
  :exec_pid,                # erlexec controller pid
  :os_pid,                  # integer
  :stderr_log_path,         # string
  next_id: 1,               # integer; monotonic
  pending_requests: %{},    # %{id => {from, timeout_ref}}
  frame_buffer: %FrameBuffer{},  # incremental LSP parser state
  ready?: false,            # true after python.ping round-trip succeeds
  test_mode: false          # short-circuits :exec.run/2 in :test
]
```

## 4. Public Elixir API

Four functions on `Ezagent.Domain.Python` (the facade alias module
under `lib/ezagent/domain/python.ex`, mirroring Domain.Pty's
`Ezagent.Domain.Pty`):

```elixir
@type handle :: URI.t() | binary()   # canonicalized via handle_key/1 (§1.2.1)

@doc """
Start a managed Python subprocess for `spec.handle` under
EzagentDomainPython.Supervisor. SYNCHRONOUSLY blocks until the
subprocess answers `python.ping` (or fails) — when this returns
`{:ok, pid}`, the runtime is ready to accept calls. May take up
to `spec.ping_timeout_ms` (default 5s).

Preflight failures (uv missing, bad cwd, invalid Spec) return
{:error, _} WITHOUT touching the DynamicSupervisor — no half-started
child, no restart loop.
"""
@spec start_subprocess(Spec.t()) ::
        {:ok, pid}
        | {:error, :uv_not_found | :bad_cwd | :ping_timeout |
                   {:spawn_failed, term()} |
                   {:spawn_died_at_init, term()} |
                   {:already_started, pid}}
def start_subprocess(%Spec{} = spec)

@doc """
Synchronous JSON-RPC call. `timeout` is wall-clock for the call only
(start_subprocess already ensured readiness). On timeout the
subprocess is treated as unhealthy and torn down — see §3.3.1.
"""
@spec call(handle(), method :: String.t(), params :: map(), timeout :: pos_integer()) ::
        {:ok, term()}
        | {:error, :not_alive | :rpc_timeout | :subprocess_unhealthy |
                   {:subprocess_died, term()} | %{required(String.t()) => term()}}
def call(handle, method, params, timeout \\ 5_000)

@doc "Fire-and-forget JSON-RPC notification."
@spec notify(handle(), method :: String.t(), params :: map()) ::
        :ok | {:error, :not_alive}
def notify(handle, method, params)

@doc "Graceful shutdown. Idempotent — returns :ok whether the server was alive or not."
@spec stop(handle()) :: :ok
def stop(handle)

@doc "True iff a Server is registered + the process is alive for this handle."
@spec alive?(handle()) :: boolean()
def alive?(handle)
```

All four functions canonicalize the handle through `handle_key/1`
(§1.2.1). Passing a `%URI{}` to `start_subprocess` and the URI's
`URI.to_string/1` to a subsequent `call` resolves to the SAME Registry
entry. Any other type (atom, tuple, integer, map) raises
`ArgumentError` at the boundary — silent `:not_alive` on a typo is
explicitly NOT a supported failure mode (P4 production-usability: fail
loud).

If not alive: `call` → `{:error, :not_alive}`, `notify` →
`{:error, :not_alive}`, `alive?` → `false`, `stop` → `:ok`.

**No Registry of "logical handle → server pid" beyond what the
`:via` Registry already provides.** A higher-level mapping
(e.g. "agent URI → python subprocess that backs it") is the consumer
plugin's concern, not Domain.Python's — the consumer already has its
own Template Class / Behavior owning that mapping. (P1: no
plugin-isolating abstraction in core / domain unless ≥2 downstream
consumers need it. V1 has zero consumers; this stays plugin-local.)

## 5. Per-Kind / Agent integration

### 5.1 Future Python Agent Kind (illustrative — not built in this SPEC)

A future plugin `ezagent_plugin_python_agent` ships its own
`Ezagent.Template.PythonAgent` Template Class. In `instantiate/3`:

```elixir
def instantiate(_tmpl_name, %{"agent_uri" => uri_str, "script_path" => script} = tmpl, _ws) do
  agent_uri = URI.parse(uri_str)

  with {:ok, _kind_pid} <- ensure_agent_kind(agent_uri),
       spec = %Spec{
         handle: agent_uri,
         command: :uv_script,
         script_path: script,
         env: %{"EZAGENT_AGENT_URI" => URI.to_string(agent_uri)},
         cwd: Map.fetch!(tmpl, "cwd")
       },
       {:ok, _pid} <- Ezagent.Domain.Python.start_subprocess(spec) do
    {:ok, [agent_uri], %{fresh?: true}}
  end
end
```

The plugin's Behavior implementation (e.g.
`Ezagent.PluginPythonAgent.Behavior.PythonChat`) implements `Chat`
on the Agent Kind by delegating to Domain.Python:

```elixir
def invoke(:send, slice, args, _ctx) do
  case Ezagent.Domain.Python.call(args.agent_uri, "chat.send", args, 30_000) do
    {:ok, %{"reply" => reply}} -> {:ok, slice, {:replied, reply}}
    {:error, reason} -> {:error, reason}
  end
end
```

Python side (`script.py`):

```python
from ezagent_python import method, run

@method("chat.send")
def chat_send(params):
    # plugin's actual LLM-call logic
    return {"reply": call_my_llm(params["text"])}

if __name__ == "__main__":
    run()
```

This is the **binding pattern**. Note the parallels to the cc plugin
+ Domain.Pty: the plugin owns the Template Class, Domain.* owns the
subprocess primitive, the Behavior's `:invoke` calls into the
Domain.* facade. The plugin script + the Python lib together
correspond to claude + `ezagent_mcp_bridge.py` in the cc case.

### 5.2 Future Python Plugin Template Class

A plugin can ship a `pyproject.toml` directory in its `priv/python/`
and instantiate via `command: :uv_project`. This is the multi-file
plugin pattern — recommended when the plugin grows past one file.

The pattern is identical to the single-file case; only the Spec's
`command` shape differs (and `entry_module` is required instead of
`script_path`).

## 6. Python-side library

Ship `apps/ezagent_domain_python/priv/python/ezagent_python.py` —
stdlib-only (PEP-723 inline header declares `dependencies = []`), so
the library has no transitive deps. Plugins that need extra deps add
them in their own PEP-723 header or `pyproject.toml`.

### 6.1 Surface (~150 LOC target)

```python
# apps/ezagent_domain_python/priv/python/ezagent_python.py
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
ezagent_python — small Python-side library for Domain.Python plugins.

Plugins import this to register handlers and let the library drive
the JSON-RPC over LSP-framed stdio event loop. The lib has no
non-stdlib deps so plugins don't inherit any.
"""

import json
import sys
import threading
import traceback
from typing import Any, Callable

_HANDLERS: dict[str, Callable[[dict], Any]] = {}
_stdout_lock = threading.Lock()


class RpcError(Exception):
    """Raised inside a handler to send a structured JSON-RPC error response."""
    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def method(name: str):
    """Decorator: register a JSON-RPC method handler."""
    def wrap(fn):
        _HANDLERS[name] = fn
        return fn
    return wrap


def log(level: str, message: str, **meta) -> None:
    """Send a `log` notification to BEAM. level ∈ {debug, info, warn, error}."""
    _send_frame({
        "jsonrpc": "2.0",
        "method": "log",
        "params": {"level": level, "message": message, "meta": meta or {}},
    })


def progress(call_id: str, fraction: float, message: str = "") -> None:
    """Send a `progress` notification to BEAM."""
    _send_frame({
        "jsonrpc": "2.0",
        "method": "progress",
        "params": {"id": call_id, "fraction": fraction, "message": message},
    })


# --- internals -------------------------------------------------------------

def _read_frame() -> dict | None:
    """Read one LSP-framed JSON-RPC frame from stdin. Returns None on EOF."""
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.decode("ascii", errors="strict").rstrip("\r\n")
        if line == "":
            break
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    n = int(headers["content-length"])
    body = sys.stdin.buffer.read(n)
    if len(body) < n:
        return None
    return json.loads(body)


def _send_frame(obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    with _stdout_lock:
        sys.stdout.buffer.write(header)
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()


def _handle_request(msg: dict) -> None:
    req_id = msg.get("id")
    name = msg.get("method", "")
    params = msg.get("params", {}) or {}

    # Builtin: python.ping
    if name == "python.ping":
        _send_frame({"jsonrpc": "2.0", "id": req_id, "result": {"pong": True}})
        return

    handler = _HANDLERS.get(name)
    if handler is None:
        _send_frame({
            "jsonrpc": "2.0", "id": req_id,
            "error": {"code": -32601, "message": f"method not found: {name}"},
        })
        return

    try:
        result = handler(params)
        _send_frame({"jsonrpc": "2.0", "id": req_id, "result": result})
    except RpcError as e:
        err = {"code": e.code, "message": e.message}
        if e.data is not None:
            err["data"] = e.data
        _send_frame({"jsonrpc": "2.0", "id": req_id, "error": err})
    except Exception as e:
        _send_frame({
            "jsonrpc": "2.0", "id": req_id,
            "error": {
                "code": -32603,
                "message": f"{type(e).__name__}: {e}",
                "data": {"traceback": traceback.format_exc()},
            },
        })


def _handle_notification(msg: dict) -> None:
    name = msg.get("method", "")
    if name == "python.shutdown":
        sys.exit(0)
    handler = _HANDLERS.get(name)
    if handler is not None:
        try:
            handler(msg.get("params", {}) or {})
        except Exception:
            log("error", f"notification handler {name} raised", traceback=traceback.format_exc())


def run() -> None:
    """Event loop: read frames, dispatch, write responses, until stdin EOF."""
    while True:
        msg = _read_frame()
        if msg is None:
            return
        if "id" in msg and "method" in msg:
            _handle_request(msg)
        elif "method" in msg:
            _handle_notification(msg)
        # responses/results (BEAM → Python → BEAM) are not supported in V1
        # since BEAM doesn't send requests through python except as caller.
```

### 6.2 What's intentionally NOT in the library

- **Async / await event loop.** V1 is synchronous (one frame at a
  time). The Python side typically does network IO inside a handler;
  if a future plugin needs concurrent in-flight handlers, the
  library grows an asyncio variant in V2 (`from ezagent_python.aio
  import method, run`). The current synchronous design matches the
  expected use case (one BEAM call at a time per subprocess).
- **Schema validation.** Pydantic or similar would force a non-stdlib
  dep. Plugin authors validate params in their handler.
- **Auto-reconnect.** Domain.Python supervises lifecycle on the BEAM
  side; restart on the Python side is the supervisor's restart.

### 6.3 How a plugin uses the lib

PEP-723 single-file example (`my_plugin.py`) — codex round-1 MEDIUM-3
fixed (`os.environ` lookup, not literal `$VAR` string):

```python
#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///
"""My plugin's Python entry point."""
import os
import sys

# Domain.Python sets EZAGENT_PYTHON_LIB_DIR in the spawned subprocess's
# env, pointing at apps/ezagent_domain_python/priv/python/ — the dir
# that contains ezagent_python.py. Python does NOT expand env vars in
# string literals, so this must be an explicit os.environ lookup.
sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run, log, RpcError
import httpx

@method("greet")
def greet(params):
    name = params.get("name")
    if not name:
        raise RpcError(-32602, "name required")
    log("info", f"greeting {name}")
    return {"greeting": f"hello {name}"}

if __name__ == "__main__":
    run()
```

Domain.Python sets `EZAGENT_PYTHON_LIB_DIR` to
`:code.priv_dir(:ezagent_domain_python) |> Path.join("python")` in the
spawned subprocess's environment, so plugins can import the library
without copying it. The integration test (§9.2) fixture imports the
lib in exactly this way to make sure the documented pattern keeps
working.

## 7. uv integration specifics

### 7.1 PEP-723 inline-script header (single-file plugins)

When `Spec.command == :uv_script`:

```
[<uv_abs_path>, "run", "--script", <script_path>]
```

`uv` reads the `# /// script` PEP-723 header from `<script_path>`,
provisions a Python interpreter + the declared deps in a per-script
ephemeral environment, then runs the script. First run is slow
(seconds, while uv downloads + builds); subsequent runs hit uv's
content-addressed cache (sub-100ms). The cc plugin already uses this
pattern for `ezagent_mcp_bridge.py` — verified in production via
`Ezagent.PluginCc.McpConfigWriter` (PR #129).

### 7.2 `pyproject.toml` project (multi-file plugins)

When `Spec.command == :uv_project`:

```
[<uv_abs_path>, "run", "--directory", <project_dir>, "--", "python", "-m", <entry_module>]
```

`--directory` tells uv where to find the `pyproject.toml`; everything
after `--` is passed to Python verbatim. uv provisions the project's
declared deps + entry-module-aware Python invocation. Suitable for
plugins growing past one file (separate modules, shared utilities,
test directory alongside source).

### 7.3 Resolving `uv` to absolute path

Mirrors the `resolve_claude_executable/1` precedent in cc Template
(`Ezagent.PluginCc.Template.CcAgent`):

```elixir
@spec resolve_uv() :: {:ok, String.t()} | {:error, :uv_not_found}
defp resolve_uv do
  case System.find_executable("uv") do
    nil -> {:error, :uv_not_found}
    path -> {:ok, path}
  end
end
```

Called inside `Spec.to_argv/1` for `:uv_script` / `:uv_project`. When
caller supplies `command: [<argv>]` directly, no `uv` resolution
happens — caller is responsible.

**Failure surface for missing uv**: `start_subprocess(spec)` returns
`{:error, :uv_not_found}`. Caller (Template Class `instantiate/3`)
treats it like cc treats `:claude_not_found` — the spawn fails
loudly, no PtyServer / no half-started worker, no silent shell
fallback. Runbook addition: ezagent's INSTALL guide gains a "uv must
be on PATH if any Python plugin is enabled" line. (P4
production-usability: forcing the operator to install uv ONCE is
cheaper than every plugin author shipping their own bootstrap.)

### 7.4 PEP-723 vs project layout — when to use which

Plugin author guidance (to be captured in `docs/onboarding/python-plugin.md`
after impl):

| Use PEP-723 single file when… | Use pyproject.toml project when… |
|---|---|
| Plugin is <300 LOC | Plugin is >300 LOC |
| 1-3 third-party deps | Many deps or version pins per environment |
| One-shot handler logic | Multiple modules, shared helpers |
| No tests in the plugin's own tree | Plugin ships its own pytest suite |

Domain.Python supports **both** in V1 (the Spec.command discriminator
is the only difference). Plugin authors pick what fits.

### 7.5 No env var for PYTHONPATH manipulation

The pseudo-snippet in §6.3 uses `sys.path.insert(0, "$EZAGENT_PYTHON_LIB_DIR")`
inside the script. Alternative: Domain.Python could set
`PYTHONPATH=<lib_dir>` in the env. The env-var path is cleaner but
fights uv (uv manages its own venv per script; PYTHONPATH leaks across
runs). The `sys.path.insert` inside the script is explicit, scoped to
that script, and easy to lint for. **Picked: explicit
`sys.path.insert` in plugin scripts.**

## 8. What Phase-6's placeholder keeps vs revises

### 8.1 Kept

- `EzagentDomainPython.JsonRpc` — the encoder/decoder is correct +
  tested. Untouched.
- `test/json_rpc_test.exs` — passing tests, untouched.
- `EzagentDomainPython` module docstring (the contract) — **rewritten**
  to reflect the redesigned scope ("ezagent-launched Python
  subprocesses" vs "Python plugin host"), but the JSON-RPC contract
  summary stays.

### 8.2 Added

- `EzagentDomainPython.FrameBuffer` — incremental LSP-frame parser
  (Domain.Python reads stdout in arbitrary-size chunks; the buffer
  emits complete frames as they arrive).
- `Ezagent.Domain.Python.Spec` — typed Spec struct + `to_argv/1` +
  `validate/1`.
- `Ezagent.Domain.Python.Server` — the GenServer.
- `EzagentDomainPython.Application` — supervisor + registry.
- `Ezagent.Domain.Python` (facade) — the four public functions.
- `priv/python/ezagent_python.py` — Python lib.
- Integration test (`test/integration_test.exs`) tagged `@uv` so CI
  can skip when uv is absent.

### 8.3 Revised (relative to the Phase-6 moduledoc's "Python → BEAM" list)

- `kind.lookup`, `dispatch`, `audit.log` from Python → BEAM are **dropped
  in V1**. Rationale in §2.3 — they'd be a CapBAC bypass. `audit.log`
  is replaced by the `log` notification (no Kind lookup needed; Server
  just routes to `Logger`).
- The "Python plugin host" framing is broadened to "Tier-2 runtime for
  ezagent-launched Python subprocesses" — see §0.

## 9. Verification

### 9.1 Unit tests

- `JsonRpcTest` (existing 7 tests) — unchanged.
- `FrameBufferTest` — feed bytes in arbitrary chunk boundaries;
  assert frames emit in order, partial frames buffer correctly, two
  frames in one chunk decode separately.
- `SpecTest` — `validate/1` rejects missing required fields by shape;
  `to_argv/1` builds correct argv for each `:uv_script` / `:uv_project` /
  explicit-argv variant; `:uv_not_found` propagates.
- `ServerTest` — Server unit test using a fake port (or a mock
  `:exec` adapter via `Mox` if introduced). Asserts:
  - `python.ping` after spawn → `ready? := true`.
  - `call` enqueues + writes a frame + waits for response by id.
  - `notify` writes a frame without enqueueing.
  - Subprocess `:DOWN` replies `{:error, :subprocess_died}` to every
    pending caller.
  - `:rpc_timeout` removes the pending entry and returns `{:error, :rpc_timeout}`.

### 9.2 Integration test (`@uv` tag)

`test/integration_test.exs` — spins up a real Python subprocess via
`uv run --script test/support/echo_server.py`, then:

1. `start_subprocess` returns `{:ok, pid}`.
2. `Domain.Python.call(handle, "echo", %{"x" => 1}, 2000)` → `{:ok, %{"x" => 1}}`.
3. `Domain.Python.call(handle, "throws", %{}, 2000)` → `{:error, %{"code" => -32603, ...}}`.
4. `Domain.Python.call(handle, "no_such_method", %{}, 2000)` → `{:error, %{"code" => -32601, ...}}`.
5. `Domain.Python.notify(handle, "log_something", %{})` → `:ok`; assert
   the log notification arrived (assert the Server's Logger fired or
   that an in-process telemetry handler observed it).
6. `Domain.Python.stop(handle)` → `:ok`; assert subprocess exit within
   `shutdown_grace_ms + 500`; assert no orphan `python` / `uv` process
   (poll `pgrep -f echo_server.py` for ≤1s).

Tagged `@uv` so `mix test --exclude uv` skips it when uv is absent.
The `mix test` default in CI runs `--include uv` once we've decided
to require uv on CI runners (Allen-decided; SPEC default is
`@uv` excluded from the default `mix test` run, so the SPEC PR is
unblocked).

If uv is **not** installed on the dev's machine, the integration test
suite skips with a clear log line: `"@uv tests skipped — `uv` not on
PATH"`. The `:uv_not_found` unit test path covers the missing-uv
error surface without requiring uv.

### 9.3 Robustness / invariant tests

Per P6 (completion claim requires invariant test), each architectural
invariant gets a failing-when-violated test:

- **No CapBAC bypass via Python → BEAM**: Server's
  `handle_info({:request, ...})` MUST reply with
  `-32601 method not found` (test: feed a fake Python-sent request
  through the FrameBuffer / decode path; assert the response).
- **No orphan processes on crash**: kill the subprocess externally
  (`:exec.kill(os_pid, 9)` in the test); assert Server stops with
  `{:subprocess_died, _}`; assert DynSup restarts; assert all pending
  callers received `{:error, :subprocess_died}`.
- **Hung shutdown still terminates**: spin up a subprocess that
  ignores `python.shutdown`; call `stop/1`; assert it returns within
  `shutdown_grace_ms + ~100ms` and the OS process is gone.
- **Registry collapses concurrent starts**: two parallel
  `start_subprocess` calls with the same handle → exactly one
  `{:ok, pid}` and one `{:error, {:already_started, pid}}`.
- **Startup readiness is part of the contract** (codex round-1
  HIGH-1): `start_subprocess(%Spec{command: ["/usr/bin/false"], ...})`
  MUST return `{:error, _}`. Test fails the moment someone refactors
  to async startup that returns `{:ok, pid}` for a soon-to-die child.
- **Hung handler triggers subprocess teardown** (codex round-1 HIGH-2):
  the echo_server fixture exposes a `block_forever` method;
  `call(h, "block_forever", %{}, 100)` MUST return
  `{:error, :rpc_timeout}` AND a follow-up `alive?(h)` shortly after
  MUST return `false` (the Server stopped). A second parallel call
  in flight at the same time MUST receive `{:error, :subprocess_unhealthy}`,
  NOT a silent hang.
- **Handle canonicalization round-trip** (codex round-1 HIGH-4):
  `start_subprocess(%Spec{handle: URI.parse("system://python/default"), ...})`
  → `{:ok, _}`; then `call("system://python/default", "echo", %{}, 1000)`
  with the LITERAL BINARY of the same URI MUST hit the same Server.
  Negative test: `call(:bogus_atom, ...)` MUST raise
  `ArgumentError`, not silently return `:not_alive`.
- **Python lib import contract matches the docs** (codex round-1
  MEDIUM-3): the fixture script `test/support/echo_server.py` imports
  the library via the exact `os.environ["EZAGENT_PYTHON_LIB_DIR"]`
  pattern from §6.3. Integration test passing → docs work.

### 9.4 Future-readiness sketch (not implemented — design check)

A 1-page note in `docs/notes/python-agent-end-to-end.md` showing how
a hypothetical `ezagent_plugin_python_agent` would wire end-to-end:
Template Class → Domain.Python.start_subprocess → Behavior `:invoke`
calls Domain.Python.call → Python handler returns reply → reply
flows back through Behavior → Chat dispatch. This is a paper
exercise (no code) confirming that the API surface is sufficient
**before** committing to it. (P11: external integration is a
Receiver Kind / Behavior on an existing scheme — Domain.Python is
the OS-process primitive that backs such a Behavior.)

## 10. Decisions log (for Allen review)

| # | Decision | Rationale |
|---|---|---|
| D1 | Keep LSP `Content-Length` framing | Embedded `\n` in arbitrary-string results breaks line-delimited; encoder already exists; cost is ~50 LOC `FrameBuffer`. §2.1 |
| D2 | Notifications only Python → BEAM in V1 (no requests) | CapBAC bypass; no known use case; trivial future extension. §2.3 |
| D3 | Support BOTH PEP-723 single file AND pyproject.toml project | Both are idiomatic uv; the Spec `command` discriminator costs ~10 LOC; plugin authors pick what fits. §7.4 |
| D4 | `uv_not_found` is a hard error, no shell fallback | Mirrors `claude_not_found` precedent (P2). §7.3 |
| D5 | Python lib is stdlib-only (no asyncio in V1) | Plugins inherit no transitive deps. Synchronous handler matches expected use case. §6.2 |
| D6 | No `Ezagent.Domain.Python.Registry` higher-level mapping | Plugin-local concern (the Template Class owns "agent_uri → which python subprocess backs it"); P1 keeps it out of domain. §4 |
| D7 | `stderr` captured to file under `~/.ezagent/<profile>/logs/python-<slug>.log` | Mirrors the `ezagent_mcp_bridge.py` log naming so operators already know where to look. §3.2 step 6 |
| D8 | Handle is `URI.t() \| binary()`, not forced URI | URIs are the canonical case (P5) but Spec can be used by non-URI test fixtures and tooling without inventing a fake URI. §1.2 |
| D9 (codex round-1) | `start_subprocess/1` is SYNCHRONOUSLY ready | `{:continue, :spawn}` pattern returns `{:ok, pid}` before spawn finishes — Template Class reports success while runtime never came up. Sync init/1 closes the TOCTOU window. §3.2 |
| D10 (codex round-1) | RPC timeout = tear down subprocess | Python lib is single-threaded; hung handler poisons all future calls. Restart is the only recovery available in V1. §3.3.1 |
| D11 (codex round-1) | Plugin docs use `os.environ["EZAGENT_PYTHON_LIB_DIR"]` | Python does not expand `$VAR` in string literals; the original draft would have broken every plugin copied from the SPEC. §6.3 |
| D12 (codex round-1) | Handle is `URI.t() \| binary()` ONLY; canonicalize at boundary | "Any term" → silent `:not_alive` on typo; URI/string equivalence requires explicit `handle_key/1`. Atoms / tuples raise loud. §1.2.1 |

## 11. Migration plan

Single PR (`feat/domain-python-redesign`) onto `main`. No back-compat
shim needed — the Phase-6 placeholder has zero callers (verified by
grepping for `EzagentDomainPython` / `Ezagent.Domain.Python` in
`apps/`).

PR diff:
- Modify `apps/ezagent_domain_python/lib/ezagent_domain_python.ex` —
  rewritten moduledoc.
- Add `application.ex`, `server.ex`, `frame_buffer.ex`, `spec.ex`,
  `lib/ezagent/domain/python.ex`.
- Add `priv/python/ezagent_python.py`.
- Add 4 new test files (`frame_buffer_test.exs`, `spec_test.exs`,
  `server_test.exs`, `integration_test.exs`).
- Add `test/support/echo_server.py`.
- Update `apps/ezagent_domain_python/mix.exs` — add
  `mod: {EzagentDomainPython.Application, []}` to `application/0`.
- Add `docs/onboarding/python-plugin.md` skeleton (1-page operator-+-
  author guide; full content lands when the first Python plugin
  exists, but the skeleton documents §7 today).

No DB migration. No registry changes outside Domain.Python's own.

## 12. Out of scope (V2+)

- Python → BEAM full bidi requests (§2.3).
- asyncio variant of the Python lib (§6.2).
- Hot-reload of plugin scripts (§0.2).
- Python plugin "marketplace" / discovery (V2 plugin contract concern).
- Sandbox / per-subprocess capability boundary (V2 security concern).
- Native Erlang `Port.open(:spawn)` adapter (alternative to erlexec).
- Streaming RPC responses (a single `call/4` returns one result; if
  streaming becomes necessary, model it as a request + N
  `progress` notifications with `final?: true` on the last — that
  fits the current V1 protocol without changes).
