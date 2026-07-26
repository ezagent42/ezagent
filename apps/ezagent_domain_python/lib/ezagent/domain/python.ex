defmodule Ezagent.Domain.Python do
  @moduledoc """
  Domain.Python facade — start, call, stop for a uv-launched
  Python subprocess.

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md` §4.
  This is the ONLY API plugins / Behaviors / Template Classes should
  use; direct references to `Server` or `EzagentDomainPython.Supervisor`
  are an internal concern.

  ## V5 pid-closure A1b — resolver seam

  Servers SELF-register in the unified `Ezagent.Runtime.SidecarRegistry`
  under `{handle_key, :ezagent_domain_python, :python}` (the retired
  private `EzagentDomainPython.Registry` is gone); every facade reach —
  `call/4`, `alive?/1`, `stop/1` — resolves through the pid-free
  `Ezagent.Runtime.Resolver` face. No pid ever crosses this module's
  public surface (`start_subprocess/1`'s `{:ok, pid}` is the
  DynamicSupervisor's own start return).

  V5 A1b-rest dropped the dead faces: `notify/3` (tests-only cast) and
  `Server.phase/1` (zero-callers `:sys.get_state` reach-in — the live
  phase reaches operators via the `phase_topic/1` PubSub broadcast).

  ## Handle canonicalization (§1.2.1, codex round-1 HIGH-4 + round-2 HIGH-3)

  Handles MUST be one of:

    * `%URI{}` — production case; produced by `Ezagent.URI.new!/1`
      so it is already canonical.
    * binary — RESTRICTED to either (a) `URI.to_string/1` output of a
      URI that would have round-tripped through `Ezagent.URI.new!/1`,
      or (b) test fixtures prefixed `"test://"`.

  Any other type (atom, tuple, integer, map) raises `ArgumentError`
  at the boundary — silent `:not_alive` on a typo is explicitly NOT a
  supported failure mode (P4 production-usability).

  Non-canonical binaries (uppercase scheme, trailing slash,
  percent-encoded segment) also raise `ArgumentError` rather than
  silently binding to a different Registry key. The 6 negative cases
  enumerated in §1.2.1 are covered by `Ezagent.Domain.Python.HandleKeyTest`.
  """

  alias Ezagent.Domain.Python.{Server, Spec}
  alias Ezagent.Runtime.Resolver

  @typedoc "Canonical handle — `URI.t()` or a canonical binary (see §1.2.1)."
  @type handle :: URI.t() | binary()

  @doc """
  Canonicalize a handle to its Registry key (a binary).

  Raises `ArgumentError` on:
    * any non-URI / non-binary input
    * a binary whose canonical form via `Ezagent.URI.new!/1` +
      `URI.to_string/1` differs from the input
    * a malformed URI binary (rejected by `Ezagent.URI.new!/1`)
    * a binary using an unregistered scheme (rejected by
      `Ezagent.URI.new!/1`, except `"test://"` which is admitted as
      identity for test fixtures)
  """
  @spec handle_key(handle()) :: binary()
  def handle_key(%URI{} = uri), do: Ezagent.URI.stable_key(uri)

  def handle_key("test://" <> _ = bin), do: bin

  def handle_key(bin) when is_binary(bin) do
    uri =
      try do
        Ezagent.URI.new!(bin)
      rescue
        e ->
          reraise ArgumentError,
                  [
                    message:
                      "Ezagent.Domain.Python: invalid handle binary #{inspect(bin)}: " <>
                        Exception.message(e)
                  ],
                  __STACKTRACE__
      end

    canonical = URI.to_string(uri)

    if canonical != bin do
      raise ArgumentError,
            "Ezagent.Domain.Python: non-canonical handle binary. " <>
              "Got #{inspect(bin)}, canonical form is #{inspect(canonical)}. " <>
              "Pass the %URI{} struct or the canonical string."
    end

    # Stdlib URI.to_string/1 round-trips many non-canonical forms
    # unchanged — trailing slashes, percent-encoded path segments,
    # uppercase scheme via URI.new!. Per SPEC §1.2.1 these are caller
    # errors regardless of round-trip identity: two distinct strings
    # would otherwise produce two Registry keys for one logical handle.
    # We tighten by rejecting:
    #   * path ending with "/" (trailing slash)
    #   * any percent-encoding in the path / host segments
    #   * scheme containing uppercase letters
    cond do
      uri.scheme != nil and uri.scheme != String.downcase(uri.scheme) ->
        raise ArgumentError,
              "Ezagent.Domain.Python: scheme must be lowercase, got #{inspect(uri.scheme)} in #{inspect(bin)}"

      is_binary(uri.path) and String.ends_with?(uri.path, "/") ->
        raise ArgumentError,
              "Ezagent.Domain.Python: handle binary has trailing slash in path: #{inspect(bin)}"

      is_binary(uri.path) and String.contains?(uri.path, "%") ->
        raise ArgumentError,
              "Ezagent.Domain.Python: handle binary has percent-encoded path segment: #{inspect(bin)}"

      is_binary(uri.host) and String.contains?(uri.host, "%") ->
        raise ArgumentError,
              "Ezagent.Domain.Python: handle binary has percent-encoded host: #{inspect(bin)}"

      true ->
        bin
    end
  end

  def handle_key(other) do
    raise ArgumentError,
          "Ezagent.Domain.Python: handle must be %URI{} or binary, got: #{inspect(other)}"
  end

  @doc """
  Start a managed Python subprocess for `spec.handle` under
  `EzagentDomainPython.Supervisor`. SYNCHRONOUSLY blocks until the
  subprocess answers `python.ping` (or fails) — when this returns
  `{:ok, pid}`, the runtime is ready to accept calls. May take up to
  `spec.ping_timeout_ms` (default 5s).

  Preflight failures (uv missing, bad cwd, invalid Spec) return
  `{:error, _}` WITHOUT touching the DynamicSupervisor — no
  half-started child, no restart loop.

  Concurrent starts for the same handle collapse atomically at the
  `:via` unified `SidecarRegistry`. The losing caller calls
  `:await_ready` on the winning pid (SPEC §3.2 step 2, D13) — both
  callers observe the SAME final outcome (`{:ok, pid}` only when the
  subprocess actually reached ready, never a soon-to-die pid).
  """
  @spec start_subprocess(Spec.t()) ::
          {:ok, pid()}
          | {:error,
             :uv_not_found
             | :bad_cwd
             | :bad_handle
             | :bad_command
             | :bad_env
             | :ping_timeout
             | :concurrent_start_timeout
             | {:missing, atom()}
             | {:spawn_failed, term()}
             | {:spawn_died_at_init, term()}
             | {:concurrent_start_died, term()}}
  def start_subprocess(%Spec{} = spec) do
    _key = handle_key(spec.handle)

    with :ok <- Spec.validate(spec),
         {:ok, _argv} <- Spec.to_argv(spec) do
      do_start(spec)
    end
  end

  defp do_start(%Spec{} = spec) do
    case DynamicSupervisor.start_child(
           EzagentDomainPython.Supervisor,
           {Server, spec}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        await_ready(pid, spec.ping_timeout_ms)

      {:error, reason} ->
        {:error, reason}

      :ignore ->
        {:error, :ignore}
    end
  end

  # Codex round-2 HIGH-1 (SPEC §3.2 step 2 + D13): the losing concurrent
  # caller monitors the winning pid + asks it to reply :ok once ready.
  # Bare {:already_started, pid} would reintroduce false-readiness; this
  # path makes BOTH callers observe the SAME final outcome.
  defp await_ready(pid, ping_timeout_ms) do
    ref = Process.monitor(pid)

    try do
      case GenServer.call(pid, :await_ready, ping_timeout_ms + 500) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, {:timeout, _} ->
        {:error, :concurrent_start_timeout}

      :exit, {reason, _} ->
        {:error, {:concurrent_start_died, reason}}
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @doc """
  Synchronous JSON-RPC call. `timeout` is wall-clock for the call only
  (start_subprocess already ensured readiness). On timeout the
  subprocess is treated as unhealthy and torn down (SPEC §3.3.1).
  """
  @spec call(handle(), String.t(), map(), pos_integer()) ::
          {:ok, term()}
          | {:error,
             :not_alive
             | :rpc_timeout
             | :subprocess_unhealthy
             | {:subprocess_died, term()}
             | %{required(String.t()) => term()}}
  def call(handle, method, params, timeout \\ 5_000)
      when is_binary(method) and is_map(params) and is_integer(timeout) and timeout > 0 do
    # V5 A1b — pid-free: the seam resolves the resolver key and calls the
    # Server. Allow GenServer.call extra budget to cover the in-Server
    # timer + reply path (Server's :rpc_timeout fires at `timeout` ms; we
    # wait a touch longer to receive the :error result). Exit-reason
    # mapping preserves the pre-seam error contract exactly.
    case Resolver.call(
           Server.resolver_key(handle),
           {:rpc_call, method, params, timeout},
           timeout + 1_000
         ) do
      {:ok, reply} -> reply
      {:error, :no_such_actor} -> {:error, :not_alive}
      {:error, {:noproc, _}} -> {:error, :not_alive}
      {:error, {:timeout, _}} -> {:error, :rpc_timeout}
      {:error, {reason, _}} -> {:error, {:subprocess_died, reason}}
      {:error, reason} -> {:error, {:subprocess_died, reason}}
    end
  end

  @doc """
  Graceful shutdown. Idempotent — returns `:ok` whether the server was
  alive or not. Sends `python.shutdown` notification, waits up to
  `shutdown_grace_ms`, then force-stops via the supervisor. Pid-free —
  both reaches resolve through the V5 resolver seam (`Resolver.call/3` +
  `Resolver.terminate_child/2`).

  Returns only after the seam entry is GONE: the registry entry dies
  asynchronously with the child (Registry DOWN-cleanup), so a bare
  terminate would let a caller's immediate `alive?/1` see a stopping
  server as still up (PTY `terminate_until_gone` precedent).
  """
  @spec stop(handle()) :: :ok
  def stop(handle) do
    key = Server.resolver_key(handle)

    _ = Resolver.call(key, :graceful_stop, 30_000)
    _ = Resolver.terminate_child(key, EzagentDomainPython.Supervisor)
    await_unregistered(key, 50)

    :ok
  end

  # Bounded poll for the Registry's asynchronous DOWN-cleanup. 50 × 10 ms
  # is generous for a local ETS delete; on exhaustion we still report
  # `:ok` (the child IS terminated — only the entry lags).
  defp await_unregistered(_key, 0), do: :ok

  defp await_unregistered(key, attempts_left) do
    if Resolver.alive?(key) do
      Process.sleep(10)
      await_unregistered(key, attempts_left - 1)
    else
      :ok
    end
  end

  @doc """
  True iff a Server is registered and the process is alive. Pid-free —
  resolved through the V5 resolver seam's `Resolver.alive?/1`.
  """
  @spec alive?(handle()) :: boolean()
  def alive?(handle), do: Resolver.alive?(Server.resolver_key(handle))
end
