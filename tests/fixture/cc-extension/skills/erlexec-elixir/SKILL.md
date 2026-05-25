---
name: erlexec-elixir
description: Use whenever the task involves running an OS process from Elixir with proper lifecycle management — interactive binaries like `claude`, Python / Node / Ruby sidecars, interactive shells, or any long-running external command that must die when the BEAM dies. Triggers include any code that touches `:exec.run`, `:exec.run_link`, `:exec.send`, `:exec.start`, `:exec.kill`, `:exec.stop`, `:exec.ospid`, `:exec.winsz`, `:exec.pty_opts`, writing or extending `Ezagent.OSProcess`底座, `Ezagent.PyProcess`, the ezagent `pty` / `os-process` Process impls, anything using `Port.open` to spawn an OS child where cleanup matters, reasoning about "stdin + stdout + cleanup" trade-offs, adding PTY support to a peer, streaming a PTY to a browser terminal (xterm.js, web terminal, LiveView terminal), debugging orphaned child processes, or migrating code away from MuonTrap / naked Port.open / tmux. ALWAYS use — even if erlexec is mentioned only briefly. erlexec is the **sole** OS-process and PTY library in ezagent — there is no ExPTY, no node-pty equivalent, and no tmux. Training data covers erlexec poorly and the library has several easy-to-get-wrong API shapes (os_pid vs pid, monitor vs link, PTY options, `winsz` arg order, sync vs async, SIGKILL timing) that this skill documents from verified hexdocs.
---

# erlexec (Elixir) — OS process supervision with PTY + bidirectional I/O + cleanup

erlexec (Hex: `:erlexec`) is the go-to library for managing OS child processes from the BEAM when all of the following matter:
- **Interactive** stdin/stdout (not just fire-and-forget output capture)
- **PTY** (pseudo-terminal) allocation for programs that detect TTY presence (`claude`, bash `-i`, interactive REPLs, readline-based tools, full-screen TUIs)
- **Cleanup on parent death** — if the BEAM is `SIGKILL`-ed, the child must die too, without orphans
- **Signals** and **process-group** management (SIGTERM → SIGKILL with configurable delay, send arbitrary signals to the child)

ESR's `Ezagent.OSProcess` 底座 is built on top of erlexec (migrated from MuonTrap + `Port.open` in PR-3, 2026-04-22 — see `docs/notes/erlexec-migration.md`).

## erlexec is the only OS-process library — no ExPTY, no tmux

This is a deliberate, load-bearing decision for ezagent. **Do not reach for a second library.**

- **No ExPTY / node-pty-style NIF.** A purpose-built PTY NIF buys nicer resize ergonomics and on-the-fly echo toggling, but at a cost ezagent won't pay: it's a C NIF (a segfault takes down the whole BEAM VM, vs erlexec's `exec-port` being a *separate OS process* that can crash without killing the VM), and the available ones are WIP with incomplete cleanup — exactly the orphan-process problem erlexec was adopted to solve. erlexec already runs `claude` in a PTY in Ezagent production today (`os_process.ex`, `wrapper: :pty`). Use it.
- **No tmux.** Ezagent used to lean on `tmux` as the thing that *held* the PTY, with the BEAM connecting as a tmux client. tmux was removed from `dev` (the `adapters/cc_tmux/` + `handlers/tmux_proxy/` extraction; see the closed issue `docs/issues/closed-01-tmux-vs-erlexec-pty.md`). ezagent has the BEAM hold the PTY directly via erlexec, and **the BEAM is the multiplexer** — see "PTY → web" below. tmux brought its own server process, socket isolation headaches, and env-propagation bugs (`docs/notes/tmux-*.md`) for a job the BEAM does natively.

One library, one mental model: a newcomer learns erlexec and is done. That's the bar (ezagent architecture §2.1 — "少发明,多装配", fewer things to remember).

**Target version: 2.2.x** (pinned in `runtime/mix.exs`). Docs: https://hexdocs.pm/erlexec/2.2.3/.

---

## 🛑 Before you write any erlexec code

1. **Call `:exec.start/0` exactly once** — typically from your application's `start/2`. `run/2` will fail noisily if the exec port program isn't running. If your module is the consumer of a library that already starts exec, you don't need to call it again.
2. **Decide between `run` and `run_link`** — they differ in lifecycle semantics (see the "two key APIs" section below). Pick deliberately.
3. **Decide whether you need `pty`** — the single biggest decision. Programs that call `isatty()` on stdin (`claude`, bash interactive, full-screen readline apps) will misbehave or exit immediately without a PTY.
4. **`os_pid` is NOT the Erlang `pid`** — the confusion here is the #1 source of bugs. Read the "identifiers" section below before any `:exec.*` call.

---

## Identifiers — `os_pid` vs `pid`

erlexec exposes two distinct identifiers for every child:

| Name | Type | What it is | How to get it |
|---|---|---|---|
| `pid` (Erlang pid) | `pid()` | The BEAM-side GenServer that represents the child | Returned as `{:ok, pid, os_pid}` from `run/2` |
| `os_pid` | `integer()` (OS PID) | The kernel-level process id of the actual OS child | Returned alongside `pid`; also `:exec.ospid(pid)` |

**Almost every `:exec.*` call takes `os_pid`, NOT `pid`.** Examples:

```elixir
{:ok, pid, os_pid} = :exec.run(~c"/bin/cat", [:stdin, :stdout, :monitor])

# ✅ Correct — all of these take os_pid
:exec.send(os_pid, "input\n")
:exec.kill(os_pid, 9)              # SIGKILL by signum
:exec.stop(os_pid)                 # SIGTERM → delay → SIGKILL
:exec.winsz(os_pid, 24, 80)        # resize PTY — ⚠️ arg order is (os_pid, ROWS, COLS)
:exec.pty_opts(os_pid, [{:echo, false}])

# ❌ Wrong — don't pass the Erlang pid
:exec.send(pid, "input\n")          # TypeError
```

**Exception**: `:exec.ospid(pid)` takes the Erlang pid and returns the os_pid. Makes sense — it's the converter. Everything else takes os_pid.

---

## Two key APIs: `run/2` vs `run_link/2`

| | `:exec.run/2` | `:exec.run_link/2` |
|---|---|---|
| Caller → child link | none | linked |
| Caller dies → child | child keeps running (orphan risk) | child dies with caller |
| Use when | Long-lived services managed via their own monitor | Peer/worker lifetime == caller's lifetime |
| In Ezagent | Rare | Default for `Ezagent.OSProcess` workers |

**The trap**: if you use `run/2` and the caller crashes, the OS process is orphaned until the BEAM exits. `run_link/2` is almost always what you want for peer-like modules. Keep a `Process.monitor/1` (via the `:monitor` opt) for `{'DOWN', ...}` messages if you also want explicit notification.

---

## Options — the essentials

```elixir
opts = [
  :stdin,                   # pipe stdin (enables :exec.send/2)
  :stdout,                  # pipe stdout (caller gets {:stdout, os_pid, bytes})
  {:stderr, :stdout},       # merge stderr into stdout
  :monitor,                 # get {:DOWN, os_pid, :process, pid, reason} on exit
  :pty,                     # allocate PTY — needed for claude, bash -i, REPLs, etc.
  {:env, [{~c"K", ~c"V"}]}, # env vars (MUST be charlists, not binaries)
  {:cd, ~c"/some/dir"},     # working directory
  {:kill_timeout, 5},       # SIGTERM → wait 5s → SIGKILL on stop (default 5)
]
```

**Charlist vs binary** — a source of silent bugs:
- **Commands**: both `~c"claude"` and `"claude"` work.
- **`{:env, ...}` entries**: MUST be `{charlist, charlist}` pairs. `{"KEY", "val"}` (binaries) sometimes appears to work but is not documented and has failed on some OTP/erlexec version combos. Use `{~c"KEY", ~c"val"}` or convert with `String.to_charlist/1`.
- **`{:cd, path}`**: charlist. `{:cd, "path"}` (binary) fails on some setups.
- **`:exec.send/2` data**: `iodata()` — binaries are fine.

---

## Message shapes you'll pattern-match on

After `run_link` or `run` with `:monitor`, the caller receives:

```elixir
{:stdout, os_pid, bytes}              # stdout chunk (arbitrary boundaries — see "line framing" below)
{:stderr, os_pid, bytes}              # stderr chunk (unless merged)
{:DOWN, os_pid, :process, pid, reason}  # child exited (when :monitor is set)
{:EXIT, pid, reason}                  # child's Erlang pid crashed (when run_link)
```

`reason` shapes on exit:
- `:normal` — child exited 0
- `{:exit_status, n}` — child exited with status `n` (or died from signal, in which case the value is the raw wait(2) status — unpack with `:exec.status/1`)
- Process-specific atoms (e.g. `:killed` on SIGKILL)

Important: **erlexec does NOT provide `{:line, N}` framing** like native `Port`. You'll get stdout in arbitrary chunks (sometimes partial lines, sometimes multiple). Reassemble yourself:

```elixir
# In the Peer's state: buffer = ""
def handle_info({:stdout, os_pid, bytes}, %{buffer: buf} = s) when s.os_pid == os_pid do
  {lines, new_buf} = split_lines(buf <> bytes)
  Enum.each(lines, &handle_line(&1, s))
  {:noreply, %{s | buffer: new_buf}}
end

defp split_lines(bytes) do
  case String.split(bytes, "\n") do
    [only] -> {[], only}                         # no newline yet — all goes to buffer
    lines -> {Enum.drop(lines, -1), List.last(lines)}
  end
end
```

Under PTY, stdout lines come with `\r\n` (CRLF). Normalize to `\n` if downstream expects Unix line endings.

---

## Pattern: interactive sidecar (`claude`, python REPL, bash -i)

```elixir
defmodule MyInteractive do
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def send_input(pid, bytes), do: GenServer.cast(pid, {:send_input, bytes})
  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  @impl true
  def init(opts) do
    # :exec.start/0 is idempotent — safe to call even if already started
    {:ok, _} = :exec.start()

    cmd = Keyword.fetch!(opts, :cmd)                # e.g. ~c"claude" or ~c"/bin/bash -i"
    env = Keyword.get(opts, :env, [])
    subscriber = opts[:subscriber] || self()

    exec_opts = [
      :stdin,
      :stdout,
      {:stderr, :stdout},
      :monitor,
      :pty,                                          # ← critical for claude, bash -i, REPLs
      {:env, env_charlists(env)},
    ]

    case :exec.run_link(cmd, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        {:ok, %{
           exec_pid: exec_pid,
           os_pid: os_pid,
           subscriber: subscriber,
           buffer: "",
         }}

      {:error, reason} ->
        {:stop, {:exec_failed, reason}}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, s), do: {:reply, {:ok, s.os_pid}, s}

  @impl true
  def handle_cast({:send_input, bytes}, s) do
    :ok = :exec.send(s.os_pid, bytes)
    {:noreply, s}
  end

  @impl true
  def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid, buffer: buf} = s) do
    data = buf <> bytes
    {lines, new_buf} = split_lines(data)
    Enum.each(lines, &send(s.subscriber, {:line, &1}))
    {:noreply, %{s | buffer: new_buf}}
  end

  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = s) do
    Logger.info("OS child #{os_pid} exited: #{inspect(reason)}")
    {:stop, {:child_exited, reason}, s}
  end

  @impl true
  def terminate(_reason, s) do
    # Optional — run_link already handles kernel-level cleanup.
    # Useful if the child has its own graceful shutdown handshake (write an exit command, etc.)
    :exec.stop(s.os_pid)
    :ok
  end

  defp env_charlists(env) do
    for {k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)}
  end

  defp split_lines(bytes) do
    case String.split(bytes, ~r/\r?\n/) do
      [only] -> {[], only}
      lines -> {Enum.drop(lines, -1), List.last(lines)}
    end
  end
end
```

---

## Common mistakes

### ❌ Using `os_pid` instead of `pid` (or vice versa)

The single most common error. Re-read the "identifiers" table above. Rule of thumb: **every `:exec.*` call (except `:exec.ospid/1`) takes `os_pid`**.

### ❌ Forgetting `:exec.start/0`

```elixir
:exec.run(~c"echo hi", [:stdout, :sync])
# → ** (EXIT) no process: exec
```

Fix: put `:exec.start()` in your application's `start/2`, or call it idempotently from your module's init. It returns `{:ok, pid}` on first call and `{:error, {:already_started, pid}}` on subsequent calls — both are safe.

Or add `:erlexec` to `extra_applications` in `mix.exs` so OTP auto-starts it:

```elixir
# mix.exs
def application do
  [extra_applications: [:logger, :erlexec]]
end
```

### ❌ Using `Port.open` with `--capture-output`-style logic expecting bidirectional I/O

MuonTrap and raw-Port approaches both have holes for interactive use (see `docs/notes/erlexec-migration.md`). erlexec solves both with a single call. Don't hand-roll.

### ❌ No `:pty` for `claude`, bash `-i`, readline tools

```elixir
:exec.run(~c"claude", [:stdin, :stdout, :monitor])
# → claude exits immediately because isatty(0) returned false
```

Fix: add `:pty` to the option list. This is the most common cause of "the interactive binary works locally but flakes in tests".

### ❌ Forgetting `:monitor` then wondering why the caller doesn't get notified on exit

Either use `run_link` (which gives you `{:EXIT, pid, reason}` via the process link) or add `:monitor` to the options to get `{:DOWN, os_pid, :process, pid, reason}`. Without either, the child can exit without the caller ever knowing.

### ❌ Passing binaries to `{:env, ...}`

```elixir
{:env, [{"PYTHONUNBUFFERED", "1"}]}    # ❌ UNDOCUMENTED, fails on some versions
{:env, [{~c"PYTHONUNBUFFERED", ~c"1"}]}  # ✅ correct — charlists
```

Applies to `{:cd, ...}` too.

### ❌ Parsing stdout line-by-line assuming `{:stdout, os_pid, full_line}`

erlexec delivers arbitrary chunks. You will see partial lines, multiple lines in one message, and (with PTY) CRLF instead of LF. Buffer and split manually — see the `split_lines/1` helper in the pattern above.

### ❌ Expecting `run/2` children to die with the caller

`run/2` does NOT link. If the caller crashes, the child keeps running until it exits on its own OR you explicitly `:exec.stop/1` it. Use `run_link/2` for peer-like workers.

### ❌ Calling `:exec.send(os_pid, :eof)` when `:stdin` wasn't set

`:exec.send/2` fails if the process wasn't started with `:stdin`. Always include `:stdin` in the options if you intend to write. `:eof` is a valid data value — sends EOF without closing the whole port.

---

## Signals and graceful shutdown

| Goal | Call |
|---|---|
| Graceful exit (SIGTERM → wait `kill_timeout` → SIGKILL) | `:exec.stop(os_pid)` |
| Send a specific signal | `:exec.kill(os_pid, signum)` — e.g. `:exec.kill(os_pid, 15)` for SIGTERM |
| Change SIGKILL timing | include `{:kill_timeout, seconds}` in run opts |
| Send end-of-input (child reads a final chunk, then stdin closes) | `:exec.send(os_pid, :eof)` |

Signals: 1=SIGHUP, 2=SIGINT, 9=SIGKILL, 15=SIGTERM, 2=SIGINT (or send `<<2>>` via stdin if PTY with default vintr=Ctrl-C).

---

## BEAM-exit cleanup — how it actually works

The erlexec Hex package includes a small C++ program called `exec-port` that runs as a child of the BEAM VM. `run_link` spawns the target child via `exec-port`. When the BEAM terminates (any reason, including SIGKILL), `exec-port` detects parent death and reaps every child it started — SIGTERM → `kill_timeout` → SIGKILL.

This is more reliable than MuonTrap's wrapper approach because `exec-port` stays attached to the BEAM itself, not to the individual children. And it works on macOS (where PR_SET_PDEATHSIG doesn't exist) via the OS's native process-death signaling.

**Test this invariant** for any OSProcess peer you add:

```elixir
test "child OS process dies within 10s of Elixir owner kill" do
  Process.flag(:trap_exit, true)
  {:ok, pid} = MyInteractive.start_link(cmd: ~c"/bin/sleep 60")
  {:ok, os_pid} = MyInteractive.os_pid(pid)

  Process.exit(pid, :kill)
  assert_receive {:EXIT, ^pid, :killed}, 1_000

  # Poll up to 10s
  assert Enum.reduce_while(1..20, nil, fn _, _ ->
    case System.cmd("ps", ["-p", Integer.to_string(os_pid)]) do
      {_, 0} -> :timer.sleep(500); {:cont, nil}
      {_, _} -> {:halt, :gone}
    end
  end) == :gone
end
```

---

## PTY → web — the BEAM is the multiplexer

A common confusion: "if the BEAM holds the PTY, how does a browser connect to it?" The premise is backwards. **erlexec does not talk to the web, and it doesn't need to.** It hands the BEAM the PTY master byte stream; "web exposure" is a separate layer that works identically no matter how the PTY was created.

```
OS child (claude) ──PTY── erlexec ──{:stdout, os_pid, bytes}── BEAM ──Phoenix.PubSub/Channel── browser (xterm.js)
        ▲                                                        │
        └──── :exec.send(os_pid, keystroke) ◄── LiveView event ◄──┘
                                                                  │
                                          BEAM can also fan the same bytes out to:
                                          a log file · an AI analyzer · a Feishu message · a 2nd browser
```

**The BEAM holding the PTY is the *enabler* of web exposure, not a blocker.** Because the bytes pass through the BEAM, the BEAM can send them anywhere — including to many consumers at once.

### Multi-attach without tmux

tmux's appeal was multi-client attach: several windows view one session. With the BEAM holding the PTY you get the same thing, with the multiplexing moved *into* the BEAM:

- **tmux model:** N tmux clients attach to the tmux server process.
- **erlexec model:** N WebSockets subscribe to the same `Phoenix.PubSub` topic; the BEAM broadcasts each `{:stdout, os_pid, bytes}` chunk to all of them.

In ezagent this is the `Session.CC = pty(peer) + web(proxy)` split (architecture §6.2): the `pty` peer owns the erlexec child and republishes its output on a PubSub topic; each `web` proxy is a LiveView that subscribes to that topic. One CC session, N browsers attached — no tmux server, no socket isolation, no env-propagation bugs.

### The wiring

```elixir
# pty peer — owns the erlexec child, republishes output
def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid} = s) do
  Phoenix.PubSub.broadcast(Ezagent.PubSub, "cc:#{s.session_id}", {:pty_out, bytes})
  {:noreply, s}
end

# input from any web proxy
def handle_cast({:pty_in, bytes}, s) do
  :ok = :exec.send(s.os_pid, bytes)   # bytes is iodata — binaries are fine
  {:noreply, s}
end

# resize request from a web proxy (xterm.js reported a new size)
def handle_cast({:resize, cols, rows}, s) do
  :ok = :exec.winsz(s.os_pid, rows, cols)   # ⚠️ erlexec arg order is (os_pid, ROWS, COLS)
  {:noreply, s}
end
```

### Gotchas specific to the web path

- **`winsz` arg order is `(os_pid, rows, cols)` — rows first.** xterm.js and most JS terminal code think in `(cols, rows)`. The mismatch produced a real Ezagent bug (PR-22) that took three PRs to find: a `(cols, rows)` call against erlexec's `(rows, cols)` signature gives a wrong-but-plausible size, so output wraps subtly wrong instead of failing loudly. Convert at the boundary and comment it.
- **PTY output is CRLF.** Under `:pty`, lines end with `\r\n`. xterm.js *wants* CRLF — forward it raw. But any non-terminal consumer (a log, an AI analyzer, a line-based parser) needs `\r\n` → `\n` normalization first. Normalize per-consumer, not at the source.
- **Don't normalize input.** xterm.js already sends correct control sequences (arrow keys, Ctrl-C as `\x03`, etc.). Forward browser keystrokes to `:exec.send/2` raw — re-encoding them breaks interactive programs.
- **WebSocket keepalive.** Idle PTY sessions get dropped by proxies. Send a ping every ~30s from the `web` proxy; this is a transport concern, unrelated to erlexec.
- **One writer, many readers.** Output fans out freely via PubSub, but only feed `:exec.send/2` from one place (the `pty` peer). If multiple proxies could write, serialize through the peer's mailbox — never call `:exec.send/2` from the proxies directly.

---

## Decision table: when erlexec is the right choice

| Scenario | Recommendation |
|---|---|
| Short-lived command, capture output | `:exec.run(cmd, [:sync, :stdout])` — erlexec works but `System.cmd/3` is simpler |
| Long-lived pure-output daemon (no stdin) | erlexec `run_link` with `:stdout` (or `MuonTrap.Daemon` — both fine) |
| Long-lived daemon, need to send stdin | erlexec `run_link` + `:stdin` (MuonTrap cannot do this cleanly) |
| Interactive: `claude`, bash -i, REPL | erlexec `run_link` + `:pty` — **the only library ezagent uses** |
| Stream a PTY to a browser terminal | erlexec `run_link` + `:pty`, BEAM fans bytes out over Phoenix — see "PTY → web" |
| Need signals, PTY resize, process groups | erlexec — feature-complete for all of ezagent's needs |

---

## References

- Official docs: https://hexdocs.pm/erlexec/2.2.3/
- Source: https://github.com/saleyn/erlexec
- Ezagent migration rationale: `docs/notes/erlexec-migration.md`
- tmux retirement (why the BEAM holds the PTY now): `docs/issues/closed-01-tmux-vs-erlexec-pty.md`
- Ezagent底座 module: `runtime/lib/esr/os_process.ex` (`wrapper: :pty` runs `claude`; `wrapper: :plain` for JSON-line sidecars)
- Ezagent peer consumer: `runtime/lib/esr/py_process.ex` (Python sidecar, no `:pty`)
