defmodule EzagentPluginCodex.BridgeSidecar do
  @moduledoc """
  Python bridge sidecar for a codex agent.

  The sidecar connects to `Ezagent.AgentBridge.Socket`, receives
  `codex_turn` pushes from BEAM, forwards them to the per-agent Codex
  app-server, and emits `reply` events back through AgentBridge.

  ## Transport

  Spawns the Python bridge worker via `Ezagent.Runtime.OsProcess`
  (erlexec `run_link` + `{group,0}` + `kill_group`) so every teardown path
  — graceful shutdown, owner crash, brutal BEAM SIGKILL — reaps the full
  process group (uv → python). Replaces the native `Port.open` used before.

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §4.

  ## V5 pid-closure A1b — resolver-seam registration

  Every BridgeSidecar SELF-registers under `{agent_uri, :ezagent_plugin_codex,
  :codex_bridge}` in the unified `Ezagent.Runtime.SidecarRegistry` (the retired
  private `EzagentPluginCodex.BridgeSidecarRegistry` is gone), and every reach
  converges on the pid-free `Ezagent.Runtime.Resolver` face (`alive?/1`,
  `call/3`, `terminate_child/2`) — no caller looks up a pid or walks the
  DynamicSupervisor any more.
  """

  # `restart: :transient` (V5 A1b codex blocker B, PTY-pilot policy): an
  # ABNORMAL stop — the erlexec child's `{:bridge_sidecar_exit, _}` — still
  # restarts under `EzagentPluginCodex.BridgeSidecarSupervisor` exactly as
  # `:permanent` did. But a GRACEFUL stop (only the registry-collision
  # policy below stops this way) must NOT be restarted: the loser of a
  # registry-restart race has its :via key owned by the replacement, so a
  # restart would fail-start on `{:already_started, _}` in a loop until the
  # DynamicSupervisor's intensity tripped and took EVERY BridgeSidecar down.
  use GenServer, restart: :transient

  require Logger

  alias Ezagent.Runtime.OsProcess
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  # V5 pid-closure A1b — this sidecar's resolver-seam identity. The key is
  # the address, never a pid (PTY-pilot pattern, `Ezagent.Domain.Pty.Server`).
  @plugin :ezagent_plugin_codex
  @role :codex_bridge

  defstruct [:agent_uri, :exec_pid, :os_pid, :test_mode, :registry_ref, output: ""]

  @compile_env Mix.env()

  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCodex.BridgeSidecarSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @doc """
  The resolver-seam key for this agent's bridge sidecar:
  `{agent_uri, :ezagent_plugin_codex, :codex_bridge}`. Public so callers build
  the SAME key — the key is the address, never a pid.
  """
  @spec resolver_key(URI.t()) :: {URI.t(), atom(), atom()}
  def resolver_key(%URI{} = agent_uri), do: {agent_uri, @plugin, @role}

  @doc """
  The `:via` tuple this sidecar SELF-registers under (the unified
  `Ezagent.Runtime.SidecarRegistry`, plugin-qualified key).
  """
  def via(%URI{} = agent_uri), do: SidecarRegistry.via(agent_uri, @plugin, @role)

  @doc """
  Is this agent's bridge sidecar alive? Pid-free — resolved through the
  V5 resolver seam's `Resolver.alive?/1`.
  """
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri), do: Resolver.alive?(resolver_key(agent_uri))

  @doc """
  Recent buffered bridge output for `agent_uri`, or `\"\"` if it is not
  running. Served by the server's own `handle_call(:recent_output, ...)`
  through the seam's `Resolver.call/3` (never a pid lookup).
  """
  @spec recent_output(URI.t()) :: String.t()
  def recent_output(%URI{} = agent_uri) do
    case Resolver.call(resolver_key(agent_uri), :recent_output, 1_000) do
      {:ok, output} -> output
      {:error, _} -> ""
    end
  end

  @doc """
  Stop this agent's bridge sidecar. Pid-free — the seam resolves the key
  and asks the plugin's own `BridgeSidecarSupervisor` to terminate the child.
  """
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    _ =
      Resolver.terminate_child(
        resolver_key(agent_uri),
        EzagentPluginCodex.BridgeSidecarSupervisor
      )

    :ok
  end

  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    # V5 A1b: the :via lives on the unified `Ezagent.Runtime.SidecarRegistry`
    # (plugin-qualified `{agent_uri, :ezagent_plugin_codex, :codex_bridge}` key).
    GenServer.start_link(__MODULE__, args, name: via(agent_uri))
  end

  @impl true
  def init(%{agent_uri: agent_uri} = args) do
    # SPEC §3.1 caller contract: trap_exit UNCONDITIONALLY — even in test_mode
    # where no child spawns — so supervisor :shutdown reaches terminate/2.
    Process.flag(:trap_exit, true)

    test_mode = Map.get(args, :test_mode, @compile_env == :test)

    state = %__MODULE__{
      agent_uri: agent_uri,
      test_mode: test_mode,
      # V5 A1b codex #5 — watch the unified registry so its restart (the
      # entry dies with it) triggers self re-registration, keeping this
      # sidecar resolvable through the seam.
      registry_ref: SidecarRegistry.watch()
    }

    if test_mode do
      {:ok, state}
    else
      case start_os_process(agent_uri, args) do
        {:ok, exec_pid, os_pid} -> {:ok, %{state | exec_pid: exec_pid, os_pid: os_pid}}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl true
  def handle_call(:recent_output, _from, state) do
    {:reply, state.output, state}
  end

  # V5 A1b codex #5 — the unified SidecarRegistry restarted (it lives in
  # ANOTHER app's supervision tree); our :via entry died with it. Re-register
  # THIS process and re-arm the watch so the sidecar stays resolvable through
  # the seam. Matched BEFORE any generic stale-:DOWN clause.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{registry_ref: ref} = state)
      when is_reference(ref) do
    Logger.warning(
      "codex bridge sidecar: SidecarRegistry DOWN (#{inspect(reason)}) — re-registering " <>
        URI.to_string(state.agent_uri)
    )

    reregister_with_registry(state)
  end

  def handle_info(:retry_registry_registration, %__MODULE__{registry_ref: nil} = state),
    do: reregister_with_registry(state)

  def handle_info(:retry_registry_registration, state), do: {:noreply, state}

  # ─── stdout: raw framing — accumulate and log chunks directly ────────────

  def handle_info({:stdout, _os_pid, bytes}, state) when is_binary(bytes) do
    case String.trim(bytes) do
      "" ->
        :ok

      output ->
        Logger.info(
          "codex bridge sidecar output for #{URI.to_string(state.agent_uri)}:\n#{output}"
        )
    end

    {:noreply, %{state | output: trim_output(state.output <> bytes)}}
  end

  # ─── stderr: :merge means stderr arrives as :stdout — defensive clause ────

  def handle_info({:stderr, _os_pid, bytes}, state) when is_binary(bytes) do
    # With stderr: :merge, erlexec routes stderr to {:stdout, …}. This clause
    # is defensive; it won't fire under normal configuration.
    Logger.info(
      "codex bridge sidecar stderr for #{URI.to_string(state.agent_uri)}: #{inspect(bytes)}"
    )

    {:noreply, %{state | output: trim_output(state.output <> bytes)}}
  end

  # ─── child exit via run_link — handle ALL reason shapes ──────────────────

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    Logger.warning(
      "codex bridge sidecar exited for #{URI.to_string(state.agent_uri)} " <>
        "reason=#{inspect(reason)}; recent output:\n#{state.output}"
    )

    {:stop, {:bridge_sidecar_exit, reason}, state}
  end

  # Defensive: ignore exits from processes we didn't spawn.
  def handle_info({:EXIT, _other, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{exec_pid: exec_pid, agent_uri: agent_uri} = _state)
      when not is_nil(exec_pid) do
    OsProcess.stop(exec_pid)
    OsProcess.cleanup_pid_file("codex-bridge", agent_uri)
  end

  def terminate(_reason, _state), do: :ok

  defp start_os_process(agent_uri, args) do
    with {:ok, {runner, runner_args}} <- bridge_runner(args),
         {:ok, token} <- Ezagent.AgentBridge.TokenStore.mint(agent_uri),
         {:ok, script} <- bridge_script_path() do
      env = port_env(agent_uri, args, token)

      case OsProcess.spawn(
             [runner | runner_args ++ [script]],
             cd: Map.fetch!(args, :cwd),
             env: env,
             stderr: :merge,
             pid_file: {"codex-bridge", agent_uri}
           ) do
        {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} ->
          {:ok, exec_pid, os_pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def port_env(%URI{} = agent_uri, args, token) when is_map(args) and is_binary(token) do
    [
      {~c"EZAGENT_AGENT_URI", agent_uri |> URI.to_string() |> String.to_charlist()},
      {~c"EZAGENT_AGENT_TOKEN", String.to_charlist(token)},
      {~c"EZAGENT_BRIDGE_WS_URL", String.to_charlist(Map.fetch!(args, :bridge_ws_url))},
      {~c"EZAGENT_CODEX_APP_SERVER_SOCK",
       String.to_charlist(Map.fetch!(args, :app_server_socket))},
      {~c"EZAGENT_CODEX_THREAD_ID_FILE", String.to_charlist(Map.fetch!(args, :thread_id_file))},
      {~c"EZAGENT_CODEX_CWD", String.to_charlist(Map.fetch!(args, :cwd))}
    ]
    |> maybe_env(~c"EZAGENT_BRIDGE_TOPIC", Map.get(args, :bridge_topic))
    |> maybe_env(~c"EZAGENT_CODEX_BIN", Map.get(args, :codex_path))
    |> maybe_env(~c"EZAGENT_CODEX_MODEL", Map.get(args, :model))
    |> maybe_env(~c"EZAGENT_CODEX_APPROVAL_POLICY", Map.get(args, :approval_policy))
    |> maybe_env(~c"EZAGENT_CODEX_SANDBOX", Map.get(args, :sandbox))
    |> merge_cmd_env(Map.get(args, :cmd_env, %{}))
  end

  @doc false
  def bridge_runner(args) do
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

  defp bridge_script_path do
    case :code.priv_dir(:ezagent_plugin_codex) do
      path when is_list(path) ->
        {:ok, Path.join([to_string(path), "python", "ezagent_codex_bridge.py"])}

      _ ->
        {:error, :priv_dir_not_found}
    end
  end

  defp maybe_env(env, _key, value) when value in [nil, ""], do: env

  defp maybe_env(env, key, value) when is_binary(value),
    do: [{key, String.to_charlist(value)} | env]

  defp merge_cmd_env(env, cmd_env) when is_map(cmd_env) do
    Enum.reduce(cmd_env, env, fn {key, value}, acc ->
      [{String.to_charlist(to_string(key)), String.to_charlist(to_string(value))} | acc]
    end)
  end

  defp merge_cmd_env(env, _), do: env

  # V5 A1b codex #5 — re-register THIS process under its seam key after a
  # registry restart, then re-arm the watch. On failure (registry still down
  # after the helper's bounded wait) schedule a retry instead of crashing:
  # the worker is healthy, only its discoverability is degraded.
  #
  # codex blocker B (collision policy) — `{:error, :already_registered}`
  # means a REPLACEMENT worker won the key during the registry's empty-
  # restart window. This original is now unreachable through the seam, and
  # two live bridge sidecars for one agent must never coexist: LOSE
  # GRACEFULLY — stop; `terminate/2` releases the erlexec child, and
  # `restart: :transient` keeps the supervisor from resurrecting the loser.
  defp reregister_with_registry(state) do
    case SidecarRegistry.re_register(resolver_key(state.agent_uri)) do
      :ok ->
        {:noreply, %{state | registry_ref: SidecarRegistry.watch()}}

      {:error, :already_registered} ->
        Logger.warning(
          "codex bridge sidecar: SidecarRegistry key for #{URI.to_string(state.agent_uri)} is " <>
            "owned by a replacement that won the restart race — this losing " <>
            "original is terminating gracefully (releasing its child)"
        )

        {:stop, {:shutdown, :registry_collision}, state}

      {:error, why} ->
        Logger.error(
          "codex bridge sidecar: SidecarRegistry re-register failed for " <>
            "#{URI.to_string(state.agent_uri)} (#{inspect(why)}) — retrying"
        )

        Process.send_after(self(), :retry_registry_registration, 200)
        {:noreply, %{state | registry_ref: nil}}
    end
  end

  # #1201 ①: codepoint-boundary-aware — a raw binary_part tail can start
  # mid-codepoint on CJK-heavy sidecar output.
  defp trim_output(output), do: Ezagent.Utf8Tail.tail(output, 8192)
end
