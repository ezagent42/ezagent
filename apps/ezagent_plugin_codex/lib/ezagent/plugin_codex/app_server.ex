defmodule EzagentPluginCodex.AppServer do
  @moduledoc """
  Per-agent Codex app-server sidecar.

  The app-server is the shared control plane used by both the operator's
  Codex TUI (`codex --remote unix://...`) and the ezagent bridge sidecar
  (`codex app-server proxy --sock ...`). It is deliberately separate from
  Domain.Pty: the app-server is a control daemon, while Domain.Pty owns the
  interactive TUI process and terminal surface.
  """

  use GenServer

  require Logger

  defstruct [:agent_uri, :cwd, :socket_path, :port, :test_mode, output: ""]

  @compile_env Mix.env()

  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCodex.AppServerSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @spec lookup(URI.t()) :: {:ok, pid()} | :error
  def lookup(%URI{} = agent_uri) do
    case Registry.lookup(EzagentPluginCodex.AppServerRegistry, URI.to_string(agent_uri)) do
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

  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(EzagentPluginCodex.AppServerSupervisor, pid)
        :ok

      :error ->
        :ok
    end
  end

  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {EzagentPluginCodex.AppServerRegistry, URI.to_string(agent_uri)}}
    )
  end

  @impl true
  def init(%{agent_uri: agent_uri, cwd: cwd, socket_path: socket_path} = args) do
    test_mode = Map.get(args, :test_mode, @compile_env == :test)

    state = %__MODULE__{
      agent_uri: agent_uri,
      cwd: cwd,
      socket_path: socket_path,
      test_mode: test_mode
    }

    if test_mode do
      {:ok, state}
    else
      case start_port(cwd, socket_path, args) do
        {:ok, port} -> {:ok, %{state | port: port}}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    {:noreply, %{state | output: trim_output(state.output <> data)}}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.warning(
      "codex app-server exited for #{URI.to_string(state.agent_uri)} with status #{status}"
    )

    {:stop, {:app_server_exit, status}, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_port(cwd, socket_path, args) do
    with {:ok, codex} <- codex_executable(args),
         :ok <- File.mkdir_p(Path.dirname(socket_path)) do
      _ = File.rm(socket_path)

      port =
        Port.open({:spawn_executable, codex}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["app-server", "--listen", "unix://#{socket_path}"]},
          {:cd, cwd}
        ])

      {:ok, port}
    end
  end

  defp codex_executable(args) do
    case Map.get(args, :codex_path) || System.find_executable("codex") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, :codex_not_found}
    end
  end

  defp trim_output(output) when byte_size(output) > 8192 do
    binary_part(output, byte_size(output), -8192)
  end

  defp trim_output(output), do: output
end
