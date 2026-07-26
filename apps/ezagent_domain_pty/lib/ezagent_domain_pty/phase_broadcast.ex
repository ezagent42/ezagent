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
  by its `meta.reason` — `{:respawn_halted, cause}` for a halt versus the raw exit reason
  for an ordinary death that a respawn will follow. A subscriber therefore learns both
  facts from one message. (`Ezagent.Domain.Pty.Server.status/1` also exposes `halted?` +
  `halt_reason`, and `Ezagent.Domain.Pty.halt_info/1` reads the durable ETS record.)

  Best-effort by contract: phase tracking is OPERATOR VISIBILITY plumbing and its failure
  MUST NOT block the primary PTY path (spawn / write / shutdown). A broadcast failure logs
  and degrades — subscribers losing one transition is acceptable, the periodic LV poll
  picks the next one up.

  ## V5 use-side H1 (delete-holes, #200) — dual-emit

  `emit/4` delivers the phase TWICE:

    1. `Phoenix.PubSub.broadcast/3` on `pty:phase:<agent_uri>` — the READ-ONLY
       UI read stream (`world_live`'s badge). A read-only LiveView
       subscription is NOT a hole; it STAYS.
    2. `EzagentActor.Signal.signal/2` point-to-point to the agent's own Kind
       — the ONLY path by which a phase now reaches + mutates a Kind (the
       Sandbox / PyAgent behavior's `handle_signal({:pty_phase, …})`). No
       Kind subscribes to the shared topic anymore.
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

    # V5 use-side H1 (delete-holes #200): dual-emit — the SAME phase also
    # goes point-to-point to the agent's Kind via the sanctioned signal
    # transport. The Kind no longer subscribes to the topic above (that
    # broadcast now feeds read-only UI subscribers only). Best-effort:
    # `:not_found` (a cold agent) is fine — the phase is mirrored into
    # durable state only while the Kind is live, same as the PubSub era.
    _ = EzagentActor.Signal.signal(agent_uri, {:pty_phase, agent_uri, phase, meta})

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
