defmodule Ezagent.Domain.Pty.RespawnPolicy do
  @moduledoc """
  Decides whether a PtyServer's next respawn should run the preferred command,
  a degraded fallback, or **not happen at all** (2026-07-13 — root cause note
  `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md`).

  ## Why this exists

  `Ezagent.Domain.Pty.RespawnBackoff` rate-limits a crash-looping child so it
  cannot trip supervisor intensity. It was never meant to STOP the loop, and it
  doesn't: a child that can never succeed respawns forever. Live on canary,
  `test-zyli-cc-1` respawned 933 times in two hours because the cc plugin's
  respawn argv carried `--continue` and the config home had no resumable
  conversation, so `claude` exited 1 within 37 ms of every launch — permanently.

  Two things were missing, and this module supplies both.

  ### 1. The respawn decision must be vetoable

  A `DynamicSupervisor` **freezes the child spec**: `Domain.Pty.start/2` hands it
  `{Server, params}` once, and every later restart re-runs `start_link/1` with
  those same params. The plugin that chose the argv is never consulted again. So
  the veto has to live on the spawn path itself, and it has to survive the
  GenServer restart that carries it — hence ETS, keyed by agent URI, exactly like
  `RespawnBackoff`.

  ### 2. The trigger must be cause-agnostic

  The obvious trigger — "halt when the auth-failure observer fires" — does not
  work: across those 933 crashes the observer fired **zero** times, because a
  `--continue` failure prints none of the credential signals it matches. Any
  trigger tied to a specific diagnosis will miss the next unrecoverable exit for
  the same reason.

  What every unrecoverable start has in common is not its cause but its SHAPE:
  the child dies before it ever reaches a healthy lifetime, again and again. That
  is what this module counts, so it catches the `--continue` bug, an expired
  credential, an OOM at boot, and a dialog that lands on "exit" — without knowing
  anything about any of them.

  ## The ladder

  Each spawn asks `decide/2`, each outcome is reported back:

      primary_failures ≥ max_failures, fallback → :fallback   (primary written off)
      failures = 0                              → :primary    (the preferred command)
      failures ≥ 1, fallback                    → :fallback   (degraded)
      failures ≥ max_failures                   → {:halt, info}

  ## Two counters, and why one of them must NOT be reset (codex review)

  `failures` counts CONSECUTIVE failed starts in any mode and trips the halt.
  A healthy run zeroes it — a child that got past startup is not crash-looping.

  `primary_failures` counts failures of the PREFERRED command over the agent's
  lifetime, and a healthy **fallback** run deliberately does NOT reset it. Without
  that memory the ladder does not converge, and the first draft of this module did
  not: primary fails → fallback runs → the fallback's healthy timer erases the
  whole history → the fallback later exits → the next incarnation tries primary
  again → fails again → … Each fallback erased the single primary failure, so
  `max_failures` was never reached and the pair could cycle **forever**. Slower
  than the 37 ms loop this module exists to kill, but the same unbounded shape.

  Remembering that the primary is broken bounds it: after `max_failures` primary
  failures the primary is written off and the agent settles onto the fallback (it
  keeps WORKING — it just stops paying a wasted spawn per restart to retry a
  command we now know cannot start). Only a healthy PRIMARY run, or an operator
  (`clear/1`), forgives it.

  A halt is TERMINAL and durable: it survives the GenServer restart, so the
  PtyServer that comes back up sees it and declines to spawn. Recovery is manual
  and explicit (`Ezagent.Domain.Pty.restart/1`), because an agent that failed to
  start N times running needs a human to look at it, not another retry.

  All knobs are app-env-injectable (`config :ezagent_domain_pty, ...`) so tests
  can scale them down — same seam as `RespawnBackoff`.
  """

  require Logger

  @table :ezagent_pty_respawn_policy

  @default_max_failures 3
  @default_max_probes 1

  # 2026-07-13 — aligned with `EzagentPluginCc.…Spawn.@default_transport_join_timeout_ms`
  # (30 s). A shorter window declares a child healthy BEFORE its transport bridge has
  # had time to JOIN, so a zombie that boots but never becomes reachable is waved
  # through as a healthy start.
  #
  # KNOWN LIMITATION (for Allen): elapsed time is a PROXY, not the real signal. The
  # authoritative "this child actually started" fact is the bridge JOIN
  # (`Ezagent.Agent.TransportReadiness.on_transport_joined/1`). A child that boots and
  # sits at a login prompt survives any timeout and is counted healthy, so the breaker
  # cannot catch that failure mode. Wiring the real signal in means either the PTY
  # domain app depending on `ezagent_domain_agent_bridge` (its mix.exs forbids it:
  # "Tier-2 rule: Domain apps depend on ezagent_core ONLY") or a new core-level health
  # topic. Both are architecture decisions — deliberately NOT made in this PR.
  @default_healthy_after_ms 30_000

  @type mode :: :primary | :fallback
  @type halt_info :: %{reason: term(), failures: pos_integer(), at: integer()}

  @doc "Create the policy ETS table if absent. Idempotent."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    # Two PtyServers racing their first spawn — the table exists either way.
    ArgumentError -> :ok
  end

  @doc """
  How the next spawn for `agent_uri` should run.

  `fallback_available?` says whether the caller actually HAS a degraded command
  to fall back to; without one, a failing agent simply retries the primary until
  the breaker trips.
  """
  @spec decide(URI.t(), boolean()) :: mode() | {:halt, halt_info()}
  def decide(%URI{} = agent_uri, fallback_available?) when is_boolean(fallback_available?) do
    max = max_failures()

    case load(URI.to_string(agent_uri)) do
      %{halt: %{} = info} ->
        {:halt, info}

      # PROBE: the primary is written off, but a fallback has since run healthily —
      # the child really worked, so whatever broke the primary may well be fixed
      # (for cc: a conversation now exists, so `--continue` would resolve). Spend
      # ONE spawn finding out. A healthy primary here erases the write-off entirely;
      # a failed probe burns the probe and we settle back onto the fallback. Probes
      # are capped and only granted by a HEALTHY fallback run, so this cannot become
      # the unbounded primary/fallback cycle the two-counter model exists to prevent.
      %{primary_failures: p, probes: probes} when fallback_available? and p >= max and probes > 0 ->
        :primary

      # Written off with no probe left: stop paying a wasted spawn per restart to
      # retry a command we know cannot start. This is what makes the ladder CONVERGE.
      %{primary_failures: p} when fallback_available? and p >= max ->
        :fallback

      %{failures: 0} ->
        :primary

      %{failures: _n} when fallback_available? ->
        :fallback

      _ ->
        :primary
    end
  end

  @doc """
  The child for `agent_uri` died before reaching a healthy lifetime, while running
  `mode`'s command.

  Increments the consecutive-failure count (and, for `:primary`, the lifetime
  primary-failure count) and trips the breaker at `max_failures/0`, returning
  `{:halted, info}` on the transition so the caller can surface it.
  """
  @spec record_failure(URI.t(), term(), mode(), boolean()) :: :ok | {:halted, halt_info()}
  # `mode` and `fallback_available?` are MANDATORY on purpose — no defaults. A
  # defaulted `:primary` would let an accidental short call book a FALLBACK failure
  # against the primary, silently corrupting the write-off decision this module's
  # convergence depends on.
  def record_failure(%URI{} = agent_uri, reason, mode, fallback_available?)
      when mode in [:primary, :fallback] and is_boolean(fallback_available?) do
    key = URI.to_string(agent_uri)
    state = load(key)
    max = max_failures()
    failures = state.failures + 1
    primary_failures = state.primary_failures + if(mode == :primary, do: 1, else: 0)

    # A failed PROBE is spent — otherwise the same probe would retry the doomed
    # primary on every restart, which is the unbounded cycle in another costume.
    probes = if mode == :primary and state.probes > 0, do: state.probes - 1, else: state.probes

    state = %{state | failures: failures, primary_failures: primary_failures, probes: probes}

    # The primary failure that FIRST reaches the threshold is the WRITE-OFF transition,
    # not a halt: `decide/2` answers it by retiring the primary and switching to the
    # fallback. Halting here would mean a perfectly valid `max_failures: 1` never tries
    # the fallback AT ALL — the self-healing path skipped at precisely the threshold it
    # was built for (codex review, P4). The breaker still trips once the FALLBACK is
    # also failing, or when there is no fallback to fall back to.
    write_off_crossing? =
      fallback_available? and mode == :primary and primary_failures >= max and probes == 0

    if failures >= max and not write_off_crossing? do
      info = %{reason: reason, failures: failures, at: System.os_time(:millisecond)}
      store(key, %{state | halt: info})

      Logger.error(
        "PtyServer: RESPAWN HALTED for #{key} after #{failures} consecutive failed starts " <>
          "(last reason: #{inspect(reason)}). This child never reached a healthy lifetime, so " <>
          "respawning it again would loop forever. The agent stays up in a halted state; an " <>
          "operator must fix the cause and restart it (Ezagent.Domain.Pty.restart/1)."
      )

      :telemetry.execute([:ezagent, :pty, :respawn_halted], %{failures: failures}, %{
        agent_uri: agent_uri,
        reason: reason
      })

      {:halted, info}
    else
      store(key, state)
      maybe_announce_write_off(agent_uri, mode, primary_failures)
      :ok
    end
  end

  # The transition where the PREFERRED command is written off is a real, DURABLE
  # degradation — the agent keeps working, but on the fallback, and (for cc) that
  # means it will no longer resume its conversation across restarts. It is exactly
  # the regression `--continue` existed to prevent, so it must never happen QUIETLY.
  # `status/1` also reports `degraded?: true` from here on.
  defp maybe_announce_write_off(%URI{} = agent_uri, :primary, count) do
    if count == max_failures() do
      Logger.error(
        "PtyServer: PREFERRED COMMAND WRITTEN OFF for #{URI.to_string(agent_uri)} after " <>
          "#{count} failed starts — the preferred command will NOT be retried at startup. " <>
          "This is a DURABLE degradation, not a blip. Fix the cause and restart the agent " <>
          "(Ezagent.Domain.Pty.restart/1) to let it be tried again."
      )

      :telemetry.execute([:ezagent, :pty, :primary_written_off], %{failures: count}, %{
        agent_uri: agent_uri
      })
    end

    :ok
  end

  defp maybe_announce_write_off(_agent_uri, :fallback, _count), do: :ok

  @doc """
  The child for `agent_uri` survived `healthy_after_ms/0` running `mode`'s command
  — it got past startup.

  A healthy **primary** erases the history entirely: the preferred command works,
  so nothing is left to remember. This is how a written-off primary gets FULLY
  rehabilitated — reached via the probe (below).

  A healthy **fallback** zeroes the consecutive-failure count (it is not
  crash-looping) but KEEPS `primary_failures`. That memory is load-bearing: erasing
  it lets a fallback that survives the health timer without actually working reset
  the ladder on every cycle, so the primary is retried forever and the breaker never
  converges (codex review — see the moduledoc).

  It DOES, however, grant one PROBE (capped at `max_probes/0`). A fallback that ran
  healthily means the child really worked — for cc that means a conversation was
  persisted, so the `--continue` that was written off would very likely succeed now.
  Without the probe the write-off is PERMANENT and the agent silently loses resume
  forever; the probe is what stops the breaker from being a one-way door.
  """
  @spec record_healthy(URI.t(), mode()) :: :ok
  # `mode` is MANDATORY (see `record_failure/3`): a defaulted `:primary` here would
  # make a healthy FALLBACK erase the primary's failure history — the exact
  # non-convergence codex found.
  def record_healthy(%URI{} = agent_uri, mode) when mode in [:primary, :fallback] do
    key = URI.to_string(agent_uri)
    state = load(key)

    case mode do
      :primary ->
        :ets.delete(@table, key)

      :fallback ->
        store(key, %{
          state
          | failures: 0,
            halt: nil,
            probes: min(state.probes + 1, max_probes())
        })
    end

    :ok
  end

  @doc """
  True when the preferred command has failed for `agent_uri`, i.e. the agent is (or
  is about to be) running the degraded fallback. Survives a healthy fallback run —
  that is exactly the point.
  """
  @spec degraded?(URI.t()) :: boolean()
  def degraded?(%URI{} = agent_uri), do: load(URI.to_string(agent_uri)).primary_failures > 0

  @doc "The halt record for `agent_uri`, or `nil` when it is not halted."
  @spec halt_info(URI.t()) :: halt_info() | nil
  def halt_info(%URI{} = agent_uri), do: load(URI.to_string(agent_uri)).halt

  @doc "Consecutive failed starts currently recorded for `agent_uri`."
  @spec failures(URI.t()) :: non_neg_integer()
  def failures(%URI{} = agent_uri), do: load(URI.to_string(agent_uri)).failures

  @doc """
  Forget `agent_uri`'s failure history and clear any halt — the operator's
  "restart this agent" lever. See `Ezagent.Domain.Pty.restart/1`.
  """
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = agent_uri) do
    init()
    :ets.delete(@table, URI.to_string(agent_uri))
    :ok
  end

  @doc """
  How long a child must survive before its start counts as healthy. Default
  #{@default_healthy_after_ms} ms; override with
  `config :ezagent_domain_pty, :respawn_healthy_after_ms`.
  """
  @spec healthy_after_ms() :: pos_integer()
  def healthy_after_ms, do: cfg(:respawn_healthy_after_ms, @default_healthy_after_ms)

  @doc """
  Consecutive failed starts that trip the breaker. Default
  #{@default_max_failures}; override with
  `config :ezagent_domain_pty, :respawn_max_failures`.
  """
  @spec max_failures() :: pos_integer()
  def max_failures, do: cfg(:respawn_max_failures, @default_max_failures)

  @doc """
  How many PROBES a written-off primary may accumulate — one retry each, granted by a
  healthy fallback run. Default #{@default_max_probes}; override with
  `config :ezagent_domain_pty, :respawn_max_probes`.

  The cap is what keeps the probe from re-creating the unbounded primary/fallback
  cycle: probes are granted ONLY by a healthy fallback (which costs a full
  `healthy_after_ms`), spent one per retry, and never exceed this ceiling.
  """
  @spec max_probes() :: pos_integer()
  def max_probes, do: cfg(:respawn_max_probes, @default_max_probes)

  @doc "Probes currently banked for `agent_uri` (test/observability helper)."
  @spec probes(URI.t()) :: non_neg_integer()
  def probes(%URI{} = agent_uri), do: load(URI.to_string(agent_uri)).probes

  defp load(key) do
    init()

    case :ets.lookup(@table, key) do
      [{^key, %{} = state}] -> state
      _ -> %{failures: 0, primary_failures: 0, probes: 0, halt: nil}
    end
  end

  defp store(key, state), do: :ets.insert(@table, {key, state})

  defp cfg(key, default) do
    case Application.get_env(:ezagent_domain_pty, key, default) do
      v when is_integer(v) and v > 0 -> v
      _ -> default
    end
  end
end
