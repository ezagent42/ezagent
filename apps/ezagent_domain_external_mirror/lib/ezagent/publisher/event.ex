defmodule Ezagent.Publisher.Event do
  @moduledoc """
  Typed event delivered to Publisher subscribers via
  `{:publisher_event, %Ezagent.Publisher.Event{}}` messages.

  Built from the underlying `Ezagent.SliceChange` envelope by the
  publishing Kind's slice-change handler. Each event is appended to
  the publisher's bounded ring (V1 default 100; see
  `Ezagent.ActionSet.Publisher.history_retention/0`) with a
  monotonically-increasing per-publisher cursor.

  ## Fields

  - `cursor` — monotonic integer per publisher; never resets. The
    first event after publisher init has cursor 1.
  - `publisher_uri` — URI of the Kind that produced the event
    (`session://...`, future `entity://agent/...`, etc).
  - `slice_key` — atom key of the slice that changed (e.g. `:chat`)
    as carried in the SliceChange envelope (PR-N1
    `apps/ezagent_core/lib/ezagent/slice_change.ex` §"Message shape").
  - `event_at` — wall-clock timestamp when the publisher's
    `handle_kind_message({:slice_changed, _}, _, _)` ran (NOT used as
    the cursor — cursor is monotonic integer; this is metadata only).
  - `payload` — opaque map carrying the slice diff. PR-EM-0 stores the
    SliceChange envelope's `:new_slice` directly (subscribers that
    care about the diff can also look at `:old_slice` if a future
    iteration adds it; PR-EM-0 keeps the payload minimal because the
    Worker layer in PR-EM-2 does its own diff inside
    `adapter.event_to_payload/1`).
  """

  @typedoc "Monotonically increasing per-publisher cursor — never resets within a publisher's lifetime."
  @type cursor :: non_neg_integer()

  @type t :: %__MODULE__{
          cursor: cursor(),
          publisher_uri: URI.t(),
          slice_key: atom(),
          event_at: DateTime.t(),
          payload: map()
        }

  @enforce_keys [:cursor, :publisher_uri, :slice_key, :event_at, :payload]
  defstruct [:cursor, :publisher_uri, :slice_key, :event_at, :payload]
end
