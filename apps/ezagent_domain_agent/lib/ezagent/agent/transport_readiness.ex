defmodule Ezagent.Agent.TransportReadiness do
  @moduledoc """
  Domain-agent transport readiness contract for bridge-backed agents.

  A bridge-backed agent's Kind process being alive is not enough to receive
  routed messages. The transport bridge must join first. This module keeps that
  readiness requirement generic and keyed by `agent_uri`.
  """

  alias Ezagent.Agent.LiveJoinRegistry

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
    true = :ets.insert(@table, {URI.to_string(agent_uri), timeout_ms})
    :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)
  end

  @doc false
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = agent_uri) do
    init()
    :ets.delete(@table, URI.to_string(agent_uri))
    :ok
  end

  @doc false
  @spec defer_ready?(URI.t() | String.t()) :: :ready | {:defer, pos_integer()}
  def defer_ready?(uri) do
    agent_uri = normalize_uri(uri)
    init()

    cond do
      agent_uri == nil ->
        :ready

      LiveJoinRegistry.joined?(agent_uri) ->
        :ready

      true ->
        case :ets.lookup(@table, URI.to_string(agent_uri)) do
          [{_, timeout_ms}] -> {:defer, timeout_ms}
          [] -> :ready
        end
    end
  end

  @doc false
  @spec await_transport_or_fail(URI.t() | String.t()) :: :ok | {:error, :timeout}
  def await_transport_or_fail(uri) do
    agent_uri = normalize_uri(uri)

    case agent_uri do
      nil ->
        :ok

      %URI{} ->
        timeout_ms =
          case defer_ready?(agent_uri) do
            :ready -> 0
            {:defer, ms} -> ms
          end

        if timeout_ms == 0 do
          mark_ready(agent_uri)
        else
          deadline = System.monotonic_time(:millisecond) + timeout_ms
          await_join(agent_uri, deadline)
        end
    end
  end

  defp await_join(agent_uri, deadline) do
    if LiveJoinRegistry.joined?(agent_uri) do
      mark_ready(agent_uri)
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        :ok = Ezagent.ReadyGate.mark_failed(agent_uri)
        {:error, :timeout}
      else
        Process.sleep(@poll_ms)
        await_join(agent_uri, deadline)
      end
    end
  end

  defp mark_ready(agent_uri) do
    :ok = Ezagent.ReadyGate.mark_ready(agent_uri)
  end

  defp normalize_uri(%URI{} = uri), do: uri

  defp normalize_uri(uri) when is_binary(uri) do
    Ezagent.URI.new!(uri)
  rescue
    ArgumentError -> nil
  end

  defp normalize_uri(_), do: nil
end
