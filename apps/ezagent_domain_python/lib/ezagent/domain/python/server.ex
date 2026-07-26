defmodule Ezagent.Domain.Python.Server do
  @moduledoc """
  GenServer wrapping one `:exec.run/2`-launched Python subprocess.

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md`. The
  Server owns the subprocess lifecycle:

    * synchronous spawn + `python.ping` readiness gate inside `init/1`
      (SPEC §3.2 / D9 — closes the false-readiness window that an async
      `{:continue, :spawn}` pattern would open)
    * per-call timer + cancel/flush late-result race handling
      (§3.3 step 5 / D16)
    * RPC timeout treated as subprocess unhealthy → tear down + restart
      (§3.3.1 / D10)
    * bounded 2-file rotating stderr (§3.7 / D17)
    * `tearing_down?` flag drops in-flight frames during shutdown
      (§3.3.1 / D16)
    * `:await_ready` queue so concurrent callers see the same outcome
      (§3.2 step 2 / D13)

  Sibling of `Ezagent.Domain.Pty.Server` — both wrap `:exec.run/2`;
  Domain.Pty allocates a tty (`:pty` opt), Domain.Python does not.

  ## Test mode

  When `Spec.test_mode` is `true` (default in `:test`), `init/1`
  short-circuits the `:exec.run/2` spawn + ping handshake and goes
  straight to `ready? := true`. Used by `ServerTest` / facade tests
  that exercise the dispatch / Registry / canonicalization paths
  without exercising real uv / Python.
  """

  use GenServer
  require Logger

  alias Ezagent.Domain.Python
  alias EzagentDomainPython.{FrameBuffer, JsonRpc}

  defstruct [
    :handle,
    :handle_key,
    :spec,
    :exec_pid,
    :os_pid,
    :monitor_ref,
    :stderr_log_path,
    :stderr_log_io,
    :stderr_log_bytes,
    next_id: 1,
    pending_requests: %{},
    frame_buffer: %FrameBuffer{},
    ready?: false,
    ready_waiters: [],
    tearing_down?: false,
    test_mode: false,
    # PTY-phase-state-machine 2026-05-26 follow-up (b). Symmetric
    # tracking of the three canonical subprocess phases — same shape
    # as `Ezagent.Domain.Pty.Server`. Transition points:
    #
    #   :starting → :running  on python.ping pong success (we broadcast
    #                          :running AFTER the ping handshake so
    #                          operator-visible "ready" only flips when
    #                          the subprocess is actually accepting work)
    #   :starting → :dead     on :uv_not_found / :spawn_failed / ping
    #                          timeout / spawn-died-at-init
    #   :running  → :dead     on {:DOWN, ...} or :rpc_timeout tear-down
    #
    # `dead_broadcast?` prevents terminate/2 from double-emitting the
    # terminal phase when an upstream signal already published.
    phase: :starting,
    dead_broadcast?: false
  ]

  @type state :: %__MODULE__{}

  # --- start_link ------------------------------------------------------

  @doc "child_spec for DynamicSupervisor.start_child/2."
  def child_spec(spec) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [spec]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Start a Server bound to `spec.handle` via the Registry."
  def start_link(%Python.Spec{} = spec) do
    key = Python.handle_key(spec.handle)
    GenServer.start_link(__MODULE__, {spec, key}, name: via(key))
  end

  defp via(key) when is_binary(key) do
    {:via, Registry, {EzagentDomainPython.Registry, key}}
  end

  @doc """
  PubSub topic for a Python subprocess's phase transitions
  (PTY-phase-state-machine 2026-05-26 follow-up b).

  Subscribers receive messages of shape
  `{:pty_phase, agent_uri, phase, meta}` where:

    * `phase` is `:starting | :running | :dead`
    * `meta` carries `%{os_pid: integer() | nil, reason: term() | nil,
      at: System.os_time(:millisecond)}`

  The topic name mirrors `Ezagent.Domain.Pty.Server.phase_topic/1`
  intentionally — the np plugin subscribes via the agent URI's
  topic; whether the agent is a cc-flavor PTY or an np-flavor Python
  subprocess is opaque to the LV badge.

  Best-effort: PubSub broadcast failures are logged but never raise
  into the Server's primary path.
  """
  def phase_topic(%URI{} = agent_uri),
    do: "pty:phase:" <> URI.to_string(agent_uri)

  @doc """
  Public accessor for the current phase of a live Python Server.

  Returns `:starting | :running | :dead` for a live server, or
  `:dead` when no server exists. Callers that need to distinguish
  "no server" from "server in :dead" should use
  `Ezagent.Domain.Python.alive?/1` first.
  """
  @spec phase(URI.t() | binary()) :: :starting | :running | :dead
  def phase(handle) do
    key = Python.handle_key(handle)

    case Registry.lookup(EzagentDomainPython.Registry, key) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid, 500)
          state.phase || :dead
        catch
          _, _ -> :dead
        end

      [] ->
        :dead
    end
  end

  # --- init: SYNCHRONOUS spawn + ping (SPEC §3.2) ----------------------

  @impl true
  def init({%Python.Spec{} = spec, key}) do
    Process.flag(:trap_exit, true)

    test_mode = resolve_test_mode(spec)

    state = %__MODULE__{
      handle: spec.handle,
      handle_key: key,
      spec: spec,
      test_mode: test_mode,
      stderr_log_path: stderr_log_path(key),
      stderr_log_bytes: 0,
      phase: :starting
    }

    # PTY-phase-state-machine follow-up (b): emit :starting before any
    # spawn / ping work. Subscribers (PyAgent slice + LV) see the
    # canonical opening transition even on a fast-fail
    # (uv_not_found / bad cwd / etc).
    broadcast_phase(state, :starting, %{})

    if test_mode do
      # Test mode short-circuits the real spawn. Per Allen's directive
      # the test-mode path STILL emits :starting → :running so unit
      # tests subscribing to phase_topic/1 see the canonical sequence.
      new_state = %{state | ready?: true, phase: :running}
      broadcast_phase(new_state, :running, %{os_pid: nil})
      {:ok, new_state}
    else
      do_spawn_and_ping(state)
    end
  end

  defp resolve_test_mode(%Python.Spec{test_mode: nil}),
    do: Code.ensure_loaded?(Mix) and Mix.env() == :test

  defp resolve_test_mode(%Python.Spec{test_mode: tm}) when is_boolean(tm), do: tm

  defp do_spawn_and_ping(state) do
    with {:ok, argv} <- Python.Spec.to_argv(state.spec),
         {:ok, exec_pid, os_pid, ref} <- spawn_subprocess(argv, state.spec) do
      # PTY-pid-files 2026-05-26 follow-up (a): persist os_pid so the
      # np plugin's OrphanReaper can discover prior-incarnation children
      # at next-BEAM boot without `ps` scanning. Only when handle is a
      # URI (the plugin path); domain-level tests may use binary handles
      # and don't need pid-file tracking.
      _ = maybe_write_pid_file(state.spec.handle, os_pid)

      state =
        %{state | exec_pid: exec_pid, os_pid: os_pid, monitor_ref: ref}
        |> open_stderr_log()

      send_ping_frame(state, 0)

      case await_ping(state, state.spec.ping_timeout_ms) do
        {:ok, new_state} ->
          # PTY-phase-state-machine follow-up (b): subprocess is alive
          # AND the python.ping handshake completed — flip to :running
          # so subscribers see "ready to accept work" only when truly
          # ready. The pre-ping window stays in :starting (already
          # emitted in init/1).
          ready_state = %{new_state | ready?: true, phase: :running}
          broadcast_phase(ready_state, :running, %{os_pid: os_pid})
          {:ok, ready_state}

        {:stop, reason, _new_state} ->
          # init/1 returning {:stop, reason} propagates back as
          # {:error, reason} from start_link. Make sure the subprocess
          # doesn't leak.
          dead_state = %{state | phase: :dead, dead_broadcast?: true}
          broadcast_phase(dead_state, :dead, %{reason: reason, os_pid: os_pid})
          force_stop_exec(state.exec_pid)
          close_stderr_log(state)
          {:stop, reason}
      end
    else
      {:error, :uv_not_found} ->
        dead_state = %{state | phase: :dead, dead_broadcast?: true}
        broadcast_phase(dead_state, :dead, %{reason: :uv_not_found, os_pid: nil})
        {:stop, :uv_not_found}

      {:error, {:spawn_failed, _} = reason} ->
        dead_state = %{state | phase: :dead, dead_broadcast?: true}
        broadcast_phase(dead_state, :dead, %{reason: reason, os_pid: nil})
        {:stop, reason}

      {:error, reason} ->
        dead_state = %{state | phase: :dead, dead_broadcast?: true}
        broadcast_phase(dead_state, :dead, %{reason: reason, os_pid: nil})
        {:stop, {:spawn_failed, reason}}
    end
  end

  defp spawn_subprocess(argv, %Python.Spec{} = spec) do
    cmd = Enum.map(argv, &String.to_charlist/1)
    env = build_env(spec)

    opts = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:env, env},
      {:cd, String.to_charlist(spec.cwd)}
    ]

    case :exec.run(cmd, opts) do
      {:ok, exec_pid, os_pid} ->
        # `:monitor` causes erlexec to send {:DOWN, ref, ...} on exit.
        # The ref is the exec_pid's monitor; we record it for later use
        # but `Process.monitor`-style cleanup is not needed — erlexec
        # owns the monitor.
        {:ok, exec_pid, os_pid, exec_pid}

      {:error, _} = err ->
        err
    end
  end

  # Selective receive that handles erlexec stdout / stderr / DOWN
  # messages while waiting for the python.ping response. Frame parsing
  # uses the same FrameBuffer the main loop uses post-init.
  defp await_ping(state, timeout_ms) do
    deadline = monotonic_ms() + timeout_ms
    do_await_ping(state, deadline)
  end

  defp do_await_ping(state, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    receive do
      {:stdout, _os_pid, bytes} ->
        {new_state, frames} = FrameBuffer.feed(state.frame_buffer, IO.iodata_to_binary(bytes))
        state = %{state | frame_buffer: new_state}

        case dispatch_init_frames(frames, state) do
          {:pong, state} -> {:ok, state}
          {:cont, state} -> do_await_ping(state, deadline)
          {:error, reason, state} -> {:stop, reason, state}
        end

      {:stderr, _os_pid, bytes} ->
        state = append_stderr(state, IO.iodata_to_binary(bytes))
        do_await_ping(state, deadline)

      {:DOWN, _ref, :process, _pid, reason} ->
        {:stop, {:spawn_died_at_init, reason}, state}
    after
      remaining ->
        {:stop, :ping_timeout, state}
    end
  end

  # During init we only care about the python.ping response (id 0).
  # Other frames (notifications, late stdout) are tolerated and dropped
  # — the main loop will start handling them once init/1 returns.
  defp dispatch_init_frames([], state), do: {:cont, state}

  defp dispatch_init_frames([body | rest], state) do
    case JsonRpc.decode_body(body) do
      {:ok, {:result, 0, %{"pong" => true}}} ->
        {:pong, state}

      {:ok, {:error, 0, _code, msg, _data}} ->
        {:error, {:ping_failed, msg}, state}

      {:ok, _other} ->
        dispatch_init_frames(rest, state)

      {:error, reason} ->
        {:error, {:malformed_frame, reason}, state}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp send_ping_frame(state, id) do
    frame = JsonRpc.encode_frame({:request, id, "python.ping", %{}}) |> IO.iodata_to_binary()
    safe_exec_send(state.exec_pid, frame)
  end

  defp safe_exec_send(nil, _bytes), do: :ok

  defp safe_exec_send(exec_pid, bytes) do
    try do
      :exec.send(exec_pid, bytes)
    catch
      kind, reason ->
        Logger.warning("Domain.Python: :exec.send failed (#{inspect(kind)}, #{inspect(reason)})")

        :error
    end
  end

  defp build_env(%Python.Spec{} = spec) do
    lib_dir = python_lib_dir()

    [
      {~c"EZAGENT_PYTHON_LIB_DIR", String.to_charlist(lib_dir)}
    ] ++
      Enum.map(spec.env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)
  end

  defp python_lib_dir do
    case :code.priv_dir(:ezagent_domain_python) do
      {:error, _} ->
        # Fallback when running as escript / outside an OTP release;
        # tests typically have priv_dir resolved via the umbrella build.
        Path.expand("../../priv/python", __DIR__)

      path when is_list(path) ->
        Path.join(List.to_string(path), "python")
    end
  end

  # --- call / notify (post-ready) --------------------------------------

  @impl true
  def handle_call(:await_ready, _from, %__MODULE__{ready?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, from, %__MODULE__{ready_waiters: waiters} = state) do
    # Reached when init/1 returned (ready? could be set later) — keep
    # for symmetry with reply_ready_waiters; in current design init/1
    # only returns with ready?: true or {:stop, _}, so this branch is
    # defensive (e.g. if a future revision adds an async ready path).
    {:noreply, %{state | ready_waiters: [from | waiters]}}
  end

  def handle_call(
        {:rpc_call, _method, _params, _timeout},
        _from,
        %__MODULE__{tearing_down?: true} = state
      ) do
    {:reply, {:error, :subprocess_unhealthy}, state}
  end

  def handle_call(
        {:rpc_call, _method, _params, _timeout},
        _from,
        %__MODULE__{ready?: false} = state
      ) do
    {:reply, {:error, :not_alive}, state}
  end

  def handle_call(
        {:rpc_call, method, params, timeout},
        from,
        %__MODULE__{test_mode: true} = state
      ) do
    # In test mode there is no real subprocess to round-trip the call
    # through; return :not_alive so tests can exercise the dispatch /
    # Registry / canonicalization paths without simulating Python.
    # Tests that need real RPC behaviour use the integration suite
    # (@uv tag).
    _ = {method, params, timeout, from}
    {:reply, {:error, :not_alive}, state}
  end

  def handle_call({:rpc_call, method, params, timeout}, from, state) do
    id = state.next_id
    frame = JsonRpc.encode_frame({:request, id, method, params}) |> IO.iodata_to_binary()
    safe_exec_send(state.exec_pid, frame)

    timer_ref = Process.send_after(self(), {:rpc_timeout, id}, timeout)

    pending = Map.put(state.pending_requests, id, {from, timer_ref})

    {:noreply, %{state | next_id: id + 1, pending_requests: pending}}
  end

  def handle_call(:graceful_stop, _from, %__MODULE__{test_mode: true} = state) do
    # Reply every pending call quickly; tests do not exercise this path
    # in test_mode but the symmetry keeps semantics consistent.
    state = reply_all_pending(state, {:error, :subprocess_unhealthy})
    {:stop, :normal, :ok, state}
  end

  def handle_call(:graceful_stop, _from, state) do
    state = %{state | tearing_down?: true}

    if state.exec_pid do
      frame =
        JsonRpc.encode_frame({:notification, "python.shutdown", %{}})
        |> IO.iodata_to_binary()

      safe_exec_send(state.exec_pid, frame)

      # Wait up to shutdown_grace_ms for the subprocess to exit
      # gracefully; if not, force-stop. We do not consume erlexec
      # stdout/stderr messages while waiting; they queue and are
      # discarded by terminate/2 path.
      grace = state.spec.shutdown_grace_ms
      :ok = wait_for_subprocess_exit(state.monitor_ref, grace)
      force_stop_exec(state.exec_pid)
    end

    state = reply_all_pending(state, {:error, :subprocess_unhealthy})
    close_stderr_log(state)
    {:stop, :normal, :ok, state}
  end

  defp wait_for_subprocess_exit(nil, _grace), do: :ok

  defp wait_for_subprocess_exit(_ref, grace) do
    receive do
      {:DOWN, _ref, :process, _pid, _reason} -> :ok
    after
      grace -> :ok
    end
  end

  @impl true
  def handle_cast({:rpc_notify, _method, _params}, %__MODULE__{ready?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:rpc_notify, _method, _params}, %__MODULE__{test_mode: true} = state) do
    {:noreply, state}
  end

  def handle_cast({:rpc_notify, method, params}, state) do
    frame =
      JsonRpc.encode_frame({:notification, method, params})
      |> IO.iodata_to_binary()

    safe_exec_send(state.exec_pid, frame)
    {:noreply, state}
  end

  # --- erlexec messages ------------------------------------------------

  @impl true
  def handle_info({:stdout, _os_pid, _bytes}, %__MODULE__{tearing_down?: true} = state) do
    {:noreply, state}
  end

  def handle_info({:stdout, _os_pid, bytes}, state) do
    {new_buf, frames} = FrameBuffer.feed(state.frame_buffer, IO.iodata_to_binary(bytes))
    state = %{state | frame_buffer: new_buf}
    state = Enum.reduce(frames, state, &dispatch_main_frame/2)
    {:noreply, state}
  end

  def handle_info({:stderr, _os_pid, bytes}, state) do
    state = append_stderr(state, IO.iodata_to_binary(bytes))
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning(
      "Domain.Python: subprocess exited handle=#{state.handle_key} reason=#{inspect(reason)}"
    )

    # PTY-phase-state-machine follow-up (b): the subprocess died —
    # publish :dead BEFORE returning {:stop, ...} so subscribers see
    # the terminal phase while this GenServer is still alive enough
    # to broadcast (terminate/2 would also fire, but `dead_broadcast?:
    # true` short-circuits the duplicate emit).
    new_state = %{state | phase: :dead, dead_broadcast?: true}
    broadcast_phase(new_state, :dead, %{reason: {:subprocess_died, reason}, os_pid: state.os_pid})

    state = reply_all_pending(new_state, {:error, {:subprocess_died, reason}})
    state = reply_ready_waiters(state, {:error, {:subprocess_died, reason}})
    close_stderr_log(state)
    {:stop, {:subprocess_died, reason}, state}
  end

  def handle_info({:rpc_timeout, id}, state) do
    case Map.fetch(state.pending_requests, id) do
      :error ->
        # Stale timer — response already came in and the response
        # handler cancelled + flushed. No-op.
        {:noreply, state}

      {:ok, {from, _timer_ref}} ->
        # SPEC §3.3.1: a hung handler → tear down + restart via DynSup.
        Logger.warning(
          "Domain.Python: RPC timeout handle=#{state.handle_key} id=#{id} — tearing down"
        )

        GenServer.reply(from, {:error, :rpc_timeout})

        state =
          %{state | pending_requests: Map.delete(state.pending_requests, id)}
          |> Map.put(:tearing_down?, true)
          |> reply_all_pending({:error, :subprocess_unhealthy})

        # PTY-phase-state-machine follow-up (b): RPC-timeout tear-down
        # publishes :dead so subscribers stop polling and re-render
        # the "Dead — Restart" badge before DynSup's restart kicks in.
        dead_state = %{state | phase: :dead, dead_broadcast?: true}
        broadcast_phase(dead_state, :dead, %{reason: :subprocess_unhealthy, os_pid: state.os_pid})

        force_stop_exec(state.exec_pid)
        close_stderr_log(state)
        {:stop, :subprocess_unhealthy, dead_state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- frame dispatch (post-ready) -------------------------------------

  defp dispatch_main_frame(body, state) do
    case JsonRpc.decode_body(body) do
      {:ok, {:result, id, payload}} ->
        finish_pending(state, id, {:ok, payload})

      {:ok, {:error, id, code, msg, data}} ->
        err = %{"code" => code, "message" => msg, "data" => data}
        finish_pending(state, id, {:error, err})

      {:ok, {:notification, "log", params}} ->
        log_from_python(state, params)
        state

      {:ok, {:notification, "progress", params}} ->
        :telemetry.execute(
          [:ezagent, :python, :progress],
          %{fraction: Map.get(params, "fraction", 0.0)},
          %{handle: state.handle_key, params: params}
        )

        state

      {:ok, {:notification, name, _params}} ->
        Logger.warning(
          "Domain.Python: ignoring unknown notification #{inspect(name)} from #{state.handle_key}"
        )

        state

      {:ok, {:request, id, _method, _params}} ->
        # SPEC §2.3 — V1 disallows Python → BEAM requests; reply with
        # method-not-found so a buggy plugin sees a clear error and
        # does not deadlock awaiting a response.
        err_frame =
          JsonRpc.encode_frame(
            {:error, id, -32_601, "Python → BEAM requests are not supported in V1", nil}
          )
          |> IO.iodata_to_binary()

        safe_exec_send(state.exec_pid, err_frame)
        state

      {:error, reason} ->
        Logger.warning(
          "Domain.Python: dropped malformed frame from #{state.handle_key}: #{inspect(reason)}"
        )

        state
    end
  end

  # SPEC §3.3 step 5: pop, cancel timer, flush pending :rpc_timeout msg,
  # reply. If id absent, it is a late response for a previously-timed-out
  # call — drop it.
  defp finish_pending(state, id, reply) do
    case Map.fetch(state.pending_requests, id) do
      :error ->
        state

      {:ok, {from, timer_ref}} ->
        Process.cancel_timer(timer_ref)

        receive do
          {:rpc_timeout, ^id} -> :ok
        after
          0 -> :ok
        end

        GenServer.reply(from, reply)
        %{state | pending_requests: Map.delete(state.pending_requests, id)}
    end
  end

  defp reply_all_pending(state, reply) do
    Enum.each(state.pending_requests, fn {_id, {from, timer_ref}} ->
      _ = Process.cancel_timer(timer_ref)

      try do
        GenServer.reply(from, reply)
      catch
        _, _ -> :ok
      end
    end)

    %{state | pending_requests: %{}}
  end

  defp reply_ready_waiters(%__MODULE__{ready_waiters: []} = state, _reply), do: state

  defp reply_ready_waiters(%__MODULE__{ready_waiters: waiters} = state, reply) do
    Enum.each(waiters, fn from ->
      try do
        GenServer.reply(from, reply)
      catch
        _, _ -> :ok
      end
    end)

    %{state | ready_waiters: []}
  end

  # --- terminate -------------------------------------------------------

  @impl true
  def terminate(reason, state) do
    state = reply_all_pending(state, {:error, :subprocess_unhealthy})
    state = reply_ready_waiters(state, {:error, :subprocess_unhealthy})
    force_stop_exec(state.exec_pid)
    close_stderr_log(state)

    # PTY-pid-files 2026-05-26 follow-up (a): graceful-shutdown
    # cleanup of the pid file. Brutal BEAM kill skips this entirely —
    # the pid file remains on disk for the next BEAM's OrphanReaper.
    _ = maybe_remove_pid_file(state.spec.handle)

    # PTY-phase-state-machine follow-up (b): graceful termination
    # path — emit :dead if no upstream signal (e.g. spawn failure,
    # erlexec :DOWN, :rpc_timeout tear-down) already published it.
    maybe_broadcast_dead_on_terminate(state, reason)

    :ok
  end

  # Domain-owned pid-file namespace (flavor-NEUTRAL). Every Domain.Python
  # subprocess writes here regardless of the flavor/role that spawned it (py +
  # the np py-role both back onto Domain.Python). py-agent P4 renamed this from
  # the flavor-specific `"np"` to `"python"` when `np` stopped being its own
  # flavor; the orphan reaper (`EzagentPluginPy.OrphanReaper`) enumerates this
  # same namespace.
  @pid_namespace "python"

  defp maybe_write_pid_file(%URI{} = uri, os_pid),
    do: Ezagent.Runtime.PidFile.write(@pid_namespace, uri, os_pid)

  defp maybe_write_pid_file(_handle, _os_pid), do: :ok

  defp maybe_remove_pid_file(%URI{} = uri),
    do: Ezagent.Runtime.PidFile.remove(@pid_namespace, uri)

  defp maybe_remove_pid_file(_handle), do: :ok

  defp force_stop_exec(nil), do: :ok

  defp force_stop_exec(exec_pid) do
    try do
      :exec.stop(exec_pid)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # --- bounded stderr (SPEC §3.7 / D17) --------------------------------

  defp stderr_log_path(handle_key) do
    slug =
      handle_key
      |> String.replace("://", "-")
      |> String.replace("/", "_")

    # Resource-unification P3 (SPEC §10 OI-3): the diagnostic stderr log lives in
    # the per-deployment `logs/` tree (flat, no `<ws>` — the handle may be a
    # `test://` fixture, not a tenant URI) → a node-global artifact addressed
    # `system://logs` and resolved through `UriQuery`.
    base = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("logs"))
    File.mkdir_p(base)
    Path.join(base, "python-" <> slug <> ".log")
  end

  defp open_stderr_log(state) do
    path = state.stderr_log_path
    File.mkdir_p(Path.dirname(path))

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        size = file_size(path)
        %{state | stderr_log_io: io, stderr_log_bytes: size}

      {:error, reason} ->
        Logger.warning("Domain.Python: cannot open stderr log #{path}: #{inspect(reason)}")

        state
    end
  end

  defp close_stderr_log(%__MODULE__{stderr_log_io: nil} = state), do: state

  defp close_stderr_log(%__MODULE__{stderr_log_io: io} = state) do
    try do
      File.close(io)
    catch
      _, _ -> :ok
    end

    %{state | stderr_log_io: nil}
  end

  defp append_stderr(%__MODULE__{stderr_log_io: nil} = state, _bytes), do: state

  defp append_stderr(state, bytes) when byte_size(bytes) == 0, do: state

  defp append_stderr(state, bytes) do
    cap = state.spec.stderr_log_max_bytes
    do_append_stderr(state, bytes, cap)
  end

  defp do_append_stderr(state, bytes, _cap) when byte_size(bytes) == 0, do: state

  defp do_append_stderr(state, bytes, cap) do
    available = cap - state.stderr_log_bytes

    cond do
      available >= byte_size(bytes) ->
        IO.binwrite(state.stderr_log_io, bytes)
        %{state | stderr_log_bytes: state.stderr_log_bytes + byte_size(bytes)}

      available > 0 ->
        <<head::binary-size(available), tail::binary>> = bytes
        IO.binwrite(state.stderr_log_io, head)
        state = %{state | stderr_log_bytes: state.stderr_log_bytes + available}
        state = rotate_stderr(state)
        do_append_stderr(state, tail, cap)

      true ->
        state = rotate_stderr(state)
        do_append_stderr(state, bytes, cap)
    end
  end

  defp rotate_stderr(state) do
    path = state.stderr_log_path
    rotated = path <> ".1"

    state =
      try do
        File.close(state.stderr_log_io)
      catch
        _, _ -> :ok
      end
      |> case do
        _ -> %{state | stderr_log_io: nil}
      end

    _ = File.rm(rotated)
    _ = File.rename(path, rotated)

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        %{state | stderr_log_io: io, stderr_log_bytes: 0}

      {:error, reason} ->
        Logger.warning("Domain.Python: stderr rotation reopen failed: #{inspect(reason)}")
        %{state | stderr_log_io: nil, stderr_log_bytes: 0}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # --- log-from-python relay -------------------------------------------

  defp log_from_python(state, params) do
    level_str = Map.get(params, "level", "info")
    message = Map.get(params, "message", "")
    meta = Map.get(params, "meta", %{})

    level =
      case level_str do
        "debug" -> :debug
        "info" -> :info
        "warn" -> :warning
        "warning" -> :warning
        "error" -> :error
        _ -> :info
      end

    Logger.log(level, fn -> "[python:#{state.handle_key}] #{message}" end,
      domain: [:python_subprocess],
      meta: meta
    )
  end

  # --- phase broadcast helpers (PTY-phase-state-machine follow-up b) ---

  # Best-effort broadcast of a phase transition. Same contract as
  # `Ezagent.Domain.Pty.Server.broadcast_phase/3` — phase tracking is
  # operator-visibility plumbing and its failure MUST NOT block the
  # primary subprocess path. PubSub broadcast errors are logged and
  # swallowed.
  #
  # The handle may be a `%URI{}` (the plugin path — np spawns one
  # Python Server per Agent URI) OR an arbitrary binary key (used by
  # facade-level tests with `test://server-test/N` handles). For the
  # binary case we skip the broadcast entirely — there's no LV /
  # Sandbox slice that would consume it, and unit tests assert on the
  # struct field `state.phase` directly.
  defp broadcast_phase(%__MODULE__{handle: %URI{} = agent_uri} = state, phase, extra_meta)
       when phase in [:starting, :running, :dead] do
    meta =
      Map.merge(
        %{
          os_pid: state.os_pid,
          reason: nil,
          at: System.os_time(:millisecond)
        },
        extra_meta || %{}
      )

    try do
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        phase_topic(agent_uri),
        {:pty_phase, agent_uri, phase, meta}
      )

      # V5 use-side H1 (delete-holes #200): dual-emit — the SAME phase also
      # goes point-to-point to the agent's Kind via the sanctioned signal
      # transport (the PyAgent behavior's `handle_signal({:pty_phase, …})`).
      # The Kind no longer subscribes to the topic above; that broadcast now
      # feeds read-only UI subscribers only. Best-effort — `:not_found`
      # (a cold agent) is acceptable.
      _ = EzagentActor.Signal.signal(agent_uri, {:pty_phase, agent_uri, phase, meta})
    catch
      kind, reason ->
        Logger.warning(
          "Domain.Python: phase broadcast failed (#{inspect(kind)}, #{inspect(reason)}) " <>
            "for #{URI.to_string(agent_uri)} phase=#{inspect(phase)}; continuing"
        )

        :ok
    end
  end

  defp broadcast_phase(%__MODULE__{} = _state, _phase, _meta), do: :ok

  # Idempotency guard for the terminate/2 path. Mirrors PtyServer's
  # `dead_broadcast?` flag.
  defp maybe_broadcast_dead_on_terminate(%__MODULE__{dead_broadcast?: true}, _reason), do: :ok

  defp maybe_broadcast_dead_on_terminate(%__MODULE__{} = state, reason) do
    broadcast_phase(state, :dead, %{reason: reason, os_pid: state.os_pid})
  end
end
