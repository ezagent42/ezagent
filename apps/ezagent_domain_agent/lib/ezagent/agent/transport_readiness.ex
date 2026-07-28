defmodule Ezagent.Agent.TransportReadiness do
  @moduledoc """
  Generation-safe transport status tracking for bridge-backed agents.

  An agent Kind becoming ready and its bridge transport joining are independent
  facts. `Ezagent.ReadyGate` is owned exclusively by the Kind lifecycle; this
  module records transport-join status so CC can observe a real bridge join
  without delaying Kind readiness or failing a ready Kind when a bridge is
  unavailable.

  A tracked transport is joined when either the orchestrator MCP bridge is in
  `Ezagent.Agent.LiveJoinRegistry` or a live process is bound in
  `Ezagent.AgentBridge.Registry`. Records are generation- and incarnation-
  scoped: joins and timeouts clear only their matching current record, and a
  stale record is discarded without affecting a replacement Kind at the same
  URI.
  """

  alias Ezagent.Agent.LiveJoinRegistry
  alias Ezagent.Agent.TransportReadinessListener
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @table :ezagent_agent_transport_readiness
  @default_timeout_ms 5_000
  @poll_ms 10

  @doc false
  @spec init() :: :ok
  def init do
    LiveJoinRegistry.init()

    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec require_transport_join(URI.t(), keyword()) :: :ok
  def require_transport_join(%URI{} = agent_uri, opts \\ []) do
    init()
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    generation = make_ref()

    with_transport_lock(agent_uri, fn ->
      incarnation = current_incarnation(agent_uri)

      true =
        :ets.insert(
          @table,
          {URI.to_string(agent_uri), timeout_ms, generation, incarnation}
        )

      :ok = TransportReadinessListener.arm_timeout(agent_uri, timeout_ms, generation)

      if transport_joined?(agent_uri) do
        clear_generation_locked(agent_uri, generation)
      else
        :ok
      end
    end)
  end

  @doc false
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = agent_uri) do
    init()

    with_transport_lock(agent_uri, fn ->
      case transport_record(agent_uri) do
        {:current, _timeout_ms, generation, _incarnation, _record} ->
          clear_generation_locked(agent_uri, generation)

        :none ->
          :ok
      end
    end)
  end

  @doc false
  @spec clear_generation(URI.t(), reference()) :: :ok
  def clear_generation(%URI{} = agent_uri, generation) when is_reference(generation) do
    init()
    with_transport_lock(agent_uri, fn -> clear_generation_locked(agent_uri, generation) end)
  end

  @doc """
  Clears the matching transport record after a live bridge-join event.

  A queued event is authoritative only while the registered Kind incarnation
  still matches and the registry still reports a live transport.
  """
  @spec on_transport_joined(URI.t()) :: :ok
  def on_transport_joined(%URI{} = agent_uri) do
    init()

    with_transport_lock(agent_uri, fn ->
      case transport_record(agent_uri) do
        {:current, _timeout_ms, generation, expected_incarnation, _record} ->
          cond do
            not incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) ->
              clear_generation_locked(agent_uri, generation)

            transport_joined?(agent_uri) ->
              clear_generation_locked(agent_uri, generation)

            true ->
              :ok
          end

        :none ->
          :ok
      end
    end)
  end

  @doc false
  @spec defer_ready?(URI.t() | String.t()) :: :ready
  def defer_ready?(_uri), do: :ready

  @doc false
  @spec await_transport_or_fail(URI.t() | String.t()) :: :ok
  def await_transport_or_fail(uri) do
    case normalize_uri(uri) do
      nil -> :ok
      agent_uri -> await_join(agent_uri)
    end
  end

  defp await_join(agent_uri) do
    result =
      with_transport_lock(agent_uri, fn ->
        case transport_record(agent_uri) do
          {:current, timeout_ms, generation, expected_incarnation, _record} ->
            cond do
              not incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) ->
                clear_generation_locked(agent_uri, generation)
                :done

              transport_joined?(agent_uri) ->
                clear_generation_locked(agent_uri, generation)
                :done

              true ->
                {:wait, System.monotonic_time(:millisecond) + timeout_ms, generation,
                 expected_incarnation}
            end

          :none ->
            :done
        end
      end)

    case result do
      :done ->
        :ok

      {:wait, deadline, generation, incarnation} ->
        await_join(agent_uri, deadline, generation, incarnation)
    end
  end

  defp await_join(agent_uri, deadline, generation, waiter_incarnation) do
    result =
      with_transport_lock(agent_uri, fn ->
        case transport_record(agent_uri) do
          {:current, _timeout_ms, ^generation, expected_incarnation, _record} ->
            cond do
              not incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) ->
                clear_generation_locked(agent_uri, generation)
                :done

              transport_joined?(agent_uri) ->
                clear_generation_locked(agent_uri, generation)
                :done

              System.monotonic_time(:millisecond) >= deadline ->
                clear_generation_locked(agent_uri, generation)
                :done

              true ->
                :wait
            end

          {:current, timeout_ms, newer_generation, ^waiter_incarnation, _record}
          when is_pid(waiter_incarnation) ->
            if current_incarnation(agent_uri) == waiter_incarnation do
              {:follow, System.monotonic_time(:millisecond) + timeout_ms, newer_generation}
            else
              :done
            end

          _stale_or_cleared ->
            :done
        end
      end)

    case result do
      :done ->
        :ok

      :wait ->
        Process.sleep(@poll_ms)
        await_join(agent_uri, deadline, generation, waiter_incarnation)

      {:follow, new_deadline, newer_generation} ->
        await_join(agent_uri, new_deadline, newer_generation, waiter_incarnation)
    end
  end

  @doc false
  @spec timeout_generation(URI.t(), reference()) :: :ok
  def timeout_generation(%URI{} = agent_uri, generation) when is_reference(generation) do
    init()

    with_transport_lock(agent_uri, fn ->
      case transport_record(agent_uri) do
        {:current, _timeout_ms, ^generation, _expected_incarnation, _record} ->
          clear_generation_locked(agent_uri, generation)

        _stale_or_cleared ->
          :ok
      end
    end)
  end

  @doc false
  @spec generation_current?(URI.t(), reference()) :: boolean()
  def generation_current?(%URI{} = agent_uri, generation) when is_reference(generation) do
    init()
    current_generation(agent_uri) == generation
  end

  @doc false
  @spec transport_joined?(URI.t()) :: boolean()
  def transport_joined?(%URI{} = agent_uri) do
    init()
    LiveJoinRegistry.joined?(agent_uri) or bridge_bound?(agent_uri)
  end

  defp transport_record(%URI{} = agent_uri) do
    case :ets.lookup(@table, URI.to_string(agent_uri)) do
      [{_, timeout_ms, generation, incarnation} = record] ->
        {:current, timeout_ms, generation, incarnation, record}

      # Hot-upgrade tolerance for records armed by an earlier release.
      [{_, timeout_ms, generation} = record] ->
        {:current, timeout_ms, generation, :legacy, record}

      [{_, timeout_ms} = record] ->
        {:current, timeout_ms, :legacy, :legacy, record}

      [] ->
        :none
    end
  end

  defp current_incarnation(%URI{} = agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, pid} when is_pid(pid) -> pid
      _ -> :unregistered
    end
  end

  defp incarnation_matches?(:legacy, _current), do: true
  defp incarnation_matches?(expected, expected), do: true
  defp incarnation_matches?(_expected, _current), do: false

  defp clear_generation_locked(agent_uri, generation) do
    case transport_record(agent_uri) do
      {:current, _timeout_ms, ^generation, _incarnation, record} ->
        :ets.delete_object(@table, record)

      _newer_or_cleared ->
        :ok
    end

    :ok = TransportReadinessListener.cancel_timeout(agent_uri, generation)
    :ok
  end

  defp current_generation(%URI{} = agent_uri) do
    case transport_record(agent_uri) do
      {:current, _timeout_ms, generation, _incarnation, _record} -> generation
      _ -> :any
    end
  end

  defp bridge_bound?(%URI{} = agent_uri) do
    case BridgeRegistry.lookup(agent_uri) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  defp normalize_uri(%URI{} = uri), do: uri

  defp normalize_uri(uri) when is_binary(uri) do
    Ezagent.URI.new!(uri)
  rescue
    ArgumentError -> nil
  end

  defp normalize_uri(_), do: nil

  defp with_transport_lock(agent_uri, fun) when is_function(fun, 0) do
    :global.trans({{__MODULE__, uri_string(agent_uri)}, self()}, fun, [node()])
  end

  defp uri_string(%URI{} = agent_uri), do: URI.to_string(agent_uri)
end
