defmodule Ezagent.PublisherLifecycle do
  @moduledoc """
  `Ezagent.PublisherLifecycle` — lifecycle-event primitive for a
  Kind that implements `Ezagent.ActionSet.Publisher`.

  ## Why this exists (task #49 — 2026-05-27)

  ExternalMirrorWorker subscribers carry a transient `pid()` in the
  publisher's `:publisher.subscribers` slice map. When a Session Kind
  is cold-spawned via `Ezagent.SpawnRegistry.spawn/1` (the on-demand
  rehydration path — NOT a fresh boot), its `:publisher` slice
  restores from the snapshot the same way every other slice does
  (see `Ezagent.Kind.Snapshot.load_or_init/3` + the per-Behavior
  `reconcile_after_load/2` hook). Whatever pids were persisted are
  now stale (the Worker pids from before the Session went away);
  the live ExternalMirrorWorker Kind processes that *kept running*
  through the Session vanish have no entry in the new subscribers
  map. Result: the Session emits publisher events to a subscriber
  set that no longer contains them — outbound mirror silently drops.

  `Ezagent.ExternalMirror.BootReconciler` covers the boot-path case
  (walk every binding row, spawn each Session). It does NOT cover
  the on-demand cold-spawn path (something else woke the Session
  — chat traffic, a `chat.send`, an LV mount — and the Worker
  Kinds are already alive and subscribed *to nothing*).

  The Lifecycle primitive closes that gap. Every time a Publisher
  Kind reaches its `:ready` state (boot OR cold-spawn rehydrate), it
  broadcasts `{:publisher_alive, self_uri}` on a per-URI lifecycle
  topic. Workers subscribe to the topic at their own init and
  re-run their publisher subscribe on receipt.

  ## Why a separate primitive (not reuse `Ezagent.SliceChange`)

  - `SliceChange` fires on slice MUTATION; lifecycle fires on Kind
    `:ready` regardless of mutation. The first slice change after
    cold-spawn might be 10 minutes away, but the worker needs to
    re-subscribe NOW so the FIRST mutation reaches it.
  - `SliceChange`'s envelope is security-minimal (no payload). The
    lifecycle event needs ONLY the URI — same minimal shape.
  - Subscribers of `SliceChange` are observers of mutation; subscribers
    of `PublisherLifecycle` are subscribers of presence. Separate
    semantics, separate topic.

  ## Why this lives in `ezagent_core` (not `ezagent_domain_external_mirror`)

  Two reasons:

  1. The `apps/ezagent_domain_external_mirror/lib/` tree carries a
     grep gate (`no_pubsub_bypass_in_external_mirror_test.exs`) that
     forbids `Phoenix.PubSub.subscribe` anywhere in that tree. The
     lifecycle subscribe MUST call `Phoenix.PubSub.subscribe` somewhere
     in the framework — putting that call site in core keeps the gate
     intact and centralises the framework's PubSub primitives next
     to `Ezagent.SliceChange`.
  2. The Publisher CONTRACT (`Ezagent.ActionSet.Publisher`) lives in
     `ezagent_domain_external_mirror/` for historical reasons (the
     V1 implementer + consumer were both in that domain). The
     lifecycle primitive applies to ANY future Publisher Kind, in
     ANY domain — placing it in core matches that scope.

  ## Topic shape

      esr:publisher:<self_uri>:lifecycle

  One topic per Publisher Kind URI. Subscribers receive
  `%EzagentActor.Signal{kind: :broadcast, payload: {:publisher_alive, %URI{}}}`
  envelopes (V5 use-side B2) when the publisher (re-)reaches `:ready`; the
  Kind.Server envelope clause unwraps them back to
  `{:publisher_alive, %URI{}}` for the subscriber's `handle_signal/2`.

  ## Producer wiring

  `Ezagent.ActionSet.Publisher.SessionImpl.on_ready/2` calls
  `broadcast_alive/1` AFTER `Ezagent.ReadyGate.mark_ready/1` has
  flipped this Session to `:ready` and the `PendingDelivery` buffer
  has been drained — every Session reaching `:ready` (boot OR
  snapshot-restore cold-spawn) emits one event. Idempotent:
  re-emitting on already-subscribed workers is a no-op (worker
  re-subscribe is idempotent at the publisher side because
  `ensure_monitored/2` deduplicates by pid).

  Task #49 codex r1 FAIL #6 (2026-05-27) moved this broadcast out
  of `handle_continue/3` and into the new `Behavior.on_ready/2`
  callback. The previous timing fired the broadcast BEFORE
  `ReadyGate.mark_ready/1`; peer-side `:call`-mode dispatches that
  reacted to the broadcast hit `{:error, :not_ready}` and silently
  dropped — exactly the cold-spawn case this primitive was built
  to fix.

  ## Consumer wiring

  `Ezagent.ActionSet.ExternalMirrorWorker.handle_continue/3` calls
  `subscribe/1` against the worker's `session_uri`. On receipt
  of `{:publisher_alive, ^session_uri}` it re-runs
  `subscribe_to_session_publisher/2` — re-attaching the (still-live)
  Worker pid as a subscriber in the (newly-restored, empty) Session
  publisher slice. Idempotent: the Session's `ensure_monitored/2`
  pid-dedup makes a duplicate subscribe a no-op. The Worker also
  carries a bounded defence-in-depth retry on `{:error, :not_ready}`
  (5 × 200ms).
  """

  require Logger

  @doc "Topic shape — `esr:publisher:<self_uri>:lifecycle`."
  @spec topic(URI.t() | String.t()) :: String.t()
  def topic(%URI{} = uri), do: topic(URI.to_string(uri))
  def topic(uri_str) when is_binary(uri_str), do: "esr:publisher:#{uri_str}:lifecycle"

  @doc """
  Subscribe the calling process to the lifecycle topic for `publisher_uri`.

  After subscribing, the caller will receive
  `%EzagentActor.Signal{kind: :broadcast, payload: {:publisher_alive, %URI{}}}`
  envelopes every time the Publisher Kind at `publisher_uri` reaches
  `:ready` (boot or cold-spawn rehydrate); the Kind.Server envelope clause
  unwraps them back to `{:publisher_alive, %URI{}}`.

  Returns `:ok`. Subscribing twice from the same pid is a no-op at the
  PubSub layer.
  """
  @spec subscribe(URI.t() | String.t()) :: :ok
  def subscribe(publisher_uri) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic(publisher_uri))
  end

  @doc "Inverse of `subscribe/1`."
  @spec unsubscribe(URI.t() | String.t()) :: :ok
  def unsubscribe(publisher_uri) do
    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic(publisher_uri))
  end

  @doc """
  Broadcast a `{:publisher_alive, publisher_uri}` event on the lifecycle
  topic for `publisher_uri`.

  Called by a Publisher Kind's `on_ready/2` callback AFTER
  `Ezagent.ReadyGate.mark_ready/1` has flipped the Kind to `:ready`
  (task #49 codex r1 FAIL #6 — see moduledoc). Failure is observable
  via Logger but non-fatal — the Kind has already booted; a PubSub
  outage shouldn't crash it.

  Returns `:ok`.
  """
  @spec broadcast_alive(URI.t()) :: :ok
  def broadcast_alive(%URI{} = publisher_uri) do
    # V5 use-side B2 — the broadcast rides the sanctioned transport
    # (`Signal.broadcast/2` → the `:ezagent_actor, :pubsub` config port,
    # wired to `EzagentCore.PubSub` at core boot, so it is the SAME server
    # `subscribe/1` below uses). The only subscriber is the
    # ExternalMirrorWorker Kind: it receives
    # `%EzagentActor.Signal{kind: :broadcast, payload: {:publisher_alive, uri}}`,
    # which the Kind.Server envelope clause unwraps back to
    # `{:publisher_alive, uri}` for its `handle_signal/2`.
    EzagentActor.Signal.broadcast(topic(publisher_uri), {:publisher_alive, publisher_uri})

    :ok
  rescue
    error ->
      Logger.warning(
        "Ezagent.PublisherLifecycle.broadcast_alive failed for " <>
          "#{inspect(publisher_uri)}: #{inspect(error)}"
      )

      :ok
  end
end
