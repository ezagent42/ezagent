defmodule Ezagent.Socialware.AnonUser.Sweeper do
  @moduledoc """
  The in-app GC sweeper for abandoned anonymous external users (issue #51, §3.4).

  A small supervised `GenServer` that re-arms via `Process.send_after/3` on a fixed
  interval (default hourly) and runs `Ezagent.Socialware.AnonUser.GC.sweep/1` —
  reaping anon-Users whose binding `last_seen_at` is older than the 48h TTL. This is
  the post-collapse revision of the draft's Oban-cron proposal (Oban is absent from
  the dependency tree); `Process.send_after/3` is the idiom the codebase already
  uses for periodic in-app work.

  ## Authority

  The reaping `chat.leave` runs under the closed-catalog `system://socialware-gc`
  principal (Session `:leave` only — see `Ezagent.SystemPrincipal.Catalog`). The
  GenServer `ensure/1`s that principal identity at boot (best-effort hygiene; the
  leave dispatch passes the caps inline, so a boot-time ensure failure does not
  disable the sweep — the next tick re-ensures).

  ## Configuration

  - `:gc_sweep_interval_ms` (app env, default 1h) — the re-arm interval. Tests set
    a large value (or none) so the tick never fires mid-suite; the sweep logic is
    tested directly via `GC.sweep/1`.
  """

  use GenServer

  require Logger

  alias Ezagent.Socialware.AnonUser.GC

  @default_interval_ms 60 * 60 * 1000
  @gc_principal "socialware-gc"

  @doc """
  Start the sweeper. `:interval_ms` overrides the configured/default interval;
  `:name` overrides the registered name (pass `name: nil` for an unnamed instance,
  e.g. in tests, so it does not collide with the supervised singleton).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    # init is side-effect-free except arming the timer — no boot-time DB work, so
    # the sweeper is safe to supervise in any env (the first tick is interval-out).
    interval = opts[:interval_ms] || configured_interval()
    schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:sweep, %{interval_ms: interval} = state) do
    run_sweep()
    schedule(interval)
    {:noreply, state}
  end

  # ----- internals -----------------------------------------------------------

  defp run_sweep do
    ensure_principal()
    {:ok, count} = GC.sweep(DateTime.utc_now())
    if count > 0, do: Logger.info("Socialware GC: reaped #{count} abandoned anon-User(s)")
    :ok
  rescue
    e -> Logger.warning("Socialware GC sweep failed (will retry next tick): #{inspect(e)}")
  end

  # Best-effort: the principal identity is hygiene, not load-bearing (the leave
  # dispatch passes caps inline, so authz does not need the principal Kind alive).
  # Idempotent — re-running each sweep is cheap.
  defp ensure_principal do
    Ezagent.SystemPrincipal.ensure(Ezagent.SystemPrincipal.uri(@gc_principal))
  rescue
    e -> Logger.debug("Socialware GC: ensure #{@gc_principal} deferred: #{inspect(e)}")
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp configured_interval do
    Application.get_env(:ezagent_domain_socialware, :gc_sweep_interval_ms, @default_interval_ms)
  end
end
