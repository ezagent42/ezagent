defmodule Ezagent.Agent.TransportReadiness do
  @moduledoc """
  Domain-agent transport readiness contract for bridge-backed agents.

  A bridge-backed agent's Kind process being alive is not enough to receive
  routed messages. The transport bridge must join first. This module keeps that
  readiness requirement generic and keyed by `agent_uri`.

  ## Two transport-join signals (both satisfy readiness)

  An agent is "transport-joined" when EITHER:

  1. `Ezagent.Agent.LiveJoinRegistry.joined?/1` is true — the orchestrator MCP
     bridge (`orch:bridge:<uri>`) joined end-to-end. Marked ONLY by
     `Ezagent.Orchestrator.McpChannel` (orchestrator agents).
  2. `Ezagent.AgentBridge.Registry` holds a LIVE binding — the agent's chat
     transport bridge (`agent_bridge:<flavor>:<uri>` / `cc:bridge:<uri>`) joined
     end-to-end (PTY up → `claude` up → `esr-bridge` MCP connected → channel
     joined → bound). This is the readiness signal for a REGULAR (non-orchestrator)
     cc agent, whose `esr-bridge` MCP joins the chat channel, NOT `orch:bridge:`.

  Before this second source existed (#505), `require_transport_join` armed the
  gate for EVERY cc agent but only the orchestrator path ever marked a join — so
  a cold-activated REGULAR cc agent's ReadyGate flip deferred until the timeout
  and then `mark_failed`, even though its PTY/`claude`/bridge came up fine and
  bound in `AgentBridge.Registry`. Resolving on the actual bridge-bind event
  makes readiness fire on a real signal (not a timer), eliminating the race
  rather than widening a window.
  """

  alias Ezagent.Agent.LiveJoinRegistry
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

  @doc """
  React to a live transport-join event for `agent_uri` (an AgentBridge bind /
  orchestrator MCP join).

  If a transport-join gate is ARMED for this agent and its ReadyGate is still
  `:not_ready`, flip it to `:ready` now — the transport is live. This covers the
  ordering where the Kind announced `:ready` BEFORE the gate was armed (the
  FRESH-spawn / create path in `CcAgent.Spawn.spawn_for_local_pty`, where the
  Agent Kind is started first and `require_transport_join` runs AFTER the announce
  — so no `await_transport_or_fail` Task exists to observe the later bind). The
  rehydrate/activate path is covered by `await_transport_or_fail/1`; this is the
  event-driven complement so BOTH orderings reach `:ready` on the real bind.

  No-op when the agent has no armed gate (non-bridge-backed agents) or is already
  past `:not_ready`. Driven by `Ezagent.Agent.TransportReadinessListener`.
  """
  @spec on_transport_joined(URI.t()) :: :ok
  def on_transport_joined(%URI{} = agent_uri) do
    init()

    if armed?(agent_uri) and Ezagent.ReadyGate.status(agent_uri) == :not_ready do
      # Route through the CANONICAL completion path (`drain_pending_then_mark_ready`)
      # rather than a bare `mark_ready`, so any `:cast` buffered to `PendingDelivery`
      # while the gate sat `:not_ready` is FLUSHED to the live Kind — preserving the
      # not-ready→ready invariant (codex review). The drain casts buffered
      # invocations to the Kind pid, so we need it; if the Kind is not in the
      # registry (already gone), fall back to a bare mark (best-effort).
      case Ezagent.KindRegistry.lookup(agent_uri) do
        {:ok, pid} when is_pid(pid) ->
          _ = Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(URI.to_string(agent_uri), pid)
          :ok

        _ ->
          :ok = Ezagent.ReadyGate.mark_ready(agent_uri)
      end
    end

    :ok
  end

  defp armed?(%URI{} = agent_uri) do
    :ets.lookup(@table, URI.to_string(agent_uri)) != []
  end

  @doc false
  @spec defer_ready?(URI.t() | String.t()) :: :ready | {:defer, pos_integer()}
  def defer_ready?(uri) do
    agent_uri = normalize_uri(uri)
    init()

    cond do
      agent_uri == nil ->
        :ready

      transport_joined?(agent_uri) ->
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
    if transport_joined?(agent_uri) do
      mark_ready(agent_uri)
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        # Route through ReadyTransition (not ReadyGate directly) so any :cast
        # invocations still buffered for this never-joined agent are drained to
        # the DLQ instead of silently dropped (doc §8.1 / Invariant #9). This is
        # the real never-ready cc path (transport-join budget exhausted).
        :ok = Ezagent.Kind.ReadyTransition.mark_failed(agent_uri)
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

  # An agent's transport is joined when EITHER the orchestrator MCP bridge has
  # marked a live-join (LiveJoinRegistry, orchestrator agents) OR the agent's
  # chat transport bridge holds a LIVE binding in AgentBridge.Registry (the
  # regular cc/bridge path — #505). The alive check guards against a stale row
  # from a dead channel incarnation satisfying readiness before unbind runs.
  defp transport_joined?(%URI{} = agent_uri) do
    LiveJoinRegistry.joined?(agent_uri) or bridge_bound?(agent_uri)
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
end
