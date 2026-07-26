defmodule Ezagent.SliceChange do
  @moduledoc """
  Slice-change-as-notification primitive (SPEC v2 PR-N1, Allen 2026-05-24;
  security-minimal envelope PR-N3 codex r2 HIGH-1, Allen 2026-05-25).

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

  ## Broadcast envelope shape (security-minimal — PR-N3 codex r2 HIGH-1)

      {:slice_changed, %{
        uri:            URI.t(),              # which Kind instance
        slice_key:      atom(),               # which slice changed
        cursor:         non_neg_integer(),    # monotonic per-URI sequence
        event_at:       DateTime.t(),         # wall-clock
        result_summary: :ok | :error          # atom summary; no error detail
      }}

  **Nothing else.** No `old_slice`, no `new_slice`, no `result` map,
  no `caller`, no `kind_module`, no `action`. The pre-fix envelope
  leaked sensitive slice content (e.g. `Ezagent.ActionSet.ApiKeys`'s
  plaintext keys) to any same-VM subscriber of the public-derivable
  topic — bypassing Behavior cap gates like `identity:api_keys:read`.
  Codex r2 (PR #328) flagged this as HIGH-1; Allen approved the
  Option C fix (parallel pattern to `Ezagent.Publisher.Event` from
  PR-EM-0).

  Subscribers that need the actual slice content MUST re-fetch via
  `Ezagent.Kind.get_slice/2` (synchronous read of the live Kind's
  current slice) or `Ezagent.Invocation.dispatch/1` (cap-gated read
  via a Behavior `:list_*` / `:get_*` action). The framework is
  default-secure: the event itself doesn't leak; what each
  subscriber fetches afterward is its own cap concern.

  Invariant test:
  `apps/ezagent_core/test/invariants/slice_change_event_carries_no_slice_content_test.exs`
  asserts the broadcast envelope has ONLY the 5 allowed keys.

  ## Gate: hard switch (PR-N3, Allen 2026-05-25)

  The hook is unconditionally enabled. PR-N1 shipped with a temporary
  `Application.get_env(:ezagent_core, :slice_change_hook, false)`
  scaffold (default OFF) so PR-N1 + PR-N2 could land without firing
  events at unmigrated producers. PR-N3 removes the config knob per
  `feedback_let_it_crash_no_workarounds` (knobs are anti-patterns —
  prefer a hard structural switch). `enabled?/0` survives only as a
  compile-time-constant predicate so existing call sites
  (`Kind.Server.commit_and_notify/3`) keep their shape; PR-N5 deletes
  it entirely once the legacy `Notifications.notify/3` is gone.

  ## Drift prevention (PR-N5 invariants)

  - `Notifications.notify/3` direct calls become `Ezagent.SliceChange`
    internal (invariant grep)
  - `Phoenix.PubSub.broadcast` to entity-stream topics is forbidden
    outside this module
  - The broadcast envelope MUST stay at the 5-key minimal shape
    (`slice_change_event_carries_no_slice_content_test.exs`)
  """

  require Logger

  alias Ezagent.SliceChange.Cursors

  @doc "Topic shape — `esr:entity:<self_uri>:slice_changed`."
  @spec topic(URI.t() | String.t()) :: String.t()
  def topic(%URI{} = uri), do: topic(URI.to_string(uri))
  def topic(uri_str) when is_binary(uri_str), do: "esr:entity:#{uri_str}:slice_changed"

  @doc """
  Emit a slice-change event for `self_uri`.

  Called by `Ezagent.Kind.Server.commit_and_notify/3` AFTER
  `Snapshot.maybe_save/4` succeeds (codex PR-N1 round-2 MEDIUM fix).
  GATED on:

  1. `slice_change_event != nil` — Runtime sets `nil` when slice
     unchanged or action returned read-only
  2. Success-path only (errors / cap-denied never reach here)

  **Input shape**: accepts the "fat" producer-side event map (with
  `:old_slice` / `:new_slice` / `:result` / `:caller` / etc.) that
  `Ezagent.Kind.Runtime.handle_dispatch/4` constructs. Internally
  computes the security-minimal broadcast envelope (5 fields only;
  see moduledoc). This is the boundary where slice content is
  filtered out — call sites upstream may legitimately need the diff
  for other purposes (audit telemetry, future in-process callbacks);
  what crosses PubSub is the minimal shape.

  Returns `:ok` always. Failure is observable (`:telemetry.span`
  exception event + Logger.warning) but non-fatal — the snapshot
  is already persisted; we don't crash the Kind GenServer for a
  PubSub outage.
  """
  @spec emit(map()) :: :ok
  def emit(%{} = event) do
    _ = emit_with_projection(event)
    :ok
  end

  @doc """
  `emit/1` PLUS the canonical projection (V5 use-side H2, delete-holes
  #200).

  Identical broadcast semantics to `emit/1`, but returns
  `{:ok, projection}` where `projection` is the SAME canonical 5-key
  broadcast envelope (`uri / slice_key / cursor / event_at /
  result_summary`) that just crossed PubSub — factored out so
  `Ezagent.Kind.Server.commit_and_notify/3` can deliver the EXACT value
  (one cursor allocation, one `event_at`) to a `reacts_to_slice_change?`
  behavior as a sealed self-signal (the Publisher's PubSub
  self-subscription is deleted; the broadcast remains the outbound READ
  stream for UI/external readers). Returns `:ok` when no projection was
  built (no `:self_uri` in the event, or a rescued failure).
  """
  @spec emit_with_projection(map()) :: {:ok, map()} | :ok
  def emit_with_projection(%{} = event), do: do_emit(event)

  @doc """
  True iff the slice-change hook is enabled.

  PR-N3 (Allen 2026-05-25) hardened this from a config-driven
  predicate to an unconditional `true` per
  `feedback_let_it_crash_no_workarounds`. Retained as a function
  (rather than inlined) so `Kind.Server` and any test that
  inspected the gate keep the same call shape; PR-N5 deletes it
  along with the rest of the legacy notification surface.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: true

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
  #
  # Codex PR-N3 round-2 HIGH-1 fix (Allen 2026-05-25): broadcast the
  # security-minimal envelope (5 fields only). Slice content
  # (`old_slice` / `new_slice` / `result`) is filtered out at this
  # boundary — subscribers re-fetch via `Kind.get_slice/2` /
  # `Invocation.dispatch/1` if they need it (cap-gated).
  defp do_emit(%{self_uri: %URI{} = self_uri} = producer_event) do
    metadata = %{
      self_uri: self_uri,
      kind_module: Map.get(producer_event, :kind_module),
      action: Map.get(producer_event, :action),
      slice_key: Map.get(producer_event, :slice_key)
    }

    # Codex r3 MEDIUM (Allen 2026-05-25) — moved `build_broadcast_event/2`
    # INSIDE the try block. Pre-fix, `Cursors.next/1` called
    # `:ets.update_counter/4` against the EtsOwner-owned table; if the
    # table was unavailable (EtsOwner restart window, boot skew, test
    # tear-down race), the `ArgumentError` raised OUTSIDE the rescue and
    # crashed the Kind GenServer AFTER `commit_and_notify/3` had already
    # persisted the slice — exactly the non-fatal post-commit contract
    # this function exists to preserve.
    try do
      # V5 use-side H2: the telemetry span returns the built projection
      # (previously `:ok`), so the caller can deliver the EXACT SAME
      # canonical envelope to a `reacts_to_slice_change?` behavior as a
      # sealed self-signal — one cursor allocation, one `event_at`, one
      # value feeding both the broadcast and the self-signal.
      case :telemetry.span(
             [:ezagent, :slice_change, :emit],
             metadata,
             fn ->
               broadcast_event = build_broadcast_event(self_uri, producer_event)

               Phoenix.PubSub.broadcast(
                 pubsub(),
                 topic(self_uri),
                 {:slice_changed, broadcast_event}
               )

               {broadcast_event, %{count: 1}}
             end
           ) do
        %{} = broadcast_event -> {:ok, broadcast_event}
      end
    rescue
      error ->
        # Observable + non-fatal: failures surface via telemetry +
        # log; the Kind GenServer keeps running because the mutation
        # is already snapshotted.
        #
        # Codex r3 MEDIUM follow-on: log the URI defensively via inspect
        # rather than `URI.to_string/1` — a malformed `%URI{}` (the same
        # class of failure that lands us in this rescue branch in the
        # first place) would re-raise from the formatter and defeat the
        # non-fatal contract.
        Logger.warning(
          "Ezagent.SliceChange.emit failed for #{inspect(self_uri)} (post-commit): " <>
            inspect(error)
        )

        :ok
    end
  end

  defp do_emit(_), do: :ok

  # Build the broadcast envelope from the producer-side event map.
  # This is the ONE place that decides what crosses PubSub —
  # changing it without updating
  # `slice_change_event_carries_no_slice_content_test.exs` is the
  # regression we're locking out.
  defp build_broadcast_event(%URI{} = self_uri, producer_event) do
    slice_key =
      case Map.get(producer_event, :slice_key) do
        k when is_atom(k) -> k
        _ -> nil
      end

    event_at =
      case Map.get(producer_event, :at) do
        %DateTime{} = dt -> dt
        _ -> DateTime.utc_now()
      end

    result_summary = summarize_result(Map.get(producer_event, :result))

    # PR-N3 r4 (Allen 2026-05-25) — use the pre-allocated cursor from
    # the producer event if present; fall back to fresh allocation
    # for the legacy code path (any caller that builds a producer
    # event without going through `Ezagent.Kind.Runtime`). The
    # pre-allocated path is the production path post-PR-N3-r4 — it's
    # what guarantees the broadcast envelope's `:cursor` matches the
    # slice's `:recent_messages` ring key so flash subscribers can
    # resolve the correct message id without racing the latest
    # pointer (codex r3 HIGH-1 race fix).
    cursor =
      case Map.get(producer_event, :cursor) do
        c when is_integer(c) and c > 0 -> c
        _ -> Cursors.next(self_uri)
      end

    %{
      uri: self_uri,
      slice_key: slice_key,
      cursor: cursor,
      event_at: event_at,
      result_summary: result_summary
    }
  end

  # The Runtime hook only reaches `emit/1` on success paths (the
  # `{:error, _}` branch returns before constructing the
  # slice_change_event). So in practice `result` is always a "success"
  # value — either `nil` (read-only Behavior returned no result map) or
  # a result map (which by construction means `{:ok, _, result_map}`).
  # `:error` is reserved for any future caller that wants to surface
  # "the post-commit step failed" semantics — keeping it expressible
  # avoids forcing callers to drop a class of event.
  defp summarize_result(nil), do: :ok
  defp summarize_result({:error, _}), do: :error
  defp summarize_result(:error), do: :error
  defp summarize_result(_), do: :ok

  @doc """
  Subscribe the calling process to slice-change events for `uri`
  WITHOUT any capability check.

  **Codex PR-N1 round-5 disposition (option a, Allen 2026-05-24):**
  this function exists because `Phoenix.PubSub.subscribe/2` is itself
  open — any in-VM code can call
  `Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:entity:victim:slice_changed")`
  directly. The topic name is derived from the entity URI; there is
  no secret. We **cannot** prevent same-BEAM code from receiving
  broadcasts of topics it can compute.

  Same-VM = same trust domain. The cap-gated subscribe path
  (`Ezagent.NotificationSubscriptions.subscribe/2`) is for the
  AUDIT TRAIL + ENROLLMENT (LV reconnect, plugin reboot
  re-subscription) — it tracks INTENT, not transport access.

  **Codex PR-N3 r2 HIGH-1 (Allen 2026-05-25):** the broadcast envelope
  no longer carries slice content (only `uri / slice_key / cursor /
  event_at / result_summary`). Subscribing to the topic reveals the
  EXISTENCE + TIMING of a slice change, never its content. To read
  slice content, the subscriber dispatches `Ezagent.Kind.get_slice/2`
  or a cap-gated Behavior read action — which run their own cap gates.
  The previous risk (`new_slice`/`result` field exfil) is closed at
  the producer; subscriber-side trust is preserved by re-fetch.

  **For end-user-facing code paths** (LV mount on behalf of a
  logged-in user, plugin workers tracking another entity), use
  `NotificationSubscriptions.subscribe/2` so the registry knows
  about the subscription. This function is for INTERNAL machinery
  that has already passed cap gates (e.g. the Kind GenServer
  subscribing to its OWN topic at boot).

  Returns `:ok`. Receives `{:slice_changed, event_map}` messages on
  the calling process — see moduledoc for the envelope shape.
  """
  @spec subscribe_unverified(URI.t() | String.t()) :: :ok
  def subscribe_unverified(uri) do
    Phoenix.PubSub.subscribe(pubsub(), topic(uri))
  end

  @doc "Inverse of `subscribe_unverified/1`."
  @spec unsubscribe_unverified(URI.t() | String.t()) :: :ok
  def unsubscribe_unverified(uri) do
    Phoenix.PubSub.unsubscribe(pubsub(), topic(uri))
  end

  # C5 §3.4 pubsub injection — the PubSub server name is a config injection,
  # never a literal spine reference. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to `EzagentCore.PubSub`.
  defp pubsub, do: Application.fetch_env!(:ezagent_actor, :pubsub)
end
