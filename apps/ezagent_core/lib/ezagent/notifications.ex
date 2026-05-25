defmodule Ezagent.Notifications do
  @moduledoc """
  Unified user-inbox notifications primitive.

  Allen 2026-05-23 asked: "plugin 是否有注册 notification 的统一入口？"
  Answer (before this PR): no — `Ezagent.Behavior.Chat` and a few
  other producers each `Phoenix.PubSub.broadcast` directly to
  `esr:user:<uri>:events`. No helper, no shape, no cap gate. Plugins
  copy the pattern.

  This module is the unified entry.

  ## API

  - `notify(user_uri, notification)` — push a notification into
    `user_uri`'s inbox. Broadcasts to `esr:user:<uri>:events`.
    Producers (chat domain, future plugins) call THIS instead of
    raw PubSub.broadcast. Cap-gated: caller must hold a `:notify`
    cap on the target user.
  - `subscribe(user_uri, ctx)` — subscribe the calling process to
    the user's notification stream. Cap-gated: caller must hold a
    `:subscribe` cap on the target user. LV / admin / monitoring
    surfaces use this.

  ## Notification shape

      %{
        required(:type) => atom(),
        required(:body) => map(),
        required(:source) => module(),
        optional(:dedup_key) => binary()
      }

  - `:type` — caller's event taxonomy (`:message_received`,
    `:member_joined`, `:read_ack`, `:cap_granted`, …). Convention:
    snake_case atom. Subscribers pattern-match.
  - `:body` — the payload map. Shape per-type (caller's concern).
  - `:source` — module that emitted (e.g. `Ezagent.Behavior.Chat`).
    Used for audit + admin filtering.
  - `:dedup_key` — OPTIONAL idempotency key. If two notifications
    with the same `:dedup_key` arrive within the same VM run,
    subscribers should de-dup (the primitive itself does not store
    history — dedup is consumer-side).

  ## On-the-wire envelope

  Subscribers receive `{:notification, user_uri, notification_map}`
  on the `esr:user:<uri>:events` topic. Existing
  `{:message_received, msg}` broadcasts (legacy raw shape from
  Chat.invoke(:receive)) coexist with the new tagged envelope
  while migration completes — subscribers handle both shapes
  until V2.

  ## Cap model

  Mirrors `Ezagent.Presence`: cap-only Behavior
  (`Ezagent.Behavior.Notifications`) registered against
  `Ezagent.Entity.User`. `notify/2` checks `:notify` cap;
  `subscribe/2` checks `:subscribe` cap. System bypass via
  `ctx.caps == :system` for trusted internal callers
  (chat-domain Chat behavior, audit writer, etc.).
  """

  alias Ezagent.{Capability, CapabilityRegistry}

  @type notification :: %{
          required(:type) => atom(),
          required(:body) => map(),
          required(:source) => module(),
          optional(:dedup_key) => binary()
        }

  @doc "PubSub topic for `user_uri`'s notification stream."
  @spec topic(URI.t() | String.t()) :: String.t()
  def topic(uri), do: "esr:user:" <> to_uri_string(uri) <> ":events"

  @doc """
  Push a notification into `user_uri`'s inbox. Broadcasts the
  tagged envelope `{:notification, user_uri, notification}` on the
  user's `:events` topic.

  Cap-gated: caller must hold a `:notify` cap (or `ctx.caps == :system`).
  Validates the notification shape (`:type`, `:body`, `:source`
  required). Raises `Ezagent.Capability.Unauthorized` on cap miss
  or `ArgumentError` on bad notification shape.
  """
  @spec notify(URI.t() | String.t(), notification(), ctx :: map()) :: :ok
  def notify(user_uri, notification, ctx \\ %{caps: :system}) do
    parsed_uri = parse_uri!(user_uri)
    _ = kind_module_of!(parsed_uri)
    validate_notification!(notification)
    check_cap!(ctx, parsed_uri, :notify)

    # Notifier/log audit 2026-05-24 MED — emit telemetry so notifications
    # become visible to the Audit pipeline. Per
    # `feedback_north_star_plugin_isolation`, the audit sink subscribes
    # to events; producers just emit. Add `[:ezagent, :notification, :emit]`
    # to `Ezagent.Audit.@events` to persist.
    :telemetry.execute(
      [:ezagent, :notification, :emit],
      %{count: 1},
      %{
        user_uri: parsed_uri,
        kind: Map.get(notification, :kind),
        caller: Map.get(ctx, :caller)
      }
    )

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      topic(parsed_uri),
      {:notification, parsed_uri, notification}
    )
  end

  @doc """
  Subscribe the calling process to `user_uri`'s notification stream.

  Caller MUST pass `ctx` with `:caps`. Either `:system` (internal
  trusted) or `MapSet.t(Capability.t())`. Raises
  `Ezagent.Capability.Unauthorized` on cap miss.

  Receives `{:notification, user_uri, notification_map}` messages
  on the calling process.
  """
  @spec subscribe(URI.t() | String.t(), ctx :: map()) :: :ok
  def subscribe(user_uri, ctx) do
    parsed_uri = parse_uri!(user_uri)
    _ = kind_module_of!(parsed_uri)
    check_cap!(ctx, parsed_uri, :subscribe)

    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic(parsed_uri))
  end

  @doc "Unsubscribe from `user_uri`'s notification stream."
  @spec unsubscribe(URI.t() | String.t()) :: :ok
  def unsubscribe(user_uri) do
    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic(user_uri))
  end

  @doc """
  Subscribe the calling process to the new SPEC v2 PR-N1
  `:slice_changed` stream for `target_uri`.

  Companion to the legacy `subscribe/2` above — both helpers are
  valid + working during the PR-N2..PR-N5 transition window. The
  new topic is `Ezagent.SliceChange.topic(target_uri)` =
  `esr:entity:<uri>:slice_changed`. PR-N3 flips the auto-hook on
  so producers start firing into this topic; PR-N5 deletes the
  legacy `subscribe/2` once all producers migrate.

  Unlike `subscribe/2`, this helper performs **no cap check**.
  Per the SPEC §2.3 "subscribers self-serve" model, slice-change
  topic names are derivable from public URIs and same-VM trust is
  assumed (`notification_subscriptions.ex` §"Threat model"). For
  audit-trail-friendly cap-gated subscription (LV reconnect /
  plugin reboot re-subscription registry), call
  `Ezagent.NotificationSubscriptions.subscribe/3` instead.

  Receives `{:slice_changed, event_map}` on the calling process.
  Returns `:ok` (Phoenix.PubSub contract).
  """
  @spec subscribe_slice_change(URI.t() | String.t()) :: :ok
  def subscribe_slice_change(target_uri) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.SliceChange.topic(target_uri))
  end

  @doc "Inverse of `subscribe_slice_change/1`."
  @spec unsubscribe_slice_change(URI.t() | String.t()) :: :ok
  def unsubscribe_slice_change(target_uri) do
    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, Ezagent.SliceChange.topic(target_uri))
  end

  # ----- Private -------------------------------------------------------------

  defp parse_uri!(%URI{} = u), do: u
  defp parse_uri!(s) when is_binary(s), do: URI.parse(s)

  defp to_uri_string(%URI{} = u), do: URI.to_string(u)
  defp to_uri_string(s) when is_binary(s), do: s

  defp validate_notification!(%{type: t, body: b, source: s})
       when is_atom(t) and is_map(b) and is_atom(s),
       do: :ok

  defp validate_notification!(other) do
    raise ArgumentError,
          "Ezagent.Notifications.notify/2: notification must be a map " <>
            "with required keys :type (atom), :body (map), :source (module), " <>
            "got: #{inspect(other)}"
  end

  defp check_cap!(%{caps: :system}, _uri, _action), do: :ok

  defp check_cap!(ctx, %URI{} = uri, action) do
    needed = CapabilityRegistry.needed_for(kind_module_of!(uri), action, uri)
    caps = Map.get(ctx, :caps, MapSet.new())

    if any_cap_matches?(caps, needed) do
      :ok
    else
      raise Ezagent.Capability.Unauthorized,
        needed: needed,
        message:
          "Ezagent.Notifications.#{action}/2: caller does not hold the " <>
            "required #{inspect(action)} cap on #{URI.to_string(uri)}"
    end
  end

  defp kind_module_of!(%URI{scheme: "entity", host: "user"}), do: Ezagent.Entity.User

  defp kind_module_of!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.Notifications: only entity://user/... URIs are supported, " <>
            "got #{URI.to_string(uri)}"
  end

  defp any_cap_matches?(caps, needed) when is_struct(caps, MapSet) do
    Enum.any?(caps, &Capability.matches?(&1, needed))
  end

  defp any_cap_matches?(_caps, _needed), do: false
end
