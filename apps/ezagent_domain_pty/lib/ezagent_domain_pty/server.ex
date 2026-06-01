defmodule Ezagent.Domain.Pty.Server do
  @moduledoc """
  PTY-managed child process running an arbitrary command (cc plugin
  uses this for `claude`; future plugins use it for `/bin/bash`, an
  echo runner, etc.).

  Promoted from `Ezagent.PluginCc.PtyServer` to the Domain.Pty app per
  SPEC v1 §3.1 (Domain.Pty architecture, 2026-05-21). Module body is
  unchanged from the original cc-plugin implementation modulo the
  Registry/Supervisor name renames (now `EzagentDomainPty.{Registry,
  Supervisor}`); semantics, auto-prompt scanner, status snapshot,
  trigger_redraw and snapshot_buffer all preserve their pre-move
  behavior so the cc plugin (and tests) keep working unchanged.

  ## Background — same as the pre-move docstring

  Phase 4-completion PR 8: ESR's first plugin-managed child process.
  Uses `:exec.run/2` (erlexec) for PTY allocation (claude TUI needs
  a real tty). Post-Phase-5 (Allen 2026-05-17): inlined the previous
  `bash cc-bridge-attach.sh` wrapper into `spawn_claude_directly/1`,
  and routes `agent_uri` through mcp.json (not env-var passthrough)
  so the Python bridge always announces with the correct agent_uri.

  ## Generic auto-prompt scanner (Phase 6 PR 19)

  Allen 2026-05-18 (after dev-channels confirm worked but MCP init
  still didn't fire): "监控 pty stream 侦测到关键字后再 send key".
  Generalized the one-shot dev-channels confirm into a data-driven
  list of `{name, match, send, fired?}` rules. Each PTY stdout/stderr
  chunk accumulates into a stripped buffer; the scanner walks every
  still-unfired rule and fires those whose pattern matches.

  Adding a new auto-input becomes one entry in
  `default_auto_prompts/0` — no scanner code change. Tests + callers
  can also inject extra prompts via `:auto_prompts` arg at spawn.

  Match shapes:
  - `String.t()` — substring contains
  - `[String.t()]` — ALL substrings must be present (AND)
  - `Regex.t()` — regex match

  Built-in prompts:
  - `:dev_channels_dialog` — `--dangerously-load-development-channels`
    security confirm. Sends `"1\r"`.
  - `:trust_folder_dialog` — claude's first-run "Is this a project you
    trust?" folder-trust prompt, shown the first time claude runs in a
    cwd not yet recorded as trusted in its config dir. PtyServer always
    spawns claude in an operator-configured sandbox cwd, so trust is
    implied (same rationale as auto-accepting dev channels). Sends
    `"1\r"` to pick "Yes, I trust this folder". Without this the PTY
    hangs at the dialog → MCP never initializes → `esr-bridge` never
    binds → `EagerBridge.ensure_bound!/2` times out.

  Phase 6 PR 19 also added eager bridge-announce in the Python MCP
  bridge so the Agent Kind registers even when claude doesn't lazily
  initialize the MCP server.

  ## Crash policy

  Trap_exit + erlexec `:monitor` — child process death triggers stop;
  DynamicSupervisor restarts with backoff (3-in-60s default).

  ## Test mode

  In `Mix.env() == :test`, `:exec.run/2` is short-circuited. Real
  spawn requires host bash + script + claude binary; tests assert the
  Template Class path works without exercising claude itself.
  """

  use GenServer
  require Logger

  alias Ezagent.AnsiStrip

  defstruct [
    :agent_uri,
    :cwd,
    :exec_pid,
    :os_pid,
    :test_mode,
    # Optional cmd override. Two accepted shapes:
    #   * a STRING — run via `/bin/sh -c` (legacy; tests pass a mock
    #     script path here, e.g. `"bash /tmp/mock.sh"`).
    #   * a LIST of strings — argv form `[Cmd | Args]`, executed
    #     directly via `execve` with NO shell. Each element is exactly
    #     one argv element — no element can split into multiple args or
    #     introduce shell metacharacter behavior. The cc plugin builds
    #     its `claude ...` invocation as a list so operator-controlled
    #     sandbox paths cannot inject flags or shell commands (codex
    #     HIGH-2).
    :cmd_override,
    # Optional extra environment variables for the spawned child,
    # `%{"NAME" => "value"}`. Merged into the inherited OS env. The cc
    # plugin uses this to pass `CLAUDE_CONFIG_DIR` instead of a shell
    # `VAR=val cmd` prefix (which is unavailable in argv form and was
    # shell-injectable in string form — codex HIGH-2).
    :cmd_env,
    pty_buffer: "",
    # Phase 6 PR 19 (Allen 2026-05-18): generalize auto-confirm into a
    # data-driven list of prompt patterns. Each entry:
    #   %{name: atom, match: String.t() | [String.t()] | Regex.t(),
    #     send: iodata, fired?: boolean}
    # match: string = substring; list of strings = ALL must match
    # (AND); Regex = pattern match. send: bytes to write to PTY stdin.
    # fired? = true after one match → never re-fires (idempotent).
    auto_prompts: [],
    # 2026-06-01 finding: claude 2.1.92 shows an OAuth login screen when
    # CLAUDE_CONFIG_DIR has no valid credentials (Keychain isolation changed
    # in 2.1.92 — fresh dirs no longer inherit Keychain; each dir needs its
    # own Keychain entry). EagerBridge polls this flag and short-circuits with
    # {:error, :oauth_required} so callers get a clear error instead of a
    # 15s timeout with spurious "OAuth error: Invalid code" messages.
    oauth_blocked?: false,
    # PTY-phase-state-machine 2026-05-26 follow-up (b). Three canonical
    # phases on the OS subprocess (per Allen's directive — exactly
    # three, no `:initializing` / `:ready` / `:respawning` middle states):
    #
    #   :starting — after init/1 accepted args but before :exec.run
    #               returned an os_pid (or after respawn invoked but
    #               PTY not yet up)
    #   :running  — :exec.run returned {:ok, _, os_pid} and the
    #               link/monitor is intact
    #   :dead     — :exec.run failed, OR {:DOWN, ...} arrived from
    #               erlexec, OR terminate/2 ran
    #
    # Broadcasts on every transition via Phoenix.PubSub on topic
    # `"pty:phase:" <> URI.to_string(agent_uri)`. Best-effort: a
    # broadcast failure (PubSub down) logs + degrades; it does NOT
    # block the primary spawn / write / shutdown path. Phase tracking
    # exists for OPERATOR VISIBILITY (Sandbox slice + LV badge) — its
    # failure must never wedge the PTY itself.
    phase: :starting,
    # Tracks whether `:dead` has been broadcast already so the
    # terminate/2 path doesn't double-emit after a {:DOWN, ...} or
    # :exec.run failure has already published the terminal phase.
    dead_broadcast?: false
  ]

  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    # PR-D2: register under :via Registry keyed by agent_uri so any
    # concurrent attempt to spawn the same agent collapses to a single
    # process atomically (start_link returns {:error, {:already_started,
    # pid}} for the second caller, no race window).
    GenServer.start_link(__MODULE__, args, name: via(agent_uri))
  end

  @doc "Build the :via tuple for an agent_uri (used as a process name)."
  def via(%URI{} = agent_uri) do
    {:via, Registry, {EzagentDomainPty.Registry, URI.to_string(agent_uri)}}
  end

  @doc """
  Status snapshot for `/admin/agents/:uri` LV (Phase 5 PR 3).

  Returns the live PTY's introspectable state — operator-facing fields
  only. Heavy fields (full pty_buffer) are trimmed; recent output is
  ANSI-stripped + bounded.
  """
  def status(pid) when is_pid(pid) do
    state = :sys.get_state(pid, 500)

    recent_lines =
      state.pty_buffer
      |> AnsiStrip.strip()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(-50)

    %{
      agent_uri: state.agent_uri,
      cwd: state.cwd,
      os_pid: state.os_pid,
      exec_pid: state.exec_pid,
      test_mode: state.test_mode,
      running: state.exec_pid != nil or state.test_mode,
      # PTY-phase-state-machine follow-up (b): expose the canonical
      # three-phase state so operator LV and integration tests can
      # observe the SAME field they would receive via PubSub.
      phase: state.phase || :starting,
      # Phase 6 PR 19: expose the auto-prompt state so operator LV
      # can see which prompts fired vs which are still waiting.
      auto_prompts:
        Enum.map(state.auto_prompts, fn p ->
          %{name: p.name, fired?: p.fired?}
        end),
      recent_output: recent_lines,
      buffer_bytes: byte_size(state.pty_buffer)
    }
  end

  @doc """
  Walks the DynamicSupervisor's children looking for a PtyServer whose
  state's `agent_uri` matches. Returns `{:ok, pid}` or `:error`.

  Cheap enough for v1 (~few children typically); switch to a Registry
  if PtyServer count gets into the dozens.
  """
  def find_by_agent_uri(%URI{} = agent_uri) do
    target = URI.to_string(agent_uri)

    sup_pid = Process.whereis(EzagentDomainPty.Supervisor)

    if sup_pid do
      DynamicSupervisor.which_children(sup_pid)
      |> Enum.find_value(:error, fn
        {_, child_pid, :worker, _} when is_pid(child_pid) ->
          try do
            state = :sys.get_state(child_pid, 500)
            if URI.to_string(state.agent_uri) == target, do: {:ok, child_pid}, else: nil
          catch
            _, _ -> nil
          end

        _ ->
          nil
      end)
    else
      :error
    end
  end

  @doc """
  Write bytes to the PTY's stdin (called by Ezagent.Behavior.Pty.invoke(:write, ...)).

  Returns `:ok` on success or `{:error, reason}`. Test_mode short-circuits
  to `:ok` without invoking erlexec.
  """
  def write_input(pid, bytes) when is_pid(pid) and is_binary(bytes) do
    GenServer.call(pid, {:write_input, bytes}, 1000)
  end

  @doc "PubSub topic for an agent's PTY stdout/stderr stream (Phase 5 PR 4)."
  def output_topic(%URI{} = agent_uri),
    do: "pty:output:" <> URI.to_string(agent_uri)

  @doc """
  PubSub topic for an agent's PTY phase transitions (PTY-phase-state-machine
  2026-05-26 follow-up b).

  Subscribers (Sandbox slice updater + TerminalLive badge) receive
  messages of shape `{:pty_phase, agent_uri, phase, meta}` where:

    * `phase` is one of `:starting | :running | :dead`
    * `meta` carries `%{os_pid: integer() | nil, reason: term() | nil,
      at: System.os_time(:millisecond)}`

  Best-effort: a broadcast failure (PubSub down) is logged but never
  raises into the calling GenServer's primary path.
  """
  def phase_topic(%URI{} = agent_uri),
    do: "pty:phase:" <> URI.to_string(agent_uri)

  @doc """
  Public accessor for the current phase of a live PtyServer.

  Returns `:starting | :running | :dead` for a live server, or
  `:dead` when no server exists (consistent with "no process → not
  running"). Callers that need to distinguish "no server" from
  "server in :dead" should use `Ezagent.Domain.Pty.alive?/1` first.
  """
  @spec phase(URI.t()) :: :starting | :running | :dead
  def phase(%URI{} = agent_uri) do
    case find_by_agent_uri(agent_uri) do
      {:ok, pid} ->
        try do
          state = :sys.get_state(pid, 500)
          state.phase || :dead
        catch
          _, _ -> :dead
        end

      :error ->
        :dead
    end
  end

  @doc """
  PR #128 — return the current accumulated stdout buffer for replay
  on new xterm connections (ttyd-style initial-render fix).

  Without this, a fresh `/admin/agents/:uri/terminal` mount shows
  a black screen until claude (or whatever TUI is running) emits
  fresh output. With this, the LV pushes the existing buffer to
  xterm at mount and the operator sees the current screen state
  immediately.

  Bounded to the last `max_bytes` (default 64KB) so a long-running
  session doesn't send megabytes through PubSub on every reconnect.
  Most TUIs (claude included) re-emit their full visible screen
  within the last few KB of output via ANSI cursor + redraw
  sequences, so 64KB is generous.

  Returns `{:ok, binary}` or `:error` if PtyServer not alive.
  """
  @spec snapshot_buffer(URI.t(), pos_integer()) :: {:ok, binary()} | :error
  def snapshot_buffer(%URI{} = agent_uri, max_bytes \\ 65_536) do
    case find_by_agent_uri(agent_uri) do
      {:ok, pid} ->
        try do
          state = :sys.get_state(pid, 500)
          buf = state.pty_buffer

          tail =
            if byte_size(buf) > max_bytes do
              binary_part(buf, byte_size(buf) - max_bytes, max_bytes)
            else
              buf
            end

          {:ok, tail}
        catch
          _, _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  PR #128 — trigger a TUI redraw by sending a brief winsize change
  followed by the original size. Most TUIs (claude included) listen
  for SIGWINCH and re-emit their full screen.

  This is the **belt-and-suspenders** companion to `snapshot_buffer/2`:
  buffer replay handles the cumulative output; winsz nudge handles
  the case where the TUI's last redraw is older than the bounded
  buffer window.
  """
  @spec trigger_redraw(URI.t()) :: :ok | :error
  def trigger_redraw(%URI{} = agent_uri) do
    case find_by_agent_uri(agent_uri) do
      {:ok, pid} ->
        try do
          state = :sys.get_state(pid, 500)

          if state.os_pid do
            # Briefly shrink + restore to provoke a redraw without
            # leaving a smaller window pinned.
            :exec.winsz(state.os_pid, 40, 119)
            Process.sleep(50)
            :exec.winsz(state.os_pid, 40, 120)
          end

          :ok
        catch
          _, _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc "List all live PtyServer agent_uris under the DynamicSupervisor."
  def list_agents do
    sup_pid = Process.whereis(EzagentDomainPty.Supervisor)

    if sup_pid do
      DynamicSupervisor.which_children(sup_pid)
      |> Enum.flat_map(fn
        {_, child_pid, :worker, _} when is_pid(child_pid) ->
          try do
            state = :sys.get_state(child_pid, 500)
            [%{agent_uri: state.agent_uri, pid: child_pid, os_pid: state.os_pid}]
          catch
            _, _ -> []
          end

        _ ->
          []
      end)
    else
      []
    end
  end

  @impl true
  def init(args) do
    agent_uri = Map.fetch!(args, :agent_uri)
    cwd = Map.get(args, :cwd, File.cwd!())
    test_mode = Map.get(args, :test_mode, Mix.env() == :test)
    cmd_override = Map.get(args, :cmd_override)
    cmd_env = Map.get(args, :cmd_env, %{})

    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      agent_uri: agent_uri,
      cwd: cwd,
      test_mode: test_mode,
      cmd_override: cmd_override,
      cmd_env: cmd_env,
      auto_prompts: default_auto_prompts() ++ Map.get(args, :auto_prompts, []),
      phase: :starting
    }

    # PTY-phase-state-machine follow-up (b): broadcast :starting as
    # soon as init/1 has built the struct. Subscribers (Sandbox slice
    # + LV badge) see the agent moving through `:starting → :running`
    # / `:starting → :dead` even when :exec.run/2 fails fast.
    broadcast_phase(state, :starting, %{})

    {:ok, state, {:continue, :spawn_pty}}
  end

  # Phase 6 PR 19 — well-known prompts the spawned `claude` may pause
  # on. Each prompt fires once; the data-driven structure means new
  # prompts get added here without touching the dispatch loop.
  # Exposed (`def` + `@doc false`, not `defp`) only so the dialog match
  # specs can be unit-tested against real ANSI-stripped PTY buffers
  # without a live claude spawn (see server_auto_prompts_test.exs).
  @doc false
  def default_auto_prompts do
    [
      %{
        name: :theme_picker_dialog,
        # claude >= ~2.1 shows a FIRST-RUN theme picker ("Let's get started /
        # Choose the text style…") whenever it starts in a fresh
        # CLAUDE_CONFIG_DIR — which every per-agent cc sandbox is. It blocks
        # BEFORE the trust + dev-channels dialogs, so without this the spawned
        # claude hangs on the theme menu, never reaches MCP init, and
        # esr-bridge never binds (the 2026-06 regression: older claude on the
        # original dev machine had no theme picker). Anchored on the two static
        # prompt lines (rendered atomically, so they survive the ANSI-strip
        # that fragments animated banners).
        #
        # `repeat?: true` (NOT one-shot): the theme picker is the FIRST screen,
        # rendered ~1s in — before claude's TUI is ready for input — so a single
        # keystroke sent that early is silently eaten (the same "calling too
        # early eats the \r" hazard documented for the bridge kick). A one-shot
        # prompt would mark itself fired and never retry, leaving claude stuck
        # on the menu forever (verified: the prompt "matched" in the log yet the
        # agent never bound). So we RE-fire (rate-limited in scan_auto_prompts/1)
        # until the menu clears. We send a bare "\r" — accept the pre-highlighted
        # "Dark mode" default — not "1\r": Enter is harmless if a re-fire leaks
        # onto the next dialog (trust / dev-channels both default-highlight their
        # safe option), whereas a stray "1" could land as text in the chat input.
        match: ["Choose the text style", "looks best with your terminal"],
        send: "\r",
        repeat?: true,
        fired?: false
      },
      %{
        name: :dev_channels_dialog,
        # Anchor on the menu OPTION label, not the WARNING prose: claude's
        # TUI animates/redraws the banner ("Loading…") with cursor-move
        # escapes, so after ANSI-strip the word can fragment ("L ading"),
        # breaking a literal "Loading development channels" match. The
        # option-1 label is rendered atomically and is specific enough to
        # this exact dialog to avoid false positives.
        match: ["development channels", "I am using this for local development"],
        send: "1\r",
        fired?: false
      },
      %{
        name: :trust_folder_dialog,
        match: ["Is this a project you", "trust this folder"],
        send: "1\r",
        fired?: false
      }
    ]
  end

  @impl true
  def handle_continue(:spawn_pty, %__MODULE__{test_mode: true} = state) do
    Logger.info(
      "PtyServer test_mode: would spawn claude for " <>
        "agent=#{URI.to_string(state.agent_uri)} cwd=#{state.cwd}"
    )

    # PTY-phase-state-machine follow-up (b): test_mode short-circuits
    # the real spawn but STILL needs to flip :starting → :running so
    # subscribers (Sandbox + LV badge) see the canonical transition
    # sequence. Unit tests subscribing to phase_topic/1 assert on
    # both :starting AND :running arriving in test mode.
    state = %{state | phase: :running}
    broadcast_phase(state, :running, %{os_pid: nil})

    {:noreply, state}
  end

  def handle_continue(:spawn_pty, state) do
    case spawn_claude_directly(state) do
      {:ok, exec_pid, os_pid} ->
        Logger.info(
          "PtyServer spawned claude os_pid=#{os_pid} for agent=#{URI.to_string(state.agent_uri)}"
        )

        # PTY-pid-files 2026-05-26 follow-up (a): persist os_pid so the
        # orphan reaper at next-BEAM boot can discover prior-incarnation
        # children without `ps` scanning. Best-effort: write failure is
        # logged inside PidFile but does not block the spawn — a missing
        # pid file just degrades reaper coverage on the NEXT brutal-kill
        # cycle (same as today's behavior for pre-fix orphans).
        _ = Ezagent.Runtime.PidFile.write("cc", state.agent_uri, os_pid)

        # Per old esr's PR-24 lesson: claude's TUI queries TIOCGWINSZ
        # to learn terminal size and BLOCKS rendering past initial
        # control sequences until it gets a non-zero size. Send a
        # default 120×40 winsize ~500ms after spawn (gives claude
        # time to finish initial DA query).
        # Per memory `feedback_verify_ffi_arg_order`: rows FIRST,
        # cols second.
        Process.send_after(self(), :send_default_winsize, 500)

        new_state = %{state | exec_pid: exec_pid, os_pid: os_pid, phase: :running}
        broadcast_phase(new_state, :running, %{os_pid: os_pid})

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("PtyServer: spawn failed: #{inspect(reason)}")
        new_state = %{state | phase: :dead, dead_broadcast?: true}
        broadcast_phase(new_state, :dead, %{reason: reason, os_pid: nil})
        {:stop, {:spawn_failed, reason}, new_state}
    end
  end

  # Spawns the configured child command under erlexec's PTY.
  #
  # Domain.Pty move (2026-05-21 SPEC v1, PR-A): the cmd string is
  # supplied by the caller (cc plugin's `Template.CcAgent` builds the
  # `claude --mcp-config ...` invocation; future plugins like an echo
  # shell agent would supply `"/bin/bash -i"`). This keeps
  # `ezagent_domain_pty` Tier-2 — no plugin deps. The legacy
  # `cmd_override` arg is still honored for back-compat with existing
  # callers/tests; in practice cc.agent's `Ezagent.Domain.Pty.start/2`
  # path always supplies `cmd_override`.
  #
  # Phase 7 PR 32b (rebrand-3) — cc-side context: cut over from v1
  # prototype writer (HTTP/SSE) to v2 writer (Phoenix Channel
  # WebSocket). The MCP config writer + claude invocation is built by
  # the cc plugin and passed in as `cmd_override`; this Server module
  # no longer references any cc-plugin module.
  # erlexec frames each run command to its `exec-port` over a {packet,2}
  # channel — 65535 bytes max (deps/erlexec/src/exec.erl). If the
  # term_to_binary'd run command exceeds it, the BEAM port write fails
  # with :einval, which crashes the SHARED node-wide `:exec` manager and
  # takes EVERY subsequent PTY/Python spawn down (:no_pty), not just this
  # one. Two distinct sources have hit this: an oversized `{:env, ...}`
  # (fixed in build_env/1) and an oversized argv (e.g. a large soul
  # inlined via --append-system-prompt; cc now passes souls by file).
  # This guard is the backstop: estimate the command size and fail THIS
  # spawn alone with a clear error rather than letting any future
  # oversized command become a node-wide outage.
  @packet2_limit 65_535
  # Headroom for erlexec's own framing + the non-cmd/env run options.
  @command_size_headroom 4_096

  defp spawn_claude_directly(state) do
    exec_cmd = build_exec_cmd(state.cmd_override, state.agent_uri)
    env = build_env(state)

    with :ok <- check_command_size(exec_cmd, env) do
      case :exec.run(exec_cmd, [
             :pty,
             :monitor,
             # `:stdin` keeps the child's stdin pipe open so :exec.send/2
             # can write to it (dev-channels auto-confirm "1\r"). Without
             # this, child sees EOF on stdin → `read` fails → claude can't
             # see operator input.
             :stdin,
             {:env, env},
             {:cd, String.to_charlist(state.cwd)},
             :stderr,
             :stdout
           ]) do
        {:ok, exec_pid, os_pid} -> {:ok, exec_pid, os_pid}
        err -> err
      end
    end
  end

  @doc false
  # Proxy for the size erlexec encodes for its {packet,2} port write.
  # exec_cmd (argv) + the env list dominate; term_to_binary them together.
  def estimated_command_size(exec_cmd, env) do
    byte_size(:erlang.term_to_binary({exec_cmd, env}))
  end

  defp check_command_size(exec_cmd, env) do
    size = estimated_command_size(exec_cmd, env)

    if size <= @packet2_limit - @command_size_headroom do
      :ok
    else
      {:error, {:command_too_large, size}}
    end
  end

  # Translate a `cmd_override` into the form `:exec.run/2` expects.
  #
  # codex HIGH-2 — `:exec.run/2` runs a single binary/charlist via
  # `/bin/sh -c` (shell — metacharacters are interpreted) but runs a
  # LIST of binaries/charlists directly via `execve` with NO shell.
  # The argv (list) form is the safe path: each element is exactly one
  # `argv[]` entry, so an operator-controlled element containing
  # spaces, `;`, `$(...)`, backticks or a stray ` --flag` is delivered
  # to the program verbatim as a SINGLE argument — it can neither
  # split into extra arguments nor be interpreted by a shell.
  #
  # Two accepted shapes:
  #   * list  → argv form, no shell. The cc plugin builds the `claude`
  #             invocation this way so operator sandbox paths can never
  #             inject a flag or a command.
  #   * string → legacy `/bin/sh -c` form, kept for back-compat with
  #             callers/tests that pass a fixed, trusted command line
  #             (e.g. `"/bin/bash -i"`, `"bash /tmp/mock.sh"`).
  defp build_exec_cmd(cmd, _agent_uri) when is_list(cmd) do
    Enum.map(cmd, fn
      arg when is_binary(arg) -> String.to_charlist(arg)
      arg when is_list(arg) -> arg
    end)
  end

  defp build_exec_cmd(cmd, _agent_uri) when is_binary(cmd), do: String.to_charlist(cmd)

  defp build_exec_cmd(nil, agent_uri) do
    # No cmd supplied. The pre-move behavior built a `claude ...`
    # invocation here; that lived in plugin_cc and could not move to
    # Tier-2 Domain.Pty. Callers MUST now supply `cmd_override`. Crash
    # explicitly rather than masking the misuse —
    # `feedback_let_it_crash_no_workarounds`.
    raise ArgumentError,
          "Ezagent.Domain.Pty.Server: no `cmd_override` provided for " <>
            "agent_uri=#{URI.to_string(agent_uri)}. Callers must build " <>
            "the command (string or argv list) and pass it as :cmd_override; " <>
            "cc plugin's Template.CcAgent does this via Ezagent.Domain.Pty.start/2."
  end

  # Environment for the spawned child.
  #
  # Pass ONLY the vars we add or override — NEVER the whole inherited
  # environment. erlexec's `exec-port` already hands the child THIS
  # BEAM's full environment (the operator's PATH / HOME / proxy / API
  # key / etc. exported in the shell where `mix phx.server` runs flow
  # through automatically via OS process inheritance), so re-enumerating
  # `:os.getenv()` into `{:env, ...}` is redundant — and actively
  # dangerous:
  #
  #   * erlexec frames every run command to its `exec-port` over a
  #     `{packet, 2}` channel — max 65535 bytes (deps/erlexec/src/exec.erl
  #     line ~989). Splatting the full environment can push the
  #     `term_to_binary`-encoded command past that limit; the BEAM then
  #     fails the port write with `:einval`, which crashes the erlexec
  #     `:exec` manager and takes PTY spawns down for the WHOLE node
  #     (every later spawn → `:no_pty`), not just this agent. This is the
  #     bug once misread as an "OTP 28 / erlexec 2.3.0 PTY
  #     incompatibility" — the real trigger was environment *size*.
  #   * an env entry with an empty key (e.g. a var whose name begins with
  #     `=`) is rejected by erlexec as "invalid env argument".
  #
  # Relying on inheritance avoids both and matches the documented
  # `:cmd_env` contract ("merged into the inherited OS env"). Anything
  # claude needs that is NOT already in the ambient env is passed
  # explicitly by the caller via `:cmd_env` (the cc plugin does this for
  # CLAUDE_CONFIG_DIR / EZAGENT_AGENT_TOKEN).
  #
  # Exposed (`def` + `@doc false`, not `defp`) only so the override-only
  # / size-bounded invariant can be unit-tested without a live PTY spawn
  # (see server_env_test.exs).
  @doc false
  def build_env(state) do
    # Caller-supplied extra env (e.g. cc plugin's CLAUDE_CONFIG_DIR).
    # Passed as a structured `{name, value}` pair to `:exec.run/2` —
    # NOT interpolated into any command line — so the value cannot be
    # shell-interpreted (codex HIGH-2).
    cmd_env =
      (state.cmd_env || %{})
      |> Enum.map(fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    [
      {~c"EZAGENT_AGENT_URI", String.to_charlist(URI.to_string(state.agent_uri))},
      # PTY-orphan-restart 2026-05-26 round-2 (codex finding #2) — tag
      # the subprocess with THIS DEPLOYMENT's identity. The plugin's
      # OrphanReaper compares against the same identity at boot: a
      # subprocess whose tag differs belongs to a DIFFERENT deployment
      # (parallel dev tree, another release path, different OS user's
      # instance) and is NOT ours to reap, even though its URI is absent
      # from this BEAM's local Pty registry. See `Ezagent.DeploymentId`
      # for identity composition.
      {~c"EZAGENT_DEPLOYMENT_ID", String.to_charlist(Ezagent.DeploymentId.deployment_id())}
    ] ++ cmd_env
  end

  # --- erlexec messages -----------------------------------------------

  @impl true
  def handle_call({:write_input, _bytes}, _from, %__MODULE__{test_mode: true} = state) do
    # Tests record bytes_written in slice without invoking erlexec; the
    # invariant test asserts dispatch path was followed, not that the
    # bytes physically reached a real PTY.
    {:reply, :ok, state}
  end

  def handle_call({:write_input, bytes}, _from, %__MODULE__{exec_pid: exec_pid} = state)
      when exec_pid != nil do
    try do
      :exec.send(exec_pid, bytes)
      {:reply, :ok, state}
    catch
      kind, reason ->
        Logger.warning("PtyServer.write_input failed (#{inspect(kind)}, #{inspect(reason)})")

        {:reply, {:error, {kind, reason}}, state}
    end
  end

  def handle_call({:write_input, _bytes}, _from, state),
    do: {:reply, {:error, :pty_not_alive}, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning(
      "PtyServer: child process exited for #{URI.to_string(state.agent_uri)}: #{inspect(reason)}"
    )

    # PTY-phase-state-machine follow-up (b): the OS subprocess just
    # died — publish the terminal :dead phase BEFORE returning {:stop,
    # ...} so subscribers see the transition while this GenServer is
    # still alive enough to broadcast (terminate/2 would also fire,
    # but `dead_broadcast?: true` short-circuits the duplicate emit).
    new_state = %{state | phase: :dead, dead_broadcast?: true}
    broadcast_phase(new_state, :dead, %{reason: reason, os_pid: state.os_pid})

    {:stop, {:child_exited, reason}, new_state}
  end

  # stdout / stderr chunks from erlexec
  def handle_info({stream, _os_pid, data}, state) when stream in [:stdout, :stderr] do
    chunk = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

    # Scrub to valid UTF-8 before logging. claude >= 2.1 paints a Unicode
    # welcome banner (block art ░▓█, ellipsis …) whose multi-byte codepoints
    # get split across PTY read chunks, so a single chunk can hold a PARTIAL
    # UTF-8 sequence (e.g. the lead byte 0xE2 of "…" with no trailer).
    # Interpolating that invalid binary into a log message crashes the Logger
    # formatter ("bad return value from Logger formatter") *inside this
    # handle_info*, and OTP then force-removes the failing handler — collateral
    # damage to the process that runs the auto-prompt scanner. Dropping the
    # broken partial bytes keeps the debug log readable and crash-proof.
    Logger.debug(fn ->
      "PtyServer[#{state.os_pid}] #{stream}: " <>
        (chunk |> AnsiStrip.strip() |> scrub_utf8() |> String.trim_trailing())
    end)

    # Phase 5 PR 4: fan out raw chunk to LV Pty-Web subscribers
    # (xterm renders escape sequences directly — no ANSI strip here).
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      output_topic(state.agent_uri),
      {:pty_output, state.agent_uri, chunk}
    )

    new_buffer = state.pty_buffer <> chunk
    state = %{state | pty_buffer: new_buffer}

    state = scan_auto_prompts(state)

    {:noreply, state}
  end

  def handle_info(:send_default_winsize, %__MODULE__{os_pid: nil} = state),
    do: {:noreply, state}

  def handle_info(:send_default_winsize, %__MODULE__{os_pid: os_pid} = state) do
    # Per `feedback_verify_ffi_arg_order`: rows first, cols second.
    try do
      :exec.winsz(os_pid, 40, 120)
    catch
      kind, why ->
        Logger.warning("PtyServer: winsz send failed (#{inspect(kind)}, #{inspect(why)})")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- generic auto-prompt scanner (Phase 6 PR 19) ---------------------

  # Allen 2026-05-18: "监控 pty stream 侦测到关键字后再 send key".
  # Walk each (still-unfired) auto_prompt against the ANSI-stripped
  # buffer; fire any matches and mark them fired. List is stable so
  # adding a new prompt is one entry in default_auto_prompts/0.
  defp scan_auto_prompts(%__MODULE__{exec_pid: nil} = state), do: state

  defp scan_auto_prompts(%__MODULE__{auto_prompts: []} = state),
    do: trim_buffer_only(state)

  defp scan_auto_prompts(%__MODULE__{auto_prompts: prompts, pty_buffer: buf} = state) do
    stripped = AnsiStrip.strip(buf)

    # 2026-06-01: detect OAuth login screen early so EagerBridge can fail fast
    # with :oauth_required instead of spinning for 15s. The screen text
    # "Paste code here if prompted" is rendered by claude when CLAUDE_CONFIG_DIR
    # has no valid credentials (Keychain isolation changed in claude 2.1.92 —
    # fresh per-agent dirs no longer inherit the host's Keychain entry).
    # We set oauth_blocked? and log; we do NOT write to the PTY here because
    # any keystroke (including the repeated \r from theme_picker) becomes an
    # "Invalid code" error that loops claude indefinitely.
    state =
      if not state.oauth_blocked? and
           String.contains?(stripped, "Paste code here if prompted") do
        Logger.warning(
          "PtyServer[#{URI.to_string(state.agent_uri)}]: OAuth login screen detected — " <>
            "CLAUDE_CONFIG_DIR has no valid credentials for claude 2.1.92. " <>
            "Seed credentials before spawning this agent (see cc-agent-e2e.md runbook)."
        )

        %{state | oauth_blocked?: true}
      else
        state
      end

    {new_prompts, fired_any?} =
      Enum.map_reduce(prompts, false, fn p, any? ->
        cond do
          p.fired? ->
            {p, any?}

          matches?(p.match, stripped) ->
            fire_or_rearm(p, state, any?)

          true ->
            {p, any?}
        end
      end)

    state = %{state | auto_prompts: new_prompts}

    if fired_any? do
      # Reset buffer after any match — avoids re-detect on the same
      # bytes if another prompt has overlapping text.
      %{state | pty_buffer: ""}
    else
      trim_buffer_only(state)
    end
  end

  # `@doc false def` (not `defp`) so the scanner's match semantics can be
  # unit-tested against real captured PTY buffers (server_auto_prompts_test.exs).
  @doc false
  def matches?(needle, stripped) when is_binary(needle),
    do: String.contains?(stripped, needle)

  def matches?(needles, stripped) when is_list(needles),
    do: Enum.all?(needles, &String.contains?(stripped, &1))

  def matches?(%Regex{} = re, stripped), do: Regex.match?(re, stripped)

  # Drop invalid/partial UTF-8 bytes (e.g. a multi-byte codepoint split across
  # PTY read boundaries) so they can't crash the Logger formatter. Valid
  # codepoints pass through unchanged.
  defp scrub_utf8(bin) when is_binary(bin) do
    for <<c::utf8 <- bin>>, into: "", do: <<c::utf8>>
  end

  # Minimum gap between re-fires of a `repeat?: true` prompt, so an early
  # eaten keystroke is retried without spamming Enter at the redraw rate
  # (which would queue up and leak onto later screens once the menu clears).
  @rearm_min_ms 1200

  # Decide whether to actually send for a MATCHED prompt.
  #   - one-shot (default): fire once, mark fired? so it never retries.
  #   - repeat?: true: re-fire while still matched, but at most once per
  #     @rearm_min_ms; stays armed (fired? false) so it keeps retrying until
  #     claude advances past the dialog and the match disappears.
  defp fire_or_rearm(prompt, state, any?) do
    if Map.get(prompt, :repeat?, false) do
      now = System.monotonic_time(:millisecond)
      last = Map.get(prompt, :last_fired_ms)

      if is_nil(last) or now - last >= @rearm_min_ms do
        fire_prompt(prompt, state)
        {Map.put(prompt, :last_fired_ms, now), true}
      else
        {prompt, any?}
      end
    else
      fire_prompt(prompt, state)
      {%{prompt | fired?: true}, true}
    end
  end

  defp fire_prompt(prompt, state) do
    Logger.info(
      "PtyServer: auto-prompt #{prompt.name} matched for #{URI.to_string(state.agent_uri)} — sending #{inspect(prompt.send)}"
    )

    try do
      :exec.send(state.exec_pid, prompt.send)
    catch
      kind, why ->
        Logger.warning(
          "PtyServer: auto-prompt #{prompt.name} send failed (#{inspect(kind)}, #{inspect(why)})"
        )
    end
  end

  # Keep the prompt-detection buffer bounded so it doesn't grow
  # unbounded over long-running sessions.
  defp trim_buffer_only(%__MODULE__{pty_buffer: buf} = state) do
    buf2 =
      if byte_size(buf) > 64 * 1024 do
        binary_part(buf, byte_size(buf) - 16 * 1024, 16 * 1024)
      else
        buf
      end

    %{state | pty_buffer: buf2}
  end

  @impl true
  def terminate(reason, %__MODULE__{exec_pid: nil} = state) do
    # PTY-phase-state-machine follow-up (b): even when there's no
    # exec_pid (spawn never succeeded, or test_mode never ran a real
    # process), terminate/2 still fires on graceful shutdown — emit
    # the terminal :dead phase exactly once across the lifetime.
    maybe_broadcast_dead_on_terminate(state, reason)
    :ok
  end

  def terminate(reason, %__MODULE__{exec_pid: pid, agent_uri: agent_uri} = state) do
    try do
      :exec.stop(pid)
    catch
      _, _ -> :ok
    end

    # PTY-pid-files 2026-05-26 follow-up (a): clean the pid file on
    # graceful shutdown. A brutal BEAM kill skips this terminate/2
    # call entirely — the pid file stays around for the next BEAM's
    # OrphanReaper to find. That's the WHOLE POINT of the pid file
    # being on disk: it survives BEAM death and is the cross-restart
    # ownership receipt.
    _ = Ezagent.Runtime.PidFile.remove("cc", agent_uri)

    # PTY-phase-state-machine follow-up (b): graceful termination
    # path — emit :dead if no upstream signal (e.g. :exec.run failure,
    # erlexec :DOWN) already published it.
    maybe_broadcast_dead_on_terminate(state, reason)

    :ok
  end

  # --- phase broadcast helpers (PTY-phase-state-machine follow-up b) -------

  # Best-effort broadcast of a phase transition. The contract per
  # Allen's directive: phase tracking is OPERATOR VISIBILITY plumbing
  # and its failure MUST NOT block the primary PTY path (spawn /
  # write / shutdown). Wrap the Phoenix.PubSub.broadcast/3 call in
  # try/catch — if PubSub is down or the process tree is being torn
  # down, log + continue. Subscribers losing one transition is
  # acceptable; the periodic LV poll picks the next phase up.
  defp broadcast_phase(%__MODULE__{agent_uri: %URI{} = agent_uri} = state, phase, extra_meta)
       when phase in [:starting, :running, :dead] do
    meta =
      Map.merge(
        %{
          os_pid: state.os_pid,
          reason: nil,
          at: System.os_time(:millisecond)
        },
        extra_meta || %{}
      )

    try do
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        phase_topic(agent_uri),
        {:pty_phase, agent_uri, phase, meta}
      )
    catch
      kind, reason ->
        Logger.warning(
          "PtyServer: phase broadcast failed (#{inspect(kind)}, #{inspect(reason)}) " <>
            "for #{URI.to_string(agent_uri)} phase=#{inspect(phase)}; continuing"
        )

        :ok
    end
  end

  # Idempotency guard for the terminate/2 path. `dead_broadcast?` is
  # set to true the FIRST time `:dead` is emitted (from :exec.run
  # failure OR {:DOWN, ...}). The graceful terminate/2 path consults
  # the flag and only broadcasts when no upstream signal has already
  # published the terminal transition.
  defp maybe_broadcast_dead_on_terminate(%__MODULE__{dead_broadcast?: true}, _reason), do: :ok

  defp maybe_broadcast_dead_on_terminate(%__MODULE__{} = state, reason) do
    broadcast_phase(state, :dead, %{reason: reason, os_pid: state.os_pid})
  end
end
