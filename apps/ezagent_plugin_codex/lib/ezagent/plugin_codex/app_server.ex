defmodule EzagentPluginCodex.AppServer do
  @moduledoc """
  Per-agent Codex app-server sidecar.

  The app-server is the shared control plane used by both the operator's
  Codex TUI (`codex --remote unix://...`) and the ezagent bridge sidecar
  (`codex app-server proxy --sock ...`). It is deliberately separate from
  Domain.Pty: the app-server is a control daemon, while Domain.Pty owns the
  interactive TUI process and terminal surface.

  ## Transport

  Spawns the Codex app-server process via `Ezagent.Runtime.OsProcess`
  (erlexec `run_link` + `{group,0}` + `kill_group`) so every teardown path
  — graceful shutdown, owner crash, brutal BEAM SIGKILL — reaps the full
  process group (codex → vendored bins). Replaces the native `Port.open`
  used before.

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §4.
  """

  use GenServer

  require Logger

  alias Ezagent.Runtime.OsProcess

  defstruct [:agent_uri, :cwd, :socket_path, :exec_pid, :os_pid, :test_mode, output: ""]

  @compile_env Mix.env()
  @ready_poll_ms 50

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

  @doc "Recent buffered app-server output for `agent_uri`, or `\"\"` if it is not running."
  @spec recent_output(URI.t()) :: String.t()
  def recent_output(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} -> GenServer.call(pid, :recent_output, 1_000)
      :error -> ""
    end
  catch
    _, _ -> ""
  end

  @doc "Blocks until the app-server unix socket at `socket_path` exists, or `timeout_ms` elapses."
  @spec wait_until_ready(URI.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def wait_until_ready(%URI{} = agent_uri, socket_path, timeout_ms)
      when is_binary(socket_path) and is_integer(timeout_ms) and timeout_ms >= 0 do
    do_wait_until_ready(agent_uri, socket_path, System.monotonic_time(:millisecond) + timeout_ms)
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
    # SPEC §3.1 caller contract: trap_exit UNCONDITIONALLY — even in test_mode
    # where no child spawns — so supervisor :shutdown reaches terminate/2.
    Process.flag(:trap_exit, true)

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
      case start_os_process(cwd, socket_path, args) do
        {:ok, exec_pid, os_pid} -> {:ok, %{state | exec_pid: exec_pid, os_pid: os_pid}}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  # ─── stdout: raw framing — accumulate chunks directly (no LineBuffer) ────

  @impl true
  def handle_call(:recent_output, _from, state) do
    {:reply, state.output, state}
  end

  @impl true
  def handle_info({:stdout, _os_pid, bytes}, state) when is_binary(bytes) do
    {:noreply, %{state | output: trim_output(state.output <> bytes)}}
  end

  # ─── stderr: :merge means stderr arrives as :stdout — defensive clause ────

  def handle_info({:stderr, _os_pid, bytes}, state) when is_binary(bytes) do
    # With stderr: :merge, erlexec routes stderr to {:stdout, …}. This clause
    # is defensive; it won't fire under normal configuration.
    {:noreply, %{state | output: trim_output(state.output <> bytes)}}
  end

  # ─── child exit via run_link — handle ALL reason shapes ──────────────────

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    Logger.warning(
      "codex app-server exited for #{URI.to_string(state.agent_uri)} " <>
        "reason=#{inspect(reason)}; recent output:\n#{state.output}"
    )

    {:stop, {:app_server_exit, reason}, state}
  end

  # Defensive: ignore exits from processes we didn't spawn.
  def handle_info({:EXIT, _other, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{exec_pid: exec_pid, agent_uri: agent_uri} = _state)
      when not is_nil(exec_pid) do
    OsProcess.stop(exec_pid)
    OsProcess.cleanup_pid_file("codex-appserver", agent_uri)
  end

  def terminate(_reason, _state), do: :ok

  defp start_os_process(cwd, socket_path, args) do
    with {:ok, codex} <- codex_executable(args),
         :ok <- File.mkdir_p(Path.dirname(socket_path)) do
      _ = File.rm(socket_path)

      agent_uri = Map.fetch!(args, :agent_uri)

      case OsProcess.spawn(
             [codex, "app-server", "--listen", "unix://#{socket_path}"],
             cd: cwd,
             env: port_env(Map.get(args, :cmd_env, %{})),
             stderr: :merge,
             pid_file: {"codex-appserver", agent_uri}
           ) do
        {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} ->
          {:ok, exec_pid, os_pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp port_env(cmd_env) when is_map(cmd_env) do
    Enum.map(cmd_env, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp port_env(_), do: []

  defp codex_executable(args) do
    case Map.get(args, :codex_path) || System.find_executable("codex") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, :codex_not_found}
    end
  end

  defp do_wait_until_ready(agent_uri, socket_path, deadline_ms) do
    cond do
      File.exists?(socket_path) ->
        :ok

      not alive?(agent_uri) ->
        {:error, {:codex_app_server_exited_before_ready, socket_path, recent_output(agent_uri)}}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error, {:codex_app_server_socket_timeout, socket_path, recent_output(agent_uri)}}

      true ->
        Process.sleep(@ready_poll_ms)
        do_wait_until_ready(agent_uri, socket_path, deadline_ms)
    end
  end

  # #1201 ①: codepoint-boundary-aware — a raw binary_part tail can start
  # mid-codepoint on CJK-heavy sidecar output.
  defp trim_output(output), do: Ezagent.Utf8Tail.tail(output, 8192)
end
