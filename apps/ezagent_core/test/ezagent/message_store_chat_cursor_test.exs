defmodule Ezagent.MessageStoreChatCursorTest do
  @moduledoc """
  P4-2 — the CHAT message cursor primitives that back the chat_feed `:pull`
  adapter's lower-bound join/replay protocol.

  The chat cursor is the per-session ROUTE time `routed_at` (P4 codex r4 HIGH —
  NOT `messages.inserted_at` / the message creation time, which a cross-session
  relay carries unchanged into a target session and would strand the relayed
  message behind the cursor). It mirrors `committed_deliveries_since/2` but over
  the chat message ordering (chat has no settlement model). Two primitives:

    * `chat_visible_recent/2` — the N most-recent `:customer_visible` messages,
      ASCENDING (oldest→newest), for the snapshot window;
    * `chat_visible_since/2` — `:customer_visible` messages strictly after a
      `{routed_at, message_id}` cursor, ASCENDING, for the replay.

  BOTH filter per-message visibility (`:operator_only` excluded) and scope by
  session + workspace (defense-in-depth, mirroring the existing chat queries).

  ## Controlling order

  `routed_at` is a FRESH `now` captured at each `MessageStore.write/2`, so the
  natural way a real feed orders is WRITE ORDER — sequential writes give
  strictly increasing `routed_at`. These tests therefore control ordering by the
  ORDER they call `write/2`, NOT by crafting `msg.inserted_at` (which no longer
  drives the chat cursor). For deterministic TIED-`routed_at` coverage we insert
  the `message_routings` rows DIRECTLY via `Repo.insert/2` with a shared
  `routed_at`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageRouting, MessageStore}
  alias EzagentCore.Repo

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "chatcur-#{System.unique_integer([:positive])}")
  end

  defp sender, do: Ezagent.URI.entity(:team_alpha, :user, "alice")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace}
  end

  # WRITE a customer-visible chat message. `routed_at` is captured fresh at
  # write, so sequential calls produce strictly-increasing route timestamps —
  # the deterministic ordering driver for the chat cursor (NOT msg.inserted_at).
  defp write(session, text, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :customer_visible)

    msg = Message.new(sender(), %{text: text, attachments: []}, visibility: visibility)

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  # Insert a message + its routing row DIRECTLY so we can FORCE a shared
  # `routed_at` (sequential `write/2` can never tie). Returns the persisted
  # message id. Used only by the tied-`routed_at` coverage.
  defp insert_tied(session, workspace, text, routed_at) do
    id = "tied-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"

    {:ok, m} =
      Repo.insert(%Message{
        id: id,
        sender: sender(),
        body: %{"text" => text, "attachments" => []},
        visibility: :customer_visible,
        session_uri: session,
        workspace_uri: URI.to_string(workspace),
        inserted_at: DateTime.utc_now()
      })

    {:ok, _} =
      Repo.insert(%MessageRouting{
        message_id: m.id,
        session_uri: URI.to_string(session),
        inserted_at: m.inserted_at,
        routed_at: routed_at
      })

    m.id
  end

  describe "chat_visible_recent/2" do
    test "returns customer-visible messages ascending by write order, bounded by limit", %{
      session: s
    } do
      _a = write(s, "a")
      _b = write(s, "b")
      _c = write(s, "c")

      texts = s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1))
      assert texts == ["a", "b", "c"]

      # limit keeps the MOST RECENT N (latest by routed_at), still ascending
      assert s |> MessageStore.chat_visible_recent(2) |> Enum.map(&text(&1)) == ["b", "c"]
    end

    test "excludes operator_only messages", %{session: s} do
      write(s, "public")
      write(s, "secret", visibility: :operator_only)

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["public"]
    end

    test "scopes by session", %{session: s, workspace: ws} do
      other = session_uri()
      :ok = Ezagent.WorkspaceRegistry.bind(other, ws)
      write(s, "mine")
      write(other, "theirs")

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["mine"]
    end
  end

  @epoch ~U[1970-01-01 00:00:00.000000Z]

  describe "chat_visible_since/2 (composite {routed_at, message_id} keyset)" do
    test "returns customer-visible messages strictly after the cursor, ascending", %{session: s} do
      _a = write(s, "a")
      b = write(s, "b")
      _c = write(s, "c")

      # `routed_at` is the cursor column. write/2 returns the persisted Message
      # row (no routing join), so it carries no virtual routed_at — read the
      # cursor keyset off a chat query, where `select_merge` surfaces routed_at.
      b_row = s |> MessageStore.chat_visible_recent(10) |> Enum.find(&(&1.id == b.id))
      since = {b_row.routed_at, b_row.id}
      assert s |> MessageStore.chat_visible_since(since) |> Enum.map(&text(&1)) == ["c"]
    end

    test "with the epoch cursor returns ALL visible messages", %{session: s} do
      write(s, "a")
      write(s, "b")

      assert s |> MessageStore.chat_visible_since({@epoch, ""}) |> length() == 2
    end

    test "excludes operator_only messages", %{session: s} do
      write(s, "public")
      write(s, "secret", visibility: :operator_only)

      assert s
             |> MessageStore.chat_visible_since({@epoch, ""})
             |> Enum.map(&text(&1)) == ["public"]
    end

    test "TIED routed_at: a cursor at {ts, id} still returns the SIBLING with the same ts but a higher id",
         %{session: s, workspace: ws} do
      # Two messages share the SAME routed_at — forced via a direct routing
      # insert (sequential write/2 can never tie). Sort their ids so the test is
      # deterministic about which is "lower" by message_id tie-break.
      at = ~U[2026-06-10 00:00:05.000000Z]
      id1 = insert_tied(s, ws, "tied-one", at)
      id2 = insert_tied(s, ws, "tied-two", at)
      [lo_id, hi_id] = Enum.sort([id1, id2])

      # A cursor sitting EXACTLY on the lower-id tied row must still surface the
      # higher-id tied row (the old `routed_at`-only `> ts` predicate dropped it
      # forever once the cursor reached that timestamp).
      results = MessageStore.chat_visible_since(s, {at, lo_id})
      result_ids = Enum.map(results, & &1.id)

      assert hi_id in result_ids,
             "the tied sibling (same routed_at, higher message_id) must not be skipped"

      refute lo_id in result_ids, "the cursor row itself is strictly excluded"
    end

    test "TIED routed_at, ordered by [asc: routed_at, asc: message_id]", %{
      session: s,
      workspace: ws
    } do
      at = ~U[2026-06-10 00:00:05.000000Z]
      id1 = insert_tied(s, ws, "tied-a", at)
      id2 = insert_tied(s, ws, "tied-b", at)
      expected = Enum.sort([id1, id2])

      got = s |> MessageStore.chat_visible_since({@epoch, ""}) |> Enum.map(& &1.id)
      assert got == expected
    end
  end

  describe "multi-session routing (P4 codex r4): routed_at is the ROUTE-INTO-THIS-SESSION time" do
    test "the SAME message id routed into two sessions carries each session's OWN route time, NOT msg.inserted_at",
         %{session: s_a, workspace: ws_a} do
      # The PRODUCTION relay routes the SAME %Message{} (original, OLD
      # inserted_at) into a second session — it does NOT mutate inserted_at.
      old_inserted_at = ~U[2026-01-01 00:00:00.000000Z]

      m =
        Message.new(sender(), %{text: "shared", attachments: []},
          visibility: :customer_visible,
          inserted_at: old_inserted_at
        )

      {:ok, _} = MessageStore.write(m, s_a)

      # Route the SAME %Message{} (same id, same OLD inserted_at) into session B
      # — the realistic cross-session path. write/2 upserts the message row
      # (on_conflict :nothing → keeps the shared inserted_at) and inserts B's
      # routing with routed_at = a FRESH now.
      s_b = session_uri()
      ws_b = Ezagent.Capability.workspace_of(s_b)
      :ok = Ezagent.WorkspaceRegistry.bind(s_b, ws_b)
      {:ok, _} = MessageStore.write(m, s_b)

      [row_a] = MessageStore.chat_visible_recent(s_a, 10)
      [row_b] = MessageStore.chat_visible_recent(s_b, 10)

      assert row_a.id == m.id and row_b.id == m.id

      # Each session's routed_at is a fresh route timestamp — strictly AFTER the
      # message's OLD creation time, and B's is at-or-after A's (B routed later).
      assert DateTime.compare(row_a.routed_at, old_inserted_at) == :gt
      assert DateTime.compare(row_b.routed_at, old_inserted_at) == :gt
      assert DateTime.compare(row_b.routed_at, row_a.routed_at) in [:gt, :eq]

      # The shared `messages.inserted_at` stays the OLD value for BOTH (the
      # message row is shared) — proving routed_at ≠ messages.inserted_at, the
      # codex gap.
      assert row_a.inserted_at == old_inserted_at
      assert row_b.inserted_at == old_inserted_at

      _ = ws_a
    end

    test "chat_visible_since over a session uses the route time so a multi-routed id is not re-delivered forever",
         %{session: s_a} do
      old_inserted_at = ~U[2026-01-01 00:00:00.000000Z]

      m =
        Message.new(sender(), %{text: "shared", attachments: []},
          visibility: :customer_visible,
          inserted_at: old_inserted_at
        )

      {:ok, _} = MessageStore.write(m, s_a)

      s_b = session_uri()
      ws_b = Ezagent.Capability.workspace_of(s_b)
      :ok = Ezagent.WorkspaceRegistry.bind(s_b, ws_b)
      {:ok, _} = MessageStore.write(m, s_b)

      # B's cursor after rendering = B's route keyset {routed_at_b, id}. Replaying
      # from it returns NOTHING (idempotent — no infinite re-delivery).
      assert [%{routed_at: %DateTime{} = rb, id: id}] = MessageStore.chat_visible_recent(s_b, 10)
      assert [] = MessageStore.chat_visible_since(s_b, {rb, id})
    end
  end

  defp text(%Message{body: body}), do: Map.get(body, "text") || Map.get(body, :text)
end
