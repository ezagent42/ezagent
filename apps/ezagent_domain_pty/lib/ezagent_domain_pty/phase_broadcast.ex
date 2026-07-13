defmodule Ezagent.Domain.Pty.PhaseBroadcast do
  @moduledoc """
  Phase-transition broadcaster for `Ezagent.Domain.Pty.Server` (PTY-phase-state-machine
  2026-05-26 follow-up b). Extracted from `Server` to keep it under the oversized-module
  arch gate — the same pattern as `AutoPrompts` / `ParkedDialogWatch` / `AuthObservers`.

  Exactly THREE phases exist on the OS subprocess, per Allen's directive: `:starting`,
  `:running`, `:dead` — no `:initializing` / `:ready` / `:respawning` middle states, and
  `Ezagent.ActionSet.Sandbox` validates that set.

  A respawn HALT is deliberately **not** a fourth phase. The subprocess genuinely is
  `:dead`; "and no respawn is coming" is a *supervision* fact, carried separately by
  `Ezagent.Domain.Pty.RespawnPolicy` (its own `halted_topic/1` + `status/1` fields). Phase
  answers "what is the child doing"; the halt answers "will anything bring it back".

  Best-effort by contract: phase tracking is OPERATOR VISIBILITY plumbing and its failure
  MUST NOT block the primary PTY path (spawn / write / shutdown). A broadcast failure logs
  and degrades — subscribers losing one transition is acceptable, the periodic LV poll
  picks the next one up.
  """

  require Logger

  @type phase :: :starting | :running | :dead

  @doc """
  PubSub topic for an agent's PTY phase transitions. Subscribers receive
  `{:pty_phase, agent_uri, phase, meta}`.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = agent_uri), do: "pty:phase:" <> URI.to_string(agent_uri)

  @doc """
  Broadcast a phase transition. `meta` carries `:os_pid`, `:reason` and `:at`; anything in
  `extra_meta` overrides those defaults.
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
