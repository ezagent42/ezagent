defmodule Ezagent.Runtime.OsProcess do
  @moduledoc """
  The ONLY sanctioned way for non-PTY/non-Python-lib code to spawn an OS
  subprocess in ezagent.

  Bakes in the `{:group, 0}` + `:kill_group` pairing (SPEC §2 safety
  invariant) and uses `:exec.run_link` for peer-lifetime reaping.

  ## Safety invariant

  `{:group, 0}` and `:kill_group` MUST be paired (they always are here).
  Without `{:group, 0}` the child inherits exec-port's process group, so
  `:kill_group` would `kill(-exec_port_group)` — killing exec-port itself
  and every sibling erlexec child. This module is the single pairing point;
  no sidecar can set one without the other.

  ## Caller contract

  Every sidecar using `OsProcess.spawn/2` MUST:

  1. Call `Process.flag(:trap_exit, true)` in `init/1` UNCONDITIONALLY
     (even in test_mode where no child spawns) BEFORE calling `spawn/2`,
     else supervisor `:shutdown` skips `terminate/2` and orphans the child.

  2. Handle `{:EXIT, exec_pid, reason}` for ALL reasons:
     - `:normal` — child exited with status 0 (`:monitor` is dropped, so the
       numeric status collapses to `:normal` via the run_link BEAM link)
     - `{:exit_status, n}` — child exited with non-zero status
     - `:port_closed` — the exec-port closed the connection

  3. Handle `{:stdout, os_pid, bytes}` (and `{:stderr, os_pid, bytes}` when
     `stderr: :separate`).

  4. Call `OsProcess.stop(exec_pid)` + `OsProcess.cleanup_pid_file/2` in
     `terminate/2` (belt-and-suspenders; the run_link already handles most
     paths; `:exec.stop` on an already-dead pid is a no-op via try/catch).

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §3.1.
  """

  require Logger

  alias Ezagent.Runtime.PidFile

  @type spawn_opts :: [
          cd: String.t(),
          env: [{String.t(), String.t()}] | %{String.t() => String.t()},
          clear_env: boolean(),
          stderr: :merge | :separate,
          pid_file: nil | {plugin :: String.t(), key :: URI.t()}
        ]

  @doc """
  Spawn an OS process and return `{:ok, %{exec_pid: pid, os_pid: integer}}`.

  `cmd` as a **list** runs via `execve` (argv-safe, no shell interpretation —
  each element is one `argv[]` entry). A string runs via `$SHELL -c` (legacy;
  trusted callers only). Use the list form for all new callers.

  Options:
  - `cd:` — working directory (required for most callers)
  - `env:` — additional environment variables (map or `[{k, v}]` string pairs)
  - `clear_env:` — clear the inherited environment before applying `env:`
  - `stderr:` — `:merge` → stderr merged into stdout; `:separate` → own
    `{:stderr, os_pid, bytes}` messages (default: `:separate`)
  - `pid_file:` — `{plugin, uri}` writes a pid file on success; `nil` skips

  The caller (owner) is linked to `exec_pid` via `run_link`. Child exit arrives
  as `{:EXIT, exec_pid, reason}` — owner MUST trap exits.
  """
  @spec spawn(cmd :: [String.t()] | String.t(), spawn_opts()) ::
          {:ok, %{exec_pid: pid(), os_pid: pos_integer()}} | {:error, term()}
  def spawn(cmd, opts \\ []) do
    :ok = ensure_started()

    cd = Keyword.get(opts, :cd, System.tmp_dir!())
    env_raw = Keyword.get(opts, :env, [])
    clear_env? = Keyword.get(opts, :clear_env, false)
    stderr_opt = Keyword.get(opts, :stderr, :separate)
    pid_file = Keyword.get(opts, :pid_file, nil)

    exec_opts = build_exec_opts(cd, env_raw, stderr_opt, clear_env?)
    exec_cmd = build_cmd(cmd)

    case :exec.run_link(exec_cmd, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        maybe_write_pid_file(pid_file, os_pid)
        {:ok, %{exec_pid: exec_pid, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send `iodata` to the process's stdin.

  Requires that the process was spawned (`:stdin` is always included in opts).
  """
  @spec send(exec_pid :: pid(), iodata()) :: :ok | {:error, term()}
  def send(exec_pid, data) when is_pid(exec_pid) do
    :exec.send(exec_pid, data)
  end

  @doc """
  Stop the OS process (SIGTERM → kill_timeout → SIGKILL the whole process group).

  Takes the **Erlang exec_pid** (the `pid()` from `spawn/2`, NOT the os_pid).
  This is the documented exception to the skill's "always os_pid" rule — matches
  the working `Domain.Pty.Server` and `Domain.Python.Server` pattern.

  `stop(nil)` is a no-op (caller can store `nil` before spawn completes).
  """
  @spec stop(exec_pid :: pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(exec_pid) when is_pid(exec_pid) do
    try do
      :exec.stop(exec_pid)
    catch
      _, _ -> :ok
    end

    :ok
  end

  @doc """
  Remove the pid file written by `spawn/2` for `{plugin, key}`.

  Idempotent — safe to call even if the file was never written or already removed.
  """
  @spec cleanup_pid_file(plugin :: String.t(), key :: URI.t()) :: :ok
  def cleanup_pid_file(plugin, %URI{} = key) when is_binary(plugin) do
    PidFile.remove(plugin, key)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec ensure_started() :: :ok
  defp ensure_started do
    case :exec.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp build_exec_opts(cd, env_raw, stderr_opt, clear_env?) do
    stderr_exec_opt =
      case stderr_opt do
        :merge -> {:stderr, :stdout}
        :separate -> :stderr
      end

    env = build_env_charlists(env_raw)
    env = if clear_env?, do: [:clear | env], else: env

    [
      :stdin,
      :stdout,
      stderr_exec_opt,
      {:group, 0},
      :kill_group,
      {:cd, String.to_charlist(cd)},
      {:env, env}
    ]
  end

  # Build exec command — list stays as list (execve, argv-safe); string uses $SHELL -c
  defp build_cmd(cmd) when is_list(cmd), do: cmd
  defp build_cmd(cmd) when is_binary(cmd), do: cmd

  # Convert env to charlist pairs as required by erlexec
  defp build_env_charlists(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp build_env_charlists(env) when is_list(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp maybe_write_pid_file(nil, _os_pid), do: :ok

  defp maybe_write_pid_file({plugin, %URI{} = key}, os_pid)
       when is_binary(plugin) and is_integer(os_pid) do
    _ = PidFile.write(plugin, key, os_pid)
    :ok
  end
end
