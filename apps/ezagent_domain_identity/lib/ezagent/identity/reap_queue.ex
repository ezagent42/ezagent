defmodule Ezagent.Identity.ReapQueue do
  @moduledoc """
  Durable best-effort cleanup queue for generation-revoked principals.

  Revocation is complete before a URI enters this queue. The queue only
  reclaims a still-live Kind and its snapshot, and is durable so a node crash
  between enqueue and retry cannot lose cleanup work.
  """

  use Ecto.Schema
  use GenServer

  import Ecto.Query

  alias Ezagent.Identity.Offboarding.Reaper
  alias EzagentCore.Repo

  @primary_key {:principal_uri, :string, autogenerate: false}
  schema "identity_reap_queue" do
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:enqueued_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, 30_000)
    if runtime_sweeps?(), do: schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, %{interval: interval} = state) do
    _ = sweep()
    schedule(interval)
    {:noreply, state}
  end

  @doc "Persist an idempotent cleanup retry for an already-revoked principal."
  @spec enqueue(URI.t() | String.t()) :: :ok | {:error, term()}
  def enqueue(uri) do
    now = DateTime.utc_now()

    attrs = %{
      principal_uri: uri_string(uri),
      attempts: 0,
      last_error: nil,
      enqueued_at: now,
      updated_at: now
    }

    Repo.insert_all(__MODULE__, [attrs],
      on_conflict: [set: [updated_at: now]],
      conflict_target: [:principal_uri]
    )

    :ok
  rescue
    error -> {:error, error}
  end

  @doc "List principals awaiting cleanup convergence."
  @spec pending() :: [URI.t()]
  def pending do
    Repo.all(
      from(item in __MODULE__,
        order_by: [asc: item.enqueued_at, asc: item.principal_uri],
        select: item.principal_uri
      )
    )
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  @doc "Retry every pending cleanup once, retaining incomplete entries."
  @spec sweep() :: :ok
  def sweep do
    Repo.all(from(item in __MODULE__, order_by: [asc: item.updated_at, asc: item.principal_uri]))
    |> Enum.each(&retry/1)

    :ok
  end

  @doc "Remove a cleanup entry after process death and snapshot removal are proven."
  @spec resolve(URI.t() | String.t()) :: :ok
  def resolve(uri) do
    Repo.delete_all(from(item in __MODULE__, where: item.principal_uri == ^uri_string(uri)))
    :ok
  end

  defp retry(%__MODULE__{} = item) do
    uri = Ezagent.URI.new!(item.principal_uri)

    case Reaper.teardown_and_reap(uri) do
      :ok ->
        resolve(uri)

      {:error, reason} ->
        item
        |> Ecto.Changeset.change(%{
          attempts: item.attempts + 1,
          last_error: inspect(reason),
          updated_at: DateTime.utc_now()
        })
        |> Repo.update()

        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp runtime_sweeps? do
    not (Code.ensure_loaded?(Mix) and Mix.env() == :test)
  rescue
    _ -> true
  end

  defp uri_string(%URI{} = uri), do: Ezagent.URI.stable_key(uri)
  defp uri_string(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> uri_string()
end
