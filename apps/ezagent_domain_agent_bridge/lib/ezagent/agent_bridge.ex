defmodule Ezagent.AgentBridge do
  @moduledoc """
  Domain facade for delivering chat payloads to bridge-backed agents.
  """

  require Logger

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  @spec deliver(URI.t(), Payload.t()) :: :ok | {:ok, term()} | {:error, term()}
  def deliver(%URI{} = agent_uri, %Payload{} = payload) do
    case resolve_flavor(agent_uri) do
      {:ok, flavor} ->
        case AdapterRegistry.transport_class(flavor) do
          :in_process_sync ->
            # No subprocess, no WebSocket, no channel pid — deliver inline.
            deliver_in_process(agent_uri, payload, flavor)

          :subprocess_ws ->
            # Status-quo WS path, UNCHANGED ordering: channel-lookup first
            # (so a missing bridge surfaces as :no_bridge as before).
            with {:ok, channel_pid} <- lookup_channel(agent_uri),
                 :ok <- AdapterRegistry.deliver_or_buffer(flavor, payload, channel_pid) do
              :ok
            else
              {:error, reason} -> drop(agent_uri, payload, reason)
            end
        end

      {:error, _flavor_reason} ->
        # Flavor unresolved — only the WS transport is meaningful (default).
        # Preserve the pre-PR-0 ordering: surface :no_bridge before flavor.
        with {:ok, channel_pid} <- lookup_channel(agent_uri),
             {:ok, flavor} <- resolve_flavor(agent_uri),
             :ok <- AdapterRegistry.deliver_or_buffer(flavor, payload, channel_pid) do
          :ok
        else
          {:error, reason} -> drop(agent_uri, payload, reason)
        end
    end
  end

  @doc """
  Deliver when the caller already resolved the bridge flavor from trusted
  stored agent state.

  This exists for in-Kind `chat.receive`: the handler is already executing
  inside the target Agent Kind and can receive the `:sandbox` sibling slice
  from the runtime. Re-reading the same slice through `Kind.get_slice/2`
  would be a `GenServer.call(self)`.
  """
  @spec deliver_with_flavor(URI.t(), Payload.t(), String.t()) ::
          :ok | {:ok, term()} | {:error, term()}
  def deliver_with_flavor(%URI{} = agent_uri, %Payload{} = payload, flavor)
      when is_binary(flavor) and flavor != "" do
    case AdapterRegistry.transport_class(flavor) do
      :in_process_sync ->
        # No subprocess, no WebSocket, no channel pid — deliver synchronously
        # in-process. The result flows back to the owning Behavior (PR-6).
        deliver_in_process(agent_uri, payload, flavor)

      :subprocess_ws ->
        with {:ok, channel_pid} <- lookup_channel(agent_uri),
             :ok <- AdapterRegistry.deliver_or_buffer(flavor, payload, channel_pid) do
          :ok
        else
          {:error, reason} -> drop(agent_uri, payload, reason)
        end
    end
  end

  @doc """
  Synchronously ask a `curl`-flavor agent for an LLM completion and return the
  text. Reuses the `:in_process_sync` deliver primitive: the curl adapter reads
  the agent's OWN `:api_keys` + `:curl_agent` snapshot slices and does the HTTP
  round-trip — the CALLER never sees the API key.

  The PUBLIC entry is `Ezagent.Entity.Agent.complete/3` — it enforces the
  cap-gate (caller == agent owner OR caller holds `cap(Complete, :complete,
  agent_uri, ws)`, per lead #1239 finalize ①). This function is the THIN
  TRANSPORT body called from that gate.
  """
  @spec complete(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(%URI{} = agent_uri, prompt) when is_binary(prompt) do
    agent_uri_str = URI.to_string(agent_uri)

    payload = %Payload{
      message_id: "complete-" <> Integer.to_string(System.unique_integer([:positive])),
      session_uri: nil,
      sender_uri: agent_uri,
      text: prompt,
      event_type: :system,
      meta: %{"agent_uri" => agent_uri_str}
    }

    case deliver_with_flavor(agent_uri, payload, "curl") do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_complete_result, other}}
    end
  rescue
    e -> {:error, {:complete_raise, e}}
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
          :ok | {:ok, term()} | {:error, term()}
  def deliver_ensuring(%URI{} = agent_uri, %Payload{} = payload, heal_fn \\ resolve_heal_fn())
      when is_function(heal_fn, 1) do
    if in_process_sync?(agent_uri) do
      # :in_process_sync — no subprocess to heal, no readiness gate. Deliver
      # synchronously in-process (the readiness gate lives ONE LAYER UP here,
      # so the deliver/2 branch alone would not bypass it — codex MED-2).
      deliver(agent_uri, payload)
    else
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
  end

  @doc """
  `deliver_ensuring/3` variant for callers that already resolved flavor from
  stored state.
  """
  @spec deliver_ensuring_with_flavor(
          URI.t(),
          Payload.t(),
          String.t(),
          (URI.t() -> :ok | {:error, term()})
        ) :: :ok | {:ok, term()} | {:error, term()}
  def deliver_ensuring_with_flavor(
        %URI{} = agent_uri,
        %Payload{} = payload,
        flavor,
        heal_fn \\ resolve_heal_fn()
      )
      when is_binary(flavor) and flavor != "" and is_function(heal_fn, 1) do
    case AdapterRegistry.transport_class(flavor) do
      :in_process_sync ->
        # No subprocess to heal, no Registry row, no readiness gate — call the
        # adapter's deliver/2 synchronously in-process (codex MED-2 point 3).
        deliver_with_flavor(agent_uri, payload, flavor)

      :subprocess_ws ->
        case Registry.lookup(agent_uri) do
          {:ok, _pid} ->
            deliver_with_flavor(agent_uri, payload, flavor)

          :error ->
            case ensure_ready(agent_uri, heal_fn) do
              :ok -> deliver_with_flavor(agent_uri, payload, flavor)
              {:error, reason} -> drop(agent_uri, payload, reason)
            end
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

  # Default relaunch (PR-DR). Heals BOTH failure modes without a self-call
  # deadlock (this runs INSIDE the target Kind's dispatch process via
  # `Chat.handle_receive`, so reading the Kind's OWN live slice via
  # `Kind.get_slice/2` would deadlock — see kind/server.ex):
  #   1. Kind itself exited → `SpawnRegistry.spawn/1` restarts it (its
  #      `Sandbox.activate/2` re-runs `ensure_subprocess_alive/2`).
  #   2. Kind alive but the claude/python subprocess exited (the actual
  #      blocker #1) → read the persisted Sandbox slice from the SNAPSHOT
  #      STORE (a DB read, NOT a Kind call) for `template_class` +
  #      `respawn_template_data`, then call `template_class.ensure_subprocess_
  #      alive/2` — the same relaunch `Sandbox.activate/2` performs in-process,
  #      so it is safe to call here too. The relaunched bridge re-joins and
  #      `ensure_ready/2` observes the rebind via the Registry connect topic.
  defp default_heal(%URI{} = agent_uri) do
    with :ok <- ensure_kind_running(agent_uri),
         {:ok, template_class, respawn_data} <- load_sandbox_respawn(agent_uri) do
      template_class.ensure_subprocess_alive(agent_uri, respawn_data)
    end
  end

  defp ensure_kind_running(%URI{} = agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} -> :ok
      # Not a spawnable scheme (e.g. a flavor with no spawn_fn) — the
      # snapshot path below can still relaunch the subprocess if state exists.
      {:error, {:no_spawn_fn, _scheme}} -> :ok
      {:error, reason} -> {:error, {:ensure_kind_failed, reason}}
    end
  end

  # Read the persisted Sandbox slice for `agent_uri` without touching the live
  # Kind (snapshot store = DB). Returns the relaunch inputs only when a usable
  # `template_class` exporting `ensure_subprocess_alive/2` + a `respawn_data`
  # map are present; otherwise an error so `ensure_ready/2` fails loud (no shim).
  defp load_sandbox_respawn(%URI{} = agent_uri) do
    case Ezagent.SnapshotStore.latest(agent_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        sandbox = Ezagent.Kind.normalize_slice_view(Map.get(state, :sandbox, %{}))
        template_class = Map.get(sandbox, :template_class)
        respawn_data = Map.get(sandbox, :respawn_template_data)

        if is_atom(template_class) and not is_nil(template_class) and is_map(respawn_data) and
             Code.ensure_loaded?(template_class) and
             function_exported?(template_class, :ensure_subprocess_alive, 2) do
          {:ok, template_class, respawn_data}
        else
          {:error, :no_sandbox_respawn_state}
        end

      {:error, reason} ->
        {:error, {:snapshot_unavailable, reason}}
    end
  end

  defp lookup_channel(agent_uri) do
    case Registry.lookup(agent_uri) do
      {:ok, channel_pid} -> {:ok, channel_pid}
      :error -> {:error, :no_bridge}
    end
  end

  # :in_process_sync delivery — bypasses the Channel/Registry/readiness gate.
  # The adapter runs its work in-process (e.g. an HTTP round-trip) with a nil
  # channel ref and returns `{:ok, result}` / `{:error, reason}` synchronously.
  defp deliver_in_process(agent_uri, payload, flavor) do
    case AdapterRegistry.lookup(flavor) do
      {:ok, adapter} ->
        adapter.deliver(payload, nil)

      :error ->
        drop(agent_uri, payload, {:no_adapter, flavor})
    end
  end

  defp in_process_sync?(%URI{} = agent_uri) do
    case resolve_flavor(agent_uri) do
      {:ok, flavor} -> AdapterRegistry.transport_class(flavor) == :in_process_sync
      {:error, _} -> false
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

  defp resolve_flavor(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      :none -> {:error, :unknown_agent_flavor}
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:invalid_agent_flavor, other}}
    end
  end
end
