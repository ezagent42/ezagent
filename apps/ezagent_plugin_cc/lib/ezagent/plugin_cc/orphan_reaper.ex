defmodule EzagentPluginCc.OrphanReaper do
  @moduledoc """
  Identifies and reaps stale `claude` TUI OS processes left behind by a
  previous BEAM instance, before the cc plugin's Workspace.Loader
  re-instantiates its Agent Kinds.

  ## Why this exists (PTY-orphan-restart 2026-05-26, Allen directive)

  cc agents have a two-layer process model:

    1. Agent Kind (Elixir GenServer) — OTP-supervised, recovers from
       snapshot.
    2. PtyServer + claude TUI subprocess — `:exec.run/2` (erlexec)
       port runs the OS-level `claude` process. erlexec normally reaps
       the child on BEAM exit (`SIGTERM` propagation), but a brutal
       BEAM kill (`SIGKILL`, panic, SEGV) skips that cleanup and the
       OS `claude` lives on as an orphan attached to the old PTY.

  Without reaping, the orphan reconnects to Ezagent via the cc bridge
  Channel as soon as the new BEAM is up — and demand-spawns the Agent
  Kind via the chat router. By the time `Workspace.Loader` later runs
  `cc.agent.instantiate/3`, the Agent Kind is already alive (codex
  round-8 returns immediately) and the NEW PtyServer is never started.

  ## Discovery: pid files, NOT `ps`

  PTY-pid-files 2026-05-26 follow-up (a) replaced the original
  `ps -axEo pid,command` scan with explicit pid files that
  `Ezagent.Domain.Pty.Server` writes at spawn and removes at graceful
  shutdown. The reaper now enumerates
  `Ezagent.Runtime.PidFile.enumerate("cc")` — files we wrote ourselves
  — and checks each os_pid for liveness + start-time match (PID-recycle
  protection).

  This eliminates three sharp edges of the v1 reaper:

    1. macOS / Linux `ps -E` flag differences.
    2. Argv-signature fragility (every cc Template change had to
       preserve the signature substring).
    3. Cross-BEAM friendly-fire safety via env-tag comparison.

  Per-deployment subdirectory in `PidFile.dir/1` (keyed off
  `Ezagent.DeploymentId.deployment_id/0`) structurally segregates
  parallel BEAMs: one deployment cannot see another's pid files at
  all, so friendly-fire is impossible by construction.

  ## Reaping rules

  For each pid-file entry `%{agent_uri, os_pid, start_seconds, path}`:

    * If `Ezagent.Domain.Pty.alive?(agent_uri)` returns true — the
      current PtyServer wrote this file as part of normal operation;
      leave it alone. (This case shouldn't happen during `after_boot/0`
      since Workspace.Loader hasn't run yet, but the check is cheap
      defense.)
    * Else read the current start-time of `os_pid` via
      `PidFile.process_start_seconds/1`.
        - `nil` (process dead): just `File.rm/1` the stale pid file.
        - Mismatch with `start_seconds`: PID has been recycled for an
          unrelated process — `File.rm/1` and skip kill.
        - Match: the OS process is our prior-incarnation orphan —
          `kill -TERM <pid>` + `File.rm/1`.

  Memory `feedback_no_pkill_tmux_default_socket`: same principle — we
  send TARGETED signals to specific PIDs we own (via pid files we
  wrote), never broad `pkill`.

  ## When this runs

  Plugin Application's `after_boot/0` calls `reap/0` BEFORE
  `Ezagent.Workspace.Loader.load_all/0`. Sequencing matters:

    1. Reap orphans → no leftover OS claudes own a bridge channel.
    2. `load_all/0` → cc.agent.instantiate/3 spawns Agent Kinds AND
       fresh PtyServers. No race against an orphan claude reconnecting.
  """

  require Logger

  alias Ezagent.Domain.Pty
  alias Ezagent.Runtime.PidFile

  @plugin "cc"

  @doc """
  Walk this deployment's cc pid files, identify orphans, SIGTERM each.

  Best-effort: returns the count of orphans terminated. Errors during
  enumeration are logged and the function returns `{:error, reason}`;
  the caller continues.
  """
  @spec reap() :: {:ok, killed :: non_neg_integer()} | {:error, term()}
  def reap do
    entries = PidFile.enumerate(@plugin)
    {killed, stale} = Enum.reduce(entries, {0, 0}, &process_entry/2)

    cond do
      killed > 0 ->
        Logger.warning(
          "EzagentPluginCc.OrphanReaper: SIGTERM'd #{killed} orphan claude " <>
            "process(es) from a previous BEAM run (#{stale} stale pid-files " <>
            "cleaned up alongside)"
        )

      stale > 0 ->
        Logger.info(
          "EzagentPluginCc.OrphanReaper: no live orphans, cleaned #{stale} " <>
            "stale pid-file(s)"
        )

      true ->
        Logger.debug("EzagentPluginCc.OrphanReaper: no cc pid-files to inspect")
    end

    {:ok, killed}
  end

  defp process_entry(
         %{agent_uri: %URI{} = uri, os_pid: pid, start_seconds: written_start, path: path},
         {killed, stale}
       ) do
    cond do
      Pty.alive?(uri) ->
        # A current PtyServer claims this URI — leave the file alone.
        # This branch is defensive; in `after_boot/0` before
        # Workspace.Loader, no PtyServers should be alive yet.
        {killed, stale}

      true ->
        case PidFile.process_start_seconds(pid) do
          nil ->
            # OS process dead — just remove the stale file.
            _ = File.rm(path)
            {killed, stale + 1}

          current_start when current_start != written_start ->
            # PID recycled by the OS for an unrelated process.
            # Remove our file, do NOT kill.
            Logger.info(
              "EzagentPluginCc.OrphanReaper: pid=#{pid} recycled " <>
                "(start_seconds=#{current_start} != written #{written_start}); " <>
                "removing stale pid-file without signalling"
            )

            _ = File.rm(path)
            {killed, stale + 1}

          _match ->
            # The OS process IS our prior-incarnation orphan.
            case sigterm(pid, uri) do
              :ok ->
                _ = File.rm(path)
                {killed + 1, stale}

              {:error, _reason} ->
                # Leave the pid file in place — next boot will retry.
                {killed, stale}
            end
        end
    end
  end

  defp sigterm(pid, %URI{} = uri) do
    Logger.warning(
      "EzagentPluginCc.OrphanReaper: SIGTERM orphan claude pid=#{pid} " <>
        "agent_uri=#{inspect(URI.to_string(uri))}"
    )

    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.warning(
          "EzagentPluginCc.OrphanReaper: kill -TERM pid=#{pid} failed " <>
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
