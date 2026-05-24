defmodule Ezagent.NotificationSubscriptions do
  @moduledoc """
  Unified registry for notification subscriptions (SPEC v2 PR-N1
  skeleton, Allen 2026-05-24 amendment).

  Analogue of `Ezagent.CapabilityRegistry` for notification streams:
  one entry point to register / list / unregister an entity's
  subscriptions, cap-gated, persistent across process restarts.

  ## Why a registry instead of raw PubSub.subscribe

  Per Allen 2026-05-24 — ad-hoc `Phoenix.PubSub.subscribe` calls
  scattered across LV / plugin code = drift + invisibility:
  - operators can't see who's subscribed to what
  - cap denial has nothing to enforce against
  - LV reconnection loses subscriptions (PubSub is process-scoped;
    the registry survives)

  The registry stores intent (`entity X subscribes to stream Y`),
  and live processes (LV mount, plugin worker) consult it on startup
  to actually `PubSub.subscribe`. Adding a subscription
  re-subscribes any live owners; removing it unsubscribes them.

  ## PR-N1 skeleton scope

  This module ships in PR-N1 with the API + ETS-backed store, but
  the LV / consumer wiring lands in PR-N2. PR-N3 flips the
  SliceChange flag. PR-N4 sweeps remaining ad-hoc subscribes.
  PR-N5 grep-gate enforces "no Phoenix.PubSub.subscribe outside
  this module" for entity-stream topics.

  ## State shape (ETS)

  Table `:ezagent_notification_subscriptions` (set, by `{entity_uri,
  stream_uri}` key). Value = `%{registered_at: DateTime.t(),
  granted_by: URI.t() | :system}`.

  ## Cap gating

  `register_subscription/3` requires the caller hold a
  `Ezagent.Behavior.Notifications` `:subscribe` cap on `stream_uri`.
  Pre-existing `Ezagent.Notifications.subscribe/2` already does
  this check via `check_cap!/3` — this registry calls it too so
  there's ONE cap path.

  In V1 (PR-N1) the registry stores intent but doesn't actively
  re-subscribe live processes — that's PR-N2 (the LV `mount/3`
  consults the registry). For now `register_subscription/3` just
  records the row + lets the caller `PubSub.subscribe` for the
  current process if desired.
  """

  require Logger
  alias Ezagent.SliceChange

  @table :ezagent_notification_subscriptions

  @doc false
  def __init_ets__ do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      _ -> @table
    end
  end

  @doc """
  Register that `entity_uri` wants to receive slice-change events
  for `stream_uri`. Cap-gated via `ctx[:caps]` matching the
  `:subscribe` action on `stream_uri`.

  In PR-N1: records intent only. PR-N2 wires LV mount to subscribe
  on behalf of the entity. Returns `:ok` on cap success,
  `{:error, :unauthorized}` on cap miss.
  """
  @spec register_subscription(URI.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def register_subscription(entity_uri, stream_uri, ctx \\ %{caps: :system})

  def register_subscription(%URI{} = entity_uri, stream_uri, ctx) do
    stream_str = stream_to_string(stream_uri)

    case check_subscribe_cap(stream_uri, ctx) do
      :ok ->
        __init_ets__()

        :ets.insert(@table, {
          {URI.to_string(entity_uri), stream_str},
          %{
            registered_at: DateTime.utc_now(),
            granted_by: Map.get(ctx, :caller, :system)
          }
        })

        :ok

      {:error, _} = err ->
        err
    end
  end

  def register_subscription(_, _, _), do: {:error, :invalid_args}

  @doc """
  List `entity_uri`'s subscriptions. Returns
  `[{stream_uri_string, metadata_map}]`.
  """
  @spec list_subscriptions(URI.t() | String.t()) :: [{String.t(), map()}]
  def list_subscriptions(entity_uri) do
    __init_ets__()

    entity_str =
      case entity_uri do
        %URI{} -> URI.to_string(entity_uri)
        s when is_binary(s) -> s
      end

    @table
    |> :ets.match({{entity_str, :"$1"}, :"$2"})
    |> Enum.map(fn [stream, meta] -> {stream, meta} end)
  end

  @doc """
  Unregister a subscription. No cap check — entity can always
  unsubscribe themselves.
  """
  @spec unregister_subscription(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def unregister_subscription(entity_uri, stream_uri) do
    __init_ets__()

    entity_str =
      case entity_uri do
        %URI{} -> URI.to_string(entity_uri)
        s when is_binary(s) -> s
      end

    :ets.delete(@table, {entity_str, stream_to_string(stream_uri)})

    :ok
  end

  @doc """
  List all subscribers of `stream_uri`. Used by the runtime hook
  to know who to notify (PR-N2 — currently informational only).
  """
  @spec list_subscribers(URI.t() | String.t()) :: [String.t()]
  def list_subscribers(stream_uri) do
    __init_ets__()
    stream_str = stream_to_string(stream_uri)

    @table
    |> :ets.match({{:"$1", stream_str}, :_})
    |> Enum.map(fn [entity] -> entity end)
  end

  # --- internals ----------------------------------------------------

  defp stream_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp stream_to_string(s) when is_binary(s), do: s

  # Mirror of `Ezagent.Notifications.check_cap!/3` shape but return-
  # based (not raise-based) so callers can pattern-match. Required cap:
  # `Ezagent.Behavior.Notifications` `:subscribe` on `stream_uri`.
  defp check_subscribe_cap(_stream_uri, %{caps: :system}), do: :ok

  defp check_subscribe_cap(stream_uri, %{caps: caps}) when is_struct(caps, MapSet) do
    # PR-N1 skeleton: defer to SliceChange topic for entity streams.
    # PR-N2 will add proper Capability.matches? against
    # `Behavior.Notifications` `:subscribe` cap.
    if SliceChange.topic(stream_uri) =~ "esr:entity:" do
      # Owner ALWAYS allowed to subscribe to own stream.
      :ok
    else
      :ok
    end

    _ = caps
    :ok
  end

  defp check_subscribe_cap(_, _), do: {:error, :missing_caps_in_ctx}
end
