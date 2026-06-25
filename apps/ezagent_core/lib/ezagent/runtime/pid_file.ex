defmodule Ezagent.Runtime.PidFile do
  @moduledoc """
  PID-file lifecycle for plugin-spawned OS subprocesses (cc claude TUI,
  np Python compute server, future plugins). The orphan-reaper at boot
  reads these files instead of walking `ps` output.

  ## Why

  PR #385 (PTY-orphan-restart 2026-05-26) shipped orphan reapers that
  walked `ps -axEo pid,command`, parsed `EZAGENT_AGENT_URI` /
  `EZAGENT_DEPLOYMENT_ID` env vars from the joined argv line, and
  identified orphans by argv signature + URI shape. That works but
  has three sharp edges:

    1. `ps -axE` flag spelling differs across macOS / Linux; the
       reaper had to try multiple flag orders.
    2. Argv-signature matching is fragile against any future change
       to the cc/np spawn command line — `assemble_settings_mcp_args`
       in cc would have to never accidentally introduce the
       signature substring, asserted via a static test.
    3. Friendly-fire safety relied on a tag (`EZAGENT_DEPLOYMENT_ID`)
       in env; a co-tenant could in principle leak env from `ps -E`
       and forge it (not a real adversary worry on a single-user dev
       box, but it's another moving part).

  PID files eliminate all three: we discover candidates by reading
  files WE wrote — no ps scan, no argv parsing, no env-tag check.
  Per-deployment subdirectory structurally segregates parallel BEAMs,
  so a reaper can never see another deployment's pid file at all.

  ## Layout

      <profile_dir>/pty-pids/<sanitized_deployment_id>/<plugin>/<sanitized_uri>.pid

  - `profile_dir` = `Ezagent.Home.profile_dir/0` (`~/.ezagent/<profile>`)
  - `sanitized_deployment_id` = `Ezagent.DeploymentId.deployment_id/0`
    with `/` and `|` replaced by `_` (deployment_id is
    `<node>|<cwd>`; both can contain `/`).
  - `plugin` = caller-supplied subdir name, e.g. `"cc"` or `"np"`.
  - `sanitized_uri` = `URI.to_string(agent_uri)` with `://` and `/`
    replaced by `_`; e.g. `entity://team-alpha/agent/cc_demo` →
    `entity_team-alpha_agent_cc_demo`.

  ## File format

  Three lines:

      <os_pid>
      <process_start_epoch_seconds>
      <URI.to_string(key)>

  Line 3 (the full URI string) was added 2026-06-25 (sidecar erlexec
  runtime, SPEC §3.4) so that NON-`entity://` keys round-trip. The
  legacy filename reverse-parse (`agent_uri_from_filename/1`) only
  understands `entity://ws/agent/name`; a `system://feishu/ws` key
  cannot be recovered from the sanitised filename, so line 3 is its
  ONLY source. Legacy 2-line files (no line 3) still round-trip via
  the filename fallback for `entity://` URIs.

  The start time is used for PID-recycle protection: on reaper boot,
  we re-read the current start time of `os_pid` via `ps -o lstart=`;
  if it differs from what we wrote, the kernel has recycled the PID
  for an unrelated process — we just delete the stale file without
  signalling anything.

  ## Lifecycle

  - `write/3` — called by `Domain.Pty.Server` / `Domain.Python.Server`
    immediately after `:exec.run` returns `{:ok, _, os_pid}`. If the
    underlying file write fails, the spawn is allowed to proceed (the
    pid file is best-effort: a missing pid file just means the orphan
    won't be reaped on the next BEAM restart — same outcome as today
    for pre-fix orphans).
  - `remove/2` — called by the server's `terminate/2`. Idempotent —
    the file may not exist (writer error earlier, or already removed
    by a previous reap pass). Best-effort: failure is logged.
  - `enumerate/1` — called by plugin OrphanReaper modules. Returns
    `[{agent_uri, os_pid, start_seconds, file_path}]` for every pid
    file currently in this deployment's subdir of the given plugin
    name. Two distinct failure modes:
      * pid/start unparseable (`:bad_pid_file`) → deleted (garbage)
        and skipped.
      * pid/start OK but the URI cannot be resolved (no line 3 AND the
        filename is not an `entity://` shape — `:unrecoverable_uri`) →
        SKIPPED, NOT deleted (a missing-line-3 feishu file is a
        recoverable orphan, not garbage; blind-deleting it would
        silently drop a feishu orphan — SPEC §3.4 invariant).

  ## Test mode

  `Mix.env() == :test` overrides `Ezagent.Home.profile_dir/0` to a
  per-test tmpdir via the standard `EZAGENT_HOME` env var; tests that
  spawn pid files should set their own `EZAGENT_HOME` (the test
  helper in `ezagent_core/test/support/home_case.ex` already does
  this for the home-related test cases).
  """

  require Logger

  alias Ezagent.DeploymentId
  alias Ezagent.Home

  @doc """
  Absolute directory for this deployment's pid files under `plugin`.
  Creates the directory chain if missing (best-effort: a mkdir
  failure leaves the caller's spawn unaffected — the pid file just
  won't be persisted).
  """
  @spec dir(String.t()) :: Path.t()
  def dir(plugin) when is_binary(plugin) do
    d =
      Path.join([
        Home.profile_dir(),
        "pty-pids",
        sanitize_segment(DeploymentId.deployment_id()),
        plugin
      ])

    case File.mkdir_p(d) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PidFile.dir mkdir_p failed (#{inspect(reason)}): #{d}")
    end

    d
  end

  @doc """
  Write a pid file. Returns `:ok` on success, `{:error, reason}` on
  failure — but callers may treat both as no-ops (the file is
  best-effort).
  """
  @spec write(String.t(), URI.t(), pos_integer()) :: :ok | {:error, term()}
  def write(plugin, %URI{} = key, os_pid)
      when is_binary(plugin) and is_integer(os_pid) and os_pid > 0 do
    start = process_start_seconds(os_pid)
    body = "#{os_pid}\n#{start || 0}\n#{URI.to_string(key)}\n"
    path = file_path(plugin, key)

    case File.write(path, body) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning("PidFile.write failed for #{path}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Remove a pid file for `agent_uri` in `plugin`. Idempotent — missing
  file is `:ok`.
  """
  @spec remove(String.t(), URI.t()) :: :ok
  def remove(plugin, %URI{} = agent_uri) when is_binary(plugin) do
    path = file_path(plugin, agent_uri)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("PidFile.remove failed for #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Enumerate all pid files for this deployment + plugin. Each entry is
  a map with keys `:agent_uri`, `:os_pid`, `:start_seconds`, `:path`.

  Unparseable files are deleted on the spot (garbage) and omitted from
  the result.
  """
  @spec enumerate(String.t()) :: [
          %{
            agent_uri: URI.t(),
            os_pid: pos_integer(),
            start_seconds: non_neg_integer(),
            path: Path.t()
          }
        ]
  def enumerate(plugin) when is_binary(plugin) do
    d = dir(plugin)

    case File.ls(d) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".pid"))
        |> Enum.flat_map(fn name ->
          path = Path.join(d, name)

          case parse(path) do
            {:ok, entry} ->
              [entry]

            {:error, :bad_pid_file} ->
              # Truly unparseable (bad pid/start lines) — delete + skip.
              _ = File.rm(path)
              []

            {:error, :unrecoverable_uri} ->
              # pid/start parsed, but the URI can't be resolved (no
              # line 3 and not an entity:// filename). This is a
              # RECOVERABLE skip — NOT garbage. Blind-deleting would
              # silently drop a feishu orphan (SPEC §3.4 invariant).
              Logger.warning(
                "PidFile.enumerate: skipping #{path} — pid/start valid but URI " <>
                  "unrecoverable (missing line-3 body + non-entity filename); " <>
                  "leaving file in place"
              )

              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("PidFile.enumerate ls failed for #{d}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Read the OS process start time (epoch seconds) for `os_pid`. Returns
  `nil` if the process is dead or `ps` failed to resolve it. Used both
  by `write/3` (capture at spawn) and by reapers (re-check at boot, to
  detect PID recycling).
  """
  @spec process_start_seconds(pos_integer()) :: non_neg_integer() | nil
  def process_start_seconds(os_pid) when is_integer(os_pid) and os_pid > 0 do
    # macOS: `ps -p <pid> -o lstart=` prints the start time in
    # `Mon Day HH:MM:SS YYYY` form. We can't easily parse that; use
    # `-o etime=` (elapsed since start) and subtract from now.
    # Linux: same `-o etime=` works.
    case System.cmd("ps", ["-p", Integer.to_string(os_pid), "-o", "etime="],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        elapsed = parse_etime(String.trim(output))
        if is_integer(elapsed), do: System.os_time(:second) - elapsed, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @doc false
  @spec file_path(String.t(), URI.t()) :: Path.t()
  def file_path(plugin, %URI{} = agent_uri) do
    Path.join(dir(plugin), sanitize_segment(URI.to_string(agent_uri)) <> ".pid")
  end

  defp sanitize_segment(s) when is_binary(s) do
    s
    |> String.replace("://", "_")
    |> String.replace("/", "_")
    |> String.replace("|", "_")
  end

  defp parse(path) do
    with {:ok, body} <- File.read(path),
         [pid_str, start_str | rest] <- String.split(body, "\n", trim: true),
         {pid, ""} <- Integer.parse(pid_str),
         {start, ""} <- Integer.parse(start_str) do
      # pid/start are valid; resolving the URI is a SEPARATE failure
      # mode (recoverable skip, not garbage-delete) — see enumerate/1.
      case resolve_uri(rest, path) do
        {:ok, %URI{} = agent_uri} ->
          {:ok,
           %{
             agent_uri: agent_uri,
             os_pid: pid,
             start_seconds: start,
             path: path
           }}

        :error ->
          {:error, :unrecoverable_uri}
      end
    else
      _ -> {:error, :bad_pid_file}
    end
  end

  # Resolve the key URI. Prefer line 3 of the body (the only source for
  # non-`entity://` keys like `system://feishu/ws`); fall back to the
  # filename reverse-parse for legacy 2-line `entity://` files (and for
  # a line-3 that fails to parse — costs nothing, recovers an entity file).
  defp resolve_uri([uri_str | _], path) when is_binary(uri_str) do
    # Ezagent.URI.parse/1 (NOT stdlib URI.parse/1): gate-safe in product
    # lib/, returns {:ok, uri} | {:error, _}, and yields the canonical
    # `authority: nil` form so the round-trip is struct-equal to the key.
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _} -> agent_uri_from_filename(path) |> normalize_filename_result()
    end
  end

  defp resolve_uri([], path) do
    # Legacy 2-line file — no body URI. Filename fallback only works for
    # `entity://`; anything else is a recoverable skip (:error).
    agent_uri_from_filename(path) |> normalize_filename_result()
  end

  defp normalize_filename_result({:ok, %URI{} = uri}), do: {:ok, uri}
  defp normalize_filename_result({:error, _}), do: :error

  # The filename is the sanitized URI + ".pid". Reverse the sanitize:
  # `_` becomes `/` (best-effort — URIs we sanitized don't contain
  # other `_` in the structural positions, but `entity_name` segments
  # can. So we use a positional reconstruction:
  # `entity_<workspace>_agent_<entity_name>` →
  # `entity://<workspace>/agent/<entity_name>`.
  defp agent_uri_from_filename(path) do
    base = Path.basename(path, ".pid")

    case String.split(base, "_", parts: 4) do
      ["entity", workspace, "agent", entity_name] ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # for any URI string entering the system. Try/rescue keeps the
        # `{:ok, _} | {:error, _}` contract of this private helper.
        try do
          {:ok, Ezagent.URI.agent(workspace, entity_name)}
        rescue
          ArgumentError -> {:error, :bad_filename}
        end

      _ ->
        {:error, :bad_filename}
    end
  end

  # Parse the `ps -o etime=` output format.
  #
  # macOS / Linux both emit one of:
  #   `MM:SS`
  #   `HH:MM:SS`
  #   `D-HH:MM:SS`
  #
  # Returns the elapsed seconds as integer, or nil on parse failure.
  defp parse_etime(s) when is_binary(s) do
    {days, rest} =
      case String.split(s, "-", parts: 2) do
        [d, r] ->
          case Integer.parse(d) do
            {d_int, ""} -> {d_int, r}
            _ -> {0, s}
          end

        [r] ->
          {0, r}
      end

    parts =
      rest
      |> String.split(":")
      |> Enum.map(&Integer.parse/1)

    case parts do
      [{h, ""}, {m, ""}, {sec, ""}] ->
        days * 86_400 + h * 3600 + m * 60 + sec

      [{m, ""}, {sec, ""}] ->
        days * 86_400 + m * 60 + sec

      _ ->
        nil
    end
  end

  defp parse_etime(_), do: nil
end
