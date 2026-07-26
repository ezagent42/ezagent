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

  ## V5 pid-closure A1b — resolver-seam registration

  Every AppServer SELF-registers under `{agent_uri, :ezagent_plugin_codex,
  :codex_app}` in the unified `Ezagent.Runtime.SidecarRegistry` (the retired
  private `EzagentPluginCodex.AppServerRegistry` is gone), and every reach
  converges on the pid-free `Ezagent.Runtime.Resolver` face (`alive?/1`,
  `call/3`, `terminate_child/2`) — no caller looks up a pid, probes state
  with `:sys.get_state/2`, or walks the DynamicSupervisor any more.
  """

  # `restart: :transient` (V5 A1b codex blocker B, PTY-pilot policy): an
  # ABNORMAL stop — the erlexec child's `{:app_server_exit, _}` — still
  # restarts under `EzagentPluginCodex.AppServerSupervisor` exactly as
  # `:permanent` did. But a GRACEFUL stop (only the registry-collision
  # policy below stops this way) must NOT be restarted: the loser of a
  # registry-restart race has its :via key owned by the replacement, so a
  # restart would fail-start on `{:already_started, _}` in a loop until the
  # DynamicSupervisor's intensity tripped and took EVERY AppServer down.
  use GenServer, restart: :transient

  require Logger

  alias Ezagent.Runtime.OsProcess
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  # V5 pid-closure A1b — this sidecar's resolver-seam identity. The key is
  # the address, never a pid (PTY-pilot pattern, `Ezagent.Domain.Pty.Server`).
  @plugin :ezagent_plugin_codex
  @role :codex_app

  defstruct [
    :agent_uri,
    :cwd,
    :socket_path,
    :exec_pid,
    :os_pid,
    :test_mode,
    :registry_ref,
    output: ""
  ]

  @compile_env Mix.env()
  @ready_poll_ms 50

  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentPluginCodex.AppServerSupervisor,
      {__MODULE__, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @doc """
  The resolver-seam key for this agent's app-server sidecar:
  `{agent_uri, :ezagent_plugin_codex, :codex_app}`. Public so callers build
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
  Is this agent's app-server sidecar alive? Pid-free — resolved through the
  V5 resolver seam's `Resolver.alive?/1`.
  """
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri), do: Resolver.alive?(resolver_key(agent_uri))

  @doc """
  Recent buffered app-server output for `agent_uri`, or `\"\"` if it is not
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
  The OS pid of the spawned app-server (`nil` in test_mode / not running).

  V5 A1b: the explicit status query that replaced the test-only
  `:sys.get_state/2` reach-in — served by `handle_call(:os_pid, ...)` through
  the seam's `Resolver.call/3`.
  """
  @spec os_pid(URI.t()) :: non_neg_integer() | nil
  def os_pid(%URI{} = agent_uri) do
    case Resolver.call(resolver_key(agent_uri), :os_pid, 500) do
      {:ok, os_pid} -> os_pid
      {:error, _} -> nil
    end
  end

  @doc "Blocks until the app-server unix socket at `socket_path` exists, or `timeout_ms` elapses."
  @spec wait_until_ready(URI.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def wait_until_ready(%URI{} = agent_uri, socket_path, timeout_ms)
      when is_binary(socket_path) and is_integer(timeout_ms) and timeout_ms >= 0 do
    do_wait_until_ready(agent_uri, socket_path, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc """
  Stop this agent's app-server sidecar. Pid-free — the seam resolves the key
  and asks the plugin's own `AppServerSupervisor` to terminate the child.
  """
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    _ = Resolver.terminate_child(resolver_key(agent_uri), EzagentPluginCodex.AppServerSupervisor)
    :ok
  end

  def start_link(%{agent_uri: %URI{} = agent_uri} = args) do
    # V5 A1b: the :via lives on the unified `Ezagent.Runtime.SidecarRegistry`
    # (plugin-qualified `{agent_uri, :ezagent_plugin_codex, :codex_app}` key).
    GenServer.start_link(__MODULE__, args, name: via(agent_uri))
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
      test_mode: test_mode,
      # V5 A1b codex #5 — watch the unified registry so its restart (the
      # entry dies with it) triggers self re-registration, keeping this
      # sidecar resolvable through the seam.
      registry_ref: SidecarRegistry.watch()
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

  @impl true
  def handle_call(:recent_output, _from, state) do
    {:reply, state.output, state}
  end

  # V5 A1b — the explicit os_pid status query that replaced the test-only
  # `:sys.get_state/2` reach-in (PTY-pilot pattern).
  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  # V5 A1b codex #5 — the unified SidecarRegistry restarted (it lives in
  # ANOTHER app's supervision tree); our :via entry died with it. Re-register
  # THIS process and re-arm the watch so the sidecar stays resolvable through
  # the seam. Matched BEFORE any generic stale-:DOWN clause.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{registry_ref: ref} = state)
      when is_reference(ref) do
    Logger.warning(
      "codex app-server: SidecarRegistry DOWN (#{inspect(reason)}) — re-registering " <>
        URI.to_string(state.agent_uri)
    )

    reregister_with_registry(state)
  end

  def handle_info(:retry_registry_registration, %__MODULE__{registry_ref: nil} = state),
    do: reregister_with_registry(state)

  def handle_info(:retry_registry_registration, state), do: {:noreply, state}

  # ─── stdout: raw framing — accumulate chunks directly (no LineBuffer) ────

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

  # V5 A1b codex #5 — re-register THIS process under its seam key after a
  # registry restart, then re-arm the watch. On failure (registry still down
  # after the helper's bounded wait) schedule a retry instead of crashing:
  # the worker is healthy, only its discoverability is degraded.
  #
  # codex blocker B (collision policy) — `{:error, :already_registered}`
  # means a REPLACEMENT worker won the key during the registry's empty-
  # restart window. This original is now unreachable through the seam, and
  # two live app-servers for one agent must never coexist: LOSE GRACEFULLY —
  # stop; `terminate/2` releases the erlexec child, and `restart: :transient`
  # keeps the supervisor from resurrecting the loser.
  defp reregister_with_registry(state) do
    case SidecarRegistry.re_register(resolver_key(state.agent_uri)) do
      :ok ->
        {:noreply, %{state | registry_ref: SidecarRegistry.watch()}}

      {:error, :already_registered} ->
        Logger.warning(
          "codex app-server: SidecarRegistry key for #{URI.to_string(state.agent_uri)} is " <>
            "owned by a replacement that won the restart race — this losing " <>
            "original is terminating gracefully (releasing its child)"
        )

        {:stop, {:shutdown, :registry_collision}, state}

      {:error, why} ->
        Logger.error(
          "codex app-server: SidecarRegistry re-register failed for " <>
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
