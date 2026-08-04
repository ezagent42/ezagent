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

  Phase 4-completion PR 8: Ezagent's first plugin-managed child process. Uses
  `:exec.run/2` (erlexec) for PTY allocation (the claude TUI needs a real tty), and
  routes `agent_uri` through mcp.json (not env-var passthrough) so the Python bridge
  always announces with the correct agent_uri.

  ## Generic auto-prompt scanner (Phase 6 PR 19)

  Allen 2026-05-18: "监控 pty stream 侦测到关键字后再 send key". Each stdout/stderr
  chunk accumulates into a stripped buffer; the scanner walks every still-unfired
  rule and writes the `send` bytes of any that match. Adding a new auto-input is one
  entry in `Ezagent.Domain.Pty.AutoPrompts` — no scanner change; callers can inject
  extra rules via the `:auto_prompts` arg. Match shapes are substring /
  list-of-substrings (AND) / regex — see `Ezagent.Domain.Pty.ScreenMatch`.

  ## Crash policy (2026-07-10 hardening; respawn BREAKER added 2026-07-13)

  Trap_exit + erlexec `:monitor` — child death triggers `{:stop, {:child_exited,
  _}}`, `EzagentDomainPty.Supervisor` restarts this GenServer, and
  `handle_continue(:spawn_pty)` spawns a fresh child. THREE layers bound that loop:

    * an explicit supervisor intensity (`20 / 60 s`, not OTP's 3-in-5s — see
      `EzagentDomainPty.Application`), so one bad child cannot wipe the node;
    * `Ezagent.Domain.Pty.RespawnBackoff`, which rate-limits a looper below that
      ceiling — it ISOLATES the loop, it does not end it;
    * `Ezagent.Domain.Pty.RespawnPolicy`, which ENDS it: a child that never reaches
      a healthy lifetime is retried with `cmd_fallback`, then HALTED.

  Without the breaker a permanently-failing child respawned forever — 933 times in
  two hours on canary, because the cc respawn argv carried `--continue` and nothing
  was resumable, so `claude` exited 1 within 37 ms every time. See
  `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md`.

  If the PTY goes idle on a selection dialog (`❯`) matching no armed auto-prompt,
  `Ezagent.Domain.Pty.ParkedDialogWatch` EMITS the stripped screen so the stuck
  state is OBSERVABLE before the transport-join times out opaquely (audit #1).

  ## Test mode

  In `Mix.env() == :test`, `:exec.run/2` is short-circuited. Real
  spawn requires host bash + script + claude binary; tests assert the
  Template Class path works without exercising claude itself.
  """

  use GenServer
  require Logger

  alias Ezagent.AnsiStrip
  alias Ezagent.Domain.Pty.AuthObservers
  alias Ezagent.Domain.Pty.ParkedDialogWatch
  alias Ezagent.Domain.Pty.PhaseBroadcast
  alias Ezagent.Domain.Pty.RespawnPolicy
  alias Ezagent.Domain.Pty.ScreenMatch
  alias Ezagent.Utf8Tail

  defstruct [
    :agent_uri,
    :cwd,
    :exec_pid,
    :os_pid,
    :test_mode,
    # Optional cmd override. A STRING runs via `/bin/sh -c` (legacy; tests pass a
    # mock script path). A LIST is argv form, executed via `execve` with NO shell —
    # each element is exactly one argv entry, so an operator-controlled sandbox path
    # can neither split into extra args nor be interpreted by a shell (codex HIGH-2).
    # The cc plugin builds its `claude ...` invocation as a list for that reason.
    :cmd_override,
    # Optional extra environment variables for the spawned child,
    # `%{"NAME" => "value"}`. Merged into the inherited OS env. The cc
    # plugin uses this to pass `CLAUDE_CONFIG_DIR` instead of a shell
    # `VAR=val cmd` prefix (which is unavailable in argv form and was
    # shell-injectable in string form — codex HIGH-2).
    :cmd_env,
    # Optional DEGRADED command used when `cmd_override` cannot start. cc supplies
    # its argv WITHOUT `--continue`. See `Ezagent.Domain.Pty.RespawnPolicy`.
    :cmd_fallback,
    pty_buffer: "",
    # Phase 6 PR 19 — data-driven auto-confirm rules, `%{name, match, send, fired?}`.
    # `fired?` makes each one-shot. See `Ezagent.Domain.Pty.AutoPrompts`.
    auto_prompts: [],
    # #17 PR-C — emit-only auth-failure observers (%{name, match, fired?},
    # one-shot, NEVER write stdin). See `Ezagent.Domain.Pty.AuthObservers`.
    auth_observers: [],
    # The three canonical phases of the OS subprocess — `:starting | :running |
    # :dead`, per Allen's directive (no middle states). A respawn HALT is NOT a
    # fourth phase; see `Ezagent.Domain.Pty.PhaseBroadcast`.
    phase: :starting,
    # Tracks whether `:dead` has been broadcast already so the
    # terminate/2 path doesn't double-emit after a {:DOWN, ...} or
    # :exec.run failure has already published the terminal phase.
    dead_broadcast?: false,
    # cc-PTY hardening 2026-07-10 (audit #1) — parked-on-unknown-dialog watchdog.
    # `parked_check_ref`: the one-shot idle timer (re)armed on every output chunk.
    # `parked_dialog_signature`: the screen we last emitted for (dedupe).
    parked_check_ref: nil,
    parked_dialog_signature: nil,
    # Breaker: `healthy?` = survived `healthy_after_ms`; `halted?` = tripped (alive,
    # no child, none spawned until an operator).
    healthy?: false,
    halted?: false,
    # 2026-07-13 — auth observer fired this incarnation? → halt gets :needs_login
    # reason instead of the opaque exit code. See `tag_reason/2`.
    auth_failed?: false,
    # Which cmd this incarnation launched — breaker books per-mode.
    spawn_mode: :primary
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
      # 2026-07-13 breaker. `halted?` = no respawn is coming without an operator
      # (`:dead` alone does NOT say that); `degraded?` = running the fallback argv.
      halted?: state.halted? == true,
      halt_reason: halt_reason(state),
      degraded?: RespawnPolicy.degraded?(state.agent_uri),
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
  Walk the DynamicSupervisor's children for the PtyServer whose `agent_uri` matches.
  Returns `{:ok, pid}` or `:error`. Cheap enough for the current child count.
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
  Write bytes to the PTY's stdin (called by Ezagent.ActionSet.Pty.invoke(:write, ...)).

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
  #17 PR-C — per-agent auth-failure topic; subscribers receive
  `{:pty_auth_failed, agent_uri, observer_name}`. See `Ezagent.Domain.Pty.AuthObservers`.
  """
  def auth_failed_topic(%URI{} = agent_uri), do: AuthObservers.topic(agent_uri)

  @doc """
  #17 PR-C2 — the SHARED auth-failure topic; the domain credential notifier subscribes
  here ONCE for every agent. See `Ezagent.Domain.Pty.AuthObservers`.
  """
  def auth_failed_all_topic, do: AuthObservers.all_topic()

  @doc """
  PubSub topic for an agent's PTY phase transitions. Subscribers receive
  `{:pty_phase, agent_uri, phase, meta}`. See `Ezagent.Domain.Pty.PhaseBroadcast`.
  """
  def phase_topic(%URI{} = agent_uri), do: PhaseBroadcast.topic(agent_uri)

  @doc """
  PubSub topic for an agent's "parked on an UNKNOWN dialog" signal (cc-PTY
  hardening 2026-07-10, audit #1). Subscribers receive
  `{:pty_parked_unknown_dialog, agent_uri, screen}`. See
  `Ezagent.Domain.Pty.ParkedDialogWatch`.
  """
  def parked_dialog_topic(%URI{} = agent_uri),
    do: Ezagent.Domain.Pty.ParkedDialogWatch.topic(agent_uri)

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

  Bounded to the last `max_bytes` (default 64KB) so a long-running session doesn't
  send megabytes through PubSub on every reconnect — most TUIs re-emit their full
  visible screen within the last few KB via ANSI redraw sequences.

  Returns `{:ok, binary}` or `:error` if PtyServer not alive.
  """
  @spec snapshot_buffer(URI.t(), pos_integer()) :: {:ok, binary()} | :error
  def snapshot_buffer(%URI{} = agent_uri, max_bytes \\ 65_536) do
    case find_by_agent_uri(agent_uri) do
      {:ok, pid} ->
        try do
          state = :sys.get_state(pid, 500)
          buf = state.pty_buffer

          # #1201 ①: codepoint-boundary-aware cut — a raw binary_part
          # tail can start mid-codepoint and break downstream consumers
          # (PubSub replay / LiveView render) on CJK-heavy output.
          {:ok, Utf8Tail.tail(buf, max_bytes)}
        catch
          _, _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  PR #128 — trigger a TUI redraw via a brief winsize change (most TUIs listen for
  SIGWINCH and re-emit their screen). Belt-and-suspenders companion to
  `snapshot_buffer/2`, for when the TUI's last redraw predates the bounded buffer.
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
    test_mode = Map.get(args, :test_mode, Code.ensure_loaded?(Mix) and Mix.env() == :test)
    cmd_override = Map.get(args, :cmd_override)
    cmd_env = Map.get(args, :cmd_env, %{})

    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      agent_uri: agent_uri,
      cwd: cwd,
      test_mode: test_mode,
      cmd_override: cmd_override,
      cmd_fallback: Map.get(args, :cmd_fallback),
      cmd_env: cmd_env,
      auto_prompts: default_auto_prompts() ++ Map.get(args, :auto_prompts, []),
      auth_observers:
        Enum.map(Map.get(args, :auth_observers, []), fn o ->
          %{name: o.name, match: o.match, fired?: false}
        end),
      phase: :starting
    }

    # PTY-phase-state-machine follow-up (b): broadcast :starting as
    # soon as init/1 has built the struct. Subscribers (Sandbox slice
    # + LV badge) see the agent moving through `:starting → :running`
    # / `:starting → :dead` even when :exec.run/2 fails fast.
    broadcast_phase(state, :starting, %{})

    {:ok, state, {:continue, :spawn_pty}}
  end

  # Phase 6 PR 19 — well-known prompts the spawned `claude` may pause on. The
  # data catalog (one entry per dialog) lives in `Ezagent.Domain.Pty.AutoPrompts`
  # (extracted for the oversized-module arch gate); a new prompt is one entry
  # there, no scanner-loop change. Delegated to keep the public `/0` API stable.
  @doc false
  def default_auto_prompts, do: Ezagent.Domain.Pty.AutoPrompts.default()

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
    # 2026-07-13 — the respawn decision is VETOABLE. Before the breaker existed
    # this clause always spawned, so a child that could never succeed respawned
    # forever (933 times in 2 h on canary). RespawnPolicy answers one of three
    # ways: run the preferred command, run the degraded fallback, or don't spawn
    # at all. The decision lives in ETS, so it survives the very GenServer restart
    # that carries us back here (DynamicSupervisor replays the FROZEN child spec —
    # the plugin that chose the argv is never consulted again).
    case RespawnPolicy.decide(state.agent_uri, state.cmd_fallback != nil) do
      {:halt, info} -> {:noreply, enter_halt(state, info)}
      mode -> spawn_child(state, mode)
    end
  end

  defp spawn_child(state, mode) do
    # cc-PTY hardening 2026-07-10 (audit #3): rate-limit a crash-looping child's
    # respawns so one bad `claude` cannot trip the supervisor intensity and wipe
    # every sibling PtyServer (per-agent sliding-window backoff, self-resetting).
    apply_respawn_backoff(state)

    cmd = if mode == :fallback, do: state.cmd_fallback, else: state.cmd_override

    if mode == :fallback do
      Logger.warning(
        "PtyServer: DEGRADED respawn for #{URI.to_string(state.agent_uri)} — the preferred " <>
          "command failed to start; retrying with the `cmd_fallback` argv. The agent comes up " <>
          "with reduced capability rather than not at all; what is given up is defined by the " <>
          "plugin that supplied the fallback."
      )
    end

    case spawn_claude_directly(state, cmd) do
      {:ok, exec_pid, os_pid} ->
        Logger.info(
          "PtyServer spawned claude os_pid=#{os_pid} for agent=#{URI.to_string(state.agent_uri)}"
        )

        # Healthy = survived startup. Timer carries exec_pid so a stale one cannot
        # vouch for a replacement child.
        Process.send_after(self(), {:mark_healthy, exec_pid}, RespawnPolicy.healthy_after_ms())

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

        new_state = %{
          state
          | exec_pid: exec_pid,
            os_pid: os_pid,
            phase: :running,
            spawn_mode: mode
        }

        broadcast_phase(new_state, :running, %{os_pid: os_pid})

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("PtyServer: spawn failed: #{inspect(reason)}")
        # A launch that never got off the ground is a failed start too — count it,
        # or an unspawnable command (bad binary, oversized argv) loops forever.
        fb? = state.cmd_fallback != nil
        _ = RespawnPolicy.record_failure(state.agent_uri, {:spawn_failed, reason}, mode, fb?)

        new_state = %{state | phase: :dead, dead_broadcast?: true}

        broadcast_phase(new_state, :dead, %{
          reason: reason,
          os_pid: nil,
          respawning: true
        })

        {:stop, {:spawn_failed, reason}, new_state}
    end
  end

  # Breaker tripped: do NOT spawn, do NOT stop. Stay alive with no child (status/ptBuffer
  # stay observable). Phase :dead; halt is a supervision fact, not a fourth phase.
  defp enter_halt(state, info) do
    halted = %{
      state
      | phase: :dead,
        dead_broadcast?: true,
        halted?: true,
        exec_pid: nil,
        os_pid: nil
    }

    broadcast_phase(halted, :dead, %{
      reason: {:respawn_halted, info.reason},
      os_pid: nil,
      respawning: false
    })

    halted
  end

  # Rate-limit this child's respawn BEFORE launching (see the module's docs): the
  # sleep blocks only this PtyServer, so a looping child spins slowly.
  defp apply_respawn_backoff(%__MODULE__{agent_uri: %URI{} = agent_uri}) do
    Ezagent.Domain.Pty.RespawnBackoff.throttle(agent_uri)
  end

  # Backstop for the erlexec `{packet,2}` `:einval` crash: estimate the
  # command size and fail THIS spawn alone with a clear error rather than
  # letting an oversized command become a node-wide outage.
  @packet2_limit 65_535
  # Headroom for erlexec's own framing + the non-cmd/env run options.
  @command_size_headroom 4_096

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
  defp spawn_claude_directly(state, cmd) do
    exec_cmd = build_exec_cmd(cmd, state.agent_uri)
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

  def build_env(state) do
    # Pass ONLY the env vars ezagent adds or overrides — never the whole
    # inherited OS environment. The child still receives the operator's
    # ambient env via normal OS-process inheritance through erlexec's
    # exec-port. Splatting :os.getenv() into {:env,...} inflated the
    # erlexec {packet,2} command past its 65535-byte limit on hosts with
    # large environments, crashing the :exec manager node-wide.
    cmd_env =
      (state.cmd_env || %{})
      |> Enum.map(fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    [
      {~c"EZAGENT_AGENT_URI", String.to_charlist(URI.to_string(state.agent_uri))},
      {~c"EZAGENT_DEPLOYMENT_ID", String.to_charlist(Ezagent.DeploymentId.deployment_id())}
    ] ++ cmd_env
  end

  # --- cmd_env redaction helpers (issue #1455) -------------------------
  # ALL cmd_env values are replaced with "[REDACTED]" inside
  # format_status/2 (the single chokepoint before OTP crash reports and
  # :sys.get_status output). cmd_env carries secrets by design (vendor API
  # keys, internal tokens); suffix-based heuristics are brittle and can
  # miss future key names. Blanket redaction — key names stay visible for
  # debugging, values are always scrubbed.

  @doc false
  defp redact_cmd_env(env) when is_map(env) and map_size(env) > 0 do
    Map.new(env, fn {k, _v} -> {k, "[REDACTED]"} end)
  end

  defp redact_cmd_env(env), do: env

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

  # Operator recovery (`Ezagent.Domain.Pty.restart/1` clears the breaker, kills any
  # live child, re-enters the spawn path with a clean slate).
  @impl true
  def handle_cast(:respawn, state) do
    if state.exec_pid, do: safe_stop_child(state.exec_pid)

    fresh = %{
      state
      | exec_pid: nil,
        os_pid: nil,
        halted?: false,
        healthy?: false,
        auth_failed?: false,
        spawn_mode: :primary,
        phase: :starting,
        dead_broadcast?: false,
        pty_buffer: "",
        # Re-arm auth observers for the replacement child (codex review, P2).
        auth_observers: Enum.map(state.auth_observers, &%{&1 | fired?: false})
    }

    broadcast_phase(fresh, :starting, %{os_pid: nil})
    {:noreply, fresh, {:continue, :spawn_pty}}
  end

  # erlexec DOWN, correlated on exec_pid (an Erlang pid — never recycled). A stale one
  # (operator `:respawn` swapped the child) must NOT hit its successor (codex, HIGH).
  @impl true
  def handle_info(
        {:DOWN, _os_pid, :process, exec_pid, reason},
        %__MODULE__{exec_pid: exec_pid} = state
      )
      when not is_nil(exec_pid) do
    Logger.warning(
      "PtyServer: child process exited for #{URI.to_string(state.agent_uri)}: #{inspect(reason)}"
    )

    # A child dying BEFORE `:mark_healthy` never got past startup → feed the breaker.
    # One that already ran healthily is an ordinary crash: respawn, count nothing.
    if not state.healthy?,
      do:
        RespawnPolicy.record_failure(
          state.agent_uri,
          tag_reason(reason, state),
          state.spawn_mode,
          state.cmd_fallback != nil
        )

    # PTY-phase-state-machine follow-up (b): the OS subprocess just
    # died — publish the terminal :dead phase BEFORE returning {:stop,
    # ...} so subscribers see the transition while this GenServer is
    # still alive enough to broadcast (terminate/2 would also fire,
    # but `dead_broadcast?: true` short-circuits the duplicate emit).
    new_state = %{state | phase: :dead, dead_broadcast?: true}

    broadcast_phase(new_state, :dead, %{
      reason: reason,
      os_pid: state.os_pid,
      respawning: true
    })

    {:stop, {:child_exited, reason}, new_state}
  end

  # Stale DOWN from a replaced child — ignore.
  def handle_info({:DOWN, _os_pid, :process, _stale, _reason}, state), do: {:noreply, state}

  # The child this timer was armed for got past startup. A healthy PRIMARY clears the
  # history; a healthy FALLBACK keeps `primary_failures` (RespawnPolicy moduledoc).
  def handle_info(
        {:mark_healthy, exec_pid},
        %__MODULE__{exec_pid: exec_pid, halted?: false} = state
      )
      when not is_nil(exec_pid) do
    RespawnPolicy.record_healthy(state.agent_uri, state.spawn_mode)
    {:noreply, %{state | healthy?: true}}
  end

  # Stale timer (child replaced, or server halted) — must not vouch for what runs now.
  def handle_info({:mark_healthy, _stale}, state), do: {:noreply, state}

  # stdout / stderr chunks from erlexec
  def handle_info({stream, _os_pid, data}, state) when stream in [:stdout, :stderr] do
    chunk = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

    Logger.debug(
      "PtyServer[#{state.os_pid}] #{stream}: #{chunk |> AnsiStrip.strip() |> String.trim_trailing()}"
    )

    # Phase 5 PR 4: fan out raw chunk to LV Pty-Web subscribers
    # (xterm renders escape sequences directly — no ANSI strip here).
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      output_topic(state.agent_uri),
      {:pty_output, state.agent_uri, chunk}
    )

    new_buffer = state.pty_buffer <> chunk
    state = %{state | pty_buffer: new_buffer}

    # #17 PR-C — emit-only auth-failure detection BEFORE auto_prompts (auto_prompts may
    # reset the buffer on a match; observers must see the same bytes). Observers never
    # send to stdin.
    {state, auth_just_fired} =
      scan_auth_observers(state, AnsiStrip.strip(new_buffer))

    state = %{state | auth_failed?: state.auth_failed? or auth_just_fired}

    state = scan_auto_prompts(state)

    # cc-PTY hardening 2026-07-10 (audit #1) — (re)arm the idle watchdog (fires
    # only after output SILENCE, so an active claude keeps cancelling it).
    state = arm_parked_check(state)

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

  # Stale stdout/stderr from a replaced child: must not reach its successor.
  def handle_info({stream, _os_pid, _data}, state) when stream in [:stdout, :stderr],
    do: {:noreply, state}

  # cc-PTY hardening 2026-07-10 (audit #1) — output has been silent for
  # `parked_dialog_idle_ms`; check whether we are parked on an unknown dialog.
  def handle_info(:check_parked_dialog, state) do
    {:noreply, maybe_emit_parked_dialog(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- #17 PR-C: emit-only auth-failure observers (Ezagent.Domain.Pty.AuthObservers) ---
  # Returns `{state, just_fired?}` → halt names :needs_login instead of an opaque code.
  defp scan_auth_observers(%__MODULE__{auth_observers: observers} = state, stripped) do
    new = AuthObservers.scan(observers, stripped, state.agent_uri)
    just_fired? = Enum.count(new, & &1.fired?) > Enum.count(observers, & &1.fired?)
    {%{state | auth_observers: new}, just_fired?}
  end

  # Auth observer fired → the crash is almost certainly a credential failure.
  # Name it so the halt is diagnostic (":needs_login" vs "{:exit_status, 256}").
  defp tag_reason(_reason, %__MODULE__{auth_failed?: true}), do: :needs_login
  defp tag_reason(reason, _state), do: reason

  defp halt_reason(%__MODULE__{halted?: true, agent_uri: agent_uri}) do
    case RespawnPolicy.halt_info(agent_uri) do
      %{reason: reason} -> reason
      _ -> :unknown
    end
  end

  defp halt_reason(_state), do: nil

  defp safe_stop_child(pid) do
    :exec.stop(pid)
    :ok
  catch
    _, _ -> :ok
  end

  # --- parked-on-unknown-dialog watchdog (cc-PTY hardening 2026-07-10) --
  # Detection + emit live in `Ezagent.Domain.Pty.ParkedDialogWatch`; the Server
  # owns only the idle timer + state plumbing.

  @default_parked_dialog_idle_ms 8_000

  # (Re)arm the one-shot idle watchdog. Cancels any pending timer first so the
  # deadline always measures from the LAST output chunk.
  defp arm_parked_check(%__MODULE__{parked_check_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :check_parked_dialog, parked_dialog_idle_ms())
    %{state | parked_check_ref: new_ref}
  end

  defp maybe_emit_parked_dialog(%__MODULE__{phase: :running} = state) do
    stripped = state.pty_buffer |> AnsiStrip.strip() |> ScreenMatch.normalize_ws()
    armed? = Enum.any?(state.auto_prompts, &(not &1.fired? and matches?(&1.match, stripped)))

    case ParkedDialogWatch.check(state.agent_uri, stripped, armed?, state.parked_dialog_signature) do
      {:emitted, signature} -> %{state | parked_dialog_signature: signature}
      :noop -> state
    end
  end

  defp maybe_emit_parked_dialog(state), do: state

  defp parked_dialog_idle_ms do
    case Application.get_env(
           :ezagent_domain_pty,
           :parked_dialog_idle_ms,
           @default_parked_dialog_idle_ms
         ) do
      v when is_integer(v) and v > 0 -> v
      _ -> @default_parked_dialog_idle_ms
    end
  end

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

    {new_prompts, fired_any?} =
      Enum.map_reduce(prompts, false, fn p, any? ->
        cond do
          p.fired? ->
            {p, any?}

          matches?(p.match, stripped) ->
            fire_prompt(p, state)
            {%{p | fired?: true}, true}

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

  @doc false
  # ScreenMatch holds the implementation (extracted for the oversized-module gate).
  defdelegate matches?(needle, stripped), to: Ezagent.Domain.Pty.ScreenMatch

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
  #
  # #1201 ①: the cut MUST be codepoint-boundary-aware. A raw
  # `binary_part/3` cut can split a multi-byte UTF-8 codepoint, leaving
  # the buffer starting with a continuation byte; the next chunk's scan
  # then feeds invalid UTF-8 into `normalize_ws/1`'s `/u` regex, which
  # raises and crashes this server. Long CJK-heavy turns died reliably.
  defp trim_buffer_only(%__MODULE__{pty_buffer: buf} = state) do
    buf2 =
      if byte_size(buf) > 64 * 1024 do
        Utf8Tail.tail(buf, 16 * 1024)
      else
        buf
      end

    %{state | pty_buffer: buf2}
  end

  # format_status/2 — the single chokepoint that redacts cmd_env from
  # OTP crash reports and :sys.get_status output. Every GenServer exit
  # path (:stop / :shutdown / crash) flows through this callback before
  # the state reaches the error logger — so vendor API keys carried in
  # cmd_env (ANTHROPIC_AUTH_TOKEN, EZAGENT_AGENT_TOKEN, etc.) are
  # replaced with "[REDACTED]" and never reach logs (issue #1455).
  @impl true
  def format_status(:normal, [pdict, %__MODULE__{} = state]) do
    [pdict, scrub_state(state)]
  end

  def format_status(:terminate, [pdict, %__MODULE__{} = state]) do
    [pdict, scrub_state(state)]
  end

  defp scrub_state(%__MODULE__{cmd_env: env} = state) when is_map(env) and map_size(env) > 0 do
    %{state | cmd_env: redact_cmd_env(env)}
  end

  defp scrub_state(state), do: state

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
    safe_stop_child(pid)

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
  # Emit lives in `Ezagent.Domain.Pty.PhaseBroadcast` (extracted for the oversized-module
  # arch gate); the Server owns only the state plumbing + the dedupe flag.
  defp broadcast_phase(%__MODULE__{agent_uri: %URI{} = agent_uri} = state, phase, extra_meta),
    do: PhaseBroadcast.emit(agent_uri, phase, state.os_pid, extra_meta)

  # Idempotency guard: `dead_broadcast?` = true when :dead was already emitted, so
  # terminate/2 does not double-emit the terminal transition.
  defp maybe_broadcast_dead_on_terminate(%__MODULE__{dead_broadcast?: true}, _reason), do: :ok

  defp maybe_broadcast_dead_on_terminate(%__MODULE__{} = state, reason),
    do:
      broadcast_phase(state, :dead, %{
        reason: reason,
        os_pid: state.os_pid,
        respawning: false
      })
end
