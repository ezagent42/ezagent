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

  Called by `Ezagent.Kind.Runtime.handle_dispatch/4` between step 9
  (state update) and step 10 (telemetry), GATED on:

  1. The feature flag (default OFF in PR-N1)
  2. `new_slice != old_slice` (no event when state unchanged)
  3. Success-path only (errors / cap-denied never reach here)

  Returns `:ok` always. Best-effort — broadcast failures log + swallow
  so a notification problem doesn't break the dispatch.
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

  # Codex PR-N1 round-1 MED-2 fix: no catch-all rescue. A
  # PubSub broadcast failure is infrastructure breakage — surface
  # it as a crash in dev/test (caller is `Kind.Runtime.handle_dispatch`,
  # which already isolates per-dispatch via supervised tasks), and
  # let prod telemetry record the failure via the standard
  # `[:ezagent, :slice_change, :emit, :exception]` event the
  # `:telemetry.span` helper produces. The old `rescue _ -> :ok`
  # silently dropped notifications, defeating the architectural goal
  # of "slice mutation → state sync across surfaces is invariant".
  defp do_emit(%{self_uri: %URI{} = self_uri} = event) do
    :telemetry.span(
      [:ezagent, :slice_change, :emit],
      %{
        self_uri: self_uri,
        kind_module: Map.get(event, :kind_module),
        action: Map.get(event, :action),
        slice_key: Map.get(event, :slice_key)
      },
      fn ->
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          topic(self_uri),
          {:slice_changed, event}
        )

        {:ok, %{count: 1}}
      end
    )

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
