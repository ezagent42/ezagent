defmodule EzagentWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor + metric declarations.

  ## Reporter wiring

  `metrics/0` is consumed by `Phoenix.LiveDashboard` (mounted at
  `/dashboard` — see `EzagentWeb.Router` `live_dashboard "/dashboard",
  metrics: EzagentWeb.Telemetry`). The metrics appear in LiveDashboard's
  Metrics tab — no separate Prometheus/Console reporter needed for
  the current single-node-ops setup.

  If a Prometheus scrape endpoint becomes a requirement (multi-node
  / external alerting), add `{TelemetryMetricsPrometheus, metrics:
  metrics()}` to the `children` list below and expose the default
  port via `mix.exs` deps; LiveDashboard will keep working in
  parallel because both reporters subscribe to the same telemetry
  events.

  Audit reference: `docs/notes/2026-05-24-architecture-audit-loc-report.md`
  LOW item — originally reported as "no reporter attached"; that
  was incorrect (LiveDashboard already consumes this), corrected
  in cleanup batch 2026-05-24.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Reporters: `metrics/0` is consumed via LiveDashboard
      # (`live_dashboard "/dashboard", metrics: EzagentWeb.Telemetry`).
      # No standalone Console / Prometheus reporter needed for the
      # single-node-ops setup; see moduledoc.
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("ezagent_core.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("ezagent_core.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("ezagent_core.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("ezagent_core.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("ezagent_core.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EzagentWeb, :count_users, []}
    ]
  end
end
