defmodule Ezagent.Domain.Pty do
  @moduledoc """
  Domain.Pty facade — start, stop, status, alive? for an agent's PTY
  sidecar process. Per SPEC v1 (2026-05-21).

  This is the ONLY API other code (plugins, LV, lifecycle status
  helpers) should use to reach a `Ezagent.Domain.Pty.Server`. Direct
  references to `Server`, `EzagentDomainPty.Supervisor`, or
  `EzagentDomainPty.Registry` are an internal concern of the
  Domain.Pty app.

  Per `feedback_let_it_crash_no_workarounds`: no back-compat aliases to
  `Ezagent.PluginCc.PtyServer` — callers update to this facade.
  """

  alias Ezagent.Domain.Pty.Server

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

  @doc "Lookup the PtyServer pid by agent_uri."
  @spec lookup(URI.t()) :: {:ok, pid()} | :error
  def lookup(%URI{} = agent_uri), do: Server.find_by_agent_uri(agent_uri)

  @doc "True iff a PtyServer exists + is alive for this agent_uri."
  @spec alive?(URI.t()) :: boolean()
  def alive?(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  @doc """
  Operator-facing status snapshot (delegates to `Server.status/1`).
  Returns `nil` when no PtyServer is alive for this agent_uri.
  """
  @spec status(URI.t()) :: map() | nil
  def status(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        try do
          Server.status(pid)
        catch
          _, _ -> nil
        end

      :error ->
        nil
    end
  end

  @doc """
  Stop the PtyServer for `agent_uri`. Idempotent — returns `:ok`
  whether the server was alive or not.
  """
  @spec stop(URI.t()) :: :ok
  def stop(%URI{} = agent_uri) do
    case lookup(agent_uri) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(EzagentDomainPty.Supervisor, pid)
        :ok

      :error ->
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

    case lookup(agent_uri) do
      {:ok, pid} -> GenServer.cast(pid, :respawn)
      :error -> {:error, :not_running}
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
