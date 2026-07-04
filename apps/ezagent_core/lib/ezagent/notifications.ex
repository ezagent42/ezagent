defmodule Ezagent.Notifications do
  @moduledoc """
  Unified user-inbox notifications primitive.

  Allen 2026-05-23 asked: "plugin 是否有注册 notification 的统一入口？"
  Answer (before this PR): no — `Ezagent.ActionSet.Session` and a few
  other producers each `Phoenix.PubSub.broadcast` directly to
  `esr:user:<uri>:events`. No helper, no shape, no cap gate. Plugins
  copy the pattern.

  This module is the unified entry.

  ## API

  - `notify(user_uri, notification)` — push a notification into
    `user_uri`'s inbox. Broadcasts to `esr:user:<uri>:events`.
    Producers (chat domain, future plugins) call THIS instead of
    raw PubSub.broadcast.
  - `subscribe(user_uri)` — subscribe the calling process to
    the user's notification stream. LV / admin / monitoring
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
  - `:source` — module that emitted (e.g. `Ezagent.ActionSet.Session`).
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

  ## Authorization

  Notify/subscribe are in-VM-internal operations: the producers are
  trusted in-VM code (chat-domain Chat behavior, audit writer, session
  fan-out, etc.). Under the #154 VM-internal-trust model the
  authorization boundary is the dispatch chokepoint (which serves
  external authenticated callers); these helpers are reached only from
  trusted in-VM code, so the previous secondary `:notify`/`:subscribe`
  cap checks were dormant (every caller passed the trusted bypass) and
  were removed. They take no `ctx`.
  """

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

  In-VM-internal (no cap check — see "## Authorization"). Validates the
  notification shape (`:type`, `:body`, `:source` required). Raises
  `ArgumentError` on bad notification shape.
  """
  @spec notify(URI.t() | String.t(), notification()) :: :ok
  def notify(user_uri, notification) do
    parsed_uri = parse_uri!(user_uri)
    _ = kind_module_of!(parsed_uri)
    validate_notification!(notification)

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
        # Contract field is `:type` (not `:kind`); pre-fix telemetry
        # always emitted `kind: nil` for shape-conformant callers.
        type: Map.fetch!(notification, :type),
        source: Map.fetch!(notification, :source),
        # In-VM-internal producer; no entity caller. (Was `Map.get(ctx, :caller)`
        # which every caller left unset → always nil; kept nil to preserve the
        # audit-pipeline contract, which resolves caller workspace via
        # `Ezagent.Persistence.workspace_uri_for/1`.)
        caller: nil
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

  In-VM-internal (no cap check — see "## Authorization"). Receives
  `{:notification, user_uri, notification_map}` messages on the
  calling process.
  """
  @spec subscribe(URI.t() | String.t()) :: :ok
  def subscribe(user_uri) do
    parsed_uri = parse_uri!(user_uri)
    _ = kind_module_of!(parsed_uri)

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
  defp parse_uri!(s) when is_binary(s), do: Ezagent.URI.new!(s)

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

  defp kind_module_of!(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :user) do
      Ezagent.Entity.User
    else
      raise_unsupported_kind!(uri)
    end
  end

  defp kind_module_of!(%URI{} = uri), do: raise_unsupported_kind!(uri)

  defp raise_unsupported_kind!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.Notifications: only entity user URIs are supported, " <>
            "got #{Ezagent.URI.stable_key(uri)}"
  end
end
