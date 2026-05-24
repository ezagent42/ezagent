defmodule Ezagent.NotificationSubscriptions do
  @moduledoc """
  Unified registry for notification subscriptions (SPEC v2 PR-N1
  Allen 2026-05-24 amendment).

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

  ## Owner-mediated `:protected` ETS (codex PR-N1 round-2 HIGH-1 fix)

  Round-1 placed the table under `EzagentCore.EtsOwner` with `:public`
  (matching other registries). Codex round-2 correctly observed:
  `:public` lets ANY BEAM code call `:ets.insert/2` / `:ets.delete/2`
  on `:ezagent_notification_subscriptions`, bypassing
  `check_subscribe_cap/2` + `authorize_unregister/2`.

  This module now owns its OWN `:protected` ETS table via a
  dedicated GenServer:

  - reads (`list_subscriptions/1`, `list_subscribers/1`) go direct
    via `:ets.match` — `:protected` allows reads from any process
  - writes (`register_*`, `unregister_*`) go through GenServer.call
    so the table is only modified after cap enforcement; serialised
    on the owner process

  Trade-off: writes are now serialised (one-at-a-time through the
  GenServer mailbox). Subscriptions are not a hot path (1 per LV
  mount / plugin worker), so the cost is acceptable for the
  enforcement boundary it gives.

  ## Explicit ctx — no `:system` default (codex round-2 CRITICAL fix)

  Round-1 had `ctx \\ %{caps: :system}` defaults. ANY caller could
  call the arity-2 form and get system authority — the cap fix
  was a no-op. Round-2 removes the defaults; all public mutation
  APIs require a 3-arg `ctx`. Trusted internal callers use
  `system_register/2` / `system_unregister/2` — same module, but
  the call site is grep-visible.

  ## Tightened admin predicate (codex round-2 HIGH-3 fix)

  Round-1 `has_admin_cap?` matched ANY `workspace_uri: :any` cap.
  Codex round-2: a narrow cross-workspace Chat.send cap would
  qualify. Now requires `behavior == Ezagent.Behavior.Notifications
  AND workspace_uri == :any` — i.e., specifically a notifications-
  admin cap. Tested.
  """

  use GenServer
  require Logger
  alias Ezagent.Capability

  @table :ezagent_notification_subscriptions

  # --- supervised init ----------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "ETS table name (read-only access via `:ets.match/2`)."
  def table, do: @table

  # --- public mutation API (cap-gated) ------------------------------

  @doc """
  Register that `entity_uri` wants to receive slice-change events
  for `stream_uri`. Cap-gated by `ctx`.

  `ctx` MUST include `:caps` (MapSet of `Ezagent.Capability` structs
  OR the atom `:system`). For non-`:system` ctx, must also include
  `:caller` (the URI on whose behalf the registration is being made).

  Returns `:ok` on cap success, `{:error, :unauthorized}` on cap
  miss, `{:error, :missing_caps_in_ctx}` when `ctx[:caps]` is absent.
  """
  @spec register_subscription(URI.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def register_subscription(%URI{} = entity_uri, stream_uri, ctx) when is_map(ctx) do
    GenServer.call(__MODULE__, {:register, entity_uri, stream_uri, ctx})
  end

  def register_subscription(_, _, _), do: {:error, :invalid_args}

  @doc """
  Unregister a subscription.

  `ctx` MUST include `:caller`. Authorisation:
  - `ctx.caller == entity_uri` (self-unsubscribe) — allowed
  - notifications-admin cap (`Behavior.Notifications` +
    `workspace_uri: :any`) — allowed
  - otherwise — `{:error, :unauthorized}`

  Idempotent: deleting a missing row returns `:ok`.
  """
  @spec unregister_subscription(URI.t() | String.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def unregister_subscription(entity_uri, stream_uri, ctx) when is_map(ctx) do
    GenServer.call(__MODULE__, {:unregister, entity_uri, stream_uri, ctx})
  end

  def unregister_subscription(_, _, _), do: {:error, :invalid_args}

  # --- system call sites (grep-visible) -----------------------------

  @doc """
  Internal/system registration — bypasses cap check.

  Use ONLY for trusted internal callers (bootstrap, infrastructure
  re-subscriptions). Every call site is grep-visible to make the
  trust boundary auditable.
  """
  @spec system_register(URI.t(), URI.t() | String.t()) :: :ok
  def system_register(%URI{} = entity_uri, stream_uri) do
    GenServer.call(
      __MODULE__,
      {:register, entity_uri, stream_uri, %{caps: :system, caller: :system}}
    )
  end

  @doc """
  Internal/system unregistration — bypasses cap check. Same trust
  boundary semantics as `system_register/2`.
  """
  @spec system_unregister(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def system_unregister(entity_uri, stream_uri) do
    GenServer.call(
      __MODULE__,
      {:unregister, entity_uri, stream_uri, %{caps: :system, caller: :system}}
    )
  end

  # --- read API (direct ETS) ----------------------------------------

  @doc """
  List `entity_uri`'s subscriptions. Returns
  `[{stream_uri_string, metadata_map}]`. No cap check on the read
  side — keyed by entity, so any process can introspect.
  """
  @spec list_subscriptions(URI.t() | String.t()) :: [{String.t(), map()}]
  def list_subscriptions(entity_uri) do
    entity_str = entity_to_string(entity_uri)

    @table
    |> :ets.match({{entity_str, :"$1"}, :"$2"})
    |> Enum.map(fn [stream, meta] -> {stream, meta} end)
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

  # --- GenServer callbacks ------------------------------------------

  @impl true
  def handle_call({:register, entity_uri, stream_uri, ctx}, _from, state) do
    stream_str = stream_to_string(stream_uri)
    stream_uri_parsed = parse_stream_uri(stream_uri)

    reply =
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

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unregister, entity_uri, stream_uri, ctx}, _from, state) do
    entity_str = entity_to_string(entity_uri)
    stream_str = stream_to_string(stream_uri)

    reply =
      case authorize_unregister(entity_str, ctx) do
        :ok ->
          :ets.delete(@table, {entity_str, stream_str})
          :ok

        {:error, _} = err ->
          err
      end

    {:reply, reply, state}
  end

  # --- internals ----------------------------------------------------

  defp entity_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp entity_to_string(s) when is_binary(s), do: s

  defp stream_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp stream_to_string(s) when is_binary(s), do: s

  defp parse_stream_uri(%URI{} = u), do: u
  defp parse_stream_uri(s) when is_binary(s), do: URI.parse(s)

  # Codex round-1 CRITICAL + round-2 reinforcement: deny-by-default,
  # `:system` ctx allowed (explicit), otherwise caller must hold a
  # matching `Behavior.Notifications` cap.
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

  # Codex round-1 HIGH-3 + round-2 HIGH-3 reinforcement: caller must
  # be the entity, `:system`, or hold a NOTIFICATIONS-admin cap
  # (behavior + :any). Generic `:any` caps no longer qualify.
  defp authorize_unregister(_entity_str, %{caps: :system}), do: :ok

  defp authorize_unregister(entity_str, %{caller: %URI{} = caller} = ctx) do
    cond do
      URI.to_string(caller) == entity_str ->
        :ok

      notifications_admin?(ctx) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp authorize_unregister(_, _), do: {:error, :unauthorized}

  defp notifications_admin?(%{caps: caps}) do
    caps
    |> normalize_caps()
    |> Enum.any?(fn
      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Notifications,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp notifications_admin?(_), do: false

  defp normalize_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_caps(caps) when is_list(caps), do: caps
  defp normalize_caps(_), do: []
end
