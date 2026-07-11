defmodule Ezagent.Domain.Pty.RespawnBackoff do
  @moduledoc """
  Crash-loop respawn rate-limiter for `Ezagent.Domain.Pty.Server` (2026-07-10
  cc-PTY hardening — audit `docs/notes/2026-07-10-cc-pty-pitfalls.md` #3).

  ## Why this exists

  The `EzagentDomainPty.Supervisor` `DynamicSupervisor` parents one PtyServer
  per agent. When a child exceeds the supervisor's restart intensity, OTP
  terminates **all** children and the supervisor itself — so a single
  crash-looping `claude` (expired creds, an OOM loop, a dialog that lands on an
  "exit" option) would take down **every** PtyServer on the node. Raising the
  supervisor intensity alone only *delays* that: an infinite loop trips any
  finite intensity eventually. The genuine isolation is to **rate-limit** the
  looping child so it can never produce enough restarts within the intensity
  window to trip it — while siblings and genuinely-systemic mass-crashes are
  unaffected.

  ## Mechanism — sliding-window, pruned on read (no reset timer)

  Each (re)spawn attempt records `System.monotonic_time(:millisecond)` in an ETS
  row keyed by the agent URI. `delay_for/1`, called at the START of every real
  spawn attempt, prunes timestamps older than `window_ms` and returns a backoff
  delay that grows linearly with the number of *recent* prior attempts:

      delay_ms = min(cap_ms, base_ms * recent_count)

  * First spawn (or a child that has been stable long enough that its history
    aged out of the window) → `recent_count == 0` → `0` delay. **The sliding
    window is the reset** — a stabilized child needs no timer to clear it.
  * A crash-looping child accumulates recent attempts, so its per-restart delay
    escalates (0, base, 2·base, …) up to `cap_ms`, capping its restart RATE.

  ### Arithmetic (why the defaults isolate)

  With `base_ms = 1_000`, `cap_ms = 30_000`, `window_ms = 60_000`: a child that
  crashes instantly on every spawn ramps through delays 0, 1s, 2s, … so it takes
  `Σ base·k ≈ base·n²/2` wall-clock to reach `n` restarts — roughly **≤ 12
  restarts in any 60 s window** (then ~2/min at the cap). The supervisor's
  `max_restarts: 20 / max_seconds: 60` therefore is never tripped by ONE bad
  child, leaving headroom for legitimate sibling restarts. Many children
  crashing at once IS systemic — that is exactly when intensity SHOULD escalate,
  so we do not suppress it.

  All three knobs (and the supervisor intensity, in `Application`) are
  app-env-injectable (`config :ezagent_domain_pty, ...`) so tests can scale them
  down; the same seam pattern as `:transport_join_timeout_ms`.
  """

  require Logger

  @table :ezagent_pty_respawn_backoff

  @default_window_ms 60_000
  @default_base_ms 1_000
  @default_cap_ms 30_000

  @doc "Create the backoff ETS table if it does not yet exist. Idempotent."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  rescue
    # A concurrent `:ets.new/2` (two PtyServers racing their first spawn) can
    # raise ArgumentError on the loser — the table exists either way.
    ArgumentError -> :ok
  end

  @doc """
  Record a spawn attempt for `key` (the agent URI string) at `now` and return
  the backoff delay in ms to apply BEFORE spawning.

  Prunes attempts older than the sliding window on every call, so a child that
  stabilized past the window returns to `0` with no external reset.
  """
  @spec delay_for(String.t()) :: non_neg_integer()
  def delay_for(key) when is_binary(key) do
    init()
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms()
    prior = recent_attempts(key, cutoff)

    delay = min(cap_ms(), base_ms() * length(prior))
    :ets.insert(@table, {key, [now | prior]})
    delay
  end

  @doc """
  Record a respawn attempt for `agent_uri` and BLOCK for its backoff delay (log +
  telemetry when non-zero). Called from the PtyServer's spawn continuation, so
  the sleep rate-limits ONLY this one crash-looping child.
  """
  @spec throttle(URI.t()) :: :ok
  def throttle(%URI{} = agent_uri) do
    key = URI.to_string(agent_uri)

    case delay_for(key) do
      0 ->
        :ok

      ms when is_integer(ms) and ms > 0 ->
        Logger.warning(
          "PtyServer: respawn backoff #{ms}ms for #{key} — this child is restarting " <>
            "rapidly (crash-loop guard). Delaying the respawn so it cannot trip the " <>
            "DynamicSupervisor intensity and take down sibling PtyServers."
        )

        :telemetry.execute([:ezagent, :pty, :respawn_backoff], %{delay_ms: ms}, %{
          agent_uri: agent_uri
        })

        Process.sleep(ms)
        :ok
    end
  end

  @doc """
  Number of spawn attempts recorded within the current sliding window for
  `key`. Test/observability helper — does not record a new attempt.
  """
  @spec attempt_count(String.t()) :: non_neg_integer()
  def attempt_count(key) when is_binary(key) do
    init()
    cutoff = System.monotonic_time(:millisecond) - window_ms()
    length(recent_attempts(key, cutoff))
  end

  @doc "Forget `key`'s crash history (e.g. a clean operator restart)."
  @spec clear(String.t()) :: :ok
  def clear(key) when is_binary(key) do
    init()
    :ets.delete(@table, key)
    :ok
  end

  defp recent_attempts(key, cutoff) do
    case :ets.lookup(@table, key) do
      [{^key, ts_list}] when is_list(ts_list) -> Enum.filter(ts_list, &(&1 >= cutoff))
      _ -> []
    end
  end

  defp window_ms, do: cfg(:respawn_backoff_window_ms, @default_window_ms)
  defp base_ms, do: cfg(:respawn_backoff_base_ms, @default_base_ms)
  defp cap_ms, do: cfg(:respawn_backoff_cap_ms, @default_cap_ms)

  defp cfg(key, default) do
    case Application.get_env(:ezagent_domain_pty, key, default) do
      v when is_integer(v) and v >= 0 -> v
      _ -> default
    end
  end
end
