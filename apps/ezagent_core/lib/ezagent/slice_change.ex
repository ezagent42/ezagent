defmodule Ezagent.SliceChange do
  @moduledoc """
  Slice-change-as-notification primitive (SPEC v2 PR-N1, Allen 2026-05-24).

  ## The model (from `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`)

  When a Behavior's `:invoke` mutates a Kind's slice — and the
  mutation actually changed the slice (`new_slice != old_slice`) —
  emit a slice-change event to the affected entity's own stream.
  Flash / Feishu / mobile-push / etc subscribe to this stream. The
  Behavior author NEVER calls notify/3 directly — slice mutation
  IS the trigger.

  ## Topic

  `esr:entity:<self_uri>:slice_changed` — one topic per Kind URI.
  Subscribers get every slice change for that entity (Allen OQ-V2-N-1:
  per-entity wholesale, not per-slice; simpler).

  ## Message shape

      {:slice_changed, %{
        self_uri: URI.t(),
        kind_module: module(),
        action: atom(),
        slice_key: atom(),
        old_slice: map() | nil,
        new_slice: map(),
        result: term() | nil,
        caller: URI.t() | nil,
        at: DateTime.t()
      }}

  ## Gate: feature flag

  This module ships in PR-N1 with the emission **DISABLED** by
  default — `Application.get_env(:ezagent_core, :slice_change_hook, false)`.
  PR-N3 flips the flag on after PR-N2 wires the subscribers in
  dual-mode (old `Notifications.notify/3` topic + new
  `:slice_changed` topic). PR-N5 deletes the old path.

  ## Drift prevention (PR-N5 invariants)

  - `Notifications.notify/3` direct calls become `Ezagent.SliceChange`
    internal (invariant grep)
  - `Phoenix.PubSub.broadcast` to entity-stream topics is forbidden
    outside this module
  """

  require Logger

  @config_flag {:ezagent_core, :slice_change_hook}

  @doc "Topic shape — `esr:entity:<self_uri>:slice_changed`."
  @spec topic(URI.t() | String.t()) :: String.t()
  def topic(%URI{} = uri), do: topic(URI.to_string(uri))
  def topic(uri_str) when is_binary(uri_str), do: "esr:entity:#{uri_str}:slice_changed"

  @doc """
  Emit a slice-change event for `self_uri`.

  Called by `Ezagent.Kind.Server.commit_and_notify/3` AFTER
  `Snapshot.maybe_save/4` succeeds (codex PR-N1 round-2 MEDIUM fix).
  GATED on:

  1. The feature flag (default OFF in PR-N1)
  2. `slice_change_event != nil` — Runtime sets `nil` when slice
     unchanged or action returned read-only
  3. Success-path only (errors / cap-denied never reach here)

  Returns `:ok` always. Failure is observable (`:telemetry.span`
  exception event + Logger.warning) but non-fatal — the snapshot
  is already persisted; we don't crash the Kind GenServer for a
  PubSub outage.
  """
  @spec emit(map()) :: :ok
  def emit(%{} = event) do
    if enabled?() do
      do_emit(event)
    else
      :ok
    end
  end

  @doc "True iff the slice-change hook is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    {app, key} = @config_flag
    Application.get_env(app, key, false) == true
  end

  # Codex PR-N1 round-2 MEDIUM fix: post-commit semantics.
  #
  # Caller (`Kind.Server.commit_and_notify/3`) invokes us AFTER
  # `Snapshot.maybe_save/4` succeeds. The slice is already durably
  # persisted; a PubSub broadcast failure here cannot lose the
  # user's mutation. Round-1 used a bare `rescue _ -> :ok` swallow
  # which silently dropped notifications; round-1 fix removed it but
  # then a PubSub crash could roll back the mutation (because emit
  # ran INSIDE Runtime, BEFORE snapshot). Round-2 keeps emit safe-to-
  # crash by routing it through `:telemetry.span/3`: the span emits
  # `[:ezagent, :slice_change, :emit, :exception]` if PubSub raises,
  # so failures are observable, but we rescue the exception locally
  # so the GenServer's commit-then-notify pair doesn't take down the
  # Kind process for an infrastructure hiccup.
  defp do_emit(%{self_uri: %URI{} = self_uri} = event) do
    metadata = %{
      self_uri: self_uri,
      kind_module: Map.get(event, :kind_module),
      action: Map.get(event, :action),
      slice_key: Map.get(event, :slice_key)
    }

    try do
      :telemetry.span(
        [:ezagent, :slice_change, :emit],
        metadata,
        fn ->
          Phoenix.PubSub.broadcast(
            EzagentCore.PubSub,
            topic(self_uri),
            {:slice_changed, event}
          )

          {:ok, %{count: 1}}
        end
      )
    rescue
      error ->
        # Observable + non-fatal: failures surface via telemetry +
        # log; the Kind GenServer keeps running because the mutation
        # is already snapshotted.
        Logger.warning(
          "Ezagent.SliceChange.emit failed for #{URI.to_string(self_uri)} (post-commit): " <>
            inspect(error)
        )
    end

    :ok
  end

  defp do_emit(_), do: :ok

  @doc """
  Subscribe the calling process to slice-change events for `uri`.

  Returns `:ok`. Receives `{:slice_changed, event_map}` messages on
  the calling process.
  """
  @spec subscribe(URI.t() | String.t()) :: :ok
  def subscribe(uri) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic(uri))
  end

  @doc "Inverse of `subscribe/1`."
  @spec unsubscribe(URI.t() | String.t()) :: :ok
  def unsubscribe(uri) do
    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic(uri))
  end
end
