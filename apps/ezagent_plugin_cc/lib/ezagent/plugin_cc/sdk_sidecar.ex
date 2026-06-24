defmodule EzagentPluginCc.SdkSidecar do
  @moduledoc """
  Supervised Python Claude Code SDK worker for one `cc-headless` agent.

  The worker speaks stdin/stdout JSON lines. It owns the SDK client and
  serializes `query + receive_response`; this GenServer owns process lifecycle
  and request correlation.
  """

  use GenServer

  require Logger

  defstruct [
    :agent_uri,
    :port,
    :session_id,
    :cwd,
    :config_dir,
    pending: %{},
    next_id: 0,
    output: ""
  ]

  @line_length 1_048_576
  @default_timeout 120_000

  @doc false
  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCc.SdkSidecarSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @doc false
  @spec lookup(URI.t()) :: {:ok, pid()} | :error
  def lookup(%URI{} = agent_uri) do
    case Registry.lookup(EzagentPluginCc.SdkSidecarRegistry, URI.to_string(agent_uri)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc false
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  @doc false
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(EzagentPluginCc.SdkSidecarSupervisor, pid)
        :ok

      :error ->
        :ok
    end
  end

  @doc false
  @spec recent_output(URI.t()) :: String.t()
  def recent_output(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} -> GenServer.call(pid, :recent_output, 1_000)
      :error -> ""
    end
  catch
    _, _ -> ""
  end

  @doc false
  @spec query(URI.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(%URI{} = agent_uri, text, opts \\ []) when is_binary(text) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    session_id = Keyword.get(opts, :session_id)

    case lookup(agent_uri) do
      {:ok, pid} -> GenServer.call(pid, {:query, text, session_id}, timeout)
      :error -> {:error, :sdk_sidecar_not_started}
    end
  catch
    :exit, {:timeout, _} -> {:error, :sdk_sidecar_timeout}
  end

  @doc false
  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {EzagentPluginCc.SdkSidecarRegistry, URI.to_string(agent_uri)}}
    )
  end

  @impl true
  def init(%{agent_uri: agent_uri} = args) do
    state = %__MODULE__{
      agent_uri: agent_uri,
      session_id: Map.get(args, :session_id, new_session_id()),
      cwd: Map.fetch!(args, :cwd),
      config_dir: Map.fetch!(args, :config_dir)
    }

    case start_port(args) do
      {:ok, port} -> {:ok, %{state | port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:recent_output, _from, state) do
    {:reply, state.output, state}
  end

  def handle_call({:query, text, session_id}, from, state) do
    req_id = "cc-sdk-" <> Integer.to_string(state.next_id + 1)

    frame = %{
      id: req_id,
      op: "query",
      text: text,
      session_id: session_id || state.session_id
    }

    case send_frame(state.port, frame) do
      :ok ->
        pending = Map.put(state.pending, req_id, from)
        {:noreply, %{state | pending: pending, next_id: state.next_id + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({_port, {:data, {:eol, line}}}, state) do
    handle_line(to_string(line), state)
  end

  def handle_info({_port, {:data, {:noeol, line}}}, state) do
    {:noreply, %{state | output: trim_output(state.output <> to_string(line))}}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.warning(
      "cc-headless SDK sidecar exited for #{URI.to_string(state.agent_uri)} " <>
        "with status #{status}; recent output:\n#{state.output}"
    )

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, {:sdk_sidecar_exit, status}})
    end)

    {:stop, {:sdk_sidecar_exit, status}, %{state | pending: %{}}}
  end

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    Port.close(port)
  catch
    _, _ -> :ok
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

  defp start_port(args) do
    with {:ok, {runner, runner_args}} <- sdk_runner(args),
         {:ok, script} <- sdk_worker_path(args) do
      env =
        [
          {~c"EZAGENT_CC_SDK_CWD", args |> Map.fetch!(:cwd) |> String.to_charlist()},
          {~c"EZAGENT_CC_SDK_CONFIG_DIR",
           args |> Map.fetch!(:config_dir) |> String.to_charlist()},
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

      port =
        Port.open({:spawn_executable, runner}, [
          :binary,
          :exit_status,
          {:line, @line_length},
          {:args, runner_args ++ [script]},
          {:cd, Map.fetch!(args, :cwd)},
          {:env, env}
        ])

      {:ok, port}
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

  defp send_frame(port, frame) when is_port(port) do
    data = Jason.encode!(frame) <> "\n"

    if Port.command(port, data) do
      :ok
    else
      {:error, :port_closed}
    end
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

  defp maybe_env(env, _key, value) when value in [nil, ""], do: env

  defp maybe_env(env, key, value) when is_binary(value),
    do: [{key, String.to_charlist(value)} | env]

  defp maybe_json_env(env, _key, value) when value in [nil, "", [], %{}], do: env

  defp maybe_json_env(env, key, value),
    do: [{key, value |> Jason.encode!() |> String.to_charlist()} | env]

  defp trim_output(output) when byte_size(output) > 8192 do
    binary_part(output, byte_size(output), -8192)
  end

  defp trim_output(output), do: output

  defp new_session_id do
    "ezagent-cc-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
