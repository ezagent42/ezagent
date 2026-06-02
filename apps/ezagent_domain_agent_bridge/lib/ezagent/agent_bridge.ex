defmodule Ezagent.AgentBridge do
  @moduledoc """
  Domain facade for delivering chat payloads to bridge-backed agents.
  """

  require Logger

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  @spec deliver(URI.t(), Payload.t()) :: :ok | {:error, term()}
  def deliver(%URI{} = agent_uri, %Payload{} = payload) do
    with {:ok, channel_pid} <- lookup_channel(agent_uri),
         {:ok, flavor} <- derive_flavor(agent_uri),
         :ok <- AdapterRegistry.deliver_or_buffer(flavor, payload, channel_pid) do
      :ok
    else
      {:error, reason} -> drop(agent_uri, payload, reason)
    end
  end

  @default_ready_timeout_ms 15_000

  @doc """
  Deliver, self-healing a vanished bridge first (PR-DR — blocker #1).

  When a bridge-backed agent's claude/python subprocess exits, its WS
  `Channel.terminate/2` unbinds the Registry row and nothing proactively
  relaunches it; a routed message then `:no_bridge`-drops silently. This
  variant, on a missing bridge, runs `ensure_ready/2` (relaunch + await the
  rebind, bounded) and retries delivery ONCE. If the bridge still can't be
  restored it drops AS BEFORE (logged + telemetry) — no degraded masking
  beyond one bounded retry (`feedback_let_it_crash_no_workarounds`).

  `heal_fn` is the injectable relaunch step (DI): a 1-arity fn that, given the
  agent URI, makes the agent's subprocess (re)start so its bridge re-joins.
  The caller supplies it (it has the Kind's `template_class` +
  `respawn_template_data` in dispatch ctx); defaults to the configured
  `:bridge_heal_fn`.
  """
  @spec deliver_ensuring(URI.t(), Payload.t(), (URI.t() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def deliver_ensuring(%URI{} = agent_uri, %Payload{} = payload, heal_fn \\ resolve_heal_fn())
      when is_function(heal_fn, 1) do
    case Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        deliver(agent_uri, payload)

      :error ->
        case ensure_ready(agent_uri, heal_fn) do
          :ok -> deliver(agent_uri, payload)
          {:error, reason} -> drop(agent_uri, payload, reason)
        end
    end
  end

  @doc """
  Ensure a bridge-backed agent's bridge is bound, relaunching it if absent.

  Already bound → `:ok`. Otherwise: subscribe to the Registry connect topic
  (subscribe-then-recheck to close the bind race), run `heal_fn` to trigger a
  subprocess relaunch, then await the `{:agent_bridge_connected, uri, _}`
  broadcast (or a lookup that becomes bound) up to `:bridge_ready_timeout_ms`.
  Returns `{:error, :timeout}` if no rebind, or the heal fn's `{:error, _}`.
  """
  @spec ensure_ready(URI.t(), (URI.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def ensure_ready(%URI{} = agent_uri, heal_fn \\ resolve_heal_fn())
      when is_function(heal_fn, 1) do
    case Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        topic = Registry.topic()
        :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

        try do
          # Re-check AFTER subscribing: if it bound in the gap we'd otherwise
          # miss the broadcast and wait the full timeout for nothing.
          case Registry.lookup(agent_uri) do
            {:ok, _pid} ->
              :ok

            :error ->
              case heal_fn.(agent_uri) do
                :ok -> await_bound(agent_uri, ready_timeout_ms())
                {:error, _reason} = err -> err
              end
          end
        after
          Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
        end
    end
  end

  defp await_bound(%URI{} = agent_uri, timeout) do
    case Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        receive do
          {:agent_bridge_connected, ^agent_uri, _info} -> :ok
        after
          timeout ->
            # Final lookup — the connect broadcast can race the receive window.
            case Registry.lookup(agent_uri) do
              {:ok, _pid} -> :ok
              :error -> {:error, :timeout}
            end
        end
    end
  end

  defp resolve_heal_fn do
    case Application.get_env(:ezagent_domain_agent_bridge, :bridge_heal_fn) do
      fun when is_function(fun, 1) -> fun
      _ -> &default_heal/1
    end
  end

  defp ready_timeout_ms do
    Application.get_env(
      :ezagent_domain_agent_bridge,
      :bridge_ready_timeout_ms,
      @default_ready_timeout_ms
    )
  end

  # Default relaunch: ensure the agent Kind is running. If the Kind itself had
  # exited, `SpawnRegistry.spawn/1` restarts it and its `Sandbox.activate/2`
  # re-runs `ensure_subprocess_alive/2`. The "Kind alive but subprocess dead"
  # case is healed by the richer ctx-derived heal_fn the dispatch caller passes
  # (it has the Kind's template_class + respawn_template_data); this default is
  # the dependency-free fallback. Runs out-of-Kind-process safe (SpawnRegistry
  # is a separate process — no self-call).
  defp default_heal(%URI{} = agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} -> :ok
      {:error, {:no_spawn_fn, _scheme}} -> {:error, :no_spawn_fn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_channel(agent_uri) do
    case Registry.lookup(agent_uri) do
      {:ok, channel_pid} -> {:ok, channel_pid}
      :error -> {:error, :no_bridge}
    end
  end

  defp drop(agent_uri, payload, reason) do
    Logger.warning(
      "AgentBridge deliver dropped for #{URI.to_string(agent_uri)}: #{inspect(reason)}. " <>
        "Message from #{URI.to_string(payload.sender_uri)}: " <>
        String.slice(payload.text || "", 0, 80)
    )

    :telemetry.execute(
      [:ezagent, :agent_bridge, :deliver, :dropped],
      %{count: 1},
      %{
        recipient: agent_uri,
        sender: payload.sender_uri,
        event_type: payload.event_type,
        reason: reason
      }
    )

    {:error, reason}
  end

  defp derive_flavor(%URI{scheme: "entity", host: "agent", path: "/" <> rest})
       when rest != "" do
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [flavor, suffix] when flavor != "" and suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      {:ok, flavor}
    else
      _ -> {:error, :unknown_agent_flavor}
    end
  end

  defp derive_flavor(_), do: {:error, :unknown_agent_flavor}
end
