defmodule EzagentPluginNp.OrphanReaper do
  @moduledoc """
  Sibling of `EzagentPluginCc.OrphanReaper` for the np plugin's Python
  compute-server subprocesses.

  See `EzagentPluginCc.OrphanReaper` for the design rationale + the
  PTY-pid-files 2026-05-26 refactor that replaced `ps`-walking with
  per-deployment pid-file enumeration.

  ## Discovery

  The np Template (`Ezagent.PluginNp.Template.NpAgent`) spawns its
  Python subprocess via `Ezagent.Domain.Python` with the agent URI as
  `spec.handle`. `Ezagent.Domain.Python.Server` writes a pid file at
  spawn (and removes it at graceful shutdown) — the reaper enumerates
  the np subdirectory under this deployment's pid-file tree.

  ## Reaping rules

  Identical shape to the cc reaper:

    * `Ezagent.Domain.Python.alive?(agent_uri)` true → leave alone.
    * OS pid dead → remove stale pid file.
    * OS pid alive + start-time mismatch → remove stale file (PID
      recycle).
    * OS pid alive + start-time match → SIGTERM + remove file.
  """

  require Logger

  alias Ezagent.Domain.Python
  alias Ezagent.Runtime.PidFile

  @plugin "np"

  @doc """
  Walk this deployment's np pid files, identify orphans, SIGTERM each.

  Returns `{:ok, killed}` (count of OS processes signalled). The
  caller continues regardless.
  """
  @spec reap() :: {:ok, killed :: non_neg_integer()} | {:error, term()}
  def reap do
    entries = PidFile.enumerate(@plugin)
    {killed, stale} = Enum.reduce(entries, {0, 0}, &process_entry/2)

    cond do
      killed > 0 ->
        Logger.warning(
          "EzagentPluginNp.OrphanReaper: SIGTERM'd #{killed} orphan python " <>
            "subprocess(es) from a previous BEAM run (#{stale} stale " <>
            "pid-files cleaned up alongside)"
        )

      stale > 0 ->
        Logger.info(
          "EzagentPluginNp.OrphanReaper: no live orphans, cleaned #{stale} " <>
            "stale pid-file(s)"
        )

      true ->
        Logger.debug("EzagentPluginNp.OrphanReaper: no np pid-files to inspect")
    end

    {:ok, killed}
  end

  defp process_entry(
         %{agent_uri: %URI{} = uri, os_pid: pid, start_seconds: written_start, path: path},
         {killed, stale}
       ) do
    cond do
      Python.alive?(uri) ->
        # Defensive — see cc reaper.
        {killed, stale}

      true ->
        case PidFile.process_start_seconds(pid) do
          nil ->
            _ = File.rm(path)
            {killed, stale + 1}

          current_start when current_start != written_start ->
            Logger.info(
              "EzagentPluginNp.OrphanReaper: pid=#{pid} recycled " <>
                "(start_seconds=#{current_start} != written #{written_start}); " <>
                "removing stale pid-file without signalling"
            )

            _ = File.rm(path)
            {killed, stale + 1}

          _match ->
            case sigterm(pid, uri) do
              :ok ->
                _ = File.rm(path)
                {killed + 1, stale}

              {:error, _reason} ->
                {killed, stale}
            end
        end
    end
  end

  defp sigterm(pid, %URI{} = uri) do
    Logger.warning(
      "EzagentPluginNp.OrphanReaper: SIGTERM orphan python pid=#{pid} " <>
        "agent_uri=#{inspect(URI.to_string(uri))}"
    )

    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.warning(
          "EzagentPluginNp.OrphanReaper: kill -TERM pid=#{pid} failed " <>
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
