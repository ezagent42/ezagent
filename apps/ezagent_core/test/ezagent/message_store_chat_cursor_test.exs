defmodule Ezagent.MessageStoreChatCursorTest do
  @moduledoc """
  P4-2 — the CHAT message cursor primitives that back the chat_feed `:pull`
  adapter's lower-bound join/replay protocol.

  The chat cursor is `inserted_at` (per Spec 5 P5-D8 — `id` is NOT monotonic),
  mirroring `committed_deliveries_since/2` but over the chat message ordering
  (chat has no settlement model). Two primitives:

    * `chat_visible_recent/2` — the N most-recent `:customer_visible` messages,
      ASCENDING (oldest→newest), for the snapshot window;
    * `chat_visible_since/2` — `:customer_visible` messages strictly after a
      `DateTime` cursor, ASCENDING, for the replay.

  BOTH filter per-message visibility (`:operator_only` excluded) and scope by
  session + workspace (defense-in-depth, mirroring the existing chat queries).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}

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

  defp write(session, text, opts) do
    visibility = Keyword.get(opts, :visibility, :customer_visible)
    at = Keyword.get(opts, :at, DateTime.utc_now())

    msg =
      Message.new(sender(), %{text: text, attachments: []},
        visibility: visibility,
        inserted_at: at
      )

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  describe "chat_visible_recent/2" do
    test "returns customer-visible messages ascending, bounded by limit", %{session: s} do
      t0 = ~U[2026-06-10 00:00:00.000000Z]
      _a = write(s, "a", at: DateTime.add(t0, 1, :second))
      _b = write(s, "b", at: DateTime.add(t0, 2, :second))
      _c = write(s, "c", at: DateTime.add(t0, 3, :second))

      texts = s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1))
      assert texts == ["a", "b", "c"]

      # limit keeps the MOST RECENT N, still ascending
      assert s |> MessageStore.chat_visible_recent(2) |> Enum.map(&text(&1)) == ["b", "c"]
    end

    test "excludes operator_only messages", %{session: s} do
      write(s, "public", at: ~U[2026-06-10 00:00:01.000000Z])
      write(s, "secret", visibility: :operator_only, at: ~U[2026-06-10 00:00:02.000000Z])

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["public"]
    end

    test "scopes by session", %{session: s, workspace: ws} do
      other = session_uri()
      :ok = Ezagent.WorkspaceRegistry.bind(other, ws)
      write(s, "mine", at: ~U[2026-06-10 00:00:01.000000Z])
      write(other, "theirs", at: ~U[2026-06-10 00:00:02.000000Z])

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["mine"]
    end
  end

  @epoch ~U[1970-01-01 00:00:00.000000Z]

  describe "chat_visible_since/2 (composite {inserted_at, message_id} keyset)" do
    test "returns customer-visible messages strictly after the cursor, ascending", %{session: s} do
      t0 = ~U[2026-06-10 00:00:00.000000Z]
      _a = write(s, "a", at: DateTime.add(t0, 1, :second))
      b = write(s, "b", at: DateTime.add(t0, 2, :second))
      _c = write(s, "c", at: DateTime.add(t0, 3, :second))

      since = {b.inserted_at, b.id}
      assert s |> MessageStore.chat_visible_since(since) |> Enum.map(&text(&1)) == ["c"]
    end

    test "with the epoch cursor returns ALL visible messages", %{session: s} do
      write(s, "a", at: ~U[2026-06-10 00:00:01.000000Z])
      write(s, "b", at: ~U[2026-06-10 00:00:02.000000Z])

      assert s |> MessageStore.chat_visible_since({@epoch, ""}) |> length() == 2
    end

    test "excludes operator_only messages", %{session: s} do
      write(s, "public", at: ~U[2026-06-10 00:00:01.000000Z])
      write(s, "secret", visibility: :operator_only, at: ~U[2026-06-10 00:00:02.000000Z])

      assert s
             |> MessageStore.chat_visible_since({@epoch, ""})
             |> Enum.map(&text(&1)) == ["public"]
    end

    test "TIED inserted_at: a cursor at {ts, id} still returns the SIBLING with the same ts but a higher id",
         %{session: s} do
      # Two messages share the SAME inserted_at. Sort their ids so the test is
      # deterministic about which is "lower" by message_id tie-break.
      at = ~U[2026-06-10 00:00:05.000000Z]
      m1 = write(s, "tied-one", at: at)
      m2 = write(s, "tied-two", at: at)
      [lo, hi] = Enum.sort_by([m1, m2], & &1.id)

      # A cursor sitting EXACTLY on the lower-id tied row must still surface the
      # higher-id tied row (the old inserted_at-only `> ts` predicate dropped it
      # forever once the cursor reached that timestamp).
      results = MessageStore.chat_visible_since(s, {at, lo.id})
      result_ids = Enum.map(results, & &1.id)

      assert hi.id in result_ids,
             "the tied sibling (same inserted_at, higher message_id) must not be skipped"

      refute lo.id in result_ids, "the cursor row itself is strictly excluded"
    end

    test "TIED inserted_at, ordered by [asc: inserted_at, asc: message_id]", %{session: s} do
      at = ~U[2026-06-10 00:00:05.000000Z]
      m1 = write(s, "tied-a", at: at)
      m2 = write(s, "tied-b", at: at)
      expected = Enum.sort_by([m1, m2], & &1.id) |> Enum.map(& &1.id)

      got = s |> MessageStore.chat_visible_since({@epoch, ""}) |> Enum.map(& &1.id)
      assert got == expected
    end
  end

  defp text(%Message{body: body}), do: Map.get(body, "text") || Map.get(body, :text)
end
