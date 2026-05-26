defmodule EzagentPluginCc.OrphanReaper do
  @moduledoc """
  Identifies and reaps stale `claude` TUI OS processes left behind by a
  previous BEAM instance, before the cc plugin's Workspace.Loader
  re-instantiates its Agent Kinds.

  ## Why this exists (PTY-orphan-restart 2026-05-26, Allen directive)

  cc agents have a two-layer process model:

    1. Agent Kind (Elixir GenServer) — OTP-supervised, recovers from
       snapshot.
    2. PtyServer + claude TUI subprocess — `:exec.run/2` (erlexec) port
       runs the OS-level `claude` process. erlexec normally reaps the
       child on BEAM exit (`SIGTERM` propagation), but a **brutal
       BEAM kill** (`SIGKILL`, panic, SEGV) skips the cleanup and the
       OS `claude` lives on as an orphan attached to the old PTY.

  Without reaping, the orphan reconnects to ESR via the cc bridge
  Channel as soon as the new BEAM is up — and demand-spawns the Agent
  Kind via the chat router. By the time `Workspace.Loader` later runs
  `cc.agent.instantiate/3`, the Agent Kind is already alive (codex
  round-8 returns immediately) and the NEW PtyServer is never started.
  Operators then see a "dead terminal" in the LV (no PtyServer to
  write to) while the orphan OS claude still chats over its old
  channel.

  ## Identification

  A cc-managed claude process carries a distinctive argv signature:

      <abs path>/claude --permission-mode bypassPermissions \\
        --dangerously-load-development-channels server:esr-bridge \\
        [--settings ...] --settings <plugin priv> --mcp-config <path> \\
        [--mcp-config ...]

  AND carries `EZAGENT_AGENT_URI=<uri>` in its env. The env tells us
  WHICH agent URI the orphan belongs to — we don't blindly kill every
  `claude` on the box, only ones whose URI is OURS.

  We compare each candidate's URI against the live PtyServer registry
  (`Ezagent.Domain.Pty.alive?/1`). Any orphan with NO matching alive
  PtyServer gets `SIGTERM` (graceful — claude has a few seconds to
  cleanup its own per-instance `.mcp.json` files; if the next
  Workspace.Loader pass re-spawns the agent, it overwrites them).

  ## When this runs

  Plugin Application's `after_boot/0` calls `reap/0` BEFORE
  `Ezagent.Workspace.Loader.load_all/0`. Sequencing matters:

    1. Reap orphans → no leftover OS claudes own a bridge channel.
    2. `load_all/0` → cc.agent.instantiate/3 spawns Agent Kinds AND
       fresh PtyServers. No race against an orphan claude reconnecting.

  ## Why a function, not a GenServer

  Reaping is a one-shot at boot. A GenServer would add lifecycle surface
  (supervised child, restart strategy) for no benefit. The function is
  called from `after_boot/0`, lives 1-2 seconds, exits. If reap itself
  fails (`ps` not on PATH, permission denied), we log + continue — the
  reaper is best-effort defense, not a correctness gate (an orphan that
  survives reaping would just produce the same "operator clicks
  Restart in LV" flow operators already use today).

  ## Safety bound

  We NEVER `pkill -9` broadly. Each candidate must:

    1. Have the FULL cc-specific argv signature (claude binary +
       `--dangerously-load-development-channels server:esr-bridge`).
    2. Carry `EZAGENT_AGENT_URI` in its env (PtyServer always sets this
       — `Ezagent.Domain.Pty.Server.build_env/1`).
    3. Have a URI that LOOKS LIKE a cc agent (`entity://agent/.../cc_*`).
    4. NOT have a corresponding live PtyServer in the registry.

  Misses are far safer than false positives — a missed orphan
  re-surfaces on next phx restart; a wrong kill takes down an
  operator's other claude session.

  Memory `feedback_no_pkill_tmux_default_socket`: same principle —
  targeted kills only, never broad `pkill`.
  """

  require Logger

  alias Ezagent.Domain.Pty

  # Distinctive substring guaranteed in the cc-managed claude argv.
  # Built by `Ezagent.PluginCc.Template.CcAgent.build_claude_cmd/3`.
  @argv_signature "--dangerously-load-development-channels server:esr-bridge"

  # Env var the cc PtyServer ALWAYS sets to the agent's URI string.
  # `Ezagent.Domain.Pty.Server.build_env/1`.
  @agent_uri_env_key "EZAGENT_AGENT_URI"

  # cc agent URI scheme + prefix gate. Per SPEC v2 §5.14 every cc agent
  # is `entity://agent/<workspace>/cc_<name>`. A URI not matching this
  # shape is rejected (don't accidentally kill another plugin's agent
  # if env reuse ever happens).
  @cc_uri_scheme "entity://agent/"

  @doc """
  Walk the OS process list, identify cc-orphans, and SIGTERM each.

  Best-effort: returns the count of orphans terminated (for log /
  test introspection). Errors during `ps` execution are logged and
  the function returns `{:error, reason}` — the caller continues.
  """
  @spec reap() :: {:ok, killed :: non_neg_integer()} | {:error, term()}
  def reap do
    case enumerate_candidates() do
      {:ok, []} ->
        Logger.debug("EzagentPluginCc.OrphanReaper: no cc-claude candidates found")
        {:ok, 0}

      {:ok, candidates} ->
        killed =
          candidates
          |> Enum.filter(&orphan?/1)
          |> Enum.map(&kill_orphan/1)
          |> Enum.count(&(&1 == :ok))

        if killed > 0 do
          Logger.warning(
            "EzagentPluginCc.OrphanReaper: reaped #{killed} orphan claude " <>
              "process(es) from a previous BEAM run"
          )
        end

        {:ok, killed}

      {:error, reason} = err ->
        Logger.warning(
          "EzagentPluginCc.OrphanReaper: enumerate failed (#{inspect(reason)}); " <>
            "continuing without reaping"
        )

        err
    end
  end

  @typedoc """
  A candidate identified by enumerate_candidates/0:
    * `:pid` — OS pid (integer)
    * `:cmd` — argv joined as string
    * `:agent_uri` — value of EZAGENT_AGENT_URI env var, or nil if absent
  """
  @type candidate :: %{pid: pos_integer(), cmd: String.t(), agent_uri: String.t() | nil}

  # ---------------------------------------------------------------------------
  # Enumeration via `ps`
  # ---------------------------------------------------------------------------

  # We use `ps -axo pid,command -E` on macOS to include env vars in the
  # command output. Linux: `ps -axEo pid,command` (capital E flag). The
  # function tries both flag orders so this works on Darwin + Linux.
  defp enumerate_candidates do
    case run_ps() do
      {:ok, output} ->
        candidates =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_ps_line/1)
          |> Enum.filter(&cc_candidate?/1)

        {:ok, candidates}

      err ->
        err
    end
  end

  # macOS: `ps -E` includes env after the argv. Linux ps doesn't accept
  # `-E` the same way; we use `ps -axe -o pid,command` which on Linux
  # has slightly different semantics but still includes the env. We
  # only need to read EZAGENT_AGENT_URI from the resulting line, so
  # the exact format doesn't matter — `parse_env_var/2` does the
  # parsing.
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

  # `ps -axo pid,command` output format:
  #   <pid>  <command>
  # We split on the first run of spaces (pid is leading) and keep the
  # whole rest as the cmd line.
  defp parse_ps_line(line) do
    case String.split(String.trim_leading(line), " ", parts: 2) do
      [pid_str, cmd] ->
        case Integer.parse(pid_str) do
          {pid, ""} when pid > 0 ->
            [
              %{
                pid: pid,
                cmd: cmd,
                agent_uri: parse_env_var(cmd, @agent_uri_env_key)
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Hunts for `EZAGENT_AGENT_URI=<value>` in the cmd string (macos
  # `ps -E` interleaves env vars with argv). Returns the value or nil.
  defp parse_env_var(cmd, key) do
    pattern = key <> "="

    case String.split(cmd, pattern, parts: 2) do
      [_, after_eq] ->
        # Env value runs until the next space (argv elements are
        # space-separated). Conservative: env values in cc never
        # contain spaces (the URI is a single token).
        case String.split(after_eq, " ", parts: 2) do
          [value | _] -> value
          [] -> nil
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Filtering
  # ---------------------------------------------------------------------------

  # The argv signature MUST be present (gates "is this a cc-managed
  # claude" vs operator's own ad-hoc `claude` invocations).
  defp cc_candidate?(%{cmd: cmd}) when is_binary(cmd) do
    String.contains?(cmd, @argv_signature)
  end

  defp cc_candidate?(_), do: false

  # Orphan = cc-candidate WITH a valid cc-shaped URI WITH no live
  # PtyServer in the registry. Any failure in URI parsing / Registry
  # lookup means "don't kill" (fail closed).
  defp orphan?(%{agent_uri: uri_str}) when is_binary(uri_str) do
    cond do
      not String.starts_with?(uri_str, @cc_uri_scheme) ->
        false

      not cc_flavor_uri?(uri_str) ->
        false

      true ->
        case URI.new(uri_str) do
          {:ok, %URI{} = uri} -> not Pty.alive?(uri)
          _ -> false
        end
    end
  end

  defp orphan?(_), do: false

  # URI must have `cc_` prefix on the entity name segment.
  defp cc_flavor_uri?(uri_str) do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} ->
        case String.split(rest, "/", parts: 2) do
          [_workspace, entity_name] when is_binary(entity_name) ->
            String.starts_with?(entity_name, "cc_")

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Killing
  # ---------------------------------------------------------------------------

  # SIGTERM (15) — graceful. claude has a chance to flush its own
  # `.credentials.json` / `.mcp.json` state. If the orphan ignores it
  # (claude is a Node.js process; should respect SIGTERM normally),
  # next phx restart's reaper sees it again — bounded retry without
  # the operator noticing.
  defp kill_orphan(%{pid: pid, agent_uri: uri_str}) do
    Logger.warning(
      "EzagentPluginCc.OrphanReaper: sending SIGTERM to orphan claude " <>
        "pid=#{pid} agent_uri=#{inspect(uri_str)}"
    )

    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.warning(
          "EzagentPluginCc.OrphanReaper: kill -TERM #{pid} failed " <>
            "(exit=#{exit_code}, output=#{String.trim(output)})"
        )

        {:error, {:kill_failed, exit_code}}
    end
  rescue
    e ->
      Logger.warning(
        "EzagentPluginCc.OrphanReaper: kill raised for pid=#{pid}: #{Exception.message(e)}"
      )

      {:error, {:kill_raised, Exception.message(e)}}
  end
end
