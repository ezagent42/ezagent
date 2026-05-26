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
    auto_prompts: []
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
      auto_prompts: default_auto_prompts() ++ Map.get(args, :auto_prompts, [])
    }

    {:ok, state, {:continue, :spawn_pty}}
  end

  # Phase 6 PR 19 — well-known prompts the spawned `claude` may pause
  # on. Each prompt fires once; the data-driven structure means new
  # prompts get added here without touching the dispatch loop.
  defp default_auto_prompts do
    [
      %{
        name: :dev_channels_dialog,
        match: ["Loading development channels", "I am using this for local development"],
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

    {:noreply, state}
  end

  def handle_continue(:spawn_pty, state) do
    case spawn_claude_directly(state) do
      {:ok, exec_pid, os_pid} ->
        Logger.info(
          "PtyServer spawned claude os_pid=#{os_pid} for agent=#{URI.to_string(state.agent_uri)}"
        )

        # Per old esr's PR-24 lesson: claude's TUI queries TIOCGWINSZ
        # to learn terminal size and BLOCKS rendering past initial
        # control sequences until it gets a non-zero size. Send a
        # default 120×40 winsize ~500ms after spawn (gives claude
        # time to finish initial DA query).
        # Per memory `feedback_verify_ffi_arg_order`: rows FIRST,
        # cols second.
        Process.send_after(self(), :send_default_winsize, 500)

        {:noreply, %{state | exec_pid: exec_pid, os_pid: os_pid}}

      {:error, reason} ->
        Logger.error("PtyServer: spawn failed: #{inspect(reason)}")
        {:stop, {:spawn_failed, reason}, state}
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
  defp spawn_claude_directly(state) do
    exec_cmd = build_exec_cmd(state.cmd_override, state.agent_uri)
    env = build_env(state)

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

  defp build_env(state) do
    # Pass operator's existing env through (proxy / API key / etc) so
    # operator-set vars from their shell where `mix phx.server` runs
    # reach claude. The two we own are EZAGENT_AGENT_URI (informational)
    # and EZAGENT_BRIDGE_URL (so the spawned MCP bridge knows where to announce).
    base = :os.getenv() |> Enum.map(fn s ->
      case :string.split(s, ~c"=") do
        [k, v] -> {k, v}
        _ -> {s, ~c""}
      end
    end)

    # Caller-supplied extra env (e.g. cc plugin's CLAUDE_CONFIG_DIR).
    # Passed as a structured `{name, value}` pair to `:exec.run/2` —
    # NOT interpolated into any command line — so the value cannot be
    # shell-interpreted (codex HIGH-2).
    cmd_env =
      (state.cmd_env || %{})
      |> Enum.map(fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    overrides =
      [
        {~c"EZAGENT_AGENT_URI", String.to_charlist(URI.to_string(state.agent_uri))},
        # PTY-orphan-restart 2026-05-26 round-2 (codex finding #2) —
        # tag the subprocess with THIS DEPLOYMENT's identity. The
        # plugin's OrphanReaper compares against the same identity at
        # boot: a subprocess whose tag differs belongs to a DIFFERENT
        # deployment (parallel dev tree, another release path,
        # different OS user's instance) and is NOT ours to reap, even
        # though its URI is absent from this BEAM's local Pty registry.
        # See `Ezagent.DeploymentId` for identity composition.
        {~c"EZAGENT_DEPLOYMENT_ID", String.to_charlist(Ezagent.DeploymentId.deployment_id())}
      ] ++ cmd_env

    overrides ++ base
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
        Logger.warning(
          "PtyServer.write_input failed (#{inspect(kind)}, #{inspect(reason)})"
        )

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

    {:stop, {:child_exited, reason}, state}
  end

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
        Logger.warning(
          "PtyServer: winsz send failed (#{inspect(kind)}, #{inspect(why)})"
        )
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

  defp matches?(needle, stripped) when is_binary(needle),
    do: String.contains?(stripped, needle)

  defp matches?(needles, stripped) when is_list(needles),
    do: Enum.all?(needles, &String.contains?(stripped, &1))

  defp matches?(%Regex{} = re, stripped), do: Regex.match?(re, stripped)

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
  def terminate(_reason, %__MODULE__{exec_pid: nil}), do: :ok

  def terminate(_reason, %__MODULE__{exec_pid: pid}) do
    try do
      :exec.stop(pid)
    catch
      _, _ -> :ok
    end

    :ok
  end
end
