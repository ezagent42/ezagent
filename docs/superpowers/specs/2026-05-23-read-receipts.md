# SPEC — `Ezagent.Chat.ReadMarker` (chat domain)

**Status:** rev 1 · 2026-05-23
**Tier:** `apps/ezagent_domain_instance_message/`
**Predecessors:** SPEC `docs/superpowers/specs/2026-05-23-presence.md` (companion; Presence is for "connected", ReadMarker is for "consumed"), `Ezagent.MessageStore` (canonical message persistence)
**Decided per Allen 2026-05-23 06:50**: "delivery ≠ consumption — two semantics, two primitives". This SPEC implements the consumption side; delivery already arrives via Mailer / Presence.

## 1. Problem

Chat sessions have no record of "which messages has user X seen?" Symptoms:

- Session list cannot render `unread: N` badges
- Chat stream cannot render "✓✓" delivered/read markers next to messages
- Routing rules cannot trigger on "user hasn't read this in N minutes → escalate" patterns
- Audit cannot answer "did user X actually read the message at 14:32?"

Per Allen 2026-05-23 06:50: "已读回执 (read receipts) 实际上和发送之后 ack (delivery) 不是一回事". Three distinct semantic signals coexist:

| Signal | Meaning | Producer |
|---|---|---|
| **delivered** | Message reached the transport endpoint | Feishu HTTP POST → 200 OK; LV WS frame ack |
| **displayed** | UI rendered the message in viewport | LV intersection observer fires |
| **read** | Recipient explicitly confirmed (high confidence) | Feishu `message_read` event from their SDK |

All three are valuable; the table stores them with a `source` discriminator so consumers pick the appropriate signal.

## 2. Goal

Land `Ezagent.Chat.ReadMarker` schema + write API + read API in chat domain. Concretely:

- New `read_markers` SQLite table — `(workspace_uri, session_uri, user_uri, source) → (last_read_message_uri, observed_at)`
- `Ezagent.Chat.ReadMarker.mark/4` — transport plugins call this when their event fires
- `Ezagent.Chat.ReadMarker.unread_count/2(session_uri, user_uri)` — returns unread count using the HIGHEST-confidence source per `(session, user)`
- `Ezagent.Chat.ReadMarker.last_read/3(session_uri, user_uri, source)` — exact lookup by source
- PubSub broadcast on mark — `{:read_marker_updated, session_uri, user_uri, %{...}}` on `esr:session:<uri>:events` so chat LV updates badges live
- LV viewport-observer hook in PR-2 (separate); this SPEC ships the schema + write API only

Non-goals (V1):
- Cross-workspace read aggregation (each workspace's markers stay scoped)
- Historical replay of read events (markers store CURRENT state per source, not history)
- Conflict resolution between sources beyond "highest confidence wins" (e.g. delivered says msg #50 but read says msg #45 — show "5 unread" via the read source)

## 3. Schema

```sql
CREATE TABLE read_markers (
  id INTEGER PRIMARY KEY,

  workspace_uri TEXT NOT NULL,     -- P21 per-tenant
  session_uri TEXT NOT NULL,
  user_uri TEXT NOT NULL,
  source TEXT NOT NULL,            -- "delivered" | "displayed" | "read"

  last_read_message_uri TEXT NOT NULL,  -- FK-by-convention to messages.uri (no SQL FK; messages is the source of truth)
  observed_at DATETIME_USEC NOT NULL,

  inserted_at DATETIME_USEC NOT NULL,
  updated_at DATETIME_USEC NOT NULL
);

CREATE UNIQUE INDEX read_markers_unique
  ON read_markers (workspace_uri, session_uri, user_uri, source);

CREATE INDEX read_markers_by_session_user
  ON read_markers (session_uri, user_uri);
```

The composite-uniqueness on `(workspace, session, user, source)` is the key — `mark/4` is an upsert that bumps `last_read_message_uri` if the new one is later.

## 4. API

### 4.1 Write side

```elixir
defmodule Ezagent.Chat.ReadMarker do
  @moduledoc """
  Per-`(session, user, source)` read marker — "what's the latest
  message this user has SEEN via this source?".

  ## Sources

  - `:delivered` — transport (Feishu HTTP POST / LV WS) successfully
    sent the message envelope. LOW confidence: doesn't mean the human
    saw it.
  - `:displayed` — UI rendered the message in viewport. MEDIUM
    confidence: human's screen showed it, but they might not have
    looked.
  - `:read` — recipient explicitly confirmed (e.g. Feishu's
    `message_read` SDK event). HIGH confidence: human definitely saw.

  Consumers (LV unread badge, chat stream ✓✓ render) pick the
  highest-confidence source available for the user-session pair.

  See SPEC `docs/superpowers/specs/2026-05-23-read-receipts.md`.
  """

  @type source :: :delivered | :displayed | :read

  @doc """
  Record that `user_uri` has seen up to `message_uri` in `session_uri`
  via `source`. Upsert keyed on (workspace, session, user, source);
  bumps `last_read_message_uri` if `message_uri` is later than the
  current marker (compared by `messages.inserted_at`).

  Idempotent on repeat with same message_uri (no-op).
  Late updates (older message_uri than current marker) are ignored
  with `:already_ahead` (NOT an error — out-of-order events are
  normal).

  Broadcasts `{:read_marker_updated, session_uri, user_uri, %{source,
  last_read_message_uri, observed_at}}` on `esr:session:<uri>:events`
  on successful mark.
  """
  @spec mark(URI.t(), URI.t(), URI.t() | String.t(), source()) ::
          {:ok, :updated | :already_ahead} | {:error, term()}
  def mark(session_uri, user_uri, message_uri, source)
end
```

### 4.2 Read side

```elixir
  @doc """
  Returns unread message count for `(session, user)`. Uses the
  highest-confidence source available. Comparison: messages in this
  session whose `inserted_at > marker.observed_at` AND `uri !=
  marker.last_read_message_uri`.

  When no marker exists, returns the session's full message count
  (everything is unread).
  """
  @spec unread_count(URI.t(), URI.t()) :: non_neg_integer()
  def unread_count(session_uri, user_uri)

  @doc """
  Returns the last_read_message_uri for `(session, user, source)`,
  or nil if no marker exists.
  """
  @spec last_read(URI.t(), URI.t(), source()) :: URI.t() | nil
  def last_read(session_uri, user_uri, source)

  @doc """
  Returns all markers for `(session, user)` — useful for the LV chat
  stream to render per-message ✓ (delivered), ✓✓ (displayed), ✓✓✓
  (read) markers.
  """
  @spec list_for(URI.t(), URI.t()) :: %{source() => map()}
  def list_for(session_uri, user_uri)
```

## 5. Migration

`apps/ezagent_core/priv/repo/migrations/20260605000000_phase10_read_markers.exs`:

```elixir
defmodule EzagentCore.Repo.Migrations.Phase10ReadMarkers do
  use Ecto.Migration

  def change do
    create table(:read_markers) do
      add :workspace_uri, :string, null: false
      add :session_uri, :string, null: false
      add :user_uri, :string, null: false
      add :source, :string, null: false

      add :last_read_message_uri, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create unique_index(:read_markers,
             [:workspace_uri, :session_uri, :user_uri, :source],
             name: :read_markers_unique
           )

    create index(:read_markers, [:session_uri, :user_uri])
  end
end
```

## 6. Source confidence ranking

Hardcoded in `Ezagent.Chat.ReadMarker`:

```elixir
@confidence %{
  read: 3,
  displayed: 2,
  delivered: 1
}

defp highest_confidence_marker(markers_map) do
  markers_map
  |> Enum.max_by(fn {source, _} -> @confidence[source] end, fn -> nil end)
end
```

`unread_count/2` picks the highest-confidence source per (session, user). If only `:delivered` exists, unread is large (most messages are technically unread because we don't know if the human saw). If `:read` exists, unread is precise.

## 7. PubSub fanout

On successful `mark/4`, broadcast on the session's `:events` topic:

```elixir
Phoenix.PubSub.broadcast(
  EzagentCore.PubSub,
  Ezagent.Behavior.Chat.session_events_topic(session_uri),
  {:read_marker_updated, session_uri, user_uri,
   %{source: source, last_read_message_uri: msg_uri, observed_at: ts}}
)
```

This is the same topic Chat behavior uses for `:chat_message`, `:member_joined`, `:member_left`, and `:member_presence` (from PresenceFanout PR #267). LV chat stream subscribes once → handles all event types.

Per `check_invariants` rule (Phase 6 audit): `behavior/chat.ex` and `audit.ex` are allowlisted broadcast sites; the new ReadMarker module needs to join the allowlist. (Same rule allowance — view fan-out per §5.7.6.)

## 8. Files

| File | Action | LOC est |
|---|---|---|
| `apps/ezagent_core/priv/repo/migrations/20260605000000_phase10_read_markers.exs` | new | ~30 |
| `apps/ezagent_domain_instance_message/lib/ezagent/chat/read_marker.ex` | new | ~200 |
| `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` | edit (allowlist `read_marker.ex` PubSub broadcast) | +2 |
| `apps/ezagent_domain_instance_message/test/ezagent/chat/read_marker_test.exs` | new | ~150 (8 tests) |
| `docs/superpowers/specs/2026-05-23-read-receipts.md` | new (this file) | — |

Total: ~400 net LOC. Single PR.

## 9. Tests

`apps/ezagent_domain_instance_message/test/ezagent/chat/read_marker_test.exs`:

1. `mark/4` upserts; `last_read/3` returns the marker
2. Repeat `mark/4` with same (session, user, message, source) → `:already_ahead`
3. `mark/4` with NEWER message → updates marker
4. `mark/4` with OLDER message → `:already_ahead` (out-of-order events tolerated)
5. `unread_count/2` with no marker returns full session message count
6. `unread_count/2` with marker uses the highest-confidence source
7. `mark/4` broadcasts `:read_marker_updated` on session events topic (subscribe + assert_receive)
8. `list_for/2` returns all sources for a user-session pair

## 10. Rollout

PR-1 (this SPEC) ships schema + write API + tests. No transport calls `mark/4` yet — it's a no-op surface until follow-ups.

Follow-up PRs (separate):
- PR-2: LV viewport-observer hook + chat stream `:displayed` mark on intersection
- PR-3: Feishu adapter — `:delivered` mark on outbound POST 200 + `:read` mark if Feishu emits `message_read`
- PR-4: LV chat stream + session-list unread badges (consumes `:read_marker_updated` events)

## 11. Open questions for Allen

- **Source enum extensibility** — V1 hardcodes `:delivered | :displayed | :read`. Future transports might want `:notified` (push fired) or `:opened` (app opened to this session but no scroll). For V1 strict typing in `mark/4` signature; can extend later.
- **Cross-source upgrades** — if user has `:displayed` marker for message N and a `:read` event arrives for message M < N, do we DROP the `:displayed` marker since `:read` is higher confidence but ago? Going NO (keep both; consumers pick higher-confidence). Document.
- **TTL / retention** — no purging in V1. `read_markers` grows linearly with session-user pairs (bounded by membership). Acceptable for V1; revisit if a workspace has 1000+ users × 100+ sessions.
