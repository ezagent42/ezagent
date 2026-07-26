defmodule Ezagent.Domain.Pty do
  @moduledoc """
  Domain.Pty facade — start, stop, status, alive? for an agent's PTY
  sidecar process. Per SPEC v1 (2026-05-21).

  This is the ONLY API other code (plugins, LV, lifecycle status
  helpers) should use to reach a `Ezagent.Domain.Pty.Server`. Direct
  references to `Server` or `EzagentDomainPty.Supervisor` are an
  internal concern of the Domain.Pty app.

  V5 pid-closure A1b: the sidecar self-registers under
  `{agent_uri, :ezagent_domain_pty, :pty}` in the unified
  `Ezagent.Runtime.SidecarRegistry` and all lookups converge on
  `Ezagent.Runtime.Resolver` — the private `EzagentDomainPty.Registry`
  is retired.

  Per `feedback_let_it_crash_no_workarounds`: no back-compat aliases to
  `Ezagent.PluginCc.PtyServer` — callers update to this facade.
  """

  alias Ezagent.Domain.Pty.Server
  alias Ezagent.Runtime.Resolver

  @doc """
  Start a `Ezagent.Domain.Pty.Server` for the given `agent_uri` under
  `EzagentDomainPty.Supervisor`. `params` is forwarded to the
  Server's `init/1`; common keys:

    * `:cmd_override` (string OR list of strings) — the command to
      spawn. Required for production callers (Server raises if
      absent). A STRING runs via `/bin/sh -c` (shell). A LIST runs in
      argv form (`[Cmd | Args]`) directly via `execve` with NO shell —
      each element is exactly one argument, so operator-controlled
      values cannot inject flags or shell commands (codex HIGH-2). The
      cc plugin supplies the argv list form.
    * `:cmd_env` (map `%{"NAME" => "value"}`) — extra environment
      variables for the child, merged into the inherited OS env and
      passed structurally to `:exec.run/2` (never interpolated into a
      command line). Used by the cc plugin for `CLAUDE_CONFIG_DIR`.
    * `:cwd` (string) — working directory for the child process.
    * `:test_mode` (boolean) — short-circuit `:exec.run/2` (default:
      `Mix.env() == :test`).
    * `:auto_prompts` (list) — extra entries appended to the default
      auto-prompt scanner.

  `agent_uri` is injected into params automatically — callers don't
  need to put it there (idempotent if they do, since we
  `Map.put/3`-override).
  """
  @spec start(URI.t(), map()) :: DynamicSupervisor.on_start_child()
  def start(%URI{} = agent_uri, params) when is_map(params) do
    DynamicSupervisor.start_child(
      EzagentDomainPty.Supervisor,
      {Server, Map.put(params, :agent_uri, agent_uri)}
    )
  end

  @doc """
  True iff a PtyServer exists + is alive for this agent_uri (resolved
  through the V5 resolver seam's `Resolver.alive?/1` — pid-free).

  The A1b-pilot `lookup/1` (which returned `{:ok, pid}`) is RETIRED
  (codex A1b-pilot #2): no public pid surface remains on this facade —
  callers that checked "is it up" use this, and callers that acted on the
  pid use the query APIs (`status/1`) or the seam's
  `terminate_child`/`cast` (see `stop/1` + `restart/1` below).
  """
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri), do: Resolver.alive?(Server.resolver_key(agent_uri))

  @doc """
  Operator-facing status snapshot (delegates to `Server.status/1`,
  served by an explicit `GenServer.call` — V5 A1b). Returns `nil` when
  no PtyServer is alive for this agent_uri.
  """
  @spec status(URI.t()) :: map() | nil
  def status(%URI{} = agent_uri), do: Server.status(agent_uri)

  @doc """
  Stop the PtyServer for `agent_uri`. Idempotent — returns `:ok`
  whether the server was alive or not.

  Also clears the respawn breaker's history (2026-07-13). A `stop/1` is a
  DELIBERATE teardown, and `terminate_child` already ends the supervisor's
  automatic restart loop — which is the only thing the breaker exists to stop.
  Leaving a halt behind would instead poison the NEXT deliberate `start/2`: it
  would be vetoed by a stale halt, `restart/1` cannot help (no server to restart),
  and the agent would have no way back at all.

  The clear happens only AFTER the server is confirmed gone (codex review). Doing it
  first left a window where a child crashing mid-`stop/1` got its PtyServer replaced
  by the supervisor: `terminate_child` then targeted the obsolete pid, returned
  `{:error, :not_found}` — which was discarded — and `stop/1` reported `:ok` while a
  REPLACEMENT server kept running with a freshly wiped crash history. That is both a
  silent failure and a clean slate handed to the very looper we meant to stop.
  """
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    terminate_until_gone(agent_uri, 5)
    Ezagent.Domain.Pty.RespawnPolicy.clear(agent_uri)
    Ezagent.Domain.Pty.RespawnBackoff.clear(URI.to_string(agent_uri))
    :ok
  end

  # A crash racing the stop can have the supervisor replace the server between our
  # terminate and the re-check. Re-resolve and stop the replacement too. Bounded —
  # the window is tiny, and a terminated DynamicSupervisor child is not restarted.
  #
  # P1 (codex review): the resolution must find the child WITHOUT probing the
  # process. When the PtyServer is sleeping inside `apply_respawn_backoff/1`
  # (up to 30 s), a probe with a 500 ms timeout fires and reports the child
  # gone even though it is ALIVE — handing a still-looping agent a clean crash
  # history. `Resolver.terminate_child/2` resolves through the seam (`Registry`
  # entry owned by the child itself), so a sleeping server is correctly found
  # and terminated — and the pid never leaves the seam (V5 A1b codex #2: this
  # loop was the last in-app pid fetch).
  defp terminate_until_gone(%URI{} = agent_uri, 0) do
    if alive?(agent_uri) do
      require Logger

      Logger.error(
        "PtyServer: stop/1 could NOT terminate #{URI.to_string(agent_uri)} — a replacement " <>
          "server kept appearing. Its respawn history is being cleared anyway; if it is " <>
          "crash-looping it now has a clean slate. Investigate."
      )
    end

    :ok
  end

  defp terminate_until_gone(%URI{} = agent_uri, attempts_left) do
    case Resolver.terminate_child(Server.resolver_key(agent_uri), EzagentDomainPty.Supervisor) do
      :ok ->
        # The registry entry dies ASYNCHRONOUSLY with the child (Registry
        # DOWN-cleanup); give it a tick so the re-resolve below doesn't
        # burn attempts on an already-terminating pid.
        Process.sleep(10)
        terminate_until_gone(agent_uri, attempts_left - 1)

      :not_found ->
        # Not registered → definitely gone (or was never started).
        :ok
    end
  end

  @doc """
  Operator recovery for a HALTED agent (2026-07-13) — and the only way back.

  When `Ezagent.Domain.Pty.RespawnPolicy` trips its breaker, the PtyServer stays
  alive but runs no child and will not spawn one: a child that failed to start N
  times in a row needs a human to look at the cause, not another retry. This is
  that human's lever. It clears the breaker AND the backoff history, then drives a
  fresh spawn — so it also works as a plain "bounce this agent".

  Returns `{:error, :not_running}` when no PtyServer exists for `agent_uri` (there
  is nothing to restart — start it through the owning plugin's spawn path instead).
  """
  @spec restart(URI.t()) :: :ok | {:error, :not_running}
  def restart(%URI{} = agent_uri) do
    Ezagent.Domain.Pty.RespawnPolicy.clear(agent_uri)
    Ezagent.Domain.Pty.RespawnBackoff.clear(URI.to_string(agent_uri))

    # Seam resolution finds the server without probing via :sys.get_state,
    # so a server sleeping in apply_respawn_backoff (up to 30 s) is
    # correctly found (codex P1) — and the pid never leaves the seam
    # (`Resolver.cast/2`, V5 A1b codex #2).
    case Resolver.cast(Server.resolver_key(agent_uri), :respawn) do
      :ok -> :ok
      :not_found -> {:error, :not_running}
    end
  end

  @doc """
  The respawn-halt record for `agent_uri`, or `nil` when it is not halted.

  A halt is DURABLE (ETS) and outlives the PtyServer process, so this answers even
  when no server is running — unlike `status/1`, which needs a live one.
  """
  @spec halt_info(URI.t()) :: map() | nil
  def halt_info(%URI{} = agent_uri), do: Ezagent.Domain.Pty.RespawnPolicy.halt_info(agent_uri)
end
