defmodule EzagentPluginNp.OrphanReaper do
  @moduledoc """
  Identifies and reaps stale `uv run --script .../np_compute_server.py`
  OS processes left behind by a previous BEAM instance.

  Sibling of `EzagentPluginCc.OrphanReaper`; same architectural
  rationale (a brutal-killed BEAM may leave the OS-level Python
  subprocess running) and same safety bound (targeted kills only,
  identified by argv signature + `EZAGENT_AGENT_URI` env var + check
  against the live `Ezagent.Domain.Python` Registry).

  See `EzagentPluginCc.OrphanReaper` moduledoc for the boot-ordering
  rationale.

  ## Identification

  An np-managed Python subprocess carries the argv signature

      <abs path>/uv run --script .../np_compute_server.py

  AND has `EZAGENT_AGENT_URI=<uri>` in its env (set by the np Template
  Class via `Ezagent.Domain.Python.Spec.env`).

  ## Safety

  We never kill a `uv run` process whose env doesn't include OUR
  identifying env var. Other `uv run` invocations on the box (operator
  dev work, other python scripts) are invisible to this reaper.
  """

  require Logger

  alias Ezagent.Domain.Python

  # Script path under the np plugin's priv dir — the LAST argv segment
  # uniquely identifies "this is an np-agent subprocess" (operator's
  # ad-hoc `uv run` invocations won't end in this path).
  @script_basename "np_compute_server.py"

  # Same env-var convention as cc.
  @agent_uri_env_key "EZAGENT_AGENT_URI"

  # Same multi-BEAM safety convention as cc — see
  # `EzagentPluginCc.OrphanReaper` for the rationale (codex round-2
  # finding #2). The np Template Class now also tags Python
  # subprocesses via Domain.Python.Spec `env`.
  @deployment_id_env_key "EZAGENT_DEPLOYMENT_ID"

  # np agent URI shape gate — SPEC v2 §5.14 `entity://agent/<ws>/np_<name>`.
  @np_uri_scheme "entity://agent/"

  @doc """
  Walk the OS process list, identify np-orphans, and SIGTERM each.

  Returns `{:ok, killed}` or `{:error, reason}` per the cc-reaper
  convention.
  """
  @spec reap() :: {:ok, killed :: non_neg_integer()} | {:error, term()}
  def reap do
    case enumerate_candidates() do
      {:ok, []} ->
        Logger.debug("EzagentPluginNp.OrphanReaper: no np Python candidates found")
        {:ok, 0}

      {:ok, candidates} ->
        killed =
          candidates
          |> Enum.filter(&orphan?/1)
          |> Enum.map(&kill_orphan/1)
          |> Enum.count(&(&1 == :ok))

        if killed > 0 do
          Logger.warning(
            "EzagentPluginNp.OrphanReaper: reaped #{killed} orphan Python " <>
              "subprocess(es) from a previous BEAM run"
          )
        end

        {:ok, killed}

      {:error, reason} = err ->
        Logger.warning(
          "EzagentPluginNp.OrphanReaper: enumerate failed (#{inspect(reason)}); " <>
            "continuing without reaping"
        )

        err
    end
  end

  @type candidate :: %{
          pid: pos_integer(),
          cmd: String.t(),
          agent_uri: String.t() | nil,
          deployment_id: String.t() | nil
        }

  defp enumerate_candidates do
    case run_ps() do
      {:ok, output} ->
        candidates =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_ps_line/1)
          |> Enum.filter(&np_candidate?/1)

        {:ok, candidates}

      err ->
        err
    end
  end

  defp run_ps do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> ["ps", "-axww", "-Eo", "pid,command"]
        {:unix, _other} -> ["ps", "-axwwe", "-o", "pid,command"]
        _ -> ["ps", "-axww", "-o", "pid,command"]
      end

    try do
      {output, exit_code} = System.cmd(hd(cmd), tl(cmd), stderr_to_stdout: true)

      if exit_code == 0 do
        {:ok, output}
      else
        {:error, {:ps_exit, exit_code, output}}
      end
    rescue
      e -> {:error, {:ps_raised, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp parse_ps_line(line) do
    case String.split(String.trim_leading(line), " ", parts: 2) do
      [pid_str, cmd] ->
        case Integer.parse(pid_str) do
          {pid, ""} when pid > 0 ->
            [
              %{
                pid: pid,
                cmd: cmd,
                agent_uri: parse_env_var(cmd, @agent_uri_env_key),
                deployment_id: parse_env_var(cmd, @deployment_id_env_key)
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp parse_env_var(cmd, key) do
    pattern = key <> "="

    case String.split(cmd, pattern, parts: 2) do
      [_, after_eq] ->
        case String.split(after_eq, " ", parts: 2) do
          [value | _] -> value
          [] -> nil
        end

      _ ->
        nil
    end
  end

  # Argv must end in (or contain) `np_compute_server.py`. We use
  # `contains?` rather than `ends_with?` because the env-var prefix
  # on macOS may push the argv into the middle of the cmd string.
  defp np_candidate?(%{cmd: cmd}) when is_binary(cmd) do
    String.contains?(cmd, @script_basename)
  end

  defp np_candidate?(_), do: false

  defp orphan?(%{agent_uri: uri_str, deployment_id: dep_id}) when is_binary(uri_str) do
    our_id = Ezagent.DeploymentId.deployment_id()

    cond do
      # Codex round-2 finding #2 — same gating as cc reaper.
      not is_binary(dep_id) or dep_id == "" -> false
      dep_id != our_id -> false
      not String.starts_with?(uri_str, @np_uri_scheme) -> false
      not np_flavor_uri?(uri_str) -> false
      true ->
        case URI.new(uri_str) do
          {:ok, %URI{} = uri} -> not Python.alive?(uri)
          _ -> false
        end
    end
  end

  defp orphan?(_), do: false

  defp np_flavor_uri?(uri_str) do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} ->
        case String.split(rest, "/", parts: 2) do
          [_workspace, entity_name] when is_binary(entity_name) ->
            String.starts_with?(entity_name, "np_")

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp kill_orphan(%{pid: pid, agent_uri: uri_str}) do
    Logger.warning(
      "EzagentPluginNp.OrphanReaper: sending SIGTERM to orphan np Python " <>
        "pid=#{pid} agent_uri=#{inspect(uri_str)}"
    )

    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.warning(
          "EzagentPluginNp.OrphanReaper: kill -TERM #{pid} failed " <>
            "(exit=#{exit_code}, output=#{String.trim(output)})"
        )

        {:error, {:kill_failed, exit_code}}
    end
  rescue
    e ->
      Logger.warning(
        "EzagentPluginNp.OrphanReaper: kill raised for pid=#{pid}: #{Exception.message(e)}"
      )

      {:error, {:kill_raised, Exception.message(e)}}
  end
end
