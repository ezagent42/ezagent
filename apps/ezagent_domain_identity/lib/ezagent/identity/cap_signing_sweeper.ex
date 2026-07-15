defmodule Ezagent.Identity.CapSigningSweeper do
  @moduledoc """
  Supervised cold-entity backstop for the capability-signing drain.

  Every pass reads the same four durable sources as `CapSigningAudit`, groups
  byte-identical unsigned artifacts by holder, and re-enqueues their domain-
  owned reconciliation plans through the durable capability outbox. Durable
  state is never rewritten here; exact-artifact CAS remains in the heal worker.

  A failed enqueue leaves the source artifact untouched, so the next periodic
  pass discovers it again. Malformed entries remain visible to strict audit and
  are reported, never guessed at or blind-signed.
  """

  use GenServer

  require Logger

  alias Ezagent.Capability
  alias Ezagent.Identity.{CapReconciler, CapSelfHeal, CapSigningAudit}

  @cap_sources [:users_caps_json, :kind_snapshots, :recipe_cap_bindings]
  @default_interval_ms 15 * 60 * 1000

  @type result :: %{
          scanned_sources: 4,
          candidates: non_neg_integer(),
          holders: non_neg_integer(),
          enqueued_holders: non_neg_integer(),
          enqueue_errors: [{URI.t(), term()}],
          unrepairable_entries: non_neg_integer(),
          open_quarantined: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    interval_ms = opts[:interval_ms] || configured_interval_ms()
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case safe_sweep() do
      %{enqueue_errors: [], unrepairable_entries: 0} ->
        :ok

      result ->
        Logger.warning("cap signing sweep incomplete; retrying next tick: #{inspect(result)}")
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  @doc "Run one synchronous four-source enumeration and enqueue pass."
  @spec sweep() :: result()
  def sweep do
    CapSigningAudit.collect_entries()
    |> sweep_entries(&enqueue_plan/2)
  end

  @doc false
  @spec sweep_entries(map(), (URI.t(), CapReconciler.plan() -> :ok | {:error, term()})) ::
          result()
  def sweep_entries(entries, enqueue_fun) when is_map(entries) and is_function(enqueue_fun, 2) do
    {grouped, unrepairable_entries} = collect_candidates(entries)

    initial = %{
      scanned_sources: 4,
      candidates: grouped |> Map.values() |> Enum.sum_by(&length/1),
      holders: map_size(grouped),
      enqueued_holders: 0,
      enqueue_errors: [],
      unrepairable_entries: unrepairable_entries,
      open_quarantined: count_open_quarantine(entries)
    }

    grouped
    |> Enum.sort_by(fn {holder, _caps} ->
      {holder.scheme, holder.userinfo, holder.host, holder.port, holder.path, holder.query,
       holder.fragment}
    end)
    |> Enum.reduce(initial, fn {holder, caps}, result ->
      plan = CapReconciler.plan(caps, holder)

      case safe_enqueue(enqueue_fun, holder, plan) do
        :ok ->
          %{result | enqueued_holders: result.enqueued_holders + 1}

        {:error, reason} ->
          %{result | enqueue_errors: [{holder, reason} | result.enqueue_errors]}
      end
    end)
    |> Map.update!(:enqueue_errors, &Enum.reverse/1)
  end

  defp collect_candidates(entries) do
    Enum.reduce(@cap_sources, {%{}, 0}, fn source, acc ->
      entries
      |> Map.get(source, [])
      |> Enum.reduce(acc, &collect_entry/2)
    end)
  end

  defp collect_entry(%{excluded: _reason}, acc), do: acc

  defp collect_entry(%{error: _reason}, {grouped, malformed}) do
    {grouped, malformed + 1}
  end

  defp collect_entry(
         %{holder_uri: %URI{} = holder, cap: %Capability{} = cap},
         {grouped, malformed}
       ) do
    cond do
      sentinel?(cap) ->
        {grouped, malformed}

      Ezagent.Cap.signed_and_valid?(cap, holder) ->
        {grouped, malformed}

      true ->
        updated =
          Map.update(grouped, holder, [cap], fn caps ->
            if Enum.any?(caps, &(&1 === cap)), do: caps, else: [cap | caps]
          end)

        {updated, malformed}
    end
  end

  defp collect_entry(_entry, {grouped, malformed}), do: {grouped, malformed + 1}

  defp sentinel?(%Capability{} = cap) do
    cap.granted_by == :plugin_declared or cap.granted_at == :compile_time
  end

  defp count_open_quarantine(entries) do
    entries
    |> Map.get(:cap_quarantine, [])
    |> Enum.count(&match?(%{status: :open}, &1))
  end

  defp safe_enqueue(enqueue_fun, holder, plan) do
    enqueue_fun.(holder, plan)
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp enqueue_plan(holder, plan) do
    with {:ok, _state} <- ensure_holder_live(holder) do
      CapSelfHeal.enqueue_plan(holder, plan)
    end
  end

  defp ensure_holder_live(holder) do
    case Ezagent.LocalRuntime.ensure_live(holder) do
      {:ok, _state} = ok ->
        ok

      {:error, :not_created} ->
        spawn_seeded_user(holder)

      {:error, reason} ->
        {:error, {:ensure_live_failed, reason}}
    end
  end

  # A provisioning-row User may be genuinely durable while still having no
  # snapshot because it has never activated. The audit candidate came from its
  # caps_json seed, so spawning that existing User is the required cold-start
  # path. Other entity kinds need a snapshot-backed durable existence proof.
  defp spawn_seeded_user(holder) do
    if Ezagent.URI.type?(holder, :user) and Ezagent.Users.get_by_uri(holder) do
      case Ezagent.LocalRuntime.ensure_started(holder) do
        {:ok, _pid} -> {:ok, :spawned_seeded_user}
        {:error, reason} -> {:error, {:seeded_user_spawn_failed, reason}}
      end
    else
      {:error, {:ensure_live_failed, :not_created}}
    end
  end

  defp safe_sweep do
    sweep()
  rescue
    error ->
      Logger.warning(
        "cap signing sweep failed before enqueue; retrying next tick: #{inspect(error)}"
      )

      %{
        scanned_sources: 4,
        candidates: 0,
        holders: 0,
        enqueued_holders: 0,
        enqueue_errors: [{Ezagent.Entity.User.admin_uri(), {:sweep_failed, error.__struct__}}],
        unrepairable_entries: 0,
        open_quarantined: 0
      }
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp configured_interval_ms do
    Application.get_env(
      :ezagent_domain_identity,
      :cap_signing_sweep_interval_ms,
      @default_interval_ms
    )
  end
end
