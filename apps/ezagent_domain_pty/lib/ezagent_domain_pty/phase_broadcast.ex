defmodule Ezagent.Domain.Pty.PhaseBroadcast do
  @moduledoc """
  Phase-transition broadcaster for `Ezagent.Domain.Pty.Server` (PTY-phase-state-machine
  2026-05-26 follow-up b). Extracted from `Server` to keep it under the oversized-module
  arch gate — the same pattern as `AutoPrompts` / `ParkedDialogWatch` / `AuthObservers`.

  Exactly THREE phases exist on the OS subprocess, per Allen's directive: `:starting`,
  `:running`, `:dead` — no `:initializing` / `:ready` / `:respawning` middle states, and
  `Ezagent.ActionSet.Sandbox` validates that set.

  A respawn HALT is deliberately **not** a fourth phase. The subprocess genuinely is
  `:dead`; "and no respawn is coming" rides on the SAME `:dead` broadcast, distinguished
  by `meta.respawning`: `true` means the permanent supervisor will replace the server;
  `false` means the death is definitive (explicit termination or a halted respawn loop).
  `meta.reason` remains diagnostic only — an ordinary child can itself exit with
  `:shutdown`, so consumers MUST NOT infer restart intent from the raw reason. A
  `{:respawn_halted, cause}` reason is paired with `respawning: false`.
  (`Ezagent.Domain.Pty.Server.status/1` also exposes `halted?` + `halt_reason`, and
  `Ezagent.Domain.Pty.halt_info/1` reads the durable ETS record.)

  Best-effort by contract: phase tracking is OPERATOR VISIBILITY plumbing and its failure
  MUST NOT block the primary PTY path (spawn / write / shutdown). A broadcast failure logs
  and degrades — subscribers losing one transition is acceptable, the periodic LV poll
  picks the next one up.
  """

  require Logger

  @type phase :: :starting | :running | :dead

  @doc """
  PubSub topic for an agent's PTY phase transitions. Subscribers receive
  `{:pty_phase, agent_uri, phase, meta}`. Every `:dead` event emitted by the current
  server includes boolean `meta.respawning`; older producers may omit it.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = agent_uri), do: "pty:phase:" <> URI.to_string(agent_uri)

  @doc """
  Broadcast a phase transition. `meta` carries `:os_pid`, `:reason` and `:at`; anything in
  `extra_meta` overrides those defaults. Server-owned `:dead` call sites must supply the
  boolean `:respawning` contract described in this module's moduledoc.
  """
  @spec emit(URI.t(), phase(), non_neg_integer() | nil, map() | nil) :: :ok
  def emit(%URI{} = agent_uri, phase, os_pid, extra_meta)
      when phase in [:starting, :running, :dead] do
    meta =
      Map.merge(
        %{os_pid: os_pid, reason: nil, at: System.os_time(:millisecond)},
        extra_meta || %{}
      )

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      topic(agent_uri),
      {:pty_phase, agent_uri, phase, meta}
    )

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "PtyServer: phase broadcast failed (#{inspect(kind)}, #{inspect(reason)}) " <>
          "for #{URI.to_string(agent_uri)} phase=#{inspect(phase)}; continuing"
      )

      :ok
  end
end
