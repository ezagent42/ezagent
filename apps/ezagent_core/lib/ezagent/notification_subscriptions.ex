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

  ## PR-N1 scope (skeleton)

  - ETS table OWNED by `EzagentCore.EtsOwner` (supervised init —
    codex PR-N1 round-1 MED-1 fix; was lazy-create with TOCTOU race)
  - `:protected` not `:public` — only this module + EtsOwner write;
    other processes read (codex MED-1)
  - `register_subscription/3` cap-gated: `:system` ctx always
    allowed; non-system caller's MapSet caps checked for
    `Ezagent.Behavior.Notifications` `:subscribe` on stream
    (codex CRITICAL — was permissive skeleton that returned :ok)
  - `unregister_subscription/3` requires ctx + checks caller
    matches entity URI OR caller is :system / admin (codex
    HIGH-3 — was no-context delete-anyone)

  PR-N2 wires LV mount to consult the registry on connect (replaces
  ad-hoc PubSub.subscribe). PR-N5 grep-gate enforces "no
  Phoenix.PubSub.subscribe to entity-stream topics outside this
  module + SliceChange".
  """

  require Logger
  alias Ezagent.Capability

  @table :ezagent_notification_subscriptions

  @doc """
  ETS table name. Used by `EzagentCore.EtsOwner` to set up the table
  at boot under a supervised owner (matches the pattern of other
  registry modules in `EtsOwner.@tables`).
  """
  def table, do: @table

  @doc """
  Register that `entity_uri` wants to receive slice-change events
  for `stream_uri`. Cap-gated.

  In PR-N1: records intent only. PR-N2 wires LV mount to subscribe
  on behalf of the entity.

  Returns `:ok` on cap success, `{:error, :unauthorized}` on cap
  miss, `{:error, :missing_caps_in_ctx}` when `ctx[:caps]` is absent.
  """
  @spec register_subscription(URI.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def register_subscription(entity_uri, stream_uri, ctx \\ %{caps: :system})

  def register_subscription(%URI{} = entity_uri, stream_uri, ctx) do
    stream_str = stream_to_string(stream_uri)
    stream_uri_parsed = parse_stream_uri(stream_uri)

    case check_subscribe_cap(stream_uri_parsed, ctx) do
      :ok ->
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
  `[{stream_uri_string, metadata_map}]`. Read path — no cap check;
  any process can see subscriptions (it's tenant-segmented by
  entity_uri key).
  """
  @spec list_subscriptions(URI.t() | String.t()) :: [{String.t(), map()}]
  def list_subscriptions(entity_uri) do
    entity_str = entity_to_string(entity_uri)

    @table
    |> :ets.match({{entity_str, :"$1"}, :"$2"})
    |> Enum.map(fn [stream, meta] -> {stream, meta} end)
  end

  @doc """
  Unregister a subscription.

  **Codex PR-N1 round-1 HIGH-3 fix**: requires `ctx` with `:caller`,
  and the caller MUST match the `entity_uri` whose subscription is
  being removed (an entity can always unsubscribe themselves),
  EXCEPT for `:system` ctx OR a caller that holds an admin (`:any`
  workspace) `Behavior.Notifications` cap.

  Returns `:ok` on success / when row absent (idempotent), or
  `{:error, :unauthorized}` if the caller is not the entity.
  """
  @spec unregister_subscription(URI.t() | String.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def unregister_subscription(entity_uri, stream_uri, ctx \\ %{caps: :system}) do
    entity_str = entity_to_string(entity_uri)
    stream_str = stream_to_string(stream_uri)

    case authorize_unregister(entity_str, ctx) do
      :ok ->
        :ets.delete(@table, {entity_str, stream_str})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  List all subscribers of `stream_uri`. Used by the runtime hook
  to know who to notify (PR-N2 — currently informational only).
  """
  @spec list_subscribers(URI.t() | String.t()) :: [String.t()]
  def list_subscribers(stream_uri) do
    stream_str = stream_to_string(stream_uri)

    @table
    |> :ets.match({{:"$1", stream_str}, :_})
    |> Enum.map(fn [entity] -> entity end)
  end

  # --- internals ----------------------------------------------------

  defp entity_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp entity_to_string(s) when is_binary(s), do: s

  defp stream_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp stream_to_string(s) when is_binary(s), do: s

  defp parse_stream_uri(%URI{} = u), do: u
  defp parse_stream_uri(s) when is_binary(s), do: URI.parse(s)

  # Codex PR-N1 round-1 CRITICAL fix: real `Capability.matches?`
  # check, not the permissive skeleton that returned :ok for any
  # MapSet. `:system` ctx always allowed (internal bootstrap).
  # Otherwise: caller's caps must include `Behavior.Notifications`
  # `:subscribe` cap on the stream URI's workspace (or `:any`).
  defp check_subscribe_cap(_stream_uri, %{caps: :system}), do: :ok

  defp check_subscribe_cap(%URI{} = stream_uri, %{caps: caps}) do
    needed = %{
      kind: :user,
      behavior: Ezagent.Behavior.Notifications,
      instance: stream_uri,
      workspace_uri: Capability.workspace_of(stream_uri)
    }

    if caps |> normalize_caps() |> Enum.any?(&Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp check_subscribe_cap(_, _), do: {:error, :missing_caps_in_ctx}

  # Codex PR-N1 round-1 HIGH-3: caller must be the entity itself,
  # `:system`, OR hold an admin (`workspace_uri: :any`) cap.
  defp authorize_unregister(_entity_str, %{caps: :system}), do: :ok

  defp authorize_unregister(entity_str, %{caller: %URI{} = caller} = ctx) do
    cond do
      URI.to_string(caller) == entity_str ->
        :ok

      has_admin_cap?(ctx) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp authorize_unregister(_, _), do: {:error, :unauthorized}

  defp has_admin_cap?(%{caps: caps}) do
    caps
    |> normalize_caps()
    |> Enum.any?(fn
      %Ezagent.Capability{workspace_uri: :any} -> true
      _ -> false
    end)
  end

  defp has_admin_cap?(_), do: false

  defp normalize_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_caps(caps) when is_list(caps), do: caps
  defp normalize_caps(_), do: []
end
