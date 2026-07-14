defmodule Ezagent.Cap.DeliveryOutbox.Sweeper do
  @moduledoc """
  Periodically retries DB-backed capability deliveries left pending by a
  process or BEAM crash. Tests opt in explicitly so the singleton never races
  an Ecto sandbox owner.
  """

  use GenServer

  @default_interval_ms 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, configured_interval_ms())
    :ok = Ezagent.Cap.DeliveryOutbox.rehydrate_hints()
    send(self(), :sweep)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:sweep, state) do
    _count = Ezagent.Cap.DeliveryOutbox.sweep_due()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  defp configured_interval_ms do
    :ezagent_core
    |> Application.get_env(Ezagent.Cap.DeliveryOutbox, [])
    |> Keyword.get(:sweep_interval_ms, @default_interval_ms)
  end
end
