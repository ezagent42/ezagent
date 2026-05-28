defmodule EzagentPluginCodex.BridgeSidecar do
  @moduledoc """
  Python bridge sidecar for a codex agent.

  The sidecar connects to `Ezagent.AgentBridge.Socket`, receives
  `codex_turn` pushes from BEAM, forwards them to the per-agent Codex
  app-server, and emits `reply` events back through AgentBridge.
  """

  use GenServer

  require Logger

  defstruct [:agent_uri, :port, :test_mode, output: ""]

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
      {:ok, pid} -> GenServer.call(pid, :recent_output, 1_000)
      :error -> ""
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
    test_mode = Map.get(args, :test_mode, @compile_env == :test)
    state = %__MODULE__{agent_uri: agent_uri, test_mode: test_mode}

    if test_mode do
      {:ok, state}
    else
      case start_port(agent_uri, args) do
        {:ok, port} -> {:ok, %{state | port: port}}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl true
  def handle_call(:recent_output, _from, state) do
    {:reply, state.output, state}
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    case String.trim(data) do
      "" ->
        :ok

      output ->
        Logger.info("codex bridge sidecar output for #{URI.to_string(state.agent_uri)}:\n#{output}")
    end

    {:noreply, %{state | output: trim_output(state.output <> data)}}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.warning(
      "codex bridge sidecar exited for #{URI.to_string(state.agent_uri)} " <>
        "with status #{status}; recent output:\n#{state.output}"
    )

    {:stop, {:bridge_sidecar_exit, status}, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_port(agent_uri, args) do
    with {:ok, {runner, runner_args}} <- bridge_runner(args),
         {:ok, token} <- Ezagent.AgentBridge.TokenStore.mint(agent_uri),
         {:ok, script} <- bridge_script_path() do
      env = [
        {~c"EZAGENT_AGENT_URI", agent_uri |> URI.to_string() |> String.to_charlist()},
        {~c"EZAGENT_AGENT_TOKEN", String.to_charlist(token)},
        {~c"EZAGENT_BRIDGE_WS_URL", String.to_charlist(Map.fetch!(args, :bridge_ws_url))},
        {~c"EZAGENT_CODEX_APP_SERVER_SOCK", String.to_charlist(Map.fetch!(args, :app_server_socket))},
        {~c"EZAGENT_CODEX_THREAD_ID_FILE", String.to_charlist(Map.fetch!(args, :thread_id_file))},
        {~c"EZAGENT_CODEX_CWD", String.to_charlist(Map.fetch!(args, :cwd))}
      ]
      |> maybe_env(~c"EZAGENT_CODEX_BIN", Map.get(args, :codex_path))
      |> maybe_env(~c"EZAGENT_CODEX_MODEL", Map.get(args, :model))
      |> maybe_env(~c"EZAGENT_CODEX_APPROVAL_POLICY", Map.get(args, :approval_policy))
      |> maybe_env(~c"EZAGENT_CODEX_SANDBOX", Map.get(args, :sandbox))

      port =
        Port.open({:spawn_executable, runner}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, runner_args ++ [script]},
          {:cd, Map.fetch!(args, :cwd)},
          {:env, env}
        ])

      {:ok, port}
    end
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
  defp maybe_env(env, key, value) when is_binary(value), do: [{key, String.to_charlist(value)} | env]

  defp trim_output(output) when byte_size(output) > 8192 do
    binary_part(output, byte_size(output), -8192)
  end

  defp trim_output(output), do: output
end
