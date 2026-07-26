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

    outcome =
      with_transition_locks(agent_uri, fn ->
        incarnation = current_incarnation(agent_uri)

        true =
          :ets.insert(
            @table,
            {URI.to_string(agent_uri), timeout_ms, generation, incarnation}
          )

        :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)
        :ok = TransportReadinessListener.arm_timeout(agent_uri, timeout_ms, generation)

        # Close the arm/event ordering window: a bridge may already be live, or
        # its broadcast may have raced this critical section. Pending →
        # transport is the single lock order shared with the core ready edge.
        if transport_joined?(agent_uri) do
          {_status, stale_entries, failed_entries} =
            settle_join_event_locked(agent_uri, incarnation)

          :ok = clear_generation_locked(agent_uri, generation)
          {:ok, stale_entries, failed_entries}
        else
          {:ok, [], []}
        end
      end)

    finalize_transition(agent_uri, outcome)
  end

  @doc false
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = agent_uri) do
    init()

    with_transport_lock(agent_uri, fn ->
      case readiness_record(agent_uri) do
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

    outcome =
      with_transition_locks(agent_uri, fn ->
        case readiness_record(agent_uri) do
          {:current, _timeout_ms, generation, expected_incarnation, _record} ->
            current_incarnation = current_incarnation(agent_uri)

            cond do
              not incarnation_matches?(expected_incarnation, current_incarnation) ->
                discard_stale_record(agent_uri, generation)
                {:ok, [], []}

              transport_joined?(agent_uri) ->
                {_status, stale_entries, failed_entries} =
                  settle_join_event_locked(agent_uri, expected_incarnation)

                :ok = clear_generation_locked(agent_uri, generation)
                {:ok, stale_entries, failed_entries}

              true ->
                # A queued bind event can arrive after the bridge unbound. Keep
                # the generation armed; only current registry truth may settle it.
                {:ok, [], []}
            end

          :none ->
            {:ok, [], []}
        end
      end)

    finalize_transition(agent_uri, outcome)
  end

  defp armed?(%URI{} = agent_uri) do
    :ets.lookup(@table, URI.to_string(agent_uri)) != []
  end

  @doc false
  @spec defer_ready?(URI.t() | String.t()) :: :ready | {:defer, pos_integer()}
  def defer_ready?(uri) do
    agent_uri = normalize_uri(uri)
    init()

    with_transport_lock(agent_uri, fn ->
      case readiness_decision(agent_uri) do
        {:defer, timeout_ms, _generation, _incarnation} -> {:defer, timeout_ms}
        :ready -> :ready
      end
    end)
  end

  @doc false
  @spec await_transport_or_fail(URI.t() | String.t()) ::
          :ok | {:error, :timeout | :superseded}
  def await_transport_or_fail(uri) do
    agent_uri = normalize_uri(uri)

    case agent_uri do
      nil ->
        :ok

      %URI{} ->
        outcome =
          with_transition_locks(agent_uri, fn ->
            case readiness_decision(agent_uri) do
              :ready ->
                if armed?(agent_uri) and transport_joined?(agent_uri) do
                  case readiness_record(agent_uri) do
                    {:current, _, generation, expected_incarnation, _} ->
                      {_status, stale_entries, failed_entries} =
                        settle_join_event_locked(agent_uri, expected_incarnation)

                      :ok = clear_generation_locked(agent_uri, generation)
                      {:ready, stale_entries, failed_entries}

                    :none ->
                      {:ready, [], []}
                  end
                else
                  {:ready, [], []}
                end

              deferred ->
                {deferred, [], []}
            end
          end)

        decision = finalize_transition(agent_uri, outcome)

        case decision do
          :ready ->
            :ok

          {:defer, timeout_ms, generation, expected_incarnation} ->
            deadline = System.monotonic_time(:millisecond) + timeout_ms
            await_join(agent_uri, deadline, generation, expected_incarnation)
        end
    end
  end

  defp await_join(agent_uri, deadline, generation, waiter_incarnation) do
    outcome =
      with_transition_locks(agent_uri, fn ->
        case readiness_record(agent_uri) do
          {:current, _timeout_ms, ^generation, expected_incarnation, _record} ->
            cond do
              not incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) ->
                discard_stale_record(agent_uri, generation)
                {{:done, {:error, :superseded}}, [], []}

              transport_joined?(agent_uri) ->
                {_status, stale_entries, failed_entries} =
                  settle_join_event_locked(agent_uri, expected_incarnation)

                :ok = clear_generation_locked(agent_uri, generation)
                {{:done, :ok}, stale_entries, failed_entries}

              System.monotonic_time(:millisecond) >= deadline ->
                failed_entries =
                  fail_current_generation_locked(agent_uri, generation, expected_incarnation)

                {{:done, {:error, :timeout}}, [], failed_entries}

              true ->
                {:wait, [], []}
            end

          :none ->
            # Clearing the only gate releases this Kind; the core waiter may
            # complete the ordinary ready transition.
            {{:done, :ok}, [], []}

          {:current, timeout_ms, newer_generation, ^waiter_incarnation, _record}
          when is_pid(waiter_incarnation) ->
            if current_incarnation(agent_uri) == waiter_incarnation do
              # Same live Kind re-armed its transport contract. Follow the
              # newest generation so the original Kind.Server waiter still
              # receives the eventual :ok and runs Lifecycle activated/2.
              new_deadline = System.monotonic_time(:millisecond) + timeout_ms
              {{:follow, new_deadline, newer_generation}, [], []}
            else
              {{:done, {:error, :superseded}}, [], []}
            end

          _replacement_or_legacy_rearm ->
            {{:done, {:error, :superseded}}, [], []}
        end
      end)

    result = finalize_transition(agent_uri, outcome)

    case result do
      {:done, result} ->
        result

      :wait ->
        Process.sleep(@poll_ms)
        await_join(agent_uri, deadline, generation, waiter_incarnation)

      {:follow, new_deadline, newer_generation} ->
        await_join(agent_uri, new_deadline, newer_generation, waiter_incarnation)
    end
  end

  defp readiness_decision(nil), do: :ready

  defp readiness_decision(%URI{} = agent_uri) do
    case readiness_record(agent_uri) do
      {:current, timeout_ms, generation, expected_incarnation, _record} ->
        if incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) do
          if transport_joined?(agent_uri) do
            :ready
          else
            {:defer, timeout_ms, generation, expected_incarnation}
          end
        else
          discard_stale_record(agent_uri, generation)
          :ready
        end

      :none ->
        :ready
    end
  end

  @doc false
  @spec timeout_generation(URI.t(), reference()) :: :ok
  def timeout_generation(%URI{} = agent_uri, generation) when is_reference(generation) do
    init()

    outcome =
      with_transition_locks(agent_uri, fn ->
        case readiness_record(agent_uri) do
          {:current, _timeout_ms, ^generation, expected_incarnation, _record} ->
            cond do
              Ezagent.ReadyGate.status(agent_uri) != :not_ready ->
                {:ok, [], []}

              not incarnation_matches?(expected_incarnation, current_incarnation(agent_uri)) ->
                discard_stale_record(agent_uri, generation)
                {:ok, [], []}

              transport_joined?(agent_uri) ->
                {_status, stale_entries, failed_entries} =
                  settle_join_event_locked(agent_uri, expected_incarnation)

                :ok = clear_generation_locked(agent_uri, generation)
                {:ok, stale_entries, failed_entries}

              true ->
                failed_entries =
                  fail_current_generation_locked(agent_uri, generation, expected_incarnation)

                {:ok, [], failed_entries}
            end

          _stale_or_cleared ->
            {:ok, [], []}
        end
      end)

    finalize_transition(agent_uri, outcome)
  end

  defp fail_current_generation_locked(agent_uri, generation, expected_incarnation) do
    case readiness_record(agent_uri) do
      {:current, _timeout_ms, ^generation, ^expected_incarnation, _record} ->
        Ezagent.Kind.ReadyTransition.mark_failed_locked(URI.to_string(agent_uri))

      _changed ->
        []
    end
  end

  # Caller holds PendingDelivery first, then the transport-generation lock.
  # Detached rows are returned so DLQ I/O happens after both locks release.
  defp settle_join_event_locked(agent_uri, expected_incarnation) do
    case Ezagent.ReadyGate.status(agent_uri) do
      :not_ready ->
        # A bridge event without its Kind is a late/stale incarnation, not a
        # success. Failing it drains authority-bearing artifacts so a later
        # entity at the same URI cannot absorb them.
        # V5 A1c — the incarnation token is resolved through the sanctioned
        # seam (`Runtime.Resolver.pid_for/1`, the chunk3 monitor-site
        # precedent): no URI-native face can express pid-identity
        # ("is this the SAME Kind process that armed the gate"), and the
        # token only ever flows back INTO the actor seam
        # (`ReadyTransition.drain_pending_then_mark_ready_locked/2`, which
        # partitions buffered casts BY incarnation pid). It never crosses
        # this module's public boundary.
        case {expected_incarnation, Ezagent.Runtime.Resolver.pid_for(agent_uri)} do
          {expected_pid, {:ok, registered_pid}}
          when is_pid(expected_pid) and registered_pid == expected_pid ->
            settle_registered_incarnation_locked(agent_uri, expected_pid)

          {:legacy, {:ok, pid}} when is_pid(pid) ->
            settle_registered_incarnation_locked(agent_uri, pid)

          {:unregistered, :not_found} ->
            failed_entries =
              Ezagent.Kind.ReadyTransition.mark_failed_locked(URI.to_string(agent_uri))

            {:failed, [], failed_entries}

          _replacement_or_stale_record ->
            # Registration + its initial :not_ready publication now takes the
            # outer PendingDelivery lock. A mismatch here is therefore a record
            # that was already stale before this transition began; never mutate
            # the replacement's URI gate from the old generation.
            {:superseded, [], []}
        end

      _already_settled ->
        {:settled, [], []}
    end
  end

  defp settle_registered_incarnation_locked(agent_uri, pid) do
    if Process.alive?(pid) do
      {status, stale_entries} =
        Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready_locked(
          URI.to_string(agent_uri),
          pid
        )

      {status, stale_entries, []}
    else
      failed_entries =
        Ezagent.Kind.ReadyTransition.mark_failed_locked(URI.to_string(agent_uri))

      {:failed, [], failed_entries}
    end
  end

  defp readiness_record(%URI{} = agent_uri) do
    case :ets.lookup(@table, URI.to_string(agent_uri)) do
      [{_, timeout_ms, generation, incarnation} = record] ->
        {:current, timeout_ms, generation, incarnation, record}

      # Hot-upgrade tolerance for rows armed by the pre-S7 process.
      [{_, timeout_ms, generation} = record] ->
        {:current, timeout_ms, generation, :legacy, record}

      [{_, timeout_ms} = record] ->
        {:current, timeout_ms, :legacy, :legacy, record}

      [] ->
        :none
    end
  end

  # The current incarnation token of `agent_uri`'s Kind — the pid, used
  # ONLY as an opaque identity token (compared for equality, handed back to
  # the actor seam; see `settle_join_event_locked/2`). Resolved through
  # `Runtime.Resolver.pid_for/1` (V5 A1c, sanctioned seam face).
  defp current_incarnation(%URI{} = agent_uri) do
    case Ezagent.Runtime.Resolver.pid_for(agent_uri) do
      {:ok, pid} when is_pid(pid) -> pid
      :not_found -> :unregistered
    end
  end

  defp incarnation_matches?(:legacy, _current), do: true
  defp incarnation_matches?(expected, expected), do: true
  defp incarnation_matches?(_expected, _current), do: false

  defp discard_stale_record(agent_uri, generation) do
    clear_generation_locked(agent_uri, generation)
  end

  defp clear_generation_locked(agent_uri, generation) do
    case readiness_record(agent_uri) do
      {:current, _timeout_ms, ^generation, _incarnation, record} ->
        # `delete_object` cannot erase a concurrent re-arm with a new
        # generation, unlike a blind `delete(key)`.
        :ets.delete_object(@table, record)

      _newer_or_cleared ->
        :ok
    end

    :ok = TransportReadinessListener.cancel_timeout(agent_uri, generation)
    :ok
  end

  @doc false
  @spec generation_current?(URI.t(), reference()) :: boolean()
  def generation_current?(%URI{} = agent_uri, generation) when is_reference(generation) do
    init()
    current_generation(agent_uri) == generation
  end

  defp current_generation(%URI{} = agent_uri) do
    case readiness_record(agent_uri) do
      {:current, _timeout_ms, generation, _incarnation, _record} -> generation
      _ -> :any
    end
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

  defp with_transition_locks(%URI{} = agent_uri, fun) when is_function(fun, 0) do
    Ezagent.PendingDelivery.with_lock(agent_uri, fn ->
      with_transport_lock(agent_uri, fun)
    end)
  end

  defp finalize_transition(%URI{} = agent_uri, {result, stale_entries, failed_entries}) do
    uri_str = URI.to_string(agent_uri)
    :ok = Ezagent.Kind.ReadyTransition.dead_letter_stale_entries(uri_str, stale_entries)
    :ok = Ezagent.Kind.ReadyTransition.dead_letter_failed_entries(uri_str, failed_entries)
    result
  end

  defp with_transport_lock(agent_uri, fun) when is_function(fun, 0) do
    lock_key = uri_string(agent_uri)
    :global.trans({{__MODULE__, lock_key}, self()}, fun, [node()])
  end

  defp uri_string(%URI{} = agent_uri), do: URI.to_string(agent_uri)
  defp uri_string(_agent_uri), do: :invalid_uri
end
