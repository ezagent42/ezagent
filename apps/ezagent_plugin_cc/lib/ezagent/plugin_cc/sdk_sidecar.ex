defmodule EzagentPluginCc.SdkSidecar do
  @moduledoc """
  Supervised Python Claude Code SDK worker for one `cc-headless` agent.

  The worker speaks stdin/stdout JSON lines. It owns the SDK client and
  serializes `query + receive_response`; this GenServer owns process lifecycle
  and request correlation.

  ## Transport

  Spawns the Python worker via `Ezagent.Runtime.OsProcess` (erlexec
  `run_link` + `{group,0}` + `kill_group`) so every teardown path — graceful
  shutdown, owner crash, brutal BEAM SIGKILL — reaps the full process group
  (uv → python). Replaces the native `Port.open` used before.

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §4.

  ## V5 pid-closure A1b — resolver-seam registration

  Every SdkSidecar SELF-registers under `{agent_uri, :ezagent_plugin_cc,
  :cc_sdk}` in the unified `Ezagent.Runtime.SidecarRegistry` (the retired
  private `EzagentPluginCc.SdkSidecarRegistry` is gone), and every reach
  converges on the pid-free `Ezagent.Runtime.Resolver` face (`alive?/1`,
  `call/3`, `terminate_child/2`) — no caller looks up a pid or walks the
  DynamicSupervisor any more.

  V5 A1b-rest dropped the dead faces: `lookup/1` (internal-only pid
  surface) and the `recent_output/1` accessor (0 callers). The
  output-BUFFER machinery stays — the EXIT crash log inlines
  `state.output`.
  """

  # `restart: :transient` (V5 A1b codex blocker B, PTY-pilot policy): an
  # ABNORMAL stop — the erlexec child's `{:sdk_sidecar_exit, _}` — still
  # restarts under `EzagentPluginCc.SdkSidecarSupervisor` exactly as
  # `:permanent` did. But a GRACEFUL stop (only the registry-collision
  # policy below stops this way) must NOT be restarted: the loser of a
  # registry-restart race has its :via key owned by the replacement, so a
  # restart would fail-start on `{:already_started, _}` in a loop until
  # the DynamicSupervisor's intensity tripped and took EVERY SdkSidecar
  # down.
  use GenServer, restart: :transient

  require Logger

  alias Ezagent.Runtime.LineBuffer
  alias Ezagent.Runtime.OsProcess
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  # V5 pid-closure A1b — this sidecar's resolver-seam identity. The key is
  # the address, never a pid (PTY-pilot pattern, `Ezagent.Domain.Pty.Server`).
  @plugin :ezagent_plugin_cc
  @role :cc_sdk

  defstruct [
    :agent_uri,
    :exec_pid,
    :os_pid,
    :line_buffer,
    :session_id,
    :cwd,
    :config_dir,
    # V5 A1b codex #5 — the `SidecarRegistry.watch/0` monitor ref. The
    # registry lives in ANOTHER app's supervision tree; if it restarts,
    # this worker's :via entry dies with it, and the worker re-registers
    # ITSELF on the :DOWN (see the :DOWN clause + `reregister_with_registry/1`).
    :registry_ref,
    pending: %{},
    next_id: 0,
    output: ""
  ]

  @line_buffer_max 1_048_576
  @default_timeout 120_000

  @doc false
  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCc.SdkSidecarSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @doc """
  The resolver-seam key for this agent's cc-sdk sidecar:
  `{agent_uri, :ezagent_plugin_cc, :cc_sdk}`. Public so callers build
  the SAME key — the key is the address, never a pid.
  """
  @spec resolver_key(URI.t()) :: {URI.t(), atom(), atom()}
  def resolver_key(%URI{} = agent_uri), do: {agent_uri, @plugin, @role}

  @doc """
  The `:via` tuple this sidecar SELF-registers under (the unified
  `Ezagent.Runtime.SidecarRegistry`, plugin-qualified key).
  """
  def via(%URI{} = agent_uri), do: SidecarRegistry.via(agent_uri, @plugin, @role)

  @doc false
  # Pid-free — resolved through the V5 resolver seam's `Resolver.alive?/1`.
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri), do: Resolver.alive?(resolver_key(agent_uri))

  @doc false
  # Pid-free — the seam resolves the key and asks the plugin's own
  # SdkSidecarSupervisor to terminate the child.
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    _ =
      Resolver.terminate_child(
        resolver_key(agent_uri),
        EzagentPluginCc.SdkSidecarSupervisor
      )

    :ok
  end

  # V5 A1b-rest: the `recent_output/1` accessor is DROPPED (0 callers —
  # the two workspace-locality `genserver_to_pid` allowlist entries it
  # shared with `query/3` leave the debt ledger). The output-BUFFER
  # machinery (`state.output` accumulation in `handle_line/2`) STAYS: the
  # EXIT crash log inlines it.

  @doc false
  # Pid-free — the seam resolves the key and `GenServer.call`s the worker.
  @spec query(URI.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(%URI{} = agent_uri, text, opts \\ []) when is_binary(text) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    session_id = Keyword.get(opts, :session_id)

    case Resolver.call(resolver_key(agent_uri), {:query, text, session_id}, timeout) do
      {:ok, reply} -> reply
      {:error, :no_such_actor} -> {:error, :sdk_sidecar_not_started}
      {:error, {:noproc, _}} -> {:error, :sdk_sidecar_not_started}
      {:error, {:timeout, _}} -> {:error, :sdk_sidecar_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    # V5 A1b: the :via lives on the unified `Ezagent.Runtime.SidecarRegistry`
    # (plugin-qualified `{agent_uri, :ezagent_plugin_cc, :cc_sdk}` key).
    GenServer.start_link(__MODULE__, args, name: via(agent_uri))
  end

  @impl true
  def init(%{agent_uri: agent_uri} = args) do
    # SPEC §3.1 caller contract: trap_exit BEFORE spawn so supervisor :shutdown
    # reaches terminate/2 and orphans are not left behind.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      agent_uri: agent_uri,
      session_id: Map.get(args, :session_id, new_session_id()),
      cwd: Map.fetch!(args, :cwd),
      config_dir: Map.fetch!(args, :config_dir),
      line_buffer: LineBuffer.new(@line_buffer_max),
      # V5 A1b codex #5 — watch the unified registry so its restart (the
      # entry dies with it) triggers self re-registration, keeping this
      # sidecar resolvable through the seam.
      registry_ref: SidecarRegistry.watch()
    }

    case start_process(args) do
      {:ok, exec_pid, os_pid} ->
        {:ok, %{state | exec_pid: exec_pid, os_pid: os_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, text, session_id}, from, state) do
    req_id = "cc-sdk-" <> Integer.to_string(state.next_id + 1)

    frame = %{
      id: req_id,
      op: "query",
      text: text,
      session_id: session_id || state.session_id
    }

    case send_frame(state.exec_pid, frame) do
      :ok ->
        pending = Map.put(state.pending, req_id, from)
        {:noreply, %{state | pending: pending, next_id: state.next_id + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ─── registry watch: SidecarRegistry restart → self re-register ───────────

  # V5 A1b codex #5 — the unified SidecarRegistry restarted (it lives in
  # ANOTHER app's supervision tree); our :via entry died with it. Re-register
  # THIS process and re-arm the watch so the sidecar stays resolvable through
  # the seam. Matched BEFORE any generic stale-:DOWN / stale-:EXIT clause
  # (chunk1 gotcha).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{registry_ref: ref} = state)
      when is_reference(ref) do
    Logger.warning(
      "cc-headless SDK sidecar: SidecarRegistry DOWN (#{inspect(reason)}) — re-registering " <>
        URI.to_string(state.agent_uri)
    )

    reregister_with_registry(state)
  end

  def handle_info(:retry_registry_registration, %__MODULE__{registry_ref: nil} = state),
    do: reregister_with_registry(state)

  def handle_info(:retry_registry_registration, state), do: {:noreply, state}

  # ─── stdout: bytes arrive from erlexec in arbitrary chunks ────────────────

  def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid} = state) do
    {new_lb, lines} = LineBuffer.feed(state.line_buffer, bytes)

    # Thread state through each complete line (id-correlation may pop pending).
    new_state =
      Enum.reduce(lines, %{state | line_buffer: new_lb}, fn line, acc ->
        case handle_line(line, acc) do
          {:noreply, updated} -> updated
          # handle_line always returns {:noreply, _}
          other -> elem(other, 1)
        end
      end)

    {:noreply, new_state}
  end

  # ─── stderr: log and drop — NEVER merge into JSON channel ─────────────────

  def handle_info({:stderr, os_pid, bytes}, %{os_pid: os_pid} = state) do
    Logger.warning(
      "cc-headless SDK sidecar stderr for #{URI.to_string(state.agent_uri)}: " <>
        inspect(bytes)
    )

    {:noreply, state}
  end

  # ─── child exit via run_link — handle ALL reason shapes ───────────────────

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    Logger.warning(
      "cc-headless SDK sidecar exited for #{URI.to_string(state.agent_uri)} " <>
        "reason=#{inspect(reason)}; recent output:\n#{state.output}"
    )

    # Reply all pending callers with an error before stopping.
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, {:sdk_sidecar_exit, reason}})
    end)

    {:stop, {:sdk_sidecar_exit, reason}, %{state | pending: %{}}}
  end

  # Defensive: ignore exits from processes we didn't spawn.
  def handle_info({:EXIT, _other, _reason}, state) do
    {:noreply, state}
  end

  # V5 A1b codex #5 — re-register THIS process under its seam key after a
  # registry restart, then re-arm the watch. On failure (registry still down
  # after the helper's bounded wait) schedule a retry instead of crashing:
  # the worker is healthy, only its discoverability is degraded.
  #
  # codex blocker B (collision policy) — `{:error, :already_registered}`
  # means a REPLACEMENT worker won the key during the registry's empty-
  # restart window. This original is now unreachable through the seam, and
  # two live sdk sidecars for one agent must never coexist: LOSE
  # GRACEFULLY — stop; `terminate/2` releases the erlexec child, and
  # `restart: :transient` keeps the supervisor from resurrecting the loser.
  defp reregister_with_registry(state) do
    case SidecarRegistry.re_register(resolver_key(state.agent_uri)) do
      :ok ->
        {:noreply, %{state | registry_ref: SidecarRegistry.watch()}}

      {:error, :already_registered} ->
        Logger.warning(
          "cc-headless SDK sidecar: SidecarRegistry key for #{URI.to_string(state.agent_uri)} " <>
            "is owned by a replacement that won the restart race — this losing " <>
            "original is terminating gracefully (releasing its child)"
        )

        {:stop, {:shutdown, :registry_collision}, state}

      {:error, why} ->
        Logger.error(
          "cc-headless SDK sidecar: SidecarRegistry re-register failed for " <>
            "#{URI.to_string(state.agent_uri)} (#{inspect(why)}) — retrying"
        )

        Process.send_after(self(), :retry_registry_registration, 200)
        {:noreply, %{state | registry_ref: nil}}
    end
  end

  @impl true
  def terminate(_reason, %{exec_pid: exec_pid, agent_uri: agent_uri} = _state)
      when not is_nil(exec_pid) do
    OsProcess.stop(exec_pid)
    OsProcess.cleanup_pid_file("cc-sdk", agent_uri)
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  def sdk_runner(args) do
    cond do
      is_binary(Map.get(args, :uv_path)) ->
        {:ok, {Map.fetch!(args, :uv_path), ["run", "--script"]}}

      is_binary(Map.get(args, :python_path)) ->
        {:ok, {Map.fetch!(args, :python_path), []}}

      uv = System.find_executable("uv") ->
        {:ok, {uv, ["run", "--script"]}}

      python = System.find_executable("python3") ->
        {:ok, {python, []}}

      true ->
        {:error, :python_runner_not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Public (`@doc false`) so tests can pin the sidecar→worker env contract
  # without spawning a real OS process. Notably `EZAGENT_CC_SDK_CONFIG_DIR` —
  # the dir whose `.mcp.json` the worker resolves as the agent's MCP surface
  # (route B, #1323) — and `EZAGENT_CC_SDK_ENV` — the process env (provider +
  # CLI-identity credential) applied to the SDK subprocess.
  @doc false
  @spec worker_env(map()) :: [{charlist(), charlist()}]
  def worker_env(args) when is_map(args) do
    [
      {~c"EZAGENT_CC_SDK_CWD", args |> Map.fetch!(:cwd) |> String.to_charlist()},
      {~c"EZAGENT_CC_SDK_CONFIG_DIR", args |> Map.fetch!(:config_dir) |> String.to_charlist()},
      {~c"EZAGENT_CC_SDK_SESSION_ID",
       Map.get(args, :session_id, new_session_id()) |> String.to_charlist()},
      {~c"EZAGENT_CC_SDK_PERMISSION_MODE",
       Map.get(args, :permission_mode, "default") |> String.to_charlist()}
    ]
    |> maybe_env(~c"EZAGENT_CC_SDK_MODEL", Map.get(args, :model))
    |> maybe_env(~c"EZAGENT_CC_SDK_EFFORT", Map.get(args, :effort))
    |> maybe_env(~c"EZAGENT_CC_SDK_CLI_PATH", Map.get(args, :cli_path))
    |> maybe_env(~c"EZAGENT_CC_SDK_SYSTEM_PROMPT", Map.get(args, :system_prompt))
    |> maybe_json_env(~c"EZAGENT_CC_SDK_ALLOWED_TOOLS", Map.get(args, :allowed_tools))
    |> maybe_json_env(~c"EZAGENT_CC_SDK_DISALLOWED_TOOLS", Map.get(args, :disallowed_tools))
    |> maybe_json_env(~c"EZAGENT_CC_SDK_MCP_SERVERS", Map.get(args, :mcp_servers))
    |> maybe_json_env(~c"EZAGENT_CC_SDK_ENV", Map.get(args, :cmd_env))
    |> maybe_json_env(~c"EZAGENT_CC_SDK_PLUGINS", Map.get(args, :plugins))
  end

  defp start_process(args) do
    with {:ok, {runner, runner_args}} <- sdk_runner(args),
         {:ok, script} <- sdk_worker_path(args),
         cwd = Map.fetch!(args, :cwd),
         # The PTY flavor's cwd exists only as a SIDE EFFECT of
         # `McpConfigWriter.write_with_token!` (cwd-level .mcp.json write); the
         # headless path never calls the writer, so on a fresh host erlexec
         # crash-looped with "Cannot chdir to <cwd>". Own the cwd explicitly —
         # fail tagged (not silent) when it cannot be created.
         :ok <- ensure_cwd(cwd) do
      env = worker_env(args)

      cmd = [runner | runner_args ++ [script]]

      case OsProcess.spawn(cmd,
             cd: cwd,
             env: env,
             stderr: :separate,
             pid_file: {"cc-sdk", Map.fetch!(args, :agent_uri)}
           ) do
        {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} ->
          {:ok, exec_pid, os_pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sdk_worker_path(%{sdk_worker_path: path}) when is_binary(path), do: {:ok, path}

  defp sdk_worker_path(_args) do
    case :code.priv_dir(:ezagent_plugin_cc) do
      path when is_list(path) ->
        {:ok, Path.join([to_string(path), "python", "ezagent_cc_sdk_worker.py"])}

      _ ->
        {:error, :priv_dir_not_found}
    end
  end

  defp send_frame(exec_pid, frame) when is_pid(exec_pid) do
    data = Jason.encode!(frame) <> "\n"
    OsProcess.send(exec_pid, data)
  catch
    :error, reason -> {:error, reason}
  end

  defp handle_line(line, state) do
    output = trim_output(state.output <> line <> "\n")

    case Jason.decode(line) do
      {:ok, %{"id" => id, "ok" => true} = frame} ->
        {from, pending} = Map.pop(state.pending, id)

        if from do
          GenServer.reply(from, {:ok, normalize_result(frame)})
        end

        {:noreply, %{state | pending: pending, output: output}}

      {:ok, %{"id" => id, "ok" => false, "error" => error}} ->
        {from, pending} = Map.pop(state.pending, id)

        if from do
          GenServer.reply(from, {:error, {:sdk_worker_error, error}})
        end

        {:noreply, %{state | pending: pending, output: output}}

      {:ok, other} ->
        Logger.debug("cc-headless SDK sidecar ignored frame: #{inspect(other)}")
        {:noreply, %{state | output: output}}

      {:error, _} ->
        Logger.warning("cc-headless SDK sidecar emitted non-JSON line: #{line}")
        {:noreply, %{state | output: output}}
    end
  end

  defp normalize_result(frame) do
    %{
      content: Map.get(frame, "content", ""),
      usage: normalize_usage(Map.get(frame, "usage", %{})),
      session_id: Map.get(frame, "session_id")
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    input = int_value(usage, "input_tokens")
    output = int_value(usage, "output_tokens")
    total = int_value(usage, "total_tokens", input + output)

    %{input: input, output: output, total: total, raw: usage}
  end

  defp normalize_usage(_), do: %{input: 0, output: 0, total: 0, raw: %{}}

  defp int_value(map, key, default \\ 0) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  rescue
    ArgumentError -> default
  end

  defp ensure_cwd(cwd) when is_binary(cwd) do
    case File.mkdir_p(cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sdk_cwd_unavailable, cwd, reason}}
    end
  end

  defp maybe_env(env, _key, value) when value in [nil, ""], do: env

  defp maybe_env(env, key, value) when is_binary(value),
    do: [{key, String.to_charlist(value)} | env]

  defp maybe_json_env(env, _key, value) when value in [nil, "", [], %{}], do: env

  defp maybe_json_env(env, key, value),
    do: [{key, value |> Jason.encode!() |> String.to_charlist()} | env]

  # #1201 ①: codepoint-boundary-aware — a raw binary_part tail can start
  # mid-codepoint on CJK-heavy sidecar output and hand invalid UTF-8 to
  # whoever renders/logs this accumulated output.
  defp trim_output(output), do: Ezagent.Utf8Tail.tail(output, 8192)

  defp new_session_id do
    "ezagent-cc-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
