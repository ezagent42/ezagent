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
  """

  use GenServer

  require Logger

  alias Ezagent.Runtime.OsProcess

  defstruct [:agent_uri, :exec_pid, :os_pid, :test_mode, output: ""]

  @compile_env Mix.env()

  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCodex.BridgeSidecarSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @spec lookup(URI.t()) :: {:ok, pid()} | :error
  def lookup(%URI{} = agent_uri) do
    case Registry.lookup(EzagentPluginCodex.BridgeSidecarRegistry, URI.to_string(agent_uri)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  @spec recent_output(URI.t()) :: String.t()
  def recent_output(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        case Ezagent.OwnerGatedExecutor.call(agent_uri, pid, :recent_output, 1_000) do
          {:error, :cross_workspace_denied} -> ""
          output -> output
        end

      :error ->
        ""
    end
  catch
    _, _ -> ""
  end

  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(EzagentPluginCodex.BridgeSidecarSupervisor, pid)
        :ok

      :error ->
        :ok
    end
  end

  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {EzagentPluginCodex.BridgeSidecarRegistry, URI.to_string(agent_uri)}}
    )
  end

  @impl true
  def init(%{agent_uri: agent_uri} = args) do
    # SPEC §3.1 caller contract: trap_exit UNCONDITIONALLY — even in test_mode
    # where no child spawns — so supervisor :shutdown reaches terminate/2.
    Process.flag(:trap_exit, true)

    test_mode = Map.get(args, :test_mode, @compile_env == :test)
    state = %__MODULE__{agent_uri: agent_uri, test_mode: test_mode}

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

  # ─── stdout: raw framing — accumulate and log chunks directly ────────────

  @impl true
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

  # #1201 ①: codepoint-boundary-aware — a raw binary_part tail can start
  # mid-codepoint on CJK-heavy sidecar output.
  defp trim_output(output), do: Ezagent.Utf8Tail.tail(output, 8192)
end
