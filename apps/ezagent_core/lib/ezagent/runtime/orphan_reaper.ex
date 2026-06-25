defmodule Ezagent.Runtime.OrphanReaper do
  @moduledoc """
  Shared boot reaper for the erlexec sidecar plugins (cc-sdk,
  codex-appserver, codex-bridge, feishu-ws). Generalises the
  `reap()`-shape of `EzagentPluginCc.OrphanReaper` (PTY) / np
  `OrphanReaper` into ONE reusable module (sidecar erlexec runtime,
  SPEC `2026-06-25-sidecar-erlexec-runtime.md` §3.4).

  ## What it does

  Each new sidecar plugin calls `reap/1` as an imperative sweep in its
  `Application.after_boot/0` — `Ezagent.Runtime.OrphanReaper.reap("feishu-ws")`
  — exactly like the existing cc/np reapers run. It is deliberately NOT
  a supervision-tree child_spec: a one-shot GenServer would leave an
  underspecified lifecycle + boot-ordering questions against the
  sidecar-spawning Kinds. `after_boot/0` runs before
  `Ezagent.Workspace.Loader.load_all/0` — the established
  reap-before-load ordering.

  One sweep of `PidFile.enumerate(plugin)`; per entry, recheck
  `PidFile.process_start_seconds/1` against the stored start (PID-recycle
  guard):

    * dead OS pid (`nil`) → `PidFile.remove` only, NO signal.
    * start mismatch (PID recycled for an unrelated process) →
      `PidFile.remove` only, NO signal.
    * start match → the OS process IS our prior-incarnation orphan:
      SIGTERM it (`kill -TERM <pid>` — a TARGETED signal to a pid we
      own via a pid file we wrote, NEVER a broad `pkill`; memory
      `feedback_no_pkill_tmux_default_socket`), then `PidFile.remove`.

  ## Coverage (honest)

  With `run_link` (`Ezagent.Runtime.OsProcess`, §3.1) owner-death is
  already reaped synchronously, and exec-port reaps every child on a
  brutal BEAM SIGKILL. This boot reaper is belt-and-suspenders for the
  residual "exec-port itself died / machine crash / leaked pid file"
  case. Kept per lead decision for defence-in-depth.

  ## Relationship to the existing reapers

  Coexists with — does NOT replace — `EzagentPluginCc.OrphanReaper`
  (PTY, subdir `"cc"`) and np `OrphanReaper` (subdir `"np"`). Each
  reaper targets its own pid-file subdir; there is no cross-contamination
  (per-deployment + per-plugin subdir isolation in `PidFile.dir/1`).
  Unlike the cc/np reapers there is no `Pty.alive?`/`Python.alive?`
  liveness branch — this generic reaper has no domain to consult.
  """

  require Logger

  alias Ezagent.Runtime.PidFile

  @doc """
  Sweep this deployment's `plugin` pid files and reap orphans from a
  previous BEAM incarnation. Always returns `:ok` (best-effort — the
  caller's boot continues regardless).
  """
  @spec reap(plugin :: String.t()) :: :ok
  def reap(plugin) when is_binary(plugin) do
    entries = PidFile.enumerate(plugin)
    {killed, stale} = Enum.reduce(entries, {0, 0}, &process_entry(&1, &2, plugin))

    cond do
      killed > 0 ->
        Logger.warning(
          "Ezagent.Runtime.OrphanReaper(#{plugin}): SIGTERM'd #{killed} orphan " <>
            "sidecar process(es) from a previous BEAM run (#{stale} stale " <>
            "pid-file(s) cleaned up alongside)"
        )

      stale > 0 ->
        Logger.info(
          "Ezagent.Runtime.OrphanReaper(#{plugin}): no live orphans, cleaned " <>
            "#{stale} stale pid-file(s)"
        )

      true ->
        Logger.debug("Ezagent.Runtime.OrphanReaper(#{plugin}): no pid-files to inspect")
    end

    :ok
  end

  defp process_entry(
         %{agent_uri: %URI{} = uri, os_pid: pid, start_seconds: written_start},
         {killed, stale},
         plugin
       ) do
    case PidFile.process_start_seconds(pid) do
      nil ->
        # OS process dead — remove the stale file, no signal.
        _ = PidFile.remove(plugin, uri)
        {killed, stale + 1}

      current_start when current_start != written_start ->
        # PID recycled by the OS for an unrelated process — remove our
        # file, do NOT signal the (unrelated) live process.
        Logger.info(
          "Ezagent.Runtime.OrphanReaper(#{plugin}): pid=#{pid} recycled " <>
            "(start_seconds=#{current_start} != written #{written_start}); " <>
            "removing stale pid-file without signalling"
        )

        _ = PidFile.remove(plugin, uri)
        {killed, stale + 1}

      _match ->
        # The OS process IS our prior-incarnation orphan.
        case sigterm(pid, uri, plugin) do
          :ok ->
            _ = PidFile.remove(plugin, uri)
            {killed + 1, stale}

          {:error, _reason} ->
            # Leave the pid file in place — next boot will retry.
            {killed, stale}
        end
    end
  end

  defp sigterm(pid, %URI{} = uri, plugin) do
    Logger.warning(
      "Ezagent.Runtime.OrphanReaper(#{plugin}): SIGTERM orphan pid=#{pid} " <>
        "key=#{inspect(URI.to_string(uri))}"
    )

    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.warning(
          "Ezagent.Runtime.OrphanReaper(#{plugin}): kill -TERM pid=#{pid} failed " <>
            "(exit=#{exit_code}, out=#{inspect(output)})"
        )

        {:error, {:kill_exit, exit_code}}
    end
  rescue
    e -> {:error, {:kill_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
