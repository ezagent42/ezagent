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

      failures = 0            → :primary    (the preferred command)
      failures ≥ 1, fallback  → :fallback   (degraded — e.g. cc drops `--continue`)
      failures ≥ max_failures → {:halt, info}

  `record_healthy/1` (the child survived `healthy_after_ms`) **erases the whole
  history** — a child that got past startup is not crash-looping, and needs no
  external reset. `clear/1` is the operator's "restart this agent" lever.

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
  @default_healthy_after_ms 15_000

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
    case load(URI.to_string(agent_uri)) do
      %{halt: %{} = info} -> {:halt, info}
      %{failures: 0} -> :primary
      %{failures: _n} when fallback_available? -> :fallback
      _ -> :primary
    end
  end

  @doc """
  The child for `agent_uri` died before reaching a healthy lifetime.

  Increments the consecutive-failure count and trips the breaker at
  `max_failures/0`, returning `{:halted, info}` on the transition so the caller
  can surface it.
  """
  @spec record_failure(URI.t(), term()) :: :ok | {:halted, halt_info()}
  def record_failure(%URI{} = agent_uri, reason) do
    key = URI.to_string(agent_uri)
    state = load(key)
    failures = state.failures + 1

    if failures >= max_failures() do
      info = %{reason: reason, failures: failures, at: System.os_time(:millisecond)}
      store(key, %{state | failures: failures, halt: info})

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
      store(key, %{state | failures: failures})
      :ok
    end
  end

  @doc """
  The child for `agent_uri` survived `healthy_after_ms/0` — it got past startup.

  Erases the crash history entirely: a healthy child is not crash-looping, and a
  later failure should start counting from zero rather than inherit a stale tally.
  """
  @spec record_healthy(URI.t()) :: :ok
  def record_healthy(%URI{} = agent_uri) do
    init()
    :ets.delete(@table, URI.to_string(agent_uri))
    :ok
  end

  @doc "The halt record for `agent_uri`, or `nil` when it is not halted."
  @spec halt_info(URI.t()) :: halt_info() | nil
  def halt_info(%URI{} = agent_uri), do: load(URI.to_string(agent_uri)).halt

  @doc """
  PubSub topic for an agent's respawn-halt signal. Subscribers receive
  `{:pty_respawn_halted, agent_uri, info}`.

  This is DISTINCT from the `:dead` phase. `:dead` says the OS subprocess is not
  running and is routinely followed by a respawn; a halt says **no respawn is
  coming** until an operator intervenes. The phase vocabulary stays exactly three
  values (`:starting | :running | :dead`, per the Server's contract and
  `Ezagent.ActionSet.Sandbox`'s `validate_phase/1`) — a halt is a supervision
  fact, not a fourth state of the subprocess.
  """
  @spec halted_topic(URI.t()) :: String.t()
  def halted_topic(%URI{} = agent_uri), do: "pty:halted:" <> URI.to_string(agent_uri)

  @doc """
  Broadcast that `agent_uri` is halted, so the operator surfaces learn about it.
  Best-effort: a PubSub failure degrades (the halt itself is already durable in
  ETS and readable via `halt_info/1`); it must never wedge the PtyServer.
  """
  @spec announce_halt(URI.t(), halt_info()) :: :ok
  def announce_halt(%URI{} = agent_uri, %{} = info) do
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      halted_topic(agent_uri),
      {:pty_respawn_halted, agent_uri, info}
    )

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "PtyServer: halt broadcast failed (#{inspect(kind)}, #{inspect(reason)}) for " <>
          "#{URI.to_string(agent_uri)}; the halt itself stands (RespawnPolicy.halt_info/1)"
      )

      :ok
  end

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

  defp load(key) do
    init()

    case :ets.lookup(@table, key) do
      [{^key, %{} = state}] -> state
      _ -> %{failures: 0, halt: nil}
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
