defmodule Ezagent.Behavior.Publisher do
  @moduledoc """
  A Kind that exposes a structured stream of its slice changes with
  history + cursor + replay semantics. Subscribers consume from a
  cursor (an opaque, monotonically increasing per-publisher value);
  the publisher retains a bounded window of recent events so a
  subscriber restarting can resume from a checkpoint.

  Implementing this behaviour on a Kind is HOW that Kind becomes
  mirrorable. The ExternalMirror Domain consumes Publishers; it
  does NOT directly observe raw SliceChange envelopes (that's an
  internal implementation detail of the Publisher).

  The Publisher behaviour is intentionally separated from raw
  Phoenix.PubSub: subscribers see a typed `%Ezagent.Publisher.Event{}`
  stream with cursor, not raw `:slice_changed` PubSub messages.
  This is what closes the P11 escape: every external-mirror worker
  subscribes via the Publisher API, not via `PubSub.subscribe`.

  ## V1 implementer

  Per SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §2.1 (Allen's option (a)): the first implementer is
  `Ezagent.Entity.Session` in `apps/ezagent_domain_session/`. The
  Session module declares `@behaviour Ezagent.Behavior.Publisher`
  and exposes the four callbacks as module functions that route
  through `Ezagent.Router.dispatch/1` against the session URI
  (subscribe/snapshot/history are dispatchable actions on the
  `Ezagent.Behavior.Publisher.SessionImpl` Kind-Behavior — caps gate
  via standard step 5.5).

  ## Subscriber message shape

  Subscribers receive `{:publisher_event, %Ezagent.Publisher.Event{}}`
  messages to their own pid. The publisher monitors the subscriber pid
  via `Process.monitor/1` and removes the subscription on `:DOWN`.

  ## Cursor semantics

  Per-publisher, monotonically increasing non-negative integer. Starts
  at 0; the first emitted event has cursor 1. Cursor is NEVER a
  wall-clock and never resets within a publisher's lifetime — even
  across snapshot restore (the cursor is part of the `:publisher` slice,
  which is persisted on change like the rest of the slice).
  """

  @typedoc """
  Cursor sentinel or concrete integer value.

  - `:latest` — subscribe to events with cursor > current; replay nothing
  - `:earliest` — replay the entire retained history then continue
  - integer — resume from that exact cursor (raise / `{:error, _}` if
    no longer retained)
  """
  @type cursor :: non_neg_integer() | :latest | :earliest

  @type event :: Ezagent.Publisher.Event.t()

  @doc """
  How many events to retain in-memory.

  V1 default: 100 events (per OQ-EM-A resolution — count-based, NOT
  wall-clock-based). Implementers MAY return a different constant; a
  future `:set_retention` action will let operators tune per-publisher
  (not in V1).
  """
  @callback history_retention() :: pos_integer()

  @doc """
  Subscribe `subscriber_pid` to this Publisher starting from `cursor`.

  - `:latest` — subscribe to future events only; the subscriber sees
    NOTHING until the NEXT slice change after subscription.
  - `:earliest` — replay the entire retained history (one
    `{:publisher_event, event}` message per retained ring entry, in
    cursor-ascending order) then continue with future events.
  - integer `n` — replay events with cursor in `(n, latest]`; if `n`
    is older than the oldest retained cursor, returns
    `{:error, :cursor_out_of_window}` (no messages sent).

  Returns `{:ok, current_cursor}` — the cursor pointing at the
  most-recent event in the publisher's ring at the moment of
  subscription (subscribers checkpoint this).
  """
  @callback subscribe_from(
              publisher_uri :: URI.t(),
              subscriber_pid :: pid(),
              cursor :: cursor()
            ) :: {:ok, cursor()} | {:error, term()}

  @doc """
  Snapshot the publisher's current cursor + current state without
  subscribing.

  Used by late-joining UI to render the "current" picture without
  receiving the stream of changes. The `state` field carries the
  publisher's user-visible state (for Session: the most recent event's
  payload; implementers MAY override).
  """
  @callback snapshot(publisher_uri :: URI.t()) ::
              {:ok, %{cursor: cursor(), state: term()}} | {:error, term()}

  @doc """
  Return events with cursor in `(from, to]` — `from` exclusive,
  `to` inclusive.

  - `from = :earliest` — start at the oldest retained event
  - `to = :latest` — end at the most-recent event
  - integer values must be non-negative and `to >= from`

  Returns `{:error, :cursor_out_of_window}` if `from` is older than
  the oldest retained cursor.
  """
  @callback history(
              publisher_uri :: URI.t(),
              from :: cursor(),
              to :: cursor()
            ) :: {:ok, [event()]} | {:error, :cursor_out_of_window | term()}
end
